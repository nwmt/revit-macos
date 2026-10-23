# Contributing

## Test reports

The most useful contribution is a test report: which Revit version, which Mac, which CrossOver version, what worked
and what did not. Open an issue with the **Test report** template and attach what `./revit report <year>` makes
([Report a problem](docs/troubleshooting.md#report-a-problem)).

`./revit test <year>` adds a check that runs by itself. It starts Revit in a temporary copy of your bottle on this Mac,
using the sign-in you made there, and deletes the copy afterwards; Autodesk files and licensing are not changed. In the
copy it plays short journals: start and quit, a new project from a template saved with Save As, then that file
opened again and saved under a new name. It reports each one as passed or failed, with times. It does not check
sign-in, add-ins, web panels, exports or how Revit looks. Before it runs: sign in once by starting Revit from
`~/Applications`, quit Revit, run `./revit stop <year>` (Autodesk's background services keep the bottle busy for hours),
and leave the Mac alone while Revit opens and closes. Then run `./revit report <year>`: the report includes the test
result. Revit starts as usual, so Autodesk's sign-in check and usage reporting run as they do when you start it
yourself. Not tested yet: whether a test run can make Revit 2024 or newer ask you to sign in again in your own
bottle.

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
9. `tests/revit-cli.sh`, `tests/plans.sh`, `tests/steps.sh`, `tests/shims.sh`, `tests/smoke.sh` and
   `python3 -I -m unittest discover -s tests -p 'test_*.py'` must pass. After a
   deliberate change to a year's plan or steps, `UPDATE=1 tests/plans.sh` rewrites
   `tests/plans/`; review that diff.
10. The menu bar app's Swift tests run with `app/test.sh`. The app has no UI tests: check a change to a view by
    running the app.

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
| What `./revit test` checks | CONTRIBUTING (Test reports) |
| The run record in a bottle | `docs/how-it-works.md` |
| Revit MCP Server: what it turns on, install, connecting an AI assistant | `docs/mcp.md` |

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
- Every warning a command prints (`!` lines of `./revit check` and `./revit doctor`) has a second line that says what
  to do.

## Supporting a new Revit year

1. `python3 -I -B tools/installer_drift.py packages installers/extracted/revit<year>` lists the installer's packages
   against the nearest year's `PKGS`.
2. Add `scripts/profiles/<year>.sh` (copy the nearest year) and the year's cases in `tests/steps.sh` and the add-in
   catalogs in `scripts/addins/`; `UPDATE=1 tests/plans.sh` writes `tests/plans/<year>.txt`. Add the year's journal
   version to the table in `tools/smoke.py` (from a journal Revit wrote for that year).
3. Install it, sign in once, then `./revit doctor <year>`, `./revit test <year>` and `./revit report <year>`.
4. Add the README row and `versions/<year>.md` only with what a real run showed.

The journals of `./revit test` in `scripts/smoke/` are written by hand: `Jrn.*` command lines and our own comments,
never a journal Revit recorded and never text from another project's journals. `python3 -I -B tools/smoke.py lint`
checks them.

## Releases

Shim DLLs are built and published by GitHub Actions, never by hand: push a tag `vX.Y.Z`.
Then set `SHIMS_VERSION` and `SHIMS_SHA256` in `scripts/lib/shims.sh` to the new release, so
`./revit install` downloads it. Until then, clones with changed shim sources build them from source.

The menu bar app is built and published the same way: push a tag `app-vX.Y.Z` (`.github/workflows/app.yml` runs
`app/build.sh` and publishes a pre-release with the DMG and the 7-Zip and cabextract sources). The tools it bundles
are pinned in `app/tools.sh`, its name and minimum macOS in `app/app.conf`. If the shim sources changed since the
pinned shims release, release the shims first: the app build refuses shims that do not fit the sources.
`app/build.sh <version>` builds the same DMG locally; the Command Line Tools are enough.

Locally, `scripts/build-shims.sh [name…]` builds shims into `build/<name>/` (the compiler comes from
`scripts/get-toolchain.sh`). The list of shims is `SHIMS` in `scripts/lib/shims.sh`; each one's flags are in
`build-shims.sh`.

Never commit or link Autodesk software. Everyone uses their own installer and
license from their Autodesk Account.
