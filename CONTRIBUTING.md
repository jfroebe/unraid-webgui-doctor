# Contributing

Keep the deployed utility one self-contained Bash file and keep this project independent of other repositories.
Use generic fixtures only. Do not attach real server diagnostics, credentials, hostnames, network addresses,
paths, or process command lines to public issues or pull requests.

Read the [Bash Coding Standard](https://github.com/Open-Technology-Foundation/bash-coding-standard).
This project pins revision `4098bc5d4e6c7ffd6dab8b2d00206fed3f9ecdec` for review and CI.
Use Bash 5.2+ and ShellCheck; run:

```text
python3 tests/validate.py
python3 -m unittest discover -s tests -v
bash /path/to/bash-coding-standard/bcs check -m gpt5 -e high --strict unraid-webgui-doctor.sh
```

The upstream checker is LLM-based and requires a separately configured backend. CI uses the repository secret
`BCS_OPENAI_API_KEY` for that audit. Never commit the key. Missing credentials block the audit and release;
the deterministic subset checker is not an equivalent replacement. Fork PRs do not receive repository secrets:
review their code first, then validate on a trusted branch. Do not use `pull_request_target` to expose secrets.

Document live validation separately from mock tests. Before enabling another repair, establish supported
service behavior on the relevant Unraid version and add tests for approval, refusal, stale diagnosis,
helper failure and failed verification. Never use production storage, Docker, networking or VMs for recovery experiments.

The script intentionally requires explicit confirmation for every repair. This overrides the optional
unattended confirmation pattern illustrated in BCS0709; there is no force/assume-yes mode.
No external configuration is sourced (BCS0111 is inapplicable). Output is plain text by design;
`--no-color` is an accepted no-op. Standard Unraid paths take precedence over generic FHS placement.

Preserve the existing GNU GPL version 3 license. Human review of all BCS rules remains necessary even when
automated checks pass; heuristic and LLM validators can miss defects or produce false positives.
