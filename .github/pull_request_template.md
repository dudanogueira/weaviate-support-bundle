## What changes

<!-- One or two sentences. -->

## Checklist

- [ ] Still read-only: no new kubectl verb, no HTTP method other than GET (`tests/check-read-only.sh` passes)
- [ ] New data sources are redacted; a planted secret in the tests proves it
- [ ] `bash tests/run-all.sh` passes locally
- [ ] Bundle format changes are documented in `docs/bundle-format.md` (and `schema_version` bumped if breaking)
- [ ] `CHANGELOG.md` updated under "Unreleased"
- [ ] Customer-facing text (USAGE.md, terminal output, SUMMARY.md) is plain and short
