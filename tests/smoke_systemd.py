"""仅限明确标记的一次性Actions VM：执行真正的单文件入口。"""
import os
from pathlib import Path
import socket
import subprocess
import sys
from unittest.mock import patch

if os.environ.get('GITHUB_ACTIONS') != 'true' or os.environ.get('SBM_CI_DISPOSABLE') != '1' or os.geteuid() != 0:
    raise SystemExit('仅允许一次性GitHub Actions root虚拟机')
ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'app'))
import common
import sk5

before = Path('/proc/sys/net/ipv4/ip_forward').read_text()
with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as sentinel:
    sentinel.bind(('0.0.0.0', 38162))
    if '--verify-only' not in sys.argv:
        result = subprocess.run(['bash', str(ROOT / 'install.sh')],
            input='223.5.5.5\n\n\n\nAbcdefGh123456789p\n',
            stdout=subprocess.PIPE, stderr=subprocess.STDOUT, universal_newlines=True, timeout=1200)
        print(result.stdout)
        assert result.returncode == 0, '单文件安装失败'
    config = common.private_json(sk5.ROOT / 'settings.json')
    assert len(config['users'][0]['name']) == 8
    assert len(str(config['port'])) == 5
    def cli(*args):
        with patch.object(sys, 'argv', ['sk5']+list(args)), \
             patch.object(sk5.getpass, 'getpass', return_value='AbcdefGh123456789q'):
            sk5.main()
    cli('add-user', 'FixtureUser2')
    cli('users')
    cli('passwd', 'FixtureUser2')
    cli('del-user', 'FixtureUser2')
    cli('port', str(common.random_port((config['udp_first'], config['udp_last']))))
    cli('check')
    cli('stop')
    cli('public-ip', '119.29.29.29')
    assert common.run('systemctl', 'is-active', sk5.UNIT, check=False).returncode != 0
    cli('start')
    cli('check')
    assert sentinel.getsockname()[1] == 38162
    assert Path('/proc/sys/net/ipv4/ip_forward').read_text() == before
    for unit in ('sbm-sk5.service', 'sbm-sk5-firewall.service'):
        common.run('systemctl', 'is-enabled', '--quiet', unit)
print('PASS: 独立单文件安装、清华依赖、真实服务自启、账户/端口管理、停止状态保持、保留L2TP端口')
