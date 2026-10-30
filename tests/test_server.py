import copy
import io
from pathlib import Path
import sys
import tarfile
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'app'))
sys.path.insert(0, str(ROOT))
import common
import sk5
import sk5_install
import build_installer


def fixture():
    return {'schema': 1, 'interface': 'eth7', 'local_ip': '10.23.4.15',
            'public_ip': '223.5.5.5', 'port': 30294, 'udp_first': 20000,
            'udp_last': 20999, 'users': [{'name': 'FixtureUser1', 'password': 'AbcdefGh123456789p'}]}


class ServerTests(unittest.TestCase):
    def test_random_credentials_match_lengths_classes_and_exclusions(self):
        for n in (8, 18):
            for _ in range(100):
                text = common.generated(n)
                self.assertEqual(len(text), n)
                self.assertTrue(text.isalnum())
                self.assertNotIn('0', text); self.assertNotIn('O', text)
                self.assertTrue(any(c.islower() for c in text))
                self.assertTrue(any(c.isupper() for c in text))
                self.assertTrue(any(c.isdigit() for c in text))

    def test_public_nat_and_fixed_pool_with_mandatory_auth(self):
        text = sk5.render(fixture())
        self.assertIn('auth strong', text)
        self.assertIn('-e10.23.4.15 -Ni223.5.5.5', text)
        self.assertIn('parent 1000 intport 0.0.0.0 20000-20999', text)
        self.assertIn('CONNECT,UDPASSOC', text)
        self.assertNotIn('BIND', text)

    def test_reject_injection_private_public_ip_empty_or_duplicate_accounts(self):
        for edit in ({'public_ip': '10.23.4.15'}, {'users': []}, {'port': 20001},
                     {'users': [{'name': 'bad\nallow', 'password': 'abc'}]},
                     {'users': [{'name': 'FixtureUser1', 'password': 'a\nsocks'}]},
                     {'udp_first': 22000, 'udp_last': 21000}, {'port': True},
                     {'interface': 'eth7\nallow'}):
            config = fixture(); config.update(edit)
            with self.assertRaises(ValueError):
                sk5.render(config)
        config = fixture(); config['users'].append(copy.deepcopy(config['users'][0]))
        with self.assertRaises(ValueError):
            sk5.render(config)

    def test_occupied_udp_pool_is_skipped_and_other_services_retained(self):
        self.assertEqual(sk5_install.free_udp_range({20005, 21017, 38162}), (22000, 22999))

    def test_asset_fetch_only_accepts_public_upstream_release(self):
        for url in ('https://github.com/private/example/archive/main.tar.gz',
                    'https://user:token@github.com/3proxy/3proxy/releases/download/x/y',
                    'http://github.com/3proxy/3proxy/releases/download/x/y',
                    'https://github.com/3proxy/3proxy/releases/download/x/y?token=secret'):
            with self.assertRaises(ValueError):
                common.public_asset_url(url)

    def test_tar_traversal_symlinks_devices_rejected(self):
        with tempfile.TemporaryDirectory() as d:
            root = Path(d)
            for name, kind in [('../outside', tarfile.REGTYPE), ('/absolute', tarfile.REGTYPE),
                               ('link', tarfile.SYMTYPE), ('device', tarfile.CHRTYPE)]:
                archive = root / 'bad.tar.gz'
                with tarfile.open(archive, 'w:gz') as tar:
                    item = tarfile.TarInfo(name); item.type = kind; item.linkname = '/etc'
                    tar.addfile(item)
                with self.assertRaises(ValueError):
                    common.extract(archive, root / 'out')
            self.assertFalse((root / 'outside').exists())

    def test_generated_one_file_installer_matches_reviewable_source(self):
        self.assertEqual((ROOT / 'install.sh').read_text(encoding='utf-8'), build_installer.render())

    def test_public_bundle_has_no_panel_private_repository_or_live_credentials(self):
        forbidden = ['singbox-manager', 'SBM_WEB_', 'manager.sqlite3', 'password_ciphertext',
            'BEGIN OPENSSH PRIVATE KEY', 'BEGIN RSA PRIVATE KEY', 'ghp_']
        for path in list((ROOT / 'app').glob('*'))+[ROOT / 'bootstrap.sh']:
            if path.is_file():
                source = path.read_text(encoding='utf-8')
                for token in forbidden:
                    self.assertNotIn(token, source, str(path))


if __name__ == '__main__':
    unittest.main()
