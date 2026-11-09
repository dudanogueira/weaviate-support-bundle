# Changelog

All notable changes are listed here. Versions follow
[semantic versioning](https://semver.org); see `docs/releasing.md`.

## Unreleased

- Weaviate images from private registries and mirrors are found: any image
  whose last path part is `weaviate` counts (for example
  `registry.example.com/mirror/weaviate:1.30`), not only
  `semitechnologies/weaviate`.
- `--statefulset` now selects the StatefulSet by name, whatever its image.
  Before, a StatefulSet whose image did not match was never found, even when
  named.
- New option `--container`: names the Weaviate container when it cannot be
  found from the image, the name `weaviate`, or a single container. Before,
  the tool went on without one and silently missed the settings, port and
  metrics.

No change to the bundle format (schema version 1).

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
