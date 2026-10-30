"""配套SOCKS5管理工具；仅管理sbm-sk5，不操作GOST、L2TP或系统账户密码。"""
import argparse
import copy
import getpass
import ipaddress
import json
import os
import re
from pathlib import Path
import socket
import struct
import sys
import tempfile
import time

from common import atomic, credential, generated, ipv4, port_available, private_json, run

ROOT = Path('/etc/sbm-sk5')
UNIT = 'sbm-sk5.service'


def validate(config):
    if config.get('schema') != 1:
        raise ValueError('配置版本无效')
    for key in ('local_ip', 'public_ip'):
        ipv4(config[key], public=key == 'public_ip')
    if not isinstance(config.get('interface'), str) or not re.fullmatch(r'[A-Za-z0-9_.:-]{1,15}', config['interface']):
        raise ValueError('网卡名称无效')
    for key in ('port', 'udp_first', 'udp_last'):
        if type(config[key]) is not int or not 1024 <= config[key] <= 65535:
            raise ValueError('端口必须在1024至65535之间')
    if config['udp_first'] > config['udp_last'] or config['udp_last']-config['udp_first'] > 4095:
        raise ValueError('UDP端口范围须递增且最多4096个端口')
    if config['udp_first'] <= config['port'] <= config['udp_last']:
        raise ValueError('TCP入口端口不能位于UDP中继范围内')
    users = config.get('users')
    if not isinstance(users, list) or not 1 <= len(users) <= 128:
        raise ValueError('必须保留1至128个账户，不能删除最后一个账户')
    names = set()
    for user in users:
        name = credential(user['name'], '账户', 64)
        credential(user['password'], '密码', 128)
        if name in names:
            raise ValueError('账户重复')
        names.add(name)
    return config


def render(config):
    validate(config)
    users = ' '.join(u['name']+':CL:'+u['password'] for u in config['users'])
    allowed = ','.join(u['name'] for u in config['users'])
    return ('# 由sk5管理；认证密码仅存于受限配置，禁止手动追加命令。\n'
        'maxconn 1024\n'
        'nserver 223.5.5.5/tcp\nnserver 119.29.29.29/tcp\nnscache 65536\n'
        'timeouts 1 5 30 60 180 1800 15 60 15 5\n'
        'auth strong\nusers '+users+'\n'
        'allow '+allowed+' * * * CONNECT,UDPASSOC\n'
        'parent 1000 intport 0.0.0.0 '+str(config['udp_first'])+'-'+str(config['udp_last'])+'\n'
        'socks -4 -u2 -p'+str(config['port'])+' -i0.0.0.0 -e'+config['local_ip']+' -Ni'+config['public_ip']+'\n'
        'flush\n')


def persist(config):
    import grp
    validate(config)
    atomic(ROOT / 'settings.json', json.dumps(config, ensure_ascii=False, indent=2)+'\n')
    path = ROOT / '3proxy.cfg'
    atomic(path, render(config), 0o640)
    os.chown(str(path), 0, grp.getgrnam('sbm-sk5').gr_gid)


def read_exact(sock, count):
    data = b''
    while len(data) < count:
        part = sock.recv(count-len(data))
        if not part:
            raise RuntimeError('SOCKS5连接提前关闭')
        data += part
    return data


def auth(sock, user):
    sock.sendall(b'\x05\x01\x02')
    if read_exact(sock, 2) != b'\x05\x02':
        raise RuntimeError('服务端未要求用户名密码认证')
    name, password = user['name'].encode(), user['password'].encode()
    sock.sendall(b'\x01'+bytes([len(name)])+name+bytes([len(password)])+password)
    if read_exact(sock, 2) != b'\x01\x00':
        raise RuntimeError('本机认证自检失败')


def reply(sock):
    version, status, reserved, atyp = read_exact(sock, 4)
    if (version, status, reserved) != (5, 0, 0):
        raise RuntimeError('SOCKS5请求未成功，状态码：'+str(status))
    if atyp == 1:
        address = socket.inet_ntop(socket.AF_INET, read_exact(sock, 4))
    elif atyp == 4:
        address = socket.inet_ntop(socket.AF_INET6, read_exact(sock, 16))
        ip = ipaddress.ip_address(address)
        address = str(ip.ipv4_mapped or ip)
    elif atyp == 3:
        address = read_exact(sock, read_exact(sock, 1)[0]).decode('ascii')
    else:
        raise RuntimeError('中继地址类型异常')
    return address, struct.unpack('!H', read_exact(sock, 2))[0]


def health(config, timeout=10):
    deadline = time.monotonic()+timeout
    reason = '服务尚未就绪'
    while time.monotonic() < deadline:
        try:
            with socket.create_connection(('127.0.0.1', config['port']), timeout=2) as sock:
                sock.settimeout(2)
                auth(sock, config['users'][0])
                sock.sendall(b'\x05\x03\x00\x01'+b'\x00'*6)
                host, port = reply(sock)
                if host != config['public_ip'] or not config['udp_first'] <= port <= config['udp_last']:
                    raise RuntimeError('UDP通告地址或端口不符合配置：'+host+':'+str(port))
                return host, port
        except (OSError, RuntimeError) as exc:
            reason = str(exc)
            time.sleep(0.3)
    raise RuntimeError('本机认证及UDP公网通告自检未通过：'+reason)


def change(previous, proposed):
    import sk5_firewall
    validate(proposed)
    history = ROOT / 'backups'
    history.mkdir(mode=0o700, exist_ok=True)
    backup = Path(tempfile.mkdtemp(prefix='change-', dir=str(history)))
    atomic(backup / 'settings.json', json.dumps(previous, ensure_ascii=False, indent=2)+'\n')
    atomic(backup / '3proxy.cfg', (ROOT / '3proxy.cfg').read_bytes())
    state = run('systemctl', 'show', UNIT, '-p', 'ActiveState', '--value').stdout.strip()
    if state not in ('active', 'inactive', 'failed'):
        raise ValueError('服务正在启动或停止，请稍后再修改')
    was_active = state == 'active'
    try:
        persist(proposed)
        sk5_firewall.apply(proposed)
        if was_active:
            run('systemctl', 'reset-failed', UNIT)
            run('systemctl', 'restart', UNIT)
            health(proposed)
    except Exception:
        try:
            persist(previous)
            sk5_firewall.apply(previous)
            if was_active:
                run('systemctl', 'reset-failed', UNIT)
                run('systemctl', 'restart', UNIT)
                health(previous)
        except Exception:
            raise RuntimeError('修改失败，自动恢复也未完成，请检查备份：'+str(backup)) from None
        raise RuntimeError('修改失败，已恢复原配置与服务；备份：'+str(backup)) from None
    print('配置已保存；'+('本SOCKS5服务已重启。' if was_active else '服务保持原停止状态。')+'备份：'+str(backup))


def info(config):
    print('SOCKS5公网IPv4：'+config['public_ip'])
    print('服务器内网IPv4：'+config['local_ip']+'（'+config['interface']+'）')
    print('TCP入口端口：'+str(config['port']))
    print('UDP中继端口范围：'+str(config['udp_first'])+'-'+str(config['udp_last']))
    print('账户数量：'+str(len(config['users'])))
    print('云安全组需放行上述TCP入口和完整UDP中继范围；仅放行TCP同号UDP端口不够。')


def main():
    import fcntl
    if os.geteuid() != 0:
        raise SystemExit('请以root运行sk5管理命令')
    parser = argparse.ArgumentParser(description='配套SOCKS5管理；不会操作现有GOST或L2TP')
    sub = parser.add_subparsers(dest='action')
    for name, text in [('info', '查看服务信息'), ('status', '查看状态'), ('start', '启动'),
                       ('stop', '停止'), ('restart', '重启'), ('check', '认证与UDP通告自检'),
                       ('firewall', '恢复本服务防火墙规则'), ('firewall-clear', '清理本服务专属规则')]:
        sub.add_parser(name, help=text)
    users = sub.add_parser('users', help='查看已有账户；默认不显示密码')
    users.add_argument('--show-passwords', action='store_true', help='在本root终端显示密码')
    add = sub.add_parser('add-user', help='添加账户；不填写则自动生成')
    add.add_argument('username', nargs='?', help='账户名，留空生成8位')
    delete = sub.add_parser('del-user', help='删除指定账户，不能删除最后一个')
    delete.add_argument('username')
    password = sub.add_parser('passwd', help='修改指定账户密码')
    password.add_argument('username')
    port = sub.add_parser('port', help='修改TCP端口')
    port.add_argument('number', type=int)
    public = sub.add_parser('public-ip', help='修改UDP中继公网通告地址')
    public.add_argument('address')
    udp = sub.add_parser('udp-range', help='修改固定UDP中继端口范围')
    udp.add_argument('range', help='例如40000-40999')
    args = parser.parse_args()
    if not args.action:
        parser.print_help()
        return
    if args.action in ('firewall', 'firewall-clear'):
        import sk5_firewall
        config = validate(private_json(ROOT / 'settings.json'))
        if args.action == 'firewall':
            sk5_firewall.apply(config)
        else:
            sk5_firewall.clear()
        print('仅更新本服务专属防火墙规则。')
        return
    with open('/run/lock/sbm-sk5.lock', 'a') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        config = validate(private_json(ROOT / 'settings.json'))
        proposed = copy.deepcopy(config)
        if args.action == 'info':
            info(config)
        elif args.action == 'users':
            for user in config['users']:
                print(user['name']+('  '+user['password'] if args.show_passwords else ''))
        elif args.action == 'status':
            result = run('systemctl', 'show', UNIT, '-p', 'ActiveState', '-p', 'SubState', '-p', 'UnitFileState')
            print(result.stdout.strip())
            info(config)
        elif args.action in ('start', 'stop', 'restart'):
            if args.action != 'stop':
                run('systemctl', 'reset-failed', UNIT)
            run('systemctl', args.action, UNIT)
            if args.action != 'stop':
                health(config)
            print('操作已返回，使用sk5 status核对状态。')
        elif args.action == 'check':
            host, relay = health(config)
            print('本机认证通过；UDP通告地址：'+host+':'+str(relay))
            print('这是本机自检，公网UDP仍需在远端完成真实数据测试。')
        else:
            if args.action == 'add-user':
                name = args.username or generated(8)
                password = getpass.getpass('密码（回车生成18位）：') or generated(18)
                proposed['users'].append({'name': name, 'password': password})
            elif args.action == 'del-user':
                if not any(u['name'] == args.username for u in config['users']):
                    raise ValueError('账户不存在')
                proposed['users'] = [u for u in config['users'] if u['name'] != args.username]
            elif args.action == 'passwd':
                target = next((u for u in proposed['users'] if u['name'] == args.username), None)
                if target is None:
                    raise ValueError('账户不存在')
                target['password'] = getpass.getpass('新密码（回车生成18位）：') or generated(18)
            elif args.action == 'port':
                if args.number != config['port'] and not port_available(args.number):
                    raise ValueError('端口已占用或无效')
                proposed['port'] = args.number
            elif args.action == 'public-ip':
                proposed['public_ip'] = ipv4(args.address, public=True)
            elif args.action == 'udp-range':
                bounds = args.range.split('-')
                if len(bounds) != 2:
                    raise ValueError('范围格式须为起始端口-结束端口')
                proposed['udp_first'], proposed['udp_last'] = map(int, bounds)
                validate(proposed)
                from common import udp_occupied
                occupied = udp_occupied()
                if any(p in occupied and not config['udp_first'] <= p <= config['udp_last']
                       for p in range(proposed['udp_first'], proposed['udp_last']+1)):
                    raise ValueError('新UDP范围包含其他服务占用端口，请另选范围')
            change(config, proposed)
            if args.action == 'add-user':
                print('账户：'+name+'\n密码：'+password)
            elif args.action == 'passwd':
                print('账户：'+args.username+'\n新密码：'+target['password'])
            if args.action in ('port', 'udp-range', 'public-ip'):
                info(proposed)


if __name__ == '__main__':
    try:
        main()
    except (ValueError, RuntimeError, OSError) as exc:
        print('操作失败：'+str(exc), file=sys.stderr)
        sys.exit(1)
