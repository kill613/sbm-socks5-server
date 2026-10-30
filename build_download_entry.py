"""构建服务端首次下载入口，缺curl时使用系统签名源准备环境。"""
import argparse
import hashlib
import json
from pathlib import Path
ROOT = Path(__file__).resolve().parent

def normalized(path):
    return path.read_text(encoding='utf-8').replace('\r\n', '\n')

def sha(path):
    return hashlib.sha256(normalized(path).encode()).hexdigest()

def render_bootstrap(root, server=False):
    common = normalized(root / ('bootstrap.sh' if server else 'installer/common.sh'))
    helper = normalized(root / ('download.sh' if server else 'installer/download.sh'))
    installer = 'install.sh' if server else 'install-manager.sh'
    repo = 'sbm-socks5-server' if server else 'sing-box-hy2-multiline'
    guard = 'sbm_fresh_guard' if server else 'sbm_fresh_guard manager'
    deps = 'sbm_dependencies "$sbm_boot"' if server else 'sbm_dependencies manager "$sbm_boot"'
    # The outer subshell preserves terminal stdin for installation questions and
    # cannot exit the user's root shell when a download or package source fails.
    return '#!/usr/bin/env bash\n(\n'+common+helper+'\nsbm_os\n'+guard+'''
sbm_boot=$(mktemp -d /root/sbm-bootstrap-XXXXXX)
trap 'rm -f -- "$sbm_boot/package.sh"' EXIT
'''+deps+'\nsbm_download "https://raw.githubusercontent.com/kill613/'+repo+'/main/'+installer+'" "$sbm_boot/package.sh" '+sha(root / installer)+'''
bash -n "$sbm_boot/package.sh"
bash "$sbm_boot/package.sh"
)
'''

def install_command(root, server=False, accelerated=True):
    repo = 'sbm-socks5-server' if server else 'sing-box-hy2-multiline'
    script = 'install.sh' if server else 'install-manager.sh'
    target = 'sk5-install.sh' if server else 'sbm-install.sh'
    url = 'https://raw.githubusercontent.com/kill613/'+repo+'/main/'+script
    prefix = 'https://ghfast.top/' if accelerated else ''
    command = 'curl -fL --connect-timeout 8 --max-time 120 '+prefix+url+' -o '+target
    if accelerated:
        command += " && printf '%s  %s\\n' "+sha(root / script)+' '+target+' | sha256sum -c -'
    return command+' && bash '+target+'\n'

def documented_install(root, server=False):
    return ('<!-- bootstrap-command:start -->\n```bash\n'+install_command(root, server)+'```\n'
            '<!-- bootstrap-command:end -->\n\n'
            '<details>\n<summary>备用：GitHub官方直连安装</summary>\n\n```bash\n'
            +install_command(root, server, accelerated=False)+'```\n\n</details>')

if __name__ == '__main__':
    parser=argparse.ArgumentParser()
    parser.add_argument('--check', action='store_true')
    args=parser.parse_args()
    text=render_bootstrap(ROOT, server=True)
    target=ROOT / 'bootstrap-server.sh'
    if args.check:
        assert normalized(target)==text, '请重新生成bootstrap-server.sh'
    else:
        target.write_text(text, encoding='utf-8', newline='\n')
    readme=ROOT / 'README.md'
    old=normalized(readme)
    start=old.index('<!-- bootstrap-command:start -->')
    end=old.index('<!-- bootstrap-command:end -->',start)+len('<!-- bootstrap-command:end -->')
    if old[end:].startswith('\n\n<details>\n<summary>'):
        end=old.index('</details>',end)+len('</details>')
    updated=old[:start]+documented_install(ROOT,server=True)+old[end:]
    if args.check:
        assert old==updated, '请重新生成README中的下载入口'
    else:
        readme.write_text(updated,encoding='utf-8',newline='\n')

    manifest = json.dumps({'schema': 1, 'files': {'install.sh': sha(ROOT / 'install.sh')}}, indent=2)+'\n'
    manifest_path = ROOT / 'download-manifest.json'
    if args.check:
        assert normalized(manifest_path) == manifest
    else:
        manifest_path.write_text(manifest, encoding='utf-8', newline='\n')
