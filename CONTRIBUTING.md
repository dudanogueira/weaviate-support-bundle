# Contributing

Guide for anyone changing this repository, people and AI coding agents
alike. Read it before editing. Treat this repository as public: never add
real user or company names, internal URLs, ticket links, or anything from a real bundle
(fixtures must be synthetic).

## What this is

`collect.sh` is run by Weaviate users on their own machine, against their
own Kubernetes cluster, usually without any AI help. It produces a bundle
(folder + `.tar.gz`) that Weaviate support reads. Support engineers and tools read
bundles, so the output format must stay stable (see `docs/bundle-format.md`).

## Rules that are never broken

1. **Read-only.** The tool must never change anything in the user's
   cluster or in Weaviate.
   - Only `lib/guard.sh` runs `kubectl` or `curl`. Everything else calls
     `kc`, `kc_raw_get`, `tunnel_open` or `http_get`.
   - `kc` allows `get`, `logs`, `version`, `config current-context`. Do not
     widen it. `kc get` refuses Secrets unless `--include-helm` is set.
     `kc_raw_get` allows a fixed list of paths, each with exactly one
     Kubernetes name in it (no `/`).
   - `http_get` is GET only, only for Weaviate's REST API (`/v1/...`) and
     `/metrics`, and refuses Weaviate's debug port (6060), whose endpoints can
     change state. `tunnel_open` refuses the debug port too
     (`GO_PROFILING_PORT`, default 6060).
     The one exception: with `--include-profiling`, the exact pprof GETs in
     `_pprof_allowed`, through a local tunnel, without the API key. Do not
     widen that list; never add `cmdline`, `trace` or other `/debug` paths.
   - No `kubectl exec`, even for "read-only" commands like `df`.
   - `tests/check-read-only.sh` enforces this. Never weaken that test to make
     a change pass.
2. **No database content.** Never collect objects, vectors, or query results.
   Metadata only: configuration, status, counts, logs, metrics.
3. **Redact before the bundle leaves the temp folder.** Everything is staged
   in a private temp folder (`$WORK`, mode 700) and goes through
   `scrub_bundle` (lib/finalize.sh) before it is copied out. Structured
   redaction (env vars, config maps, Helm values) happens at collection time;
   the final pass scrubs content patterns and known secret values from every
   file. New collectors get this for free if they write into `$STAGE`.
   If you add a source that can contain secrets, add a test fixture with a
   planted secret to `tests/test-redaction.sh` or the e2e test.
4. **Never stop on a failed step.** Every collector runs through `run_step`
   and returns a status code (0 ok, 10 skipped, 11 forbidden, 12 not found,
   13 unavailable, other = error). Only discovery problems (no cluster, no
   Weaviate StatefulSet) stop the tool.
5. **Minimal prerequisites.** bash 3.2+ (macOS default), kubectl, curl,
   jq 1.6+, and standard POSIX tools. No Python, Node or other runtimes in the
   tool itself (python3 is used only by the e2e test). bash 3.2 means: no
   associative arrays, no `mapfile`, no `${var,,}`, careful with `set -u`.
   Avoid regex intervals (`{n,m}`) in awk: mawk on Debian/Ubuntu lacks them.
   Put regex work in jq instead.
6. **Stable output.** Adding files or fields is fine. Renaming, removing or
   changing the meaning of files, fields or finding codes needs a
   `schema_version` bump in `lib/common.sh` and a note in `CHANGELOG.md` and
   `docs/bundle-format.md`.
7. **Plain language.** README, terminal output and SUMMARY.md are read by
   users under pressure, often not native English speakers. Short
   sentences, no jargon where a plain word works.
8. **The agent skill is read-only too.** `SKILL.md` lets agents run only
   `collect.sh` (preflight first, `--yes` only after the user agrees) and
   `read-bundle.sh`. `read-bundle.sh` never unpacks to disk, never contacts a
   cluster, reads only files listed in the manifest, and refuses symlinks and
   `..`. Keep the skill's rules and these checks in `tests/test-skill.sh`.

## Layout

```
collect.sh            entry point: options, then discover → approve → collect → summarise → redact → pack
lib/common.sh         output helpers, temp workspace + cleanup trap, run_step, sections
lib/guard.sh          THE read-only gate: kc, kc_raw_get, tunnel_open/close, http_get
lib/discover.sh       find the StatefulSet and pods, probe permissions, preflight table, approval
lib/kubernetes.sh     Kubernetes collectors
lib/weaviate.sh       Weaviate API collectors
lib/metrics.sh        per-pod tunnels: health checks and two metrics snapshots
lib/logs.sh           current and previous container logs
lib/disk.sh           volume usage via kubelet stats (optional permission)
lib/helm.sh           Helm release info (only with --include-helm)
lib/profiling.sh      Go profiles from the debug port (only with --include-profiling)
lib/summary.sh        manifest.json, findings.json, SUMMARY.md
lib/finalize.sh       final redaction pass, anonymization, archive
lib/jq/redact.jq      redaction rules (names and content patterns)
lib/jq/findings.jq    red-flag rules → findings.json
lib/jq/summary.jq     SUMMARY.md renderer
lib/jq/metrics.jq     metrics parsing and summary
rbac/                 optional read-only RBAC for users
USAGE.md              the user guide (README stays short and links to it)
AGENTS.md             entry point for AI agents: the skill to collect/read bundles, this file to change code
.agents/skills/weaviate-support-bundle/
                      the agent skill (Agent Skills format): SKILL.md, scripts/read-bundle.sh,
                      references/findings.md (every red-flag code), references/weaviate-facts.md
.claude/skills/       symlink to the skill, so Claude Code finds it
docs/                 bundle format (the contract), permissions, releasing
tests/                static check, guard, redaction, offline end-to-end (fake kubectl + fake Weaviate)
tests/kind/run.sh     real-cluster test: kind + official Helm chart, 3 replicas, broken pods
tests/playground/     local kind cluster with Weaviate and scenarios that break it (for contributors)
.github/workflows/    ci.yml (every PR and push to main), release.yml (on a v*.*.* tag)
```

## Common changes

**Add a collector.** Write a function that reads with `kc`/`http_get`, writes
JSON with `write_json` into `$STAGE/...`, calls `step_detail` with a short
result, and returns a status code. Register it with `run_step` in the
section's `collect_*` function. Add the file to `docs/bundle-format.md`, and
to the e2e fake (`tests/fake/`) plus an assertion in `tests/test-e2e-offline.sh`.

**Add a red flag.** Add a rule to `lib/jq/findings.jq` with a new stable
`code`, add it to the table in `docs/bundle-format.md` and to the skill's
`references/findings.md` (what it means, what to check next), and plant the
condition in the e2e fake so the test proves it fires. Only flag what the data
shows; put the reasoning in `detail` and point `file` at the evidence.

**Add a metric.** Add its name to `METRICS_KEEP` in `lib/metrics.sh`. Keep the
list short: only metrics support actually reads. Check the exact name in
Weaviate core (`usecases/monitoring/prometheus.go`).

**Touch Weaviate API or env var names.** Verify them against Weaviate core
source (OpenAPI spec in `openapi-specs/schema.json`, env parsing in
`usecases/config/environment.go`) for every Weaviate version support still
covers, not just the latest.

## Testing

```bash
bash tests/run-all.sh        # all offline tests, a few seconds, no cluster
bash tests/kind/run.sh       # real cluster, about 5 minutes (docker, kind, helm)
```

- `tests/check-read-only.sh`: static: no direct kubectl/curl, only read verbs, GET only.
- `tests/test-guard.sh`: the gate blocks write verbs, raw paths, debug port, non-HTTP URLs.
- `tests/test-redaction.sh`: planted secrets never survive; safe values do.
- `tests/test-findings.sh`: red-flag rules on hand-written facts, for edge cases.
- `tests/test-skill.sh`: SKILL.md format, every finding code documented, and
  `read-bundle.sh` refusing symlinks, `..`, absolute paths and hostile archives.
- `tests/test-e2e-offline.sh`: full run against `tests/fake/kubectl` and
  `tests/fake/weaviate_server.py` with planted problems and secrets. Set
  `KEEP=/some/dir` to keep the produced bundle.
- `tests/kind/run.sh`: throwaway kind cluster, official Helm chart, 3
  replicas, sample data, a viewer API key, then an OOM-killed and a
  crash-looping pod. Uses its own kubeconfig and deletes the cluster at the
  end. `WEAVIATE_VERSION=1.40.3` picks the image; `OUT=/some/dir` keeps the bundles.

CI runs all of these on every pull request (`.github/workflows/ci.yml`).

## Playground

`tests/playground/playground.sh` keeps a kind cluster with Weaviate running,
so you can break it in known ways and see what `collect.sh` makes of it.
Use it to reproduce a bug and to prove the fix.

```bash
tests/playground/playground.sh up                  # kind + Helm chart + sample data, about 5 minutes
tests/playground/playground.sh list                # scenarios and what each should flag
tests/playground/playground.sh scenario oom        # break something
tests/playground/playground.sh collect             # run collect.sh with a read-only (viewer) key
tests/playground/playground.sh revert oom
tests/playground/playground.sh verify --all        # apply, collect, check findings, revert; exit code
tests/playground/playground.sh demo                # one run with many red flags, then the summary
tests/playground/playground.sh down
```

- It writes to the cluster it created, and only to that one: its own
  kubeconfig in `.playground/` (gitignored), only kind clusters named `wsb-*`.
  Like `tests/kind/run.sh`, it is test tooling: the read-only rules above are
  for `collect.sh`, and the support skill never runs it.
- `tests/kind/run.sh` uses the same setup (`tests/playground/lib.sh`), so CI
  tests what the playground runs.
- **Add a scenario:** a file `tests/playground/scenarios/<name>.sh` that sets
  `SC_DESC`, `SC_KIND` (`pod`: break one pod through the StatefulSet template;
  `config`: keep a template change; `custom`: your own `sc_apply`/`sc_revert`),
  `SC_EXPECT` (finding codes), and optionally `SC_ABSENT`, `SC_NO_HIGH`,
  `sc_wait` and `sc_check <bundle>`. See `lib.sh` for the details and the
  existing scenarios for examples. When you add a red flag, add a scenario that
  makes it fire.

## Releases

See `docs/releasing.md`: semantic versioning, `TOOL_VERSION` in
`lib/common.sh`, a `CHANGELOG.md` entry, then push a `v*.*.*` tag.
