# Bundle format

Reference for every file the tool writes into a bundle. Weaviate support,
and any script that reads bundles, relies on these names and fields, so they
only change in a controlled way (see Versioning).

To read a bundle from the command line, without unpacking it, use
[`read-bundle.sh`](../.agents/skills/weaviate-support-bundle/scripts/read-bundle.sh)
(`--help` lists its options).

**Versioning.** `manifest.json` has `schema_version`. Adding files or fields
does not change it. Renaming, removing or changing the meaning of a file,
field or finding code bumps it, and the change is noted in `CHANGELOG.md`.

## Layout

```
weaviate-support-bundle-<YYYYMMDD-HHMMSS>/
├── SUMMARY.md                 human summary: versions, health, red flags, tables
├── findings.json              red flags, machine-readable (see below)
├── manifest.json              tool version, target, options, step results, file list
├── redactions.txt             what was hidden (names and counts, never values)
├── run.log                    what the tool did, step by step
├── config/
│   └── env.json               Weaviate container: image, args, env (redacted), resources
├── kubernetes/
│   ├── cluster.json           context, Kubernetes version, namespace, nodes used
│   ├── statefulset.json       the StatefulSet (env redacted, managedFields and last-applied removed)
│   ├── pods.json              {weaviate: [...], modules: [...]}: status, restarts, crash reasons, resources
│   ├── nodes.json             nodes running Weaviate: size, zone, conditions, taints, versions
│   ├── storage.json           PVCs, PVs, storage classes
│   ├── disk-usage.json        per volume: capacity, used, available, % (needs nodes/proxy)
│   ├── services.json          services selecting Weaviate pods, ready endpoint counts
│   ├── network-policies.json  network policies in the namespace
│   ├── policies.json          PDBs, resource quotas, limit ranges
│   ├── events.json            events about Weaviate's pods, StatefulSet, volumes and nodes
│   ├── configmaps.json        config maps Weaviate mounts (values redacted)
│   └── top.json               current CPU/memory (metrics-server)
├── weaviate/
│   ├── meta.json              GET /v1/meta
│   ├── nodes.json             GET /v1/nodes?output=verbose
│   ├── raft.json              GET /v1/cluster/statistics
│   ├── collections/<Name>.json  {name, config, shards, tenants} per collection
│   ├── aliases.json, replication.json, backups.json, tasks.json, roles.json, whoami.json
├── helm/
│   └── release.json           only with --include-helm: chart, history, values (redacted)
└── pods/<pod>/
    ├── status.json            this pod from kubernetes/pods.json
    ├── health.json            /v1/.well-known/live and /ready (Weaviate pods)
    ├── metrics.json           key metrics, two snapshots (Weaviate pods, if enabled)
    └── logs/
        ├── <container>.log            current container, requested window
        └── <container>.previous.log   previous container after a restart (last 5,000 lines)
```

A file is missing when its step did not run or failed. `manifest.json`
always says why.

Raw Weaviate API responses (`weaviate/*.json`) are stored as returned by the
server, so their fields follow the
[Weaviate REST API](https://docs.weaviate.io/weaviate/api/rest).

## manifest.json

```json
{
  "schema_version": "1",
  "tool": {"name": "weaviate-support-bundle", "version": "1.0.0"},
  "created_at": "2026-11-05T14:30:00Z",
  "target": {"context": "...", "namespace": "weaviate", "statefulset": "weaviate",
             "kubernetes_version": "v1.31.2", "weaviate_version": "1.40.3"},
  "run": {"sections": ["kubernetes", "weaviate", "logs", "metrics", "disk"],
          "weaviate_pods": ["weaviate-0"], "module_pods": [],
          "log_window": "last 24h", "log_since": "24h", "log_from": null, "log_to": null,
          "previous_log_lines": 5000, "max_log_mb_per_container": 100,
          "metrics_interval_seconds": 30, "connect_mode": "port-forward",
          "anonymized": false, "include_helm": false},
  "steps": [{"section": "kubernetes", "name": "pods", "status": "ok", "detail": "3 Weaviate, 0 module"}],
  "logs": [{"pod": "weaviate-0", "container": "weaviate", "kind": "current", "file": "pods/weaviate-0/logs/weaviate.log",
            "lines": 1234, "first": "2026-11-04T14:30:01.123Z", "last": "2026-11-05T14:29:59.999Z", "truncated": false}],
  "files": [{"path": "SUMMARY.md", "bytes": 5120}]
}
```

Step `status` is one of: `ok`, `skipped` (not applicable or turned off),
`forbidden` (no permission), `not_found` (not available on this cluster or
version), `unavailable` (feature off or unreachable), `error`.

## findings.json

An array, most severe first:

```json
[{"severity": "high", "code": "POD_OOMKILLED", "title": "weaviate-1/weaviate was OOMKilled",
  "detail": "Last killed at 2026-11-05T08:00:00Z. The memory limit was reached.",
  "file": "kubernetes/pods.json"}]
```

`severity`: `high` (likely cause of an outage or data risk), `warn` (needs a
look), `info` (worth knowing). `file` is the bundle file with the evidence.

| Code | Severity | Meaning |
|---|---|---|
| `WEAVIATE_VERSION_MISMATCH` | high | Nodes run different Weaviate versions |
| `NODE_NOT_HEALTHY` | high | A node is not HEALTHY in /v1/nodes |
| `NODE_OPERATIONAL_MODE` | warn | A node is not in ReadWrite mode |
| `RAFT_NOT_SYNCED` | high | /v1/cluster/statistics reports synchronized=false |
| `RAFT_NO_LEADER` | high | No node reports a Raft leader |
| `RAFT_MEMBER_NOT_HEALTHY` | high | A Raft member is not HEALTHY |
| `RAFT_MEMBER_COUNT` | warn | Raft member count differs from StatefulSet replicas |
| `RAFT_BOOTSTRAP_MISMATCH` | warn | RAFT_JOIN count differs from RAFT_BOOTSTRAP_EXPECT |
| `POD_PENDING` | high | Pod not scheduled or not started |
| `POD_CRASHLOOP` | high | Container in CrashLoopBackOff |
| `POD_CANNOT_START` | high | Image pull or container creation error |
| `POD_OOMKILLED` | high | Container was OOMKilled |
| `POD_RESTARTS` | warn | Container restarted (not OOM) |
| `POD_NOT_READY` | high | Running but readiness probe failing |
| `STATEFULSET_NOT_READY` | high | Fewer ready replicas than desired |
| `MEMORY_LIMIT_MISSING` | warn | Weaviate has no memory limit |
| `GOMEMLIMIT_NOT_SET` | warn | No GOMEMLIMIT and LIMIT_RESOURCES not true |
| `GOMEMLIMIT_ABOVE_LIMIT` | high | GOMEMLIMIT ≥ memory limit |
| `GOMEMLIMIT_HIGH` | warn | GOMEMLIMIT > 90% of the memory limit |
| `MEMORY_REQUEST_BELOW_LIMIT` | info | Memory request < limit |
| `SHARDS_READONLY` | high | Shards in READONLY status |
| `VECTOR_QUEUE_BACKLOG` | warn | ≥ 100,000 vectors waiting to be indexed |
| `REPLICATION_FACTOR_TOO_HIGH` | high | Replication factor > number of nodes |
| `TENANTS_IN_TRANSITION` | warn | Tenants in a transitional state (…ING) |
| `REPLICATION_OP_ERRORS` | warn | Replica copy/move operation reports errors |
| `BACKUP_FAILED` | warn | A backup in the list has status FAILED |
| `DISK_ALMOST_FULL` | high | Volume ≥ DISK_USE_READONLY_PERCENTAGE (default 90) |
| `DISK_HIGH` | warn | Volume ≥ DISK_USE_WARNING_PERCENTAGE (default 80) |
| `K8S_NODE_CONDITION` | high | Node NotReady or under memory/disk/PID pressure |
| `K8S_NODE_CORDONED` | warn | Node is unschedulable |
| `K8S_WARNING_EVENTS` | warn/info | Warning events grouped by reason (top 10) |
| `METRICS_DISABLED` | info | Prometheus metrics are not enabled |

## pods/<pod>/metrics.json

```json
{"interval_seconds": 30,
 "metrics": [{"name": "go_memstats_heap_inuse_bytes", "series": 1, "t0": 2.4e9, "t1": 2.5e9,
              "delta_per_s": 3333333.333, "detail": [{"labels": {}, "value": 2.5e9}]}],
 "latency": {"queries_durations_ms": {"requests_in_interval": 120, "avg_in_interval": 8.4, "avg_since_start": 6.1}}}
```

`t0`/`t1` are totals across all series of a metric. `detail` (per-label
values) is present only when a metric has 20 series or fewer. Only a fixed
list of key metrics is kept (see `METRICS_KEEP` in `lib/metrics.sh`).

## Redaction markers

Redacted values are replaced with `[REDACTED]`, `[REDACTED JWT]`,
`[REDACTED AWS KEY]` or `[REDACTED PRIVATE KEY]`. With `--anonymize`, tenant
names become `tenant-000001`, … and user names `user-001`, …; the mapping is
written next to the archive, never inside it.
