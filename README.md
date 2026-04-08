# Qt flag probe

Workflow: `.github/workflows/qt-flag-probe.yml`

Checks which Qt versions support BOTH:
- `-no-emojisegmenter`
- `-c++std c++23`

No fallback / no workaround: versions that fail are reported as FAIL.

Run: Actions → "Qt flag probe (c++23 + -no-emojisegmenter)" → Run workflow.
Optionally enable `make_release` to upload a merged report into a pre-release tag `qt-flag-probe`.
