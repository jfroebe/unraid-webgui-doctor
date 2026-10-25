"""Deterministic repository checks; not a substitute for the upstream BCS audit."""
from pathlib import Path
import re
import shutil
import subprocess

ROOT = Path(__file__).resolve().parents[1]
scripts = sorted(ROOT.rglob('*.sh'))
shellcheck = shutil.which('shellcheck')
if not shellcheck:
    raise SystemExit('ShellCheck is required (no silent skip).')
for script in scripts:
    if '.bcs' in script.parts:
        continue
    text = script.read_text()
    subprocess.run(['bash', '-n', str(script)], check=True)
    subprocess.run([shellcheck, '--severity=style', str(script)], check=True)
    assert text.startswith('#!/bin/bash\n'), f'{script}: BCS0102 shebang'
    commands = [line for line in text.splitlines() if line and not line.startswith('#')]
    assert commands[0] == 'set -euo pipefail', 'BCS0101 strict mode must be first'
    assert 'shopt -s inherit_errexit' in text, 'BCS0101 inherit_errexit'
    assert 'declare -rx PATH=' in text, 'BCS1002 fixed system PATH'
    assert text.endswith('main "$@"\n#fin\n'), 'BCS0108/0109 main/end marker'
    assert not re.search(r'^\s*(eval|set \+e|killall|reboot)\b', text, re.M), 'Unsafe command'
    assert not re.search(r'^\s*local\s+[a-zA-Z_]', text, re.M), 'BCS0201 explicit local types'
    assert not re.search(r'^\s*function\s', text, re.M), 'BCS0401 function form'
    assert '\t' not in text, 'BCS1201 spaces, not indentation tabs'
    assert all(len(line) <= 120 or 'https://' in line for line in text.splitlines()), 'BCS1201 line length'

# Public files use generic fixtures. Detect accidental credentials and non-loopback IPv4.
for path in sorted(ROOT.rglob('*')):
    if not path.is_file() or any(part in {'.git', '.bcs', '__pycache__'} for part in path.parts):
        continue
    if path.suffix == '.pyc':
        continue
    text = path.read_text()
    assert not re.search(r'gh[pousr]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}', text), path
    assert not re.search(r'-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----', text), path
    for address in re.findall(r'(?<![\w.])(?:\d{1,3}\.){3}\d{1,3}(?![\w.])', text):
        assert address in {'127.0.0.1', '0.0.0.0'}, f'{path}: non-loopback address'
print('Bash syntax, ShellCheck, deterministic BCS subset and public-file scan passed.')
