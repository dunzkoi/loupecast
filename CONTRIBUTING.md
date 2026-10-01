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
