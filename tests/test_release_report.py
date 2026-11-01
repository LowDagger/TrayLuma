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
import urllib.error

SPEC = importlib.util.spec_from_file_location('release_report', Path(__file__).parents[1] / 'scripts/release_report.py')
REPORT = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(REPORT)


class ReleaseReportTests(unittest.TestCase):
    def generate(self, root, extra=None):
        exe = root / 'TrayLuma.exe'
        if not exe.exists():
            exe.write_bytes(b'test artifact; never executed')
        argv = ['report', str(exe), '--output', str(root / 'out')] + (extra or [])
        # Mock security results must never pollute a real GitHub Actions summary.
        with patch.object(sys, 'argv', argv), patch.dict(os.environ, {'GITHUB_STEP_SUMMARY': ''}), contextlib.redirect_stdout(io.StringIO()):
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
            code, data = self.generate(Path(tmp), ['--upload-virustotal'])
            self.assertEqual(code, 3)
            self.assertEqual(data['virustotal_status'], 'incomplete')
            self.assertEqual(data['files'][0]['virustotal']['status'], 'not-configured')

    def test_binary_changes_produce_new_hash(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            _, before = self.generate(root)
            (root / 'TrayLuma.exe').write_bytes(b'different artifact')
            _, after = self.generate(root)
            self.assertNotEqual(before['files'][0]['sha256'], after['files'][0]['sha256'])

    def test_malicious_or_suspicious_results_fail(self):
        with tempfile.TemporaryDirectory() as tmp, patch.dict(os.environ, {'VT_API_KEY': 'test-only'}), patch.object(REPORT, 'scan', return_value={'status': 'completed', 'stats': {'malicious': 0, 'suspicious': 1}, 'engines': {'MockAV': {'category': 'suspicious', 'result': 'Test-only label'}}}):
            code, data = self.generate(Path(tmp), ['--upload-virustotal'])
            self.assertEqual(code, 2)
            self.assertTrue(data['detections_reported'])
            markdown = (Path(tmp) / 'out/security-report.md').read_text(encoding='utf-8')
            self.assertIn('VERIFICATION BLOCKED', markdown)
            self.assertIn('MockAV', markdown)
            self.assertIn('Test-only label', markdown)

    def test_defender_report_for_other_hash_is_not_reused(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            report = root / 'old-defender.json'
            report.write_text(json.dumps([{'sha256': 'wrong', 'status': 'completed-no-threats-reported'}]))
            _, data = self.generate(root, ['--defender', str(report)])
            self.assertIsNone(data['files'][0]['defender'])

    def test_api_error_fails_after_writing_safe_diagnostics(self):
        with tempfile.TemporaryDirectory() as tmp, patch.dict(os.environ, {'VT_API_KEY': 'private-key'}), patch.object(REPORT, 'scan', side_effect=REPORT.ApiError('upload', 404, 'NotFoundError')):
            code, data = self.generate(Path(tmp), ['--upload-virustotal'])
            self.assertEqual(code, 3)
            vt = data['files'][0]['virustotal']
            self.assertEqual((vt['stage'], vt['http_status'], vt['api_error_code']), ('upload', 404, 'NotFoundError'))
            self.assertNotIn('private-key', json.dumps(data))
            self.assertTrue((Path(tmp) / 'out/security-report.md').exists())

    def test_pending_analysis_is_not_a_success(self):
        with tempfile.TemporaryDirectory() as tmp, patch.dict(os.environ, {'VT_API_KEY': 'test-only'}), patch.object(REPORT, 'scan', return_value={'status': 'pending', 'stage': 'analysis'}):
            code, _ = self.generate(Path(tmp), ['--upload-virustotal'])
            self.assertEqual(code, 3)

    def test_completed_without_verdicts_is_not_a_success(self):
        with tempfile.TemporaryDirectory() as tmp, patch.dict(os.environ, {'VT_API_KEY': 'test-only'}), patch.object(REPORT, 'scan', return_value={'status': 'completed', 'stats': {}}):
            code, data = self.generate(Path(tmp), ['--upload-virustotal'])
            self.assertEqual(code, 3)
            self.assertEqual(data['files'][0]['virustotal']['stage'], 'result-validation')

    def test_completed_scan_succeeds(self):
        with tempfile.TemporaryDirectory() as tmp, patch.dict(os.environ, {'VT_API_KEY': 'test-only'}), patch.object(REPORT, 'scan', return_value={'status': 'completed', 'stats': {'undetected': 70}}):
            code, data = self.generate(Path(tmp), ['--upload-virustotal'])
            self.assertEqual(code, 0)
            self.assertEqual(data['virustotal_status'], 'completed')


class VirusTotalClientTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.exe = Path(self.temp.name) / 'TrayLuma.exe'
        self.exe.write_bytes(b'public test binary')
        self.sha = REPORT.hashlib.sha256(self.exe.read_bytes()).hexdigest()
        self.upload = {'data': {'type': 'analysis', 'id': 'a/b+='}}
        self.completed = {'data': {'attributes': {'status': 'completed', 'stats': {'undetected': 70}}},
                          'meta': {'file_info': {'sha256': self.sha}}}
        self.fresh = {'data': {'id': self.sha, 'attributes': {'last_analysis_date': 101,
                       'last_analysis_stats': {'undetected': 70}}}}

    def test_analysis_identifiers_are_url_encoded(self):
        with patch.object(REPORT, 'request', side_effect=[self.upload, self.completed]) as request:
            result = REPORT.scan(self.exe, 'test-only')
            self.assertEqual(result['status'], 'completed')
            self.assertEqual(request.call_args_list[1].args[0], '/analyses/a%2Fb%2B%3D')

    def test_analysis_404_is_retried_without_reuploading(self):
        with patch.object(REPORT, 'request', side_effect=[self.upload, REPORT.ApiError('analysis', 404), self.completed]) as request:
            self.assertEqual(REPORT.scan(self.exe, 'test-only')['status'], 'completed')
            self.assertEqual(sum(c.args[0] == '/files' for c in request.call_args_list), 1)

    def test_fresh_matching_file_report_can_resolve_analysis_404(self):
        missing = REPORT.ApiError('analysis', 404, 'NotFoundError')
        with patch.object(REPORT.time, 'time', return_value=100), patch.object(REPORT, 'request', side_effect=[self.upload, missing, missing, missing, self.fresh]):
            result = REPORT.scan(self.exe, 'test-only')
            self.assertEqual(result['result_source'], 'fresh-file-report')

    def test_stale_file_reports_are_rejected_and_retries_are_bounded(self):
        self.fresh['data']['attributes']['last_analysis_date'] = 99

        def respond(path, *args, **kwargs):
            if path == '/files':
                return self.upload
            if path.startswith('/analyses/'):
                raise REPORT.ApiError('analysis', 404)
            return self.fresh

        with patch.object(REPORT.time, 'time', return_value=100), patch.object(REPORT, 'request', side_effect=respond) as request:
            with self.assertRaises(REPORT.ApiError) as error:
                REPORT.scan(self.exe, 'test-only')
            self.assertEqual(error.exception.stage, 'analysis')
            self.assertEqual(sum(c.kwargs['stage'] == 'analysis' for c in request.call_args_list), 5)

    def test_hash_mismatch_is_rejected(self):
        self.completed['meta']['file_info']['sha256'] = 'wrong'
        with patch.object(REPORT, 'request', side_effect=[self.upload, self.completed]):
            with self.assertRaises(ValueError):
                REPORT.scan(self.exe, 'test-only')

    def test_file_report_hash_mismatch_is_rejected(self):
        self.fresh['data']['id'] = 'wrong'
        with patch.object(REPORT, 'request', return_value=self.fresh):
            with self.assertRaises(ValueError):
                REPORT.fresh_file_report(self.sha, 'test-only', 100, 'analysis')

    def test_quota_failure_is_not_retried(self):
        with patch.object(REPORT, 'request', side_effect=[self.upload, REPORT.ApiError('analysis', 429, 'QuotaExceededError')]) as request:
            with self.assertRaises(REPORT.ApiError):
                REPORT.scan(self.exe, 'test-only')
            self.assertEqual(request.call_count, 2)

    def test_request_diagnostics_never_include_error_message_or_unknown_code(self):
        secret = 'a' * 64
        body = io.BytesIO(json.dumps({'error': {'code': secret, 'message': secret}}).encode())
        error = urllib.error.HTTPError('https://www.virustotal.com/api/v3/files', 404, secret, {}, body)
        with patch.object(REPORT.urllib.request, 'build_opener') as opener, patch.object(REPORT.time, 'sleep'):
            opener.return_value.open.side_effect = error
            with self.assertRaises(REPORT.ApiError) as raised:
                REPORT.request('/files', secret, b'file', stage='upload')
            self.assertNotIn(secret, str(raised.exception))
            self.assertNotIn(secret, json.dumps(raised.exception.report()))

    def test_api_key_is_not_forwarded_on_redirect(self):
        self.assertIsNone(REPORT.NoRedirect().redirect_request(None, None, 302, '', {}, 'https://example.com'))

    def test_requests_are_spaced_by_at_least_16_seconds(self):
        with patch.object(REPORT, 'LAST_REQUEST', 0), patch.object(REPORT.time, 'monotonic', side_effect=[100, 100, 105, 105]), patch.object(REPORT.time, 'sleep') as sleep, patch.object(REPORT.urllib.request, 'build_opener') as opener:
            opener.return_value.open.side_effect = [io.BytesIO(b'{}'), io.BytesIO(b'{}')]
            REPORT.request('/files/test', 'test-only', stage='file-report')
            REPORT.request('/files/test', 'test-only', stage='file-report')
            self.assertEqual([c.args[0] for c in sleep.call_args_list], [0, 11])


if __name__ == '__main__':
    unittest.main()
