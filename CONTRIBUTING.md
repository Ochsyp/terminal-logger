# Contributing

Every change reaches `main` through a pull request, so that it is reviewed before it is merged.
This holds for the maintainer too.

## Workflow

1. Start from an up-to-date `main` and create a branch for the change:
   - `phase/<n>-<slug>` for a phase of the build, for example `phase/1-session-recorder`;
   - `fix/<slug>`, `feat/<slug>`, `docs/<slug>` or `chore/<slug>` for anything else.
2. Commit on that branch. Commit messages follow
   [Conventional Commits](https://www.conventionalcommits.org/en/v1.0.0/), for example
   `feat: show the REC marker in the prompt`.
3. Add an entry for the change under `## [Unreleased]` in [CHANGELOG.md](CHANGELOG.md), on the
   same branch.
4. Run the tests described under Testing: `bats tests/` passes. Locally a test may skip only for
   a reason listed there; CI fails on any skip.
5. Push the branch and open a pull request against `main`. The secret scan and the tests run on
   it.
6. Start the next phase only after the pull request is reviewed and merged. Its branch starts from
   the updated `main`.

One pull request holds one phase or one change.

## Guard rails

`main` is never committed to or pushed to directly, and no personal data should enter the
history. Git hooks in `.githooks` guard against both in each clone that turns them on:

- `pre-commit` refuses a commit while `main` or `master` is checked out, and a commit whose
  staged content, staged path names, author or committer holds a term from the denylist;
- `pre-merge-commit` runs the same checks before `git merge` records a merge commit;
- `commit-msg` refuses a commit message that holds a term from the denylist;
- `pre-push` refuses a push to `main` or `master`.

Turn them on once after cloning:

```text
git config core.hooksPath .githooks
```

The denylist is a local file outside the repository, at
`${XDG_CONFIG_HOME:-~/.config}/terminal-logger-dev/denylist`, or at the path in
`TERMINAL_LOGGER_DENYLIST`. It lists the names, host names and home paths that must never be
committed: one literal term per line, matched case-insensitively. Whitespace around a term is
ignored, and a line whose first non-blank character is `#` is a comment. Save the file as UTF-8
text: a byte order mark is ignored, and while the file holds NUL bytes, as UTF-16 text does,
every commit is refused. When the file is missing or holds no term, the hooks skip the check and
say so. A refusal names the offending files, never the term, and does not name a file whose path
holds the term.

The hooks search binary files too, and match UTF-16 text against ASCII terms only. They run only
for `git commit` and `git merge`, so the changes that `rebase`, `cherry-pick`, `revert` and `am`
replay are not checked, and they never check tags. Commit with your GitHub noreply address, so
that the author and committer fields hold no personal data either.

Do not bypass the hooks with `--no-verify`. After a pull request is merged, bring the local `main`
up to date with `git switch main` and `git pull --ff-only`.

## Privacy

Test data is synthetic only. Never commit a real session log, `.zshrc`, VPN profile or
screenshot. Examples use the user `kali@kali`, the home `/home/kali` and addresses from the
documentation ranges `192.0.2.0/24`, `198.51.100.0/24` and `203.0.113.0/24`, such as `tun0`
`192.0.2.10` and `wg0` `198.51.100.7`.

## Testing

Run the suite from the repository root:

```bash
bats tests/
```

- The ShellCheck test uses `shellcheck` from PATH, which should be 0.11.0 as in CI, and is
  skipped when it is not installed.
- Tests that need a real zsh, zsh's `zsh/zpty` module, util-linux `script` 2.35 or newer, the
  Linux `/proc`, symlinks, POSIX file modes, hard links, mawk, gawk or `/etc/skel/.zshrc` call
  `need` from `tests/helpers.bash`. They skip on a machine without them, such as Git for Windows,
  and fail when `TLOGGER_CI=1` is set. Where zsh is missing, `tests/stub-bin/zsh` answers the
  questions `bin/tlogger` asks zsh; the stub refuses to run under `TLOGGER_CI=1`. On Git for
  Windows, `MSYS=winsymlinks:sys bats tests/` lets the symlink tests run.
- `tests/config.bats` runs `lib/config.zsh` in `zsh -f`, checks every key, `prompt`, `stamp`,
  `stamp_vpn`, `vpn_ifaces` and `history_timestamps` included, and checks that it reads the same
  mode and logdir as the `read_config` of `bin/tlogger`. `tests/guard.bats` checks how the plugin
  sees its terminal over a fake process tree: `tests/helpers/fakeproc.zsh` writes made-up `stat`
  and `cmdline` files and a boot id into the folder that `TLOGGER_PROC` names. `TLOGGER_PROC`,
  default `/proc`, exists for the tests only, as do the config key `recorder` and
  `TLOGGER_RECORDER`, which name the `script` binary.
- `tests/autostart.bats` checks the autostart guard, `_tlogger_autostart_why`, in a real zsh
  without a terminal: each reason it gives, in the order of its contract, the presets and config
  keys it reads, and that it prints nothing. It runs the guard from a script file with
  `zsh -f -i FILE`, since `zsh -c` sets `ZSH_EXECUTION_STRING`, which is itself a reason.
- `tests/mode.bats` checks `tlogger mode` and the smoke test of the recorder in `tlogger mode` and
  `install`. `tests/stub-bin/tlogger-test-recorder` stands in for `script` there: it takes the
  options tlogger gives `script`, creates the empty logs and exits 0, or, with
  `TLOGGER_TEST_RECORDER_STATUS` set to 1-255, exits with that status and writes nothing.
  Wherever `install` or `tlogger mode` must pass the smoke test, `installer.bats` and `mode.bats`
  name the stub, in `TLOGGER_RECORDER` or in the config key `recorder`, so that those tests run
  without `script`. One `mode.bats` test runs the real `script`, and `tests/e2e-auto.bats`
  installs with it.
- `tests/e2e-manual.bats` records for real, without tmux. It installs tlogger from the work tree
  into the test's HOME and drives an interactive zsh in a pseudo-terminal through zsh's own
  `zsh/zpty` module, with the functions in `tests/helpers/pty.zsh`. The driver types lines, waits
  for output at most 20 seconds a time and runs under `timeout`, and it frames each command with
  marker commands that give its output and exit status. A wait that gives up, or that sees the
  shell in the terminal end first, fails the test with the end of the terminal output, control
  characters shown as `^X`; the whole transcript is the file `screen` in the test's temp folder,
  which `bats --no-tempdir-cleanup` keeps. The rc is `tests/fixtures/e2e-zshrc`, which turns the
  line editor off, and in one test the rc built from `/etc/skel/.zshrc`. These tests need Linux,
  zsh with the `zsh/zpty` and `zsh/zselect` modules, util-linux `script`, symlinks, POSIX modes
  and a non-root user.
- `tests/journal.bats` checks the command journal, the UTC stamps, the VPN list and the prompt
  segment in a real zsh without a terminal. `zsh -c` runs no hook by itself, so most tests call
  `_tlogger_preexec` and `_tlogger_precmd` themselves; the test of `$?` after a `precmd()` that
  ends with another status runs `zsh -f +o promptsp -i -s` on a file of commands instead, where
  zsh runs the hooks before each prompt. The fake `/proc` of `fakeproc.zsh` sets the state, and a
  test that forces REC by hand, with `_tlogger_state` and `TLOGGER_SESSION`, says so.
  `fake_sysfs` in `tests/helpers.bash` builds a fake `/sys/class/net` for `TLOGGER_SYSFS`, and
  `tests/stub-bin/tlogger-test-ip` stands in for `ip -o addr show` through `TLOGGER_IP`, with
  addresses the plugin must refuse among its lines; it counts its runs in the file that
  `TLOGGER_TEST_IP_LOG` names. `TLOGGER_SYSFS` (default `/sys`) and `TLOGGER_IP` exist for the
  tests only. One test calls the `configure_prompt` of `/etc/skel/.zshrc` in both of its Ctrl+P
  states. Its helper `run_hooks` runs zsh under `timeout`, so that a hook that hangs, as on a
  FIFO in place of the journal, fails its test instead of holding up the suite.
- `tests/e2e-prompt.bats` drives recorded and unrecorded terminals as `tests/e2e-manual.bats`
  does and checks the S and E lines in `commands.tsv`, the dim stamp in `output.raw`, the
  journal of a nested zsh, the REC, NOREC and EXT segments, `prompt=off`, `stamp=off`,
  `NO_COLOR`, and the segment after Ctrl+P twice under the rc built from `/etc/skel/.zshrc`, with
  the line editor on. It matches only whole notices, the segment and the line end after it, so
  that the redraws of the line editor do not matter. CI has no iproute2, and its container may
  have tunnel devices of its own, so each test names a fake sysfs.
- `tests/e2e-auto.bats` does the same for auto mode, on `tests/fixtures/e2e-auto-zshrc`, which
  sets `E2E_RC_DONE` after the tlogger block, so that a test can tell which shell loaded the rest
  of the rc. In auto mode `script` passes on what was typed before it started, so a line typed
  into a new terminal runs in the recorded shell; `pty_auto_shell` therefore types nothing until
  the banner and the REC line have come, and finds the shell that zpty started, the parent of
  `script`, through `/proc`. `pty_wait_gone` waits until a closed terminal's shell has ended, and
  `pty_close` ends a terminal so that the next one can start.
- git stores the hooks, `bin/tlogger`, the stubs in `tests/stub-bin` and every `.bats` file as
  executable files, and the sourced files as plain ones; a lint test checks the modes in the
  index. Where `core.filemode` is false, as on Git for Windows, stage a new executable file with
  `git add --chmod=+x`, and check the modes with `git ls-files -s`.
- Tests tagged `root` (`# bats test_tags=root`) run only as root and skip otherwise. The other
  tests expect a non-root user: tlogger refuses root with a HOME that is not root's, so a run as
  root fails them by design.
- To run the suite as CI does, on Linux with zsh, util-linux, mawk and gawk installed, run the
  untagged tests as yourself, then the root tests as root:

  ```bash
  TLOGGER_CI=1 bats --filter-tags '!root' tests/
  sudo env TLOGGER_CI=1 bats --filter-tags root tests/
  ```

- `TLOGGER_SKEL` names the file that `bin/tlogger` seeds a missing rc from, in place of
  `/etc/skel/.zshrc`. It exists for the tests only.
- CI runs the suite on every pull request and every push to `main`, in a `kalilinux/kali-rolling`
  container with real zsh and util-linux. There the suite, the zsh-based tests included, runs as
  a non-root user with `--filter-tags '!root'`, and the tests tagged root run afterwards as root.
  CI fails when any test fails or is skipped, and when the two runs together do not run every
  test that `bats --count tests/` counts.

### zsh pitfalls

A machine without zsh skips every zsh test, so CI is often the first place new zsh code runs.
Check new code against these rules and the zsh documentation before it gets there:

- In double quotes, zsh joins an array before `(q)` quotes it and before `(o)` sorts it. Write
  `"${(j: :)${(@q)a}}"`, with `(@)`, or leave the array unquoted.
- An `exit` inside nested functions waits until they return, and zsh then runs the `zshexit`
  hooks with that exit still pending, where the first shell function a hook calls makes the hook
  return early. `_tlogger_zshexit` therefore calls builtins only, and the plugin runs `exit` at
  most one function deep, where the hooks run in full.
- `zselect -t N` returns 1 when its time runs out; a function that ends with it returns 0
  itself.
- `zsh -c` sets `ZSH_EXECUTION_STRING`, which stops autostart, so a test that needs autostart to
  pass that check runs its code from a script file.
- With job control on, a foreground job that a signal kills can leave the terminal raw: no echo,
  and no CR before LF. A test driver does not depend on either afterwards.
- `$(<file)` reads a file without a fork; every other command substitution forks.
- `zsh -c` runs no `precmd` or `preexec` hook. `zsh -i FILE` runs `preexec` for each command of
  the file but never `precmd`; `zsh -i -s` with commands on stdin runs both, and prints its
  prompts on stderr. Without a terminal, as in CI, it also writes its `PROMPT_SP` mark there
  before each prompt: a `%` (`#` for root), spaces and CRs. Start it with `+o promptsp`.

### Hook rules

The `precmd` and `preexec` hooks run on every prompt and every command, so they follow these
rules:

- No fork per command. Builtins and `$(<file)` only; `sysopen`, `print -u` and closing the file
  descriptor append to the journal. Only `ip` and `df` fork, at a rate that bounds them: `ip` when
  the VPN interfaces change or a minute has passed, or 5 seconds after it showed a VPN interface
  without an address; `df` at most every five minutes.
- `$?` first. `_tlogger_precmd` reads `$?` in its first statement: zsh hands each hook function
  the status of the user's command, since `callhookfunc` (`Src/utils.c`) runs it through
  `doshfunc` (`Src/exec.c`) with `noreturnval` set, which restores `lastval` after each function,
  Kali's `precmd()` included. Any statement before it would put its own status there.
- Silence. A missing session folder, a read-only file or a failed write prints nothing and stops
  nothing; a hook never changes `$?`, the options or the traps of the user. The journal is opened
  nonblocking, so that a FIFO in its place cannot hold up a prompt.
- The prompt. A hook never replaces `PROMPT` wholesale: it takes out the exact text it added
  last time and inserts the new one, with every `%` doubled. It never touches `RPROMPT`,
  `PROMPT_CR` or `PROMPT_SP`, and Kali's `precmd()` stays as it is.

### Moving the Kali image

Dependabot does not update container images in workflow files, so `.github/workflows/tests.yml`
pins `kalilinux/kali-rolling` by digest and a pull request of its own moves the pin. The current
digest of the `latest` tag, the index that covers every platform, is the `digest` field of the
Docker Hub tags API:

```bash
curl -fsS https://hub.docker.com/v2/repositories/kalilinux/kali-rolling/tags/latest | jq -r .digest
```

Put the digest after the `@` in `container.image`, and say in the pull request when Docker Hub
last updated the tag, its `last_updated` field.
