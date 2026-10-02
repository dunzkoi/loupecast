# Contributing to Loupecast

Thanks for helping. This project is maintained by one person, so the rules below exist to keep reviews fast.

## Before you start

- For anything bigger than a small fix, open an issue first and wait for a 👍. Unrequested large PRs may be closed.
- One PR = one change. Don't mix refactors with fixes.

## Development

```sh
./build.sh
swift test
```

## How to open a pull request

1. Fork the repo and create a branch from `main`: `git switch -c fix/short-name`.
2. Make the change, then run `./build.sh` and `swift test`. Both must pass.
3. Commit, push to your fork, and open a PR against `dunzkoi/loupecast:main`. Fill in the template.
4. What happens next:
   - CI builds and tests on macOS, and a bot checks the title format.
   - An automated reviewer leaves inline comments and a verdict, usually within a few minutes. Reply or push a fix; it re-runs on every push.
   - The maintainer reviews, then squash-merges. Your PR title becomes the commit message and the changelog line.
5. After merge, release-please opens a release PR. Your change ships in the next release, and installed apps update themselves.

## Pull request rules

1. **Title** follows [Conventional Commits](https://www.conventionalcommits.org/): `feat: ...`, `fix: ...`, `docs: ...`, `refactor: ...`, `test: ...`, `chore: ...`. The title becomes the squash commit and the changelog entry.
2. **CI must be green.** Build, tests, and lint run on every PR.
3. **Tests:** changed logic needs a test that fails without your change.
4. **No new dependencies** without discussing in an issue first.
5. **UI changes** include a before/after screenshot or short video.
6. **AI-assisted PRs are fine** if you have run and understood the code. PRs that are clearly unreviewed generated output will be closed.
7. Fill in the PR template checklist.

An automated reviewer comments on every PR. Its verdict is advisory; the maintainer makes the final call.

## Reporting bugs

Use the bug report template and include your OS version, app version, and exact steps.
Security issues: do **not** open a public issue — see [SECURITY.md](SECURITY.md).
