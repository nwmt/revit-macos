# AGENTS.md

Scripts and shims that install Autodesk Revit (Windows x64) on Apple Silicon Macs
through CrossOver. Users are architects, not Wine experts: keep the user path
simple (`./install.sh <year>`) and the docs short.

## Layout
```
install.sh          single entry point: ./install.sh <year>
scripts/            every install step as a script; scripts/lib/versions.sh holds per-version metadata
tools/              our shim DLLs (C, llvm-mingw) and Python helpers; users get them prebuilt (scripts/get-shims.sh)
versions/<year>.md  status, what works, workarounds for one Revit version
docs/               troubleshooting, how it works
installers/         user-supplied installers and runtimes (gitignored except README and checksums)
```

## Rules
- Read CONTRIBUTING.md; enable hooks with `git config core.hooksPath .githooks`.
- English only; no personal data; no binaries. `.githooks/check-tree` must pass.
- Do not change behavior when editing comments. Shell scripts must pass `bash -n`.
- Status is factual: "works" only after a real Revit run.
- Bottles are disposable: a broken bottle is rebuilt, not repaired. One experiment, one bottle.
- If `internal/AGENTS.md` exists locally, read it too (private working notes, not in git).
