# Changelog

All notable changes are listed here. Versions follow
[semantic versioning](https://semver.org); see `docs/releasing.md`.

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
