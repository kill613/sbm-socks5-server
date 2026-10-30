import copy
import hashlib
import io
from pathlib import Path
import sys
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import Mock, patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'app'))
import common
import sk5
import sk5_firewall
from test_server import fixture


class Transactions(unittest.TestCase):
    def test_corrupt_mirror_is_rejected_then_next_verified_source_wins(self):
        good = b'\x1f\x8b'+b'official-fixture'*100
        url = 'https://github.com/3proxy/3proxy/releases/download/1.0.2/source.tar.gz'
        calls = []
        def download(request, timeout):
            calls.append(request.full_url)
            self.assertIsNone(request.get_header('Authorization'))
            return io.BytesIO(b'<html>wrong file</html>' if 'mirror-one' in request.full_url else good)
        with tempfile.TemporaryDirectory() as d, \
             patch.object(common, 'MIRRORS', ('https://mirror-one/', 'https://mirror-two/')), \
             patch.object(common, 'probe', side_effect=lambda u: 2 if 'mirror-one' in u else 1), \
             patch.object(common.OPENER, 'open', side_effect=download):
            destination = Path(d) / 'core.tar.gz'
            result = common.fetch(url, destination, hashlib.sha256(good).hexdigest())
            self.assertEqual(destination.read_bytes(), good)
            self.assertTrue(result.startswith('https://mirror-two/'))
            self.assertEqual(len(calls), 2)

    def test_failed_all_sources_preserve_existing_file(self):
        with tempfile.TemporaryDirectory() as d, patch.object(common, 'MIRRORS', ()), \
             patch.object(common.OPENER, 'open', return_value=io.BytesIO(b'corrupt')):
            destination = Path(d) / 'core.tar.gz'; destination.write_bytes(b'previous')
            with self.assertRaises(RuntimeError):
                common.fetch('https://github.com/3proxy/3proxy/releases/download/1.0.2/source.tar.gz', destination, 'a'*64)
            self.assertEqual(destination.read_bytes(), b'previous')
            self.assertEqual(sorted(p.name for p in Path(d).iterdir()), ['core.tar.gz'])

    def test_restart_failure_restores_previous_config_firewall_and_only_own_service(self):
        original = fixture(); proposed = copy.deepcopy(original); proposed['port'] = 17777
        persisted = []
        calls = []
        def execute(*args, **kwargs):
            calls.append(args)
            if args[:2] == ('systemctl', 'show'):
                return SimpleNamespace(stdout='active\n')
            if args[:2] == ('systemctl', 'restart') and len([c for c in calls if c[:2] == ('systemctl', 'restart')]) == 1:
                raise RuntimeError('fixture failed start')
            return SimpleNamespace(stdout='')
        def atomic(path, data, *args):
            Path(path).write_bytes(data if isinstance(data, bytes) else data.encode())
        with tempfile.TemporaryDirectory() as d, patch.object(sk5, 'ROOT', Path(d)), \
             patch.object(sk5, 'atomic', side_effect=atomic), \
             patch.object(sk5, 'persist', side_effect=lambda c: persisted.append(copy.deepcopy(c))), \
             patch.object(sk5, 'run', side_effect=execute), patch.object(sk5, 'health') as health, \
             patch.object(sk5_firewall, 'apply') as firewall:
            (Path(d) / '3proxy.cfg').write_bytes(b'old cfg')
            with self.assertRaisesRegex(RuntimeError, '已恢复原配置'):
                sk5.change(original, proposed)
            self.assertEqual(persisted, [proposed, original])
            self.assertEqual(firewall.call_args_list[-1].args[0], original)
            health.assert_called_once_with(original)
            self.assertTrue(all(c[2] == 'sbm-sk5.service' for c in calls))

    def test_stopped_service_stays_stopped_when_config_changes(self):
        original = fixture(); proposed = copy.deepcopy(original); proposed['port'] = 17777
        with tempfile.TemporaryDirectory() as d, patch.object(sk5, 'ROOT', Path(d)), \
             patch.object(sk5, 'atomic'), patch.object(sk5, 'persist'), \
             patch.object(sk5, 'run', return_value=SimpleNamespace(stdout='inactive')) as execute, \
             patch.object(sk5, 'health') as health, patch.object(sk5_firewall, 'apply'):
            (Path(d) / '3proxy.cfg').write_bytes(b'old cfg')
            sk5.change(original, proposed)
            self.assertEqual(execute.call_count, 1)
            health.assert_not_called()

    def test_legacy_iproute_readonly_detection(self):
        results = [SimpleNamespace(returncode=1, stdout=''),
                   SimpleNamespace(stdout='223.5.5.5 via 10.8.9.1 dev eth7 src 10.8.9.4\n'),
                   SimpleNamespace(stdout='2: eth7 inet 10.8.9.4/24 brd 10.8.9.255 scope global eth7\n')]
        with patch.object(common, 'run', side_effect=results):
            self.assertEqual(common.network(), {'interface': 'eth7', 'ip': '10.8.9.4',
                'address': '10.8.9.4/24', 'gateway': '10.8.9.1'})
