"""仅添加/更新本服务端口；不清空全局防火墙、不重启防火墙或L2TP。"""
import json
import re
import shlex
import shutil
from pathlib import Path

from common import atomic, run

STATE = Path('/etc/sbm-sk5/firewall-state.json')
COMMENTS = ('sbm-sk5-tcp', 'sbm-sk5-udp')
CHAIN = 'SBM_SK5'


def command_ok(*args):
    return run(*args, check=False).returncode == 0


def nft_rules():
    if not shutil.which('nft'):
        return []
    result = run('nft', '-j', '-a', 'list', 'ruleset', check=False)
    return json.loads(result.stdout).get('nftables', []) if result.returncode == 0 else []


def native_chains(items):
    result = []
    for item in items:
        c = item.get('chain', {})
        if c.get('family') in ('ip', 'inet') and c.get('hook') == 'input':
            if not all(re.fullmatch(r'[A-Za-z0-9_-]+', c.get(k, '')) for k in ('table', 'name')):
                raise ValueError('现有nft输入链名称需人工核对，未修改')
            result.append((c['family'], c['table'], c['name']))
    return result


def nft_clear(items):
    for item in items:
        rule = item.get('rule', {})
        if rule.get('comment') in COMMENTS and rule.get('family') in ('ip', 'inet'):
            run('nft', 'delete', 'rule', rule['family'], rule['table'], rule['chain'],
                'handle', str(int(rule['handle'])))


def state_read():
    if not STATE.exists():
        return None
    from common import private_json
    return private_json(STATE)


def _apply(settings, fresh=False):
    old = state_read()
    port = str(settings['port'])
    udp = str(settings['udp_first'])+'-'+str(settings['udp_last'])
    desired = [port+'/tcp', udp+'/udp']
    if old:
        backend = old['backend']
    elif shutil.which('firewall-cmd') and command_ok('firewall-cmd', '--state'):
        backend = 'firewalld'
    elif native_chains(nft_rules()):
        backend = 'nft'
    else:
        backend = 'iptables'
    if backend == 'firewalld':
        zone = old.get('zone') if old else run('firewall-cmd', '--get-zone-of-interface='+settings['interface'], check=False).stdout.strip()
        if not zone or zone == 'no zone':
            zone = run('firewall-cmd', '--get-default-zone').stdout.strip()
        if not re.fullmatch(r'[A-Za-z0-9_-]+', zone):
            raise ValueError('无法确定firewalld区域')
        prefix = ['firewall-cmd', '--zone='+zone]
        entries = dict((e['port'], e) for e in (old or {}).get('entries', []))
        # Record ownership before operations so interrupted changes can be retried.
        for value in desired:
            if value not in entries:
                entries[value] = {'port': value,
                    'runtime': not command_ok(*(prefix+['--query-port='+value])),
                    'permanent': not command_ok(*(prefix+['--permanent', '--query-port='+value]))}
        atomic(STATE, json.dumps({'backend': backend, 'zone': zone, 'entries': list(entries.values())}))
        for value, entry in list(entries.items()):
            for kind, flags in (('runtime', []), ('permanent', ['--permanent'])):
                if value in desired:
                    run(*(prefix+flags+['--add-port='+value]))
                elif entry[kind]:
                    run(*(prefix+flags+['--remove-port='+value]), check=False)
            if value not in desired:
                del entries[value]
        result = {'backend': backend, 'zone': zone, 'entries': list(entries.values())}
    elif backend == 'nft':
        items = nft_rules()
        chains = native_chains(items)
        if not chains:
            raise ValueError('原nft输入链已变化，请核对防火墙后重试')
        if fresh and not old and any(i.get('rule', {}).get('comment') in COMMENTS for i in items):
            raise ValueError('发现同名但非本安装记录的防火墙规则，拒绝覆盖')
        atomic(STATE, json.dumps({'backend': backend}))
        nft_clear(items)
        for family, table, chain in chains:
            for protocol, value, comment in (('tcp', port, COMMENTS[0]), ('udp', udp, COMMENTS[1])):
                run('nft', 'insert', 'rule', family, table, chain, 'ip', 'protocol', protocol,
                    protocol, 'dport', value, 'counter', 'accept', 'comment', '"'+comment+'"')
        result = {'backend': backend}
    elif backend == 'iptables':
        if command_ok('iptables', '-n', '-L', CHAIN):
            if not command_ok('iptables', '-C', CHAIN, '-m', 'comment', '--comment', 'sbm-sk5-owner', '-j', 'RETURN'):
                raise ValueError('同名iptables链不属于本服务，拒绝覆盖')
        else:
            run('iptables', '-N', CHAIN)
            run('iptables', '-A', CHAIN, '-m', 'comment', '--comment', 'sbm-sk5-owner', '-j', 'RETURN')
        atomic(STATE, json.dumps({'backend': backend}))
        desired_rules = []
        for protocol, value, comment in (('tcp', port, COMMENTS[0]), ('udp', udp.replace('-', ':'), COMMENTS[1])):
            rule = ['-p', protocol, '--dport', value, '-m', 'comment', '--comment', comment, '-j', 'ACCEPT']
            if not command_ok('iptables', '-C', CHAIN, *rule):
                run('iptables', '-I', CHAIN, '1', *rule)
            desired_rules.append((protocol, value, comment))
        for line in run('iptables', '-S', CHAIN).stdout.splitlines():
            args = shlex.split(line)
            if '--comment' not in args or args[args.index('--comment')+1] not in COMMENTS:
                continue
            entry = (args[args.index('-p')+1], args[args.index('--dport')+1], args[args.index('--comment')+1])
            if entry not in desired_rules:
                run('iptables', '-D', CHAIN, *args[2:])
        jump = ['INPUT', '-m', 'comment', '--comment', 'sbm-sk5-owner', '-j', CHAIN]
        if not command_ok('iptables', '-C', *jump):
            run('iptables', '-I', 'INPUT', '1', *jump[1:])
        result = {'backend': backend}
    else:
        raise ValueError('未知的防火墙后端，未作修改')
    atomic(STATE, json.dumps(result, ensure_ascii=False, indent=2)+'\n')
    return backend


def _clear():
    state = state_read()
    if not state:
        return
    backend = state['backend']
    if backend == 'firewalld':
        for item in state.get('entries', []):
            for key, flags in (('runtime', []), ('permanent', ['--permanent'])):
                if item.get(key):
                    run('firewall-cmd', '--zone='+state['zone'], *(flags+['--remove-port='+item['port']]), check=False)
    elif backend == 'nft':
        nft_clear(nft_rules())
    elif backend == 'iptables':
        if command_ok('iptables', '-C', CHAIN, '-m', 'comment', '--comment', 'sbm-sk5-owner', '-j', 'RETURN'):
            run('iptables', '-D', 'INPUT', '-m', 'comment', '--comment', 'sbm-sk5-owner', '-j', CHAIN, check=False)
            run('iptables', '-F', CHAIN)
            run('iptables', '-X', CHAIN, check=False)
    else:
        raise ValueError('无法确认防火墙规则归属')
    STATE.unlink()


def apply(settings, fresh=False):
    import fcntl
    from common import private_json
    with open('/run/lock/sbm-sk5-firewall.lock', 'a') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        current = STATE.parent / 'settings.json'
        if current.exists():
            settings = private_json(current)
        return _apply(settings, fresh)


def clear():
    import fcntl
    with open('/run/lock/sbm-sk5-firewall.lock', 'a') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        return _clear()
