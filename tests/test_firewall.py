import json
from pathlib import Path
import sys
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'app'))
sys.path.insert(0, str(ROOT))
import sk5_firewall as fw
import build_firewall_repair


def fixture():
    return [
        {'chain': {'family': 'ip', 'table': 'filter', 'name': 'INPUT', 'hook': 'input'}},
        {'chain': {'family': 'inet', 'table': 'sbm_relay', 'name': 'input', 'hook': 'input', 'policy': 'drop'}},
        {'rule': {'family': 'inet', 'table': 'sbm_relay', 'chain': 'input', 'handle': 41,
                  'comment': 'sbm-sk5-tcp'}},
        {'rule': {'family': 'inet', 'table': 'sbm_relay', 'chain': 'input', 'handle': 42,
                  'comment': 'existing-l2tp'}},
    ]


class FirewallTests(unittest.TestCase):
    def test_atomic_rules_cover_both_input_chains_without_changing_foreign_rules(self):
        batches = []
        def execute(*args):
            batches.append((args, Path(args[-1]).read_text()))
        with patch.object(fw, 'run', side_effect=execute):
            fw.nft_sync(fixture(), '57218', '20000-20999')
        self.assertEqual(batches[0][0][1:3], ('--check', '-f'))
        self.assertEqual(batches[1][0][1], '-f')
        self.assertEqual(batches[0][1], batches[1][1])
        text = batches[0][1]
        self.assertIn('inet sbm_relay input ip protocol tcp tcp dport 57218', text)
        self.assertIn('inet sbm_relay input ip protocol udp udp dport 20000-20999', text)
        self.assertIn('ip filter INPUT ip protocol tcp tcp dport 57218', text)
        self.assertIn('delete rule inet sbm_relay input handle 41', text)
        self.assertNotIn('handle 42', text)
        self.assertNotIn('flush', text)
        self.assertNotIn('policy', text)

    def test_failed_check_does_not_apply_batch(self):
        with patch.object(fw, 'run', side_effect=RuntimeError('check failed')) as execute:
            with self.assertRaises(RuntimeError):
                fw.nft_sync(fixture(), '57218', '20000-20999')
        self.assertEqual(execute.call_count, 1)

    def test_saved_iptables_backend_covers_later_relay_and_cleanup(self):
        settings = {'port': 57218, 'udp_first': 20000, 'udp_last': 20999}
        def atomic(path, value, *args):
            Path(path).write_text(value)
        with tempfile.TemporaryDirectory() as directory, patch.object(fw, 'STATE', Path(directory)/'state.json'), \
                patch.object(fw, 'state_read', return_value={'backend': 'iptables'}), \
                patch.object(fw, 'atomic', side_effect=atomic), \
                patch.object(fw, 'command_ok', return_value=True), \
                patch.object(fw, 'run', return_value=SimpleNamespace(stdout='')), \
                patch.object(fw, 'nft_rules', return_value=fixture()), \
                patch.object(fw, 'nft_sync') as sync, patch.object(fw, 'relay_hook'):
            fw._apply(settings)
            sync.assert_called_once_with(fixture(), '57218', '20000-20999')
            self.assertTrue(json.loads(fw.STATE.read_text())['nft_overlay'])
            with patch.object(fw, 'state_read', return_value={'backend': 'iptables', 'nft_overlay': True}), \
                    patch.object(fw, 'nft_clear') as clear:
                fw._clear()
                clear.assert_called_once_with(fixture())

    def test_relay_hook_is_owned_idempotent_and_never_restarts_services(self):
        def atomic(path, content, *args):
            Path(path).write_text(content)
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            unit = root/'relay.service'; unit.touch()
            hook = root/'relay.d/91.conf'; order = root/'sk5.d/91.conf'
            with patch.object(fw, 'RELAY_UNIT', unit), patch.object(fw, 'RELAY_DROPIN', hook), \
                    patch.object(fw, 'ORDER_DROPIN', order), patch.object(fw, 'atomic', side_effect=atomic), \
                    patch.object(fw, 'run') as execute:
                fw.relay_hook(fixture())
                self.assertEqual(hook.read_text(), fw.RELAY_HOOK)
                self.assertEqual(order.read_text(), fw.ORDER_HOOK)
                fw.relay_hook(fixture())
                execute.assert_called_once_with('systemctl', 'daemon-reload')
                hook.write_text('foreign config')
                with self.assertRaises(ValueError):
                    fw.relay_hook(fixture())
                self.assertEqual(hook.read_text(), 'foreign config')
                hook.write_text(fw.RELAY_HOOK)
                fw.relay_hook([], remove=True)
                self.assertFalse(hook.exists())
                self.assertFalse(order.exists())

    def test_repair_script_matches_source_and_preserves_service(self):
        text = build_firewall_repair.render()
        self.assertEqual((ROOT/'repair-firewall.sh').read_text(encoding='utf-8'), text)
        self.assertNotIn('systemctl restart', text)
        self.assertNotIn('flush ruleset', text)
        self.assertIn('ruleset-before.nft', text)


if __name__ == '__main__':
    unittest.main()
