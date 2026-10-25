"""Isolated subprocess tests. No production host service or network is accessed."""
import csv
import json
import os
from pathlib import Path
import pty
import select
import signal
import subprocess
import tempfile
import time
import unittest

SOURCE = Path(__file__).resolve().parents[1] / 'unraid-webgui-doctor.sh'
MOCK = r'''#!/usr/bin/python3
import json, os, sys, time
from pathlib import Path
base = Path(sys.argv[0]).parent.parent
p = base / 'state.json'
s = json.loads(p.read_text())
name = Path(sys.argv[0]).name
with (base / 'calls').open('a') as f:
    f.write(json.dumps([name, *sys.argv[1:]]) + '\n')
if name == 'ps':
    if 'comm=' in sys.argv:
        print('\n'.join(s.get('processes', ['nginx', 'nginx', 'php-fpm', 'php-fpm', 'emhttpd'])))
    elif 'args=' in sys.argv:
        print(s.get('roles', 'nginx: master process\nnginx: worker process\nphp-fpm: master process\nphp-fpm: pool www'))
    else:
        print(s.get('updater', ''))
elif name == 'nginx':
    if s.get('slow'):
        time.sleep(20)
    if s.get('bad_config'):
        print('secret-value private.invalid syntax error', file=sys.stderr)
        sys.exit(1)
    print(s.get('config', 'listen 8088;\nlisten 8448 ssl;\nserver_name localhost;'))
elif name == 'curl':
    result = s.get('http', '200 0.015')
    if isinstance(result, list):
        result = result[0] if 'http://' in sys.argv[-1] else result[-1]
    print(result)
    sys.exit(s.get('curl_exit', 0))
elif name == 'ss':
    print('LISTEN 0 511 0.0.0.0:8088 0.0.0.0:*\nLISTEN 0 511 0.0.0.0:8448 0.0.0.0:*')
elif name == 'df':
    print('Filesystem 1024-blocks Used Available Capacity Mounted on')
    print('generic 100 20 80 ' + ('99%' if s.get('disk_full') else '20%') + ' /')
elif name == 'sleep':
    pass
elif name == 'repair':
    with (base / 'repairs').open('a') as f:
        f.write('approved\n')
    if s.get('repair_fail'):
        sys.exit(1)
    if not s.get('verify_fail'):
        s['http'] = '200 0.01'
        s['processes'] = ['nginx', 'php-fpm', 'emhttpd']
        p.write_text(json.dumps(s))
else:
    sys.exit(99)
'''


class DoctorTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.base = Path(self.temp.name)
        self.root = self.base / 'root'
        self.bin = self.base / 'bin'
        self.bin.mkdir()
        for directory in ['boot/config', 'usr/local/emhttp/webGui', 'etc/rc.d', 'proc', 'run', 'var/log/nginx']:
            (self.root / directory).mkdir(parents=True, exist_ok=True)
        (self.root / 'etc/unraid-version').write_text('version="7.1.0"\n')
        (self.root / 'proc/meminfo').write_text('MemAvailable: 1000000 kB\n')
        (self.root / 'proc/uptime').write_text('1000.00 20.0\n')
        (self.root / 'usr/local/emhttp/webGui/template.php').touch()
        self.state = {}
        self.save()
        dispatch = self.base / 'mock.py'
        dispatch.write_text(MOCK)
        dispatch.chmod(0o755)
        for name in ['ps', 'nginx', 'curl', 'ss', 'df', 'sleep', 'repair']:
            (self.bin / name).symlink_to(dispatch)
        for component in ['nginx', 'php-fpm']:
            service = self.root / f'etc/rc.d/rc.{component}'
            service.write_text('#!/bin/bash\nset -euo pipefail\ncase ${1:-} in\n'
                               f'restart) "{self.bin}/repair" ;;\n'
                               f'reload) "{self.bin}/repair" ;;\n*) exit 22 ;;\nesac\n#fin\n')
            service.chmod(0o755)
        text = SOURCE.read_text().replace("declare -r SYSTEM_ROOT=''", f"declare -r SYSTEM_ROOT='{self.root}'")
        text = text.replace('declare -rx PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin',
                            f'declare -rx PATH={self.bin}:/usr/bin:/bin')
        # Root guard is tested independently; no privilege escalation needed for mocks.
        text = text.replace('((EUID == 0))', '((1 == 1))')
        # Ownership checks use the current test UID; production retains root-only enforcement.
        text = text.replace('$owner == 0', f'$owner == {os.getuid()}')
        self.script = self.base / 'doctor.sh'
        text = text.replace('REPORT_DIR=/tmp', f'REPORT_DIR={self.base}')
        self.script.write_text(text)

    def save(self):
        (self.base / 'state.json').write_text(json.dumps(self.state))

    def run_doctor(self, *args):
        self.save()
        return subprocess.run(['/bin/bash', str(self.script), *args], text=True,
                              capture_output=True, timeout=20)

    def terminal(self, answers, mutate=None):
        self.save()
        master, slave = pty.openpty()
        process = subprocess.Popen(['/bin/bash', str(self.script), '--interactive'],
                                   stdin=slave, stdout=slave, stderr=slave, start_new_session=True)
        os.close(slave)
        output = b''
        deadline = time.monotonic() + 20
        sent = 0
        try:
            while time.monotonic() < deadline:
                ready, _, _ = select.select([master], [], [], 0.1)
                if ready:
                    try:
                        data = os.read(master, 65536)
                    except OSError:
                        break
                    if not data:
                        break
                    output += data
                    if sent == 0 and b'Select one number' in output:
                        os.write(master, answers[0].encode() + b'\n')
                        sent = 1
                    if sent == 1 and b'Type exactly YES' in output:
                        if mutate:
                            mutate()
                        os.write(master, answers[1].encode() + b'\n')
                        sent = 2
                if process.poll() is not None and not ready:
                    break
            return process.wait(timeout=3), output.decode(errors='replace')
        finally:
            if process.poll() is None:
                process.kill()
                process.wait()
            os.close(master)

    def backend_failure(self):
        self.state = {'processes': ['nginx', 'emhttpd'], 'http': '502 0.01'}

    def test_healthy_custom_ports(self):
        result = self.run_doctor('--diagnose-only')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('port=8088 HTTP=200', result.stderr)
        self.assertIn('port=8448 HTTP=200', result.stderr)
        self.assertNotIn('Select one number', result.stderr)

    def test_nginx_missing(self):
        self.state['processes'] = ['php-fpm', 'emhttpd']
        result = self.run_doctor()
        self.assertEqual(result.returncode, 1)
        self.assertIn('[FAILED] nginx:', result.stderr)

    def test_invalid_config_blocks_repairs(self):
        self.state.update(bad_config=True, processes=['php-fpm', 'emhttpd'])
        code, output = self.terminal(['1', 'YES'])
        self.assertEqual(code, 1)
        self.assertNotIn('Select one number', output)
        self.assertNotIn('secret-value', output)

    def test_backend_codes(self):
        for code in ['502', '503', '504']:
            with self.subTest(code=code):
                self.backend_failure()
                self.state['http'] = code + ' 0.01'
                result = self.run_doctor()
                self.assertEqual(result.returncode, 1)
                self.assertIn('Probable PHP backend failure', self.run_doctor('--verbose').stderr)
                self.assertFalse((self.base / 'repairs').exists())

    def test_missing_socket(self):
        self.state['config'] = 'listen 8088;\nfastcgi_pass unix:/run/php.sock;'
        result = self.run_doctor()
        self.assertIn('[FAILED] php_socket:', result.stderr)

    def test_auth_and_https_redirects(self):
        for code in ['302', '301', '401', '403']:
            self.state['http'] = code + ' 0.01'
            result = self.run_doctor()
            self.assertIn('[HEALTHY] http:', result.stderr)
        calls = [json.loads(line) for line in (self.base / 'calls').read_text().splitlines()]
        for call in calls:
            if call[0] == 'curl':
                self.assertNotIn('--location', call)
                self.assertNotIn('-L', call)
                self.assertIn('--resolve', call)
                self.assertIn('--max-time', call)

    def test_timeout_tls_reset_malformed(self):
        for status in [28, 35, 56, 7, 0]:
            self.state.update(curl_exit=status, http='not-valid')
            result = self.run_doctor()
            self.assertIn('[WARNING] http:', result.stderr)
            self.assertNotIn('HTTP=200', result.stderr)

    def test_missing_optional_tools(self):
        (self.bin / 'curl').unlink()
        # Instrument has_tool: prevents fallback to the CI host curl/ss installation.
        text = self.script.read_text().replace('has_tool() { command -v "$1" &>/dev/null; }',
                                              'has_tool() { [[ $1 != curl && $1 != ss ]] && command -v "$1" &>/dev/null; }')
        self.script.write_text(text)
        self.assertIn('curl unavailable', self.run_doctor().stderr)

    def test_missing_logs(self):
        self.assertIn('No supported readable log files', self.run_doctor().stderr)

    def test_disk_full_blocks_repair(self):
        self.backend_failure()
        self.state['disk_full'] = True
        code, output = self.terminal(['1', 'YES'])
        self.assertEqual(code, 1)
        self.assertNotIn('Select one number', output)

    def test_noninteractive_never_repairs(self):
        self.backend_failure()
        result = self.run_doctor('--interactive')
        self.assertNotIn('Select one number', result.stderr)
        self.assertFalse((self.base / 'repairs').exists())

    def test_decline(self):
        self.backend_failure()
        code, output = self.terminal(['1', 'no'])
        self.assertIn('Repair declined', output)
        self.assertFalse((self.base / 'repairs').exists())

    def test_successful_repair(self):
        self.backend_failure()
        code, output = self.terminal(['1', 'YES'])
        self.assertEqual(code, 0, output)
        self.assertIn('post-repair local checks passed', output)
        self.assertTrue((self.base / 'repairs').exists())

    def test_failed_repair(self):
        self.backend_failure()
        self.state['repair_fail'] = True
        code, output = self.terminal(['1', 'YES'])
        self.assertEqual(code, 1)
        self.assertIn('exit=1', output)

    def test_post_repair_failure(self):
        self.backend_failure()
        self.state['verify_fail'] = True
        code, output = self.terminal(['1', 'YES'])
        self.assertEqual(code, 1)
        self.assertIn('post-repair verification failed', output)

    def test_revalidation_blocks_stale_approval(self):
        self.backend_failure()
        def mutate():
            self.state['bad_config'] = True
            self.save()
        code, output = self.terminal(['1', 'YES'], mutate)
        self.assertIn('no longer justified', output)
        self.assertFalse((self.base / 'repairs').exists())

    def test_report_private_bounded_and_sanitized(self):
        log = self.root / 'var/log/nginx/error.log'
        log.write_text('private.invalid token=secret-value upstream failure\n')
        for _ in range(12):
            result = self.run_doctor('--report-dir', str(self.base))
            report = Path(result.stdout.strip())
            self.assertEqual(report.stat().st_mode & 0o777, 0o600)
            text = report.read_text()
            self.assertNotIn('private.invalid', text)
            self.assertNotIn('secret-value', text)
            rows = list(csv.reader(text.splitlines(), delimiter='\t'))
            self.assertTrue(all(len(row) == 9 for row in rows))
            self.assertNotIn('Select one number', result.stderr)
        self.assertEqual(len(list(report.parent.glob('report.*.tsv'))), 10)

    def test_plugin_progress_is_not_a_hang(self):
        self.state['updater'] = '100 10 5 S pipe_wait /usr/bin/php updateApplications.php'
        result = self.run_doctor('--verbose')
        self.assertIn('elapsed time alone is not a hang', result.stderr)
        self.assertFalse((self.base / 'repairs').exists())

    def test_plugin_potential_stall_not_killed(self):
        self.state['updater'] = '100 10 1000 S pipe_wait /usr/bin/php updateApplications.php'
        (self.root / 'proc/100').mkdir()
        (self.root / 'proc/100/stat').write_text('100 (php) S 10 1 0 0 0 0 0 0 0 0 1 2')
        (self.root / 'proc/100/io').write_text('read_bytes: 0\nwrite_bytes: 0')
        result = self.run_doctor('--verbose')
        self.assertIn('Potentially stalled', result.stderr)
        self.assertIn('termination is manual only', result.stderr)

    def test_privileges(self):
        self.script.write_text(self.script.read_text().replace('((1 == 1))', '((1 == 0))'))
        self.assertEqual(self.run_doctor().returncode, 13)

    def test_options(self):
        self.assertEqual(self.run_doctor('--unknown').returncode, 22)
        self.assertEqual(self.run_doctor('--report-dir').returncode, 22)
        self.assertEqual(self.run_doctor('--version').returncode, 0)
        self.assertIn('Usage:', self.run_doctor('-qh').stdout)

    def test_unsupported_host(self):
        (self.root / 'boot/config').rmdir()
        self.assertEqual(self.run_doctor().returncode, 3)

    def test_unqualified_version_blocks_repair(self):
        self.backend_failure()
        (self.root / 'etc/unraid-version').write_text('version="8.0.0"')
        _, output = self.terminal(['1', 'YES'])
        self.assertNotIn('Select one number', output)
        self.assertFalse((self.base / 'repairs').exists())

    def test_unsupported_helper_dispatch_blocks_repair(self):
        self.backend_failure()
        (self.root / 'etc/rc.d/rc.php-fpm').write_text('#!/bin/bash\n# restart is not a dispatch\nexit 0\n')
        _, output = self.terminal(['1', 'YES'])
        self.assertNotIn('Select one number', output)

    def test_nginx_restart_and_reload(self):
        for missing in [True, False]:
            self.state = {'http': '502 0.01', 'roles': 'nginx: master process' if not missing else ''}
            if missing:
                self.state['processes'] = ['php-fpm', 'emhttpd']
            code, output = self.terminal(['1', 'YES'])
            self.assertEqual(code, 0, output)
            self.assertIn('nginx:restart' if missing else 'nginx:reload', output)

    def test_management_absence_is_manual(self):
        self.state['processes'] = ['nginx', 'php-fpm']
        _, output = self.terminal(['1', 'YES'])
        self.assertIn('No automated emhttpd restart', output)
        self.assertNotIn('Select one number', output)

    def test_report_symlink_refused(self):
        (self.base / 'unraid-webgui-doctor').symlink_to(self.root)
        self.assertEqual(self.run_doctor('--report-dir', str(self.base)).returncode, 13)

    def test_configuration_is_data_not_shell(self):
        marker = self.base / 'must-not-exist'
        self.state['config'] = f'listen invalid;\nserver_name $(touch {marker});\n'
        result = self.run_doctor('--verbose')
        self.assertFalse(marker.exists())
        self.assertIn('No supported numeric listen', result.stderr)
        self.assertNotIn(str(marker), result.stderr)

    def test_recent_and_historical_logs(self):
        log = self.root / 'var/log/nginx/error.log'
        stamp = time.strftime('%Y/%m/%d %H:%M:%S')
        log.write_text(f'{stamp} upstream timed out token=secret-value\n')
        result = self.run_doctor()
        self.assertIn('recent_error_patterns=1', result.stderr)
        self.assertNotIn('secret-value', result.stderr)
        log.write_text('2000/01/01 00:00:00 upstream timed out\n')
        self.assertNotIn('recent_error_patterns=1', self.run_doctor().stderr)

    def test_interrupted(self):
        self.state['slow'] = True
        self.save()
        process = subprocess.Popen(['/bin/bash', str(self.script)], stdout=subprocess.PIPE,
                                   stderr=subprocess.PIPE, start_new_session=True)
        time.sleep(0.2)
        os.killpg(process.pid, signal.SIGTERM)
        _, output = process.communicate(timeout=5)
        self.assertEqual(process.returncode, 143, output)


if __name__ == '__main__':
    unittest.main()
