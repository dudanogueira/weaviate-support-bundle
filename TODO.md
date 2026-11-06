# TODO

Planned work. Each item ships in its own release.

## Pod profiling (planned for a future minor version)

An optional step, off by default and turned on with a flag (for example
`--profile`), that captures Go profiles from the Weaviate pods for
performance investigations: CPU, heap, goroutines, and possibly block and
mutex profiles. Existing profiling scripts will be adapted into this step.

What the step must respect:

- **Read-only stays the rule.** Profiles come from Weaviate's debug port
  (6060 by default). That port also serves endpoints that change state, so the
  read-only gate (`lib/guard.sh`) blocks it today. The step must allow only an
  explicit list of profiling `GET` paths, and nothing else on that port.
- **The debug port is off by default** (`DEBUG_ENDPOINTS_ENABLED`, off since
  Weaviate 1.36.18). The step must detect this and say so on the approval
  screen instead of failing.
- **A CPU profile adds load while it runs.** Keep it short, show the duration
  on the approval screen, and profile one pod at a time.
- **Check what profiles contain** (for example pprof labels) for tenant or user
  names before release, and redact or anonymize them like other files.
- **Bundle format:** new files under `pods/<pod>/profiles/`, documented in
  `docs/bundle-format.md`. New files mean a minor version, no schema bump.
- **Tests:** a fake profiling endpoint in `tests/fake/`, read-only checks for
  the new paths in `tests/test-guard.sh`, and a kind run with
  `DEBUG_ENDPOINTS_ENABLED=true`.
