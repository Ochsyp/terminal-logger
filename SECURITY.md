# Security policy

## Reporting a problem

Report a vulnerability through GitHub's private vulnerability reporting: open the repository's
**Security** tab and choose **Report a vulnerability**. If the tab offers no such button, open an
issue that asks for a private contact and holds no details of the problem.

Never attach a real session log to a report, an issue, a pull request or a commit. A log holds
everything typed and shown in the recorded terminal, passwords included. Reproduce the problem
with synthetic data instead.

## Automated checks

- gitleaks scans the commits that each push adds, and the first 30 commits of a pull request,
  along the first parent and without merge commits. Only a manual run scans the full history
  (`.github/workflows/secret-scan.yml`).
- Dependabot keeps the pinned GitHub Actions up to date.
