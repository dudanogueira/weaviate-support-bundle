# Weaviate facts for reading bundles

Behaviour that is easy to misread in a bundle.

## Nodes and Raft

- `/v1/nodes` status is one of `HEALTHY`, `UNHEALTHY`, `UNAVAILABLE`,
  `TIMEOUT`. A node that is down reports an empty version, so it does not
  count as a version mismatch.
- Operational mode is one of `ReadWrite` (normal), `ReadOnly`, `WriteOnly`,
  `ScaleOut`, set with `OPERATIONAL_MODE`.
- Raft details per node are in `weaviate/raft.json` under `.statistics[]`:
  `name`, `status`, `leaderId`, `isVoter`, `ready`, `dbLoaded`, and
  `raft.state`, `raft.term`, `raft.appliedIndex`.
- When Raft quorum is lost, schema, alias, task and user calls return HTTP 500
  after about 20 seconds each. Many such steps in `manifest.json` are a
  symptom, not a problem with the tool.

## Data and counts

- Object counts in `/v1/nodes` are updated in the background, so they lag
  behind recent writes. Treat them as approximate.
- The bundle never contains objects, vectors or query results.
- Tenant status is `HOT`, `COLD` or `FROZEN`, with `FREEZING` and
  `UNFREEZING` while changing. Older names: `ACTIVE`, `INACTIVE`, `OFFLOADED`,
  `OFFLOADING`, `ONLOADING`.

## Memory

- `LIMIT_RESOURCES=true` sets `GOMEMLIMIT` to 80% of the container memory
  limit. Without either, Weaviate logs a warning at startup.
- A `GOMEMLIMIT` at or above the container limit means the pod is OOM-killed
  before the Go runtime frees memory.

## Disk and read-only shards

- Defaults: `DISK_USE_WARNING_PERCENTAGE=80`, `DISK_USE_READONLY_PERCENTAGE=90`,
  `MEMORY_WARNING_PERCENTAGE=80`, `MEMORY_READONLY_PERCENTAGE=0` (0 = off).
- Above a read-only threshold, Weaviate sets loaded shards to `READONLY` and
  logs `"action":"set_shard_read_only"`. Once disk and memory are below their
  thresholds again, those shards go back to `READY` by themselves.

## Replication and backups

- Async replication has no per-collection switch: it can only be turned off
  for the whole cluster, with `ASYNC_REPLICATION_DISABLED=true`.
- The `filesystem` backup backend is refused on clusters with more than one
  node (HTTP 422).

## Ports

- The REST API is on 8080 by default and metrics on 2112 (when
  `PROMETHEUS_MONITORING_ENABLED=true`).
- The debug port (6060) is off by default and the tool never calls it.
