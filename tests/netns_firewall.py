"""必须在独立netns内；实测nft/iptables只修改本服务规则。"""
import json
import os
from pathlib import Path
import sys
import tempfile
import socket
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
fw.RELAY_UNIT = Path('/nonexistent-sk5-test/relay.service')
fw.RELAY_DROPIN = Path('/nonexistent-sk5-test/relay.d/91.conf')
fw.ORDER_DROPIN = Path('/nonexistent-sk5-test/sk5.d/91.conf')

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
    # Reproduce production: saved nft backend, iptables-nft ACCEPT rules, and a
    # second relay input chain that was rebuilt with policy DROP.
    common.run('ip', 'link', 'set', 'lo', 'up')
    def relay_table():
        common.run('nft', 'add', 'table', 'inet', 'sbm_relay')
        common.run('nft', 'add', 'chain', 'inet', 'sbm_relay', 'input',
                   '{ type filter hook input priority 0; policy drop; }')
        common.run('nft', 'add', 'rule', 'inet', 'sbm_relay', 'input',
                   'ct', 'state', 'established,related', 'accept')
        for protocol, port, tag in [('udp', '38162', 'existing-l2tp'),
                                    ('udp', '51820', 'existing-wireguard'),
                                    ('tcp', '22', 'existing-ssh')]:
            common.run('nft', 'add', 'rule', 'inet', 'sbm_relay', 'input',
                       protocol, 'dport', port, 'accept', 'comment', '"'+tag+'"')
    def traffic():
        with socket.socket() as server, socket.socket() as client:
            server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
            server.bind(('127.0.0.1', c['port'])); server.listen(1)
            client.settimeout(2)
            client.connect(server.getsockname())
            accepted, _ = server.accept()
            accepted.close()
        with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as server, \
                socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as client:
            server.settimeout(2); server.bind(('127.0.0.1', c['udp_first']))
            client.sendto(b'coexist-test', server.getsockname())
            assert server.recv(64) == b'coexist-test'
    relay_table()
    common.atomic(fw.STATE, json.dumps({'backend': 'nft'}))
    with socket.socket() as server, socket.socket() as client:
        server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        server.bind(('127.0.0.1', c['port'])); server.listen(1); client.settimeout(0.2)
        try:
            client.connect(server.getsockname())
        except socket.timeout:
            pass
        else:
            raise AssertionError('fixture did not reproduce DROP')
    fw._apply(c)
    traffic()
    fw._apply(c)
    rules = common.run('nft', '-j', 'list', 'chain', 'inet', 'sbm_relay', 'input').stdout
    assert rules.count('sbm-sk5-tcp') == 1 and rules.count('sbm-sk5-udp') == 1
    assert '"policy": "drop"' in rules
    assert all(tag in rules for tag in ('existing-l2tp', 'existing-wireguard', 'existing-ssh'))
    # Simulate relay ExecStart replacing its table, followed by our ExecStartPost.
    common.run('nft', 'delete', 'table', 'inet', 'sbm_relay')
    relay_table()
    fw._apply(c)
    traffic()
    fw._clear()
    rules = common.run('nft', '-j', 'list', 'chain', 'inet', 'sbm_relay', 'input').stdout
    assert 'sbm-sk5-' not in rules and 'existing-wireguard' in rules
print('PASS: nft/iptables coexistence, real TCP/UDP traffic through DROP chains, relay table rebuild, exact cleanup')
