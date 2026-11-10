# Red-flag codes

Every code that `findings.json` can contain, with what it means and what to
check next. The flag's `file` field names the evidence. Commands under "Check"
are `read-bundle.sh` calls. Anything under "Options" changes the cluster: it is
the user's decision, never something to run yourself.

Severity: `high` = likely cause of an outage or data risk, `warn` = needs a
look, `info` = worth knowing.

## WEAVIATE_VERSION_MISMATCH

`high`. Weaviate nodes report different versions in `/v1/nodes`. This is only
expected during a rolling upgrade.
- Check: the image of each pod (`--query kubernetes/pods.json '.weaviate[] | {name, image: [.containers[].image]}'`),
  and whether the StatefulSet rollout is still running (`--query kubernetes/statefulset.json '.status'`:
  `currentRevision` differs from `updateRevision` while it runs).
- Options: let the rollout finish, or find why a pod is stuck on the old version.

## NODE_NOT_HEALTHY

`high`. A node in `/v1/nodes` is `UNHEALTHY`, `UNAVAILABLE` or `TIMEOUT`
instead of `HEALTHY`. A node that is down reports an empty version.
- Check: the matching pod's state and restarts (pod flags, `SUMMARY.md`), its
  current log and previous log (`--tail pods/<pod>/logs/<container>.previous.log 200`).
- Usually explained by another flag on the same pod (OOM kill, crash loop, not ready).

## NODE_OPERATIONAL_MODE

`warn`. A node is in `ReadOnly`, `WriteOnly` or `ScaleOut` mode instead of
`ReadWrite`. The mode comes from the `OPERATIONAL_MODE` environment variable.
- Check: `OPERATIONAL_MODE` in `config/env.json`.
- Options: if it was set for maintenance and the maintenance is over, the user
  sets it back to `ReadWrite`.

## RAFT_NOT_SYNCED

`high`. `/v1/cluster/statistics` reports `synchronized: false`: the nodes do
not agree on the cluster state (schema, tenants, metadata). It can be brief
right after restarts or many schema changes.
- Check: `--query weaviate/raft.json '.statistics[] | {name, status, raft}'`.
  A node with a much lower `appliedIndex`, or not `Follower`/`Leader`, is
  behind. Look for restarts on that pod.
- If nothing is restarting, a second bundle a few minutes later shows whether
  it recovers.

## RAFT_NO_LEADER

`high`. No node reports a Raft leader. Schema changes and other cluster-wide
operations fail. The usual cause is lost quorum: fewer than a majority of
voters are up.
- Check: how many Weaviate pods are ready versus the StatefulSet replicas, and
  the pod flags. While quorum is lost, schema and similar API calls return
  HTTP 500 after about 20 seconds each, so many `HTTP 500` steps in the manifest
  are expected.
- Options: bring the failing pods back first (fix the OOM kill, crash or
  scheduling problem behind them).

## RAFT_MEMBER_NOT_HEALTHY

`high`. A member in `/v1/cluster/statistics` is not `HEALTHY`.
- Check: that member's pod, as for NODE_NOT_HEALTHY.

## RAFT_MEMBER_COUNT

`warn`. The number of Raft members differs from the StatefulSet replicas.
Missing members can block consensus; a member that is down may simply not be
reported.
- Check: pods that are down or not ready, and whether the StatefulSet was
  scaled recently (events, `--query kubernetes/statefulset.json '.spec.replicas, .status'`).
- Also check RAFT_BOOTSTRAP_MISMATCH.

## RAFT_BOOTSTRAP_MISMATCH

`warn`. `RAFT_JOIN` lists a different number of nodes than
`RAFT_BOOTSTRAP_EXPECT`. They must match, or the cluster waits for voters that
never arrive.
- Check: both values in `config/env.json` and the StatefulSet replicas.
- Options: the user makes `RAFT_JOIN` and `RAFT_BOOTSTRAP_EXPECT` agree with the
  intended number of voters.

## POD_PENDING

`high`. A pod is not scheduled or not started.
- Check: `FailedScheduling` or `FailedMount`/`FailedAttach` events
  (K8S_WARNING_EVENTS), whether its volume is bound (`kubernetes/storage.json`),
  node capacity and taints (`kubernetes/nodes.json`), quotas (`kubernetes/policies.json`).

## POD_CRASHLOOP

`high`. A container keeps crashing (`CrashLoopBackOff`).
- Check: the end of its previous log (`--tail pods/<pod>/logs/<container>.previous.log 200`):
  the crash reason is almost always in the last lines, for example a fatal
  config error or a panic. Also look for POD_OOMKILLED on the same pod.
- Options: fix what the log names (often an invalid environment variable value).

## POD_CANNOT_START

`high`. Image pull error or container creation error.
- Check: the message in the flag and in `kubernetes/pods.json`: wrong image or
  tag, no access to the registry, missing image pull secret, or a Secret or
  ConfigMap the pod refers to that does not exist.

## POD_OOMKILLED

`high`. The container was killed because it reached its memory limit.
- Check: the memory limit and `GOMEMLIMIT` (`config/env.json`, and the
  GOMEMLIMIT flags), current usage (`kubernetes/top.json`), heap metrics
  (`pods/<pod>/metrics.json`), and data size per node (object counts in
  `SUMMARY.md` or `weaviate/nodes.json`).
- Options: raise the memory limit, set `GOMEMLIMIT` to about 80-90% of the
  limit (or `LIMIT_RESOURCES=true`), reduce vector memory with compression
  (quantization), or add nodes.

## POD_RESTARTS

`warn`. A container restarted for a reason other than an OOM kill.
- Check: the last exit reason and code in the flag, then the previous log.
  Exit code 137 without OOM means it was killed (for example by a failing
  liveness probe or the node); 143 means it was asked to stop (rollout,
  eviction, node drain). Compare the time with events.

## POD_NOT_READY

`high`. The pod runs but its readiness probe fails.
- Check: `pods/<pod>/health.json` (live and ready endpoints), the end of the
  current log, and `Unhealthy` events. A large node can take a while to load
  its shards after a restart; the log shows whether it is still starting.

## STATEFULSET_NOT_READY

`high`. Fewer ready replicas than desired. The pod flags show which pods and why.

## MEMORY_LIMIT_MISSING

`warn`. The Weaviate container has no memory limit, so it can use all memory
on the node and other pods can be evicted.
- Options: set a memory limit (equal to the request is safest for a
  database) and `GOMEMLIMIT` to about 80-90% of it.

## GOMEMLIMIT_NOT_SET

`warn`. Neither `GOMEMLIMIT` nor `LIMIT_RESOURCES=true` is set. The Go runtime
does not know the memory limit, which makes OOM kills more likely, and
Weaviate logs a warning at startup.
- Options: set `GOMEMLIMIT` to about 80-90% of the memory limit, or
  `LIMIT_RESOURCES=true` (which sets it to 80% of the container limit).

## GOMEMLIMIT_ABOVE_LIMIT

`high`. `GOMEMLIMIT` is at or above the container memory limit. The pod is
killed before the Go runtime starts freeing memory.
- Options: lower `GOMEMLIMIT` to about 80-90% of the limit.

## GOMEMLIMIT_HIGH

`warn`. `GOMEMLIMIT` is above 90% of the memory limit, leaving little room for
memory outside the Go heap.
- Options: lower it to about 80-90% of the limit.

## MEMORY_REQUEST_BELOW_LIMIT

`info`. The memory request is lower than the limit, so the node may not have
the full limit available when the pod needs it.
- Options: equal request and limit are safer for a database.

## SHARDS_READONLY

`high`. Shards are `READONLY` and reject writes. Usually caused by disk usage
above `DISK_USE_READONLY_PERCENTAGE` (default 90) or memory above
`MEMORY_READONLY_PERCENTAGE` (default 0, which means off).
- Check: DISK_ALMOST_FULL, the thresholds in `config/env.json`, and
  `--search 'set_shard_read_only|READONLY'` in the logs for the reason and time.
- Shards set read-only by disk or memory pressure go back to `READY` by
  themselves once disk and memory are below their thresholds again. Shards a
  user set to `READONLY` stay that way.

## VECTOR_QUEUE_BACKLOG

`warn`. 100,000 or more vectors are waiting to be indexed (async indexing).
Search results can miss objects until the queue drains.
- Check: which nodes and shards hold the queue
  (`--query weaviate/nodes.json '[.nodes[] | {name, q: ([.shards[]?.vectorQueueLength // 0] | add)}]'`)
  and CPU use (`kubernetes/top.json`). One bundle is a single snapshot; a
  second bundle later shows whether it shrinks.

## REPLICATION_FACTOR_TOO_HIGH

`high`. A collection's replication factor is larger than the number of nodes,
so writes cannot reach the requested consistency.
- Options: add nodes, or lower the replication factor.

## TENANTS_IN_TRANSITION

`warn`. Tenants are in a changing state: `FREEZING`, `UNFREEZING`, or the
older names `OFFLOADING`, `ONLOADING`.
- Check: the tenants in the collection file, and the logs for those tenant
  names. A second bundle later shows whether they are stuck.

## SCHEMA_MT_CANDIDATES

`info`. Two or more collections that are not multi-tenant have identical
properties (names, tokenization and data types). Many collections with the same
shape often mean one collection per end user, which costs memory and startup
time. One multi-tenant collection is usually a better fit.
- Check: the collections named in the flag (`--show weaviate/collections/<name>.json`)
  and whether each one really holds one end user's data. Same properties alone
  do not prove that: vector index settings can differ on purpose.
- Options: migrating to a multi-tenant collection means moving data; it is the
  user's decision.

## REPLICATION_OP_ERRORS

`warn`. A replica copy or move operation reports errors.
- Check: the error messages in `weaviate/replication.json`, and the health of
  the source and target nodes.

## EMPTY_SHARDS

`info`. Loaded shards with zero objects, in collections that are not
multi-tenant (a tenant's shard starts empty by design, and an unloaded shard
reports no count). Often a new collection, or more shards than the data needs.
Counts in `/v1/nodes` update in the background.
- Check: the shard count and object count of the collection in `SUMMARY.md`.

## REPLICA_OBJECT_COUNT_MISMATCH

`warn`. The replicas of a shard report different object counts in `/v1/nodes`.
Counts lag a little, so a small difference right after writes is normal. A
lasting one can mean async replication is off or behind, or a node missed writes.
- Check: `ASYNC_REPLICATION_DISABLED` in `config/env.json`, node health
  (`weaviate/nodes.json`), and restarts of the node with the lower count. A
  second bundle later shows whether the difference stays.
- Options: repairing replicas changes the cluster; it is the user's decision.

## BACKUP_FAILED

`warn`. A backup in the list has status `FAILED`.
- Check: the backup entry in `weaviate/backups.json`, the backup module
  settings in `config/env.json`, and the logs around the backup time. The
  `filesystem` backend does not work on clusters with more than one node.

## DISK_ALMOST_FULL

`high`. A volume is at or above `DISK_USE_READONLY_PERCENTAGE` (default 90).
Weaviate sets shards to `READONLY` at this level.
- Check: `kubernetes/disk-usage.json`, and whether the storage class allows
  volume expansion (`kubernetes/storage.json`).
- Options: expand the volume, or free space (for example delete data that is
  no longer needed).

## DISK_HIGH

`warn`. A volume is at or above `DISK_USE_WARNING_PERCENTAGE` (default 80).
Weaviate logs warnings from this level and goes read-only at the read-only
threshold.
- Options: plan more space before it reaches the read-only threshold.

## K8S_NODE_CONDITION

`high`. A Kubernetes node running Weaviate is `NotReady` or under memory,
disk or PID pressure. Pods on it can be evicted or fail.
- Check: the node in `kubernetes/nodes.json`, and which Weaviate pods run on it.

## K8S_NODE_CORDONED

`warn`. A node is unschedulable (cordoned), often during maintenance. A
Weaviate pod that needs to move there stays Pending.

## K8S_WARNING_EVENTS

`warn` or `info`. Kubernetes warning events, grouped by reason (top 10).
`warn` for reasons such as OOM, eviction, failed scheduling or mounts,
back-off and failing probes.
- Check: `kubernetes/events.json` for the objects and times; match them with
  the pod flags.

## METRICS_DISABLED

`info`. Prometheus metrics are off (`PROMETHEUS_MONITORING_ENABLED`), so the
bundle has no metrics.
- Options: enable it to get metrics in future bundles.
