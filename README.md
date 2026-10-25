# Unraid WebGUI Doctor

A self-contained Bash utility for diagnosing an inaccessible or degraded Unraid management interface over
SSH or the local terminal. It correlates nginx, PHP-FPM, management-process, listener, HTTP, resource and
plugin-update evidence, then offers narrowly scoped repairs that require explicit administrator approval.

**Status: unreleased.** Simulated validation is available; no live Unraid version has been qualified.
The full upstream Bash Coding Standard audit is a release gate. Do not treat a passing mock suite as
production certification or merge while a required check fails.

## Features

- Sequential, bounded local checks; no internet connection, Python, Docker, database, daemon or
  external configuration is needed on the diagnosed host.
- Discovers numeric listen ports from effective nginx configuration, including custom HTTP and HTTPS ports.
- Tests loopback with a discovered server name for Host/SNI, without DNS, proxies or redirect following.
- Accepts successful HTTP responses, redirects and authentication responses without declaring them backend failures.
- Examines exact-name service processes, master/worker titles, a configured FastCGI Unix socket,
  simple PHP pool limits, resource pressure, selected error logs and updater candidates.
- Labels findings HEALTHY, WARNING, FAILED, UNKNOWN or NOT APPLICABLE, with severity, evidence,
  probable cause, confidence, next action and repair availability in TSV reports or verbose output.
- Offers nginx restart when absent, nginx reload when a master has no observed workers,
  and PHP-FPM restart when PHP is absent and nginx returns a backend error, subject to additional safeguards.
- Revalidates after approval, serializes repairs, records an audit report and checks the result.
- Reports omit raw logs, configurations, process command lines, hostnames and addresses.

## Compatibility and requirements

The required interpreter is **Bash 5.2+**, matching the
[Open Technology Foundation Bash Coding Standard](https://github.com/Open-Technology-Foundation/bash-coding-standard).
Older Bash versions are rejected before version-dependent features run. There is no claim of compatibility
with an Unraid release solely because it bundles a sufficiently new Bash.

| Environment | Validation |
|---|---|
| Linux with Bash 5.2 and isolated service/filesystem fixtures | Automated subprocess and terminal tests |
| Unraid 6.12 service-layout candidate | Runtime inspection only; live qualification pending |
| Unraid 7.x service-layout candidate | Runtime inspection only; live qualification pending |
| Other Unraid families | Diagnostic best effort; no automated repairs |
| Real Unraid hardware, array, Docker or VMs | No recovery experiments performed |

Run as root on the Unraid host. Core requirements include `timeout`, `ps` and standard GNU/Linux utilities
such as `awk` (with `mktime`), `stat`, `df`, `find`, `sort`, `mktemp`, `cksum` and `tail`.
`nginx`, `curl` and `ss` are detected when needed; unavailable optional utilities produce UNKNOWN checks.
`flock` is required only for an approved repair. No software is installed during diagnosis.

The script expects `/boot/config`, `/usr/local/emhttp`, and the native `/etc/rc.d/rc.nginx` and
`/etc/rc.d/rc.php-fpm` layout for repairs. It inspects helper ownership, permissions, file type and an explicit
dispatch label before use. That inspection cannot prove every side effect of a customized service helper.
Review customized helpers and use diagnosis-only mode until their behavior is understood.

## Persistent installation

Recommended location:

```text
/boot/config/custom/scripts/unraid-webgui-doctor.sh
```

`/boot` is Unraid's persistent boot storage. The script survives reboots without a separate installation
service. Invoke it through `bash`: the flash filesystem may be mounted `noexec`, regardless of file mode.
Do not add it to startup as an unattended repair task.

After the release is merged to `main`:

```bash
mkdir -p /boot/config/custom/scripts
curl -fL \
  https://raw.githubusercontent.com/jfroebe/unraid-webgui-doctor/main/unraid-webgui-doctor.sh \
  -o /boot/config/custom/scripts/unraid-webgui-doctor.sh
chmod 755 /boot/config/custom/scripts/unraid-webgui-doctor.sh
bash -n /boot/config/custom/scripts/unraid-webgui-doctor.sh
bash /boot/config/custom/scripts/unraid-webgui-doctor.sh --help
```

During review, substitute the reviewed PR commit SHA for `main` in the download URL.
Inspect the complete script before running it with root privileges. No signed release or published checksum
is currently provided. A pinned commit identifies reviewed content but is not a detached signature.

## Command-line options

```text
bash /boot/config/custom/scripts/unraid-webgui-doctor.sh [OPTIONS]
```

| Option | Behavior |
|---|---|
| `--help`, `-h` | Help and examples |
| `--version`, `-V` | Script name and version |
| `--diagnose-only`, `--no-fix` | Diagnose without repair prompts |
| `--interactive` | Offer applicable repairs when stdin, stdout and stderr are terminals |
| `--report` | Save a private TSV report; prohibit repairs |
| `--report-dir DIR` | Choose an absolute report parent; implies `--report` |
| `--verbose`, `-v` | Expanded interpretation and next actions |
| `--quiet`, `-q` | Suppress informational output; retain warnings and failed findings |
| `--no-color` | Accepted for compatibility; all output is already plain text |

Default behavior is interactive diagnosis on a terminal and diagnosis-only otherwise.
`--diagnose-only` and reporting options always prohibit repairs, regardless of option order.
There is no assume-yes or force mode. Short options can be bundled, for example `-qV`.

## Examples

Interactive troubleshooting:

```bash
bash /boot/config/custom/scripts/unraid-webgui-doctor.sh
```

Read-only diagnosis:

```bash
bash /boot/config/custom/scripts/unraid-webgui-doctor.sh --diagnose-only
```

Generate a report (the resulting path is printed on stdout):

```bash
bash /boot/config/custom/scripts/unraid-webgui-doctor.sh --report
```

Expanded diagnosis:

```bash
bash /boot/config/custom/scripts/unraid-webgui-doctor.sh --diagnose-only --verbose
```

Choose a mounted persistent report parent outside the flash drive:

```bash
bash /boot/config/custom/scripts/unraid-webgui-doctor.sh \
  --report-dir /mnt/user/appdata/webgui-diagnostics
```

The path above is a generic example, not an existing share requirement. Verify that custom storage is mounted
before selecting it; diagnosis itself needs only a writable `/tmp` working directory.

## Diagnostics and interpretation

The utility records sanitized OS/kernel versions, uptime, Bash version, available memory and filesystem usage.
It flags filesystem capacity or inode usage at 95% and available memory below 128 MiB. These are advisory
thresholds, not proof of the cause. Resource pressure blocks offered service repairs until investigated.

`nginx -T` validates and supplies effective configuration in a private temporary directory. Its raw output
is never printed or retained in reports. Simple `listen`, `server_name` and `fastcgi_pass unix:` directives
are inspected. Up to eight distinct numeric ports are probed. Configuration testing is bounded to eight
seconds plus a two-second termination allowance; probes have a two-second connect and six-second total timeout.

HTTPS certificate verification is bypassed **only for requests forced to loopback**, to distinguish a local
HTTP service from certificate trust problems. The script does not validate certificate identity, expiry,
public reachability or a redirect destination. It never follows a redirect or disables verification for
public internet traffic. A listener bound only to a non-loopback address can yield an inconclusive loopback failure.

HTTP 502/503/504 can reflect backend failure, maintenance, overload or routing issues. PHP-FPM process presence
does not establish worker health. The script never treats every HTTP error as a PHP failure or restarts
`emhttpd` merely because no process was detected.

Selected logs are read in tails of at most 64 KiB per file. Recognized timestamped error patterns within
15 minutes are distinguished from patterns without usable timestamps. Timestamp parsing is deliberately
limited to numeric nginx-style dates. Traditional syslog timestamps and unmatched messages remain uncorrelated;
older log lines do not establish a current fault. Full logs must be examined privately when needed.

Updater candidates are sampled over one second using process metadata and I/O counters. PID, parent PID and
elapsed time are shown; raw commands and arguments are omitted. A long-lived candidate with unchanged samples
is only **potentially stalled**. It may be waiting legitimately or have active descendants. The utility never
terminates updater processes. Inspect the complete tree, start identity, wait channels, child activity and
log progress locally before considering manual termination. Recheck process identity immediately before any
manual signal to avoid PID reuse. Never use broad commands such as `killall php`.

Illustrative synthetic output:

```text
[HEALTHY] nginx: process_count=2
[FAILED] php-fpm: No exact-name process detected
[FAILED] http: http port=8088 HTTP=502 seconds=0.01
[FAILED] diagnosis: HTTP failure with nginx present and PHP-FPM absent
```

Use `--verbose` or a TSV report for confidence, cause and recommended action. HEALTHY describes the individual
observation, not the entire server. UNKNOWN is not silently upgraded to HEALTHY.

## Repair workflow and safeguards

1. Complete diagnostics and display findings.
2. Offer only repairs whose observed prerequisites and installed helper dispatch are available.
3. Explain WebGUI session and management-request interruptions.
4. Require a numbered selection and a separate exact `YES`, each with a 60-second timeout.
5. Create a private audit report and acquire an exclusive repair lock.
6. Recheck resources, processes, configuration, endpoint responses and helper safety.
7. Run one selected helper with a clean environment and a 30-second command bound.
8. Recheck diagnostics and report recovery, failure or an inconclusive outcome.

The script neither edits nginx/PHP configuration nor deletes caches or application data. It never invokes
array, Docker, container, VM, networking, upgrade or reboot controls. Management-daemon recovery, stale-instance
cleanup, permission changes, configuration fixes and plugin-process termination remain manual.
Only installed nginx/PHP-FPM helper operations are dispatched. The helper itself must be reviewed if customized.

A helper timeout/failure can leave an operation incomplete; there is no automatic retry or rollback.
Do not assume a successful helper exit proves WebGUI recovery. Lock files may remain but the advisory lock
is released when the process exits. Ctrl-C/termination stops subsequent work and removes private scratch
files; already recorded report rows remain. Signal handling can wait for an active command to return.

## Reporting and privacy

Findings and progress go to stderr; help, version and generated report paths go to stdout.
TSV reports have nine columns: timestamp, component, status, severity, evidence, cause, confidence,
next action and repair availability. Human interpretation is separate from the structured fields.

Reports default to `/tmp/unraid-webgui-doctor/`, disappear after reboot, and are retained to a maximum of ten
files per report directory. Files use mode 0600 and the directory mode 0700. Approved repairs always create
a report; ordinary diagnosis does not. Private temporary raw captures are deleted at exit.

Raw logs, process command lines, environment variables, configuration dumps, cookies, authorization headers,
credentials, certificate keys and network identifiers are omitted instead of relying on fragile redaction.
Reports still reveal operational counts, status, ports, process IDs and version information. Review them
privately before sharing publicly. Do not upload real diagnostic output to this public repository.
Choosing a report directory on `/boot` increases flash writes; prefer `/tmp` or mounted persistent data storage.
Avoid capturing the shell's own tracing (`bash -x`), which can expose data withheld by normal output.

## Exit codes and troubleshooting

| Code | Meaning |
|---|---|
| 0 | No FAILED findings in the final assessment; UNKNOWN/WARNING findings may remain |
| 1 | Failed diagnostic finding, failed/inconclusive repair, or repair lock conflict |
| 2 | Unsupported Bash version |
| 3 | Expected Unraid host layout absent |
| 5 | Working-directory/report I/O problem |
| 13 | Insufficient privileges or unsafe report/lock ownership/path |
| 18 | Required tool missing |
| 22 | Invalid option or argument |
| 130 / 143 | Interrupted / terminated |

If a command is missing, the script does not install it. If nginx configuration validation fails,
run `nginx -t` privately to inspect the actual message and correct it before a restart.
If the interface still fails after a healthy local HTTP response, inspect browser behavior, certificate trust,
DNS, reverse proxies and the network path separately. Use version-specific Unraid support guidance for
management-daemon or unsupported service layouts.

## Development and validation

Run `python3 tests/validate.py` with ShellCheck installed, then
`python3 -m unittest discover -s tests -v`. Python is needed only for development tests.
Tests instrument a private copy of the deployed script, inject fixture paths and mock commands, and use
pseudo-terminals for confirmation tests. No test can intentionally dispatch a real service helper.

CI enforces syntax, ShellCheck, a documented deterministic BCS subset, sanitized fixtures and mock tests.
A separate required upstream BCS audit uses pinned tooling and the repository secret `BCS_OPENAI_API_KEY`.
Missing backend configuration fails that gate; a partial checker is not represented as full compliance.
See [CONTRIBUTING.md](CONTRIBUTING.md) for the standard revision, review process and intentional prompt policy.

## Updating and uninstalling

Review the new revision, rerun the installation download command and check syntax before using it.
To uninstall, remove `/boot/config/custom/scripts/unraid-webgui-doctor.sh` and any reports you no longer need.
There is no daemon, startup service, external configuration or plugin to remove.

## License

The existing [GNU General Public License version 3](LICENSE) is preserved. This utility is provided without
warranty. Contributions must preserve the safety boundaries and include reproducible, sanitized tests.
