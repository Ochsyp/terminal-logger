# terminal-logger

A planned recorder for zsh terminal sessions on Kali Linux, keystrokes included, as evidence for
penetration tests.

> **Status:** phase 0, repository scaffolding only. There is nothing to install yet.
> [CONTRIBUTING.md](CONTRIBUTING.md) describes the workflow, and [CHANGELOG.md](CHANGELOG.md)
> lists what changed.

## What it will do

The planned `tlogger` command:

- records every new terminal with util-linux `script`: keystrokes and screen output, with timing
  (`--log-in`, `--log-out`, `--log-timing`, advanced format);
- captures passwords typed at hidden prompts, and everything inside reverse shells, unstable
  shells and subshells, because `script` wraps the outer terminal;
- keeps a command journal with the start time of each command in UTC;
- shows a `REC` or `NOREC` marker in Kali's own prompt;
- replays a session with `scriptreplay`;
- renders a session as a plain-text transcript offline with `python3-pyte`, with no tmux anywhere;
- seals a finished session with SHA-256 sums, which expose a later change only while a copy of
  the sums is kept apart from the logs;
- keeps its logs under `~/.local/state/tlogger`, with mode 0700 for directories and 0600 for
  files.

## Security

The logs hold everything typed and shown in a recorded terminal, passwords included.

- Keep the log folder on encrypted storage, such as a LUKS volume, with private permissions.
- Record only systems and engagements you are authorized to test. Keep and destroy the logs
  under the engagement's rules.

[SECURITY.md](SECURITY.md) describes how to report a vulnerability.

## Development

Turn on the git hooks once after cloning:

```text
git config core.hooksPath .githooks
```

They refuse commits on `main` or `master` and pushes to them. They also refuse a commit whose
staged content, path names, message, author or committer holds a term from your local denylist.
[CONTRIBUTING.md](CONTRIBUTING.md) describes them, what they do not check, and the workflow.

Run the tests from the repository root with [bats-core](https://github.com/bats-core/bats-core):

```bash
bats tests/
```

The ShellCheck test needs `shellcheck` on PATH and is skipped without it. CI runs the suite with
ShellCheck 0.11.0 and fails when any test is skipped.

## Licence

MIT, see [LICENSE](LICENSE).
