"""独立SOCKS5服务端安装，不覆盖现有代理及L2TP。"""
import argparse
import getpass
import json
import os
from pathlib import Path
import re
import shutil
import sys

from common import HERE, asset, atomic, credential, extract, generated, ipv4, network, port_available, public_address, random_port, run, udp_occupied
import sk5
import sk5_firewall

MODULES = Path('/usr/local/libexec/sbm-sk5')
UNITS = Path('/etc/systemd/system')


def free_udp_range(occupied):
    for start in list(range(20000, 31000, 1000))+list(range(10000, 20000, 1000))+list(range(40000, 60001, 1000)):
        if not any(start <= p <= start+999 for p in occupied):
            return start, start+999
    raise ValueError('没有找到连续1000个空闲UDP端口，请先检查端口占用')


def settings(detected, public, port, username, password, first, last):
    return sk5.validate({'schema': 1, 'interface': detected['interface'],
        'local_ip': detected['ip'], 'public_ip': public, 'port': port,
        'udp_first': first, 'udp_last': last, 'users': [{'name': username, 'password': password}]})


def main():
    import grp
    import pwd
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--work', type=Path, required=True)
    args = parser.parse_args()
    if os.geteuid() != 0:
        raise SystemExit('请以root运行')
    for path in (sk5.ROOT, MODULES, Path('/usr/local/bin/sk5'), Path('/etc/profile.d/sbm-sk5.sh'),
                 UNITS / 'sbm-sk5.service', UNITS / 'sbm-sk5-firewall.service'):
        if path.exists() or path.is_symlink():
            raise SystemExit('路径已占用，拒绝覆盖：'+str(path))
    try:
        pwd.getpwnam('sbm-sk5')
    except KeyError:
        pass
    else:
        raise SystemExit('同名系统账户已存在，请先核对归属，未修改')
    try:
        grp.getgrnam('sbm-sk5')
    except KeyError:
        pass
    else:
        raise SystemExit('同名系统组已存在，请先核对归属，未修改')
    work = args.work.resolve()
    if not work.is_dir() or work.is_symlink() or work.stat().st_mode & 0o077:
        raise SystemExit('安装记录目录必须仅root可访问')
    detected = network()
    print('自动识别网卡：'+detected['interface']+'；本机IPv4：'+detected['ip'])
    auto_public = public_address(detected['ip'])
    print('自动识别公网IPv4：'+(auto_public or '未能确定，请手动填写'))
    public = ipv4(input('公网IPv4（回车使用识别结果'+(' '+auto_public if auto_public else '')+'）：').strip() or auto_public, public=True)
    occupied = udp_occupied()
    first, last = free_udp_range(occupied)
    raw = input('固定UDP中继范围 ['+str(first)+'-'+str(last)+']：').strip()
    if raw:
        match = re.fullmatch(r'([0-9]+)-([0-9]+)', raw)
        if not match:
            raise ValueError('UDP范围格式应为起始端口-结束端口')
        first, last = map(int, match.groups())
    if any(first <= p <= last for p in occupied):
        raise ValueError('所选UDP范围含其他服务端口，请选择未占用范围；不停止现有服务')
    raw = input('SOCKS5 TCP端口（回车自动生成空闲五位端口）：').strip()
    port = int(raw) if raw else random_port((first, last))
    if not port_available(port):
        raise ValueError('TCP端口已占用或无效；不停止现有服务')
    username = credential(input('账户（回车自动生成8位）：').strip() or generated(8), '账户')
    password = credential(getpass.getpass('密码（回车自动生成18位，隐藏输入）：') or generated(18), '密码', 128)
    config = settings(detected, public, port, username, password, first, last)
    archive = asset('3proxy-source', work)
    source = extract(archive, work / 'source')
    makefiles = list(source.glob('*/Makefile.Linux'))
    if len(makefiles) != 1:
        raise ValueError('服务端源码结构异常')
    source = makefiles[0].parent
    from core_patch import apply as apply_core_patch
    apply_core_patch(source)
    print('正在编译3proxy 1.0.2及严格UDP端口范围修正；不调用上游系统安装脚本。', flush=True)
    build = run('make', '-f', 'Makefile.Linux', '-j'+str(min(os.cpu_count() or 1, 4)),
        'PLUGINS=', 'OPENSSL_CHECK=false', 'WOLFSSL_CHECK=false', 'PCRE_CHECK=false',
        'PAM_CHECK=false', 'HTTPSRV=false', cwd=str(source), timeout=600, check=False)
    atomic(work / 'build.log', build.stdout+'\n'+build.stderr)
    if build.returncode or not (source / 'bin/3proxy').is_file():
        raise RuntimeError('源码编译未通过；详细记录：'+str(work / 'build.log'))
    rollback = ('#!/bin/sh\nset -eu\n'
        'systemctl disable --now sbm-sk5.service sbm-sk5-firewall.service || true\n'
        '/usr/local/bin/sk5 firewall-clear || true\n'
        'echo "仅停止本次SOCKS5与移除专属规则；配置保留，未操作GOST或L2TP。"\n')
    atomic(work / 'rollback.sh', rollback, 0o700)
    try:
        shell = '/usr/sbin/nologin' if Path('/usr/sbin/nologin').exists() else '/sbin/nologin'
        run('useradd', '--system', '--user-group', '--no-create-home', '--shell', shell, 'sbm-sk5')
        group = grp.getgrnam('sbm-sk5').gr_gid
        if not MODULES.parent.exists():
            MODULES.parent.mkdir(mode=0o755)
            MODULES.parent.chmod(0o755)
        if not MODULES.parent.stat().st_mode & 0o001:
            raise ValueError('现有libexec目录不能由服务账户访问，请先核对权限')
        MODULES.mkdir(mode=0o755)
        MODULES.chmod(0o755)
        sk5.ROOT.mkdir(mode=0o750)
        sk5.ROOT.chmod(0o750)
        os.chown(str(sk5.ROOT), 0, group)
        for name in ('common.py', 'sk5.py', 'sk5_firewall.py', 'release-lock.json'):
            atomic(MODULES / name, (HERE / name).read_bytes(), 0o750 if name.endswith('.py') else 0o644)
        shutil.copy2(source / 'bin/3proxy', MODULES / '3proxy')
        (MODULES / '3proxy').chmod(0o755)
        for name in ('copying', 'COPYING', 'LICENSE'):
            if (source / name).is_file():
                atomic(MODULES / ('3proxy-'+name), (source / name).read_bytes(), 0o644)
        atomic('/usr/local/bin/sk5', '#!/bin/sh\nexport PYTHONIOENCODING=UTF-8\nexec python3 /usr/local/libexec/sbm-sk5/sk5.py "$@"\n', 0o755)
        atomic('/etc/profile.d/sbm-sk5.sh', 'case ":$PATH:" in *:/usr/local/bin:*) ;; *) export PATH="/usr/local/bin:$PATH";; esac\n', 0o644)
        sk5.persist(config)
        sk5_firewall.apply(config, fresh=True)
        firewall_unit = ('[Unit]\nDescription=SOCKS5专属端口放行\nWants=network-online.target\n'
            'After=network-online.target firewalld.service nftables.service ufw.service netfilter-persistent.service\n'
            '[Service]\nType=oneshot\nExecStart=/usr/local/bin/sk5 firewall\n'
            'ExecStop=/usr/local/bin/sk5 firewall-clear\nRemainAfterExit=yes\nUMask=0077\n'
            '[Install]\nWantedBy=multi-user.target\n')
        server_unit = ('[Unit]\nDescription=配套认证SOCKS5服务端\nRequires=sbm-sk5-firewall.service\n'
            'After=network-online.target sbm-sk5-firewall.service\nWants=network-online.target\n'
            '[Service]\nType=simple\nUser=sbm-sk5\nGroup=sbm-sk5\n'
            'ExecStart=/usr/local/libexec/sbm-sk5/3proxy /etc/sbm-sk5/3proxy.cfg\n'
            'Restart=on-failure\nRestartSec=3\nUMask=0077\nLimitNOFILE=65536\n'
            'NoNewPrivileges=true\nCapabilityBoundingSet=\nProtectSystem=full\nProtectHome=true\n'
            'PrivateTmp=true\nRestrictAddressFamilies=AF_INET AF_UNIX\n'
            '[Install]\nWantedBy=multi-user.target\n')
        atomic(UNITS / 'sbm-sk5-firewall.service', firewall_unit, 0o644)
        atomic(UNITS / 'sbm-sk5.service', server_unit, 0o644)
        run('systemctl', 'daemon-reload')
        run('systemctl', 'enable', '--now', 'sbm-sk5-firewall.service')
        run('systemctl', 'enable', '--now', sk5.UNIT)
        sk5.health(config, timeout=15)
        report = '公网IPv4：'+public+'\n内网IPv4：'+detected['ip']+'\nTCP端口：'+str(port)+'\n'
        report += '账户：'+username+'\n密码：'+password+'\nUDP中继范围：'+str(first)+'-'+str(last)+'\n'
        report += 'SOCKS5链接：socks5://'+username+':'+password+'@'+public+':'+str(port)+'\n'
        atomic(work / 'access.txt', report)
        print('\n安装完成，服务已立即启动并设置开机自启。\n'+report)
        print('本机认证及UDP公网地址通告自检通过，不代表云端公网UDP已经端到端验收。')
        print('请在云安全组放行TCP '+str(port)+'、UDP '+str(first)+'-'+str(last)+'，保持端口号一一映射。')
        print('已有GOST、L2TP未停止，系统全局转发、网卡地址及原防火墙策略未清空。')
        print('管理命令：\n sk5 info\n sk5 status\n sk5 users\n sk5 users --show-passwords\n sk5 add-user [账户]\n sk5 del-user 账户\n sk5 passwd 账户\n sk5 port 新端口\n sk5 public-ip 新公网IP\n sk5 udp-range 起始端口-结束端口\n sk5 start / stop / restart\n sk5 check\n sk5 firewall')
        print('命令已加入/usr/local/bin/sk5；凭据与回退记录：'+str(work))
    except Exception:
        run('/bin/sh', str(work / 'rollback.sh'), check=False)
        print('安装未完成，本次配置保留供检查：'+str(work), file=sys.stderr)
        raise


if __name__ == '__main__':
    try:
        main()
    except Exception as exc:
        print('安装失败：'+str(exc), file=sys.stderr)
        sys.exit(1)
