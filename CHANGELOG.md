# Changelog

All notable changes are listed here. Versions follow
[semantic versioning](https://semver.org); see `docs/releasing.md`.

## Unreleased

- For contributors: `tests/playground/playground.sh`, a local kind cluster with
  Weaviate, sample data and scenarios that break it in known ways.
  `tests/kind/run.sh` now uses the same setup.
- `--context`: the preflight, `manifest.json` and `SUMMARY.md` now show the
  context the tool really uses. Before, they showed kubectl's current context,
  which can be a different cluster. Context names with spaces now work.
- Secrets in the env vars of Weaviate and module pods are now scrubbed from
  every file also when the kubernetes section is skipped (for example
  `--only logs`). Before, a module pod's key printed in its own log could
  reach the bundle.
- Pod annotations whose name looks secret (for example a passphrase or key
  set by a vault or backup tool) are now masked in `kubernetes/pods.json` and
  listed in `redactions.txt`, like Service annotations already were.
- An API key that contains a line break or another control character is
  refused with a clear message and never sent. Such a key could add options
  to the request (for example another HTTP method).
- `--weaviate-url http://...` to another machine: the tool now warns before
  the API key is sent unencrypted, and asks first when you run it by hand
  without `--yes`.
- The read-only gate is stricter: raw API paths (disk usage, metrics-server)
  accept exactly one node or namespace name, and reading Secrets is refused
  unless `--include-helm` is set.
- The read-only gate never opens a port-forward to Weaviate's debug port
  (`GO_PROFILING_PORT`, default 6060), and HTTP requests are limited to
  Weaviate's REST API (`/v1/...`) and `/metrics`.
- Secrets masked in Helm values and config maps are now also scrubbed from
  every other file. Before, the same value printed in a log could reach the
  bundle.
- `--anonymize` no longer rewrites JSON keys: in `.json` files only string
  values are changed. Before, a tenant named like a key (for example `name`)
  corrupted every file. Common words used by the bundle and in logs (`error`,
  `level`, `logs`, ...) are never treated as tenant or user names.
- USAGE.md, `docs/bundle-format.md` and `redactions.txt` now say what
  `--anonymize` does not cover: collection names, the kube context, node names
  and IP addresses.
- A log over `--max-log-mb` now keeps its newest lines. Before, the size cap
  kept the oldest part of the time window and dropped the end, which is usually
  the incident. `manifest.json` records `"kept": "newest"` for such a log.
- A log that fails partway (timeout, lost connection) now keeps what arrived,
  marked `"partial": true` in `manifest.json`. Before, it was thrown away.
- On an unhealthy Weaviate the tool no longer spends minutes on calls that
  keep failing: after 3 failed API calls in a row, the remaining ones are
  skipped and listed in the bundle. New option `--max-api-minutes` (default 15)
  limits the time for all API calls together.
- The Weaviate API connection now falls back to the next pod when one cannot
  be reached, and reconnects if the port-forward is lost during the run.
- New red flag `SCHEMA_MT_CANDIDATES`: collections with identical properties
  that could be one multi-tenant collection.
- New red flag `EMPTY_SHARDS`: loaded shards with no objects, in collections
  that are not multi-tenant.
- New red flag `REPLICA_OBJECT_COUNT_MISMATCH`: replicas of a shard report
  different object counts.
- New opt-in `--include-profiling` (with `--include-heap` and
  `--profile-seconds`): collects Go profiles from the Weaviate pods into
  `pods/<pod>/profiles/`. The safety gate opens the debug port only for the exact
  pprof GETs, only with this option.

## 1.1.0 (2026-11-06)

- Agent skill (`.agents/skills/weaviate-support-bundle`, open Agent Skills
  format) for Claude Code, GitHub Copilot, Codex and other agents: collects a
  bundle (preflight first, then only after the user agrees) and explains it.
  Strict rules: only `collect.sh` and the reader script run, API keys are never
  handled, the bundle is never sent anywhere.
- `read-bundle.sh` in the skill: overview, files, log search and jq queries on
  a bundle or its archive. Read-only: it never unpacks to disk and reads only
  files listed in the manifest.
- `AGENTS.md` points agents to the skill.
- New option `--preflight-only`: show the preflight table, then stop without
  collecting anything.
- Documentation says "user" throughout.
- Release titles are the version only (for example `v1.1.0`).

No change to the bundle format (schema version 1).

## 1.0.0 (2026-11-05)

First release.

- One entry point, `collect.sh`: bash, kubectl, curl and jq; nothing to install.
- Read-only by construction: a single gate (`lib/guard.sh`) allows only reads
  from Kubernetes and HTTP GET to Weaviate, enforced by tests.
- Preflight screen showing what will be collected and what is not permitted,
  with an approval prompt (`--yes` to skip).
- Collects: StatefulSet, pods, nodes, storage, services, network policies,
  quotas, events, config maps, current CPU/memory; Weaviate meta, nodes, Raft
  state, per-collection configuration with shard and tenant status, aliases,
  replication operations, backups, tasks, roles; per-pod health, key metrics
  (two snapshots), current and previous container logs; volume disk usage
  (optional permission); Helm release info (`--include-helm`).
- Secrets redacted by name and by content, and known secret values scrubbed
  from every file; `redactions.txt` lists what was hidden.
- `--anonymize` replaces tenant and user names; the mapping stays with the user.
- `SUMMARY.md`, `findings.json` (stable red-flag codes) and `manifest.json`
  (bundle schema version 1).
