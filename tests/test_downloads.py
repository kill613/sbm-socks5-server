import hashlib
import io
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'app'))
import common
import downloader
sys.path.insert(0, str(ROOT))
import build_download_entry


class DownloadTests(unittest.TestCase):
    def test_blocked_range_probe_still_attempts_verified_download_and_rejects_bad_mirror(self):
        good = b'#!/bin/bash\necho standalone\n'
        def response(request, timeout):
            self.assertIsNone(request.get_header('Authorization'))
            return io.BytesIO(b'<html>wrong</html>' if '/first/' in request.full_url else good)
        with tempfile.TemporaryDirectory() as directory, patch.object(common, 'MIRRORS', ('https://example.invalid/first/', 'https://example.invalid/second/')), \
             patch.object(common, 'probe', return_value=None), patch.object(common.OPENER, 'open', side_effect=response):
            target = Path(directory) / 'install.sh'
            common.fetch_project('https://raw.githubusercontent.com/kill613/sbm-socks5-server/main/install.sh', target,
                                 hashlib.sha256(good).hexdigest())
            self.assertEqual(target.read_bytes(), good)

    def test_private_configuration_cannot_be_sent_to_mirror(self):
        for path in ('settings.json', 'backup.tar.gz', 'app/private.env', '../install.sh'):
            with self.assertRaises(ValueError):
                downloader.project_url('https://raw.githubusercontent.com/kill613/sbm-socks5-server/main/'+path)

    def test_bootstrap_entry_is_self_contained_and_matches_documented_command(self):
        text = build_download_entry.render_bootstrap(ROOT, server=True)
        self.assertEqual((ROOT / 'bootstrap-server.sh').read_text(encoding='utf-8'), text)
        readme = (ROOT / 'README.md').read_text(encoding='utf-8')
        documented = readme.split('<!-- bootstrap-command:start -->\n```bash\n', 1)[1].split('```', 1)[0]
        self.assertEqual(documented, build_download_entry.install_command(ROOT, server=True))
        self.assertEqual(len(documented.splitlines()), 1)
        self.assertIn('https://ghfast.top/https://raw.githubusercontent.com/', documented)
        self.assertIn('| sha256sum -c - && bash ', documented)
