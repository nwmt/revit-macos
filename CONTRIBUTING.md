# Contributing

The most useful contribution is a test report: which Revit version, which Mac,
which CrossOver version, what worked and what didn't. Open an issue with the
"Test report" template.

## Pull requests

1. Enable the hooks once: `git config core.hooksPath .githooks`
2. Branch: `type/short-description` (e.g. `fix/wv2fix-repaint`).
3. Commits: [Conventional Commits](https://www.conventionalcommits.org/),
   `type(scope): description`. Types: `feat fix perf refactor style docs chore test ci build`.
4. English only — code, comments, docs, commit messages.
5. No personal data (names, emails, hostnames, `/Users/<name>` paths), no
   installers, DLLs from Windows, license files or logs. The hooks check this;
   `.githooks/check-tree` runs the full check by hand.
6. Every manual step must also be a script in `scripts/`, so a bottle can be
   rebuilt from scratch.
7. Mark a feature as working only after a real run. Untested is "not tested",
   a guess is a guess.

Never commit or link Autodesk software. Everyone uses their own installer and
license from their Autodesk Account.
