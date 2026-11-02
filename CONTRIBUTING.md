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
4. Run the tests described under Testing: `bats tests/` passes with nothing skipped.
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
screenshot. Examples use the user `kali@kali`, the home `/home/kali` and addresses from
`192.0.2.0/24`.

## Testing

Run the suite from the repository root:

```bash
bats tests/
```

- The ShellCheck test uses `shellcheck` from PATH, which should be 0.11.0 as in CI, and is
  skipped when it is not installed.
- Tests that need zsh arrive in later phases and run in CI.
- CI runs the suite on every pull request and every push to `main`, and fails when any test is
  skipped.
