"""必须在独立netns内；实测nft/iptables只修改本服务规则。"""
import json
import os
from pathlib import Path
import sys
import tempfile
from unittest.mock import patch

if os.geteuid() != 0 or os.readlink('/proc/self/ns/net') == os.readlink('/proc/1/ns/net'):
    raise SystemExit('拒绝在主机网络空间运行防火墙测试')
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'app'))
import common
import sk5_firewall as fw

# Do not query the host firewalld daemon through a shared D-Bus socket.
original_which = fw.shutil.which
patcher = patch.object(fw.shutil, 'which', side_effect=lambda name: None if name == 'firewall-cmd' else original_which(name))
patcher.start()

with tempfile.TemporaryDirectory() as directory:
    fw.STATE = Path(directory) / 'state.json'
    c = {'port': 17777, 'udp_first': 20000, 'udp_last': 20999, 'interface': 'lo'}
    common.run('nft', 'add', 'table', 'inet', 'fixture')
    common.run('nft', 'add', 'chain', 'inet', 'fixture', 'input', '{ type filter hook input priority 0; policy drop; }')
    common.run('nft', 'add', 'rule', 'inet', 'fixture', 'input', 'udp', 'dport', '38162', 'accept', 'comment', '"existing-l2tp"')
    original = common.run('nft', '-j', 'list', 'chain', 'inet', 'fixture', 'input').stdout
    fw._apply(c, fresh=True)
    rules = common.run('nft', '-j', 'list', 'chain', 'inet', 'fixture', 'input').stdout
    assert 'sbm-sk5-tcp' in rules and 'sbm-sk5-udp' in rules and 'existing-l2tp' in rules
    c['port'] = 17778
    fw._apply(c)
    fw._clear()
    assert json.loads(common.run('nft', '-j', 'list', 'chain', 'inet', 'fixture', 'input').stdout) == json.loads(original)
    common.run('nft', 'delete', 'table', 'inet', 'fixture')
    common.run('iptables', '-A', 'INPUT', '-p', 'udp', '--dport', '38162', '-j', 'ACCEPT')
    original = common.run('iptables', '-S').stdout
    # iptables-nft itself creates native nft base chains. Select the explicit
    # iptables path here to test both implementations on this one runner.
    common.atomic(fw.STATE, json.dumps({'backend': 'iptables'}))
    fw._apply(c, fresh=True)
    c['port'] = 17779
    fw._apply(c)
    assert '17779' in common.run('iptables', '-S', 'SBM_SK5').stdout
    assert '17778' not in common.run('iptables', '-S', 'SBM_SK5').stdout
    fw._clear()
    assert common.run('iptables', '-S').stdout == original
print('PASS: real nft/iptables rules, port change, exact cleanup, existing L2TP rule preserved')
