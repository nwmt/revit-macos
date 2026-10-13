# Contributing

## Test reports

The most useful contribution is a test report: which Revit version, which Mac, which CrossOver version, what worked
and what did not. Open an issue with the **Test report** template. `./revit logs <year>` shows where the logs are;
[Report a problem](docs/troubleshooting.md#report-a-problem) says which file to attach.

## Pull requests

1. Enable the hooks once: `git config core.hooksPath .githooks`
2. Branch: `type/short-description` (e.g. `fix/wv2fix-repaint`).
3. Commits: [Conventional Commits](https://www.conventionalcommits.org/),
   `type(scope): description`. Types: `feat fix perf refactor style docs chore test ci build`.
4. English only — code, comments, docs, commit messages.
5. No personal data (names, emails, hostnames, `/Users/<name>` paths), no
   installers, DLLs from Windows, license files or logs. The hooks check this;
   `.githooks/check-tree` runs the full check by hand.
6. Every manual step must also be a step in `scripts/steps/` (or a script in
   `scripts/`), so a bottle can be rebuilt from scratch.
7. Mark a feature as working only after a real run. Untested is "not tested",
   a guess is a guess.
8. Status words: see the scale in the [README](README.md#which-versions-work).
9. `tests/revit-cli.sh`, `tests/plans.sh`, `tests/steps.sh` and
   `python3 -I -m unittest discover -s tests -p 'test_*.py'` must pass. After a
   deliberate change to a year's plan or steps, `UPDATE=1 tests/plans.sh` rewrites
   `tests/plans/`; review that diff.

## Writing docs

Each fact lives in one place. Other pages link to it instead of repeating it.

| Fact | Lives in |
|---|---|
| Version status | First line of `versions/<year>.md`; the summary in the README table |
| Requirements for all versions (Mac, CrossOver, Rosetta 2, Homebrew, license, msls31.dll) | README |
| Which file goes where; disk space per version | `installers/README.md` |
| Install, `./revit` commands, updating | README |
| First launch (2020, 2023 and 2024 and newer) | README |
| Issues of one version, with a one-line workaround | `versions/<year>.md` |
| Problems by symptom, shared by versions, longer workarounds, how to report a problem | `docs/troubleshooting.md` |
| Install steps and fixes per version | `docs/how-it-works.md`, one matrix |
| Microsoft components in the bottle and where each comes from | `docs/how-it-works.md` |
| Speed numbers | `docs/benchmarks.md`; one sentence in the README |
| Status scale | README |

A version page has these sections, in this order: the status line, `## Works`, `## Known issues`, `## Not tested`,
`## Notes` (only if needed).

Wording:

- **bottle**: at its first mention in the README, "a separate Windows environment that CrossOver keeps for one Revit
  version".
- **fix** on user pages; **step** and **shim** only in `docs/how-it-works.md`.
- `./revit install`, not "the install" as a noun.
- **web panels**, not "dock panels", "dockable" or "web-based dock panels".
- Names from Revit's interface in bold: **Revit PDF**, **Always Load**, **Autodesk Sign-In (rvt2025-a)**. Menus as
  File → Export → PDF.
- Versions as `2025.5`; the build once, in parentheses: 2025.5 (build 25.5.0.57).
- "do not", "does not": no contractions. Numbers as 90%, 10–30 minutes, 12 GB, 2×.
- The status words Works, Mostly works and Not tested appear only in a version's status line and the README table.
- Tone: "you", present tense, facts. No "simply", "just", "seamless", no superlatives.
- At most one alert (`> [!NOTE]` and the like) per page. No badges, banners or hand-made table of contents.

## Releases

Shim DLLs are built and published by GitHub Actions, never by hand: push a tag `vX.Y.Z`.
Then set `SHIMS_VERSION` and `SHIMS_SHA256` in `scripts/lib/shims.sh` to the new release, so
`./revit install` downloads it. Until then, clones with changed shim sources build them from source.

Never commit or link Autodesk software. Everyone uses their own installer and
license from their Autodesk Account.
