import contextlib
import importlib.util
import io
import json
import os
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

SPEC = importlib.util.spec_from_file_location('release_report', Path(__file__).parents[1] / 'scripts/release_report.py')
REPORT = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(REPORT)


class ReleaseReportTests(unittest.TestCase):
    def generate(self, root, extra=None):
        exe = root / 'TrayLuma.exe'
        if not exe.exists():
            exe.write_bytes(b'test artifact; never executed')
        argv = ['report', str(exe), '--output', str(root / 'out')] + (extra or [])
        with patch.object(sys, 'argv', argv), contextlib.redirect_stdout(io.StringIO()):
            code = REPORT.main()
        data = json.loads((root / 'out/release-report.json').read_text())
        return code, data

    def test_no_upload_without_explicit_consent(self):
        with tempfile.TemporaryDirectory() as tmp, patch.object(REPORT, 'scan') as scan:
            _, data = self.generate(Path(tmp))
            self.assertEqual(data['files'][0]['virustotal']['status'], 'not-requested')
            scan.assert_not_called()

    def test_missing_key_is_not_a_clean_result(self):
        with tempfile.TemporaryDirectory() as tmp, patch.dict(os.environ, {'VT_API_KEY': ''}):
            _, data = self.generate(Path(tmp), ['--upload-virustotal'])
            self.assertEqual(data['files'][0]['virustotal']['status'], 'not-configured')

    def test_binary_changes_produce_new_hash(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            _, before = self.generate(root)
            (root / 'TrayLuma.exe').write_bytes(b'different artifact')
            _, after = self.generate(root)
            self.assertNotEqual(before['files'][0]['sha256'], after['files'][0]['sha256'])

    def test_malicious_or_suspicious_results_fail(self):
        with tempfile.TemporaryDirectory() as tmp, patch.dict(os.environ, {'VT_API_KEY': 'test-only'}), patch.object(REPORT, 'scan', return_value={'status': 'completed', 'stats': {'malicious': 0, 'suspicious': 1}}):
            code, data = self.generate(Path(tmp), ['--upload-virustotal'])
            self.assertEqual(code, 2)
            self.assertTrue(data['detections_reported'])

    def test_defender_report_for_other_hash_is_not_reused(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            report = root / 'old-defender.json'
            report.write_text(json.dumps([{'sha256': 'wrong', 'status': 'completed-no-threats-reported'}]))
            _, data = self.generate(root, ['--defender', str(report)])
            self.assertIsNone(data['files'][0]['defender'])


if __name__ == '__main__':
    unittest.main()
