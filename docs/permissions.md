# Permissions

The tool only reads. This page lists every permission it can use, why, the
risk of granting it, and what you lose without it. A missing permission never
stops the tool: that part is skipped and listed under "What was not
collected" in `SUMMARY.md` and in `manifest.json`.

Most people run the tool with the kubectl user they already use for the
cluster and need nothing extra. For a dedicated read-only account, apply
[`rbac/read-only.yaml`](../rbac/read-only.yaml).

## Kubernetes

| Resource (API group) | Verb | Used for | Risk | Without it |
|---|---|---|---|---|
| `statefulsets` (apps) | get, list | Find Weaviate; settings, replicas, resources, env (redacted) | No risk: read only | **Required.** The tool stops. |
| `pods` | get, list | Pod status, restarts, crash reasons, placement | No risk: read only | **Required.** The tool stops. |
| `pods/log` | get | Current and previous container logs | No risk: read only. Logs can contain your data, which you review before sending | No logs |
| `pods/portforward` | create | Temporary tunnel to call Weaviate's API and read metrics | Low: opens a connection to the pod; changes nothing (see below) | No Weaviate API data (unless `--weaviate-url`), no per-pod health or metrics |
| `services`, `endpointslices` (discovery.k8s.io) | list | How Weaviate is exposed, ready endpoints | No risk: read only | No services section |
| `persistentvolumeclaims` | get, list | Volume size, storage class, status | No risk: read only | No storage section |
| `persistentvolumes`, `storageclasses` (storage.k8s.io) | get | Disk type, reclaim policy, volume expansion | No risk: read only | Less storage detail |
| `nodes` | get | Node size, zone, instance type, pressure conditions | No risk: read only | No node section |
| `events` | list | Warnings: OOM kills, failed scheduling, probe failures | No risk: read only | No events section |
| `events` (all namespaces) | list | Events about the nodes Weaviate runs on | No risk: read only | No node events |
| `configmaps` (only Weaviate's) | get | Weaviate config file and runtime overrides (redacted) | No risk: read only | No config maps section |
| `networkpolicies` (networking.k8s.io) | list | Rules that can block traffic between Weaviate pods | No risk: read only | No network policies section |
| `poddisruptionbudgets` (policy), `resourcequotas`, `limitranges` | list | Limits that affect scheduling and upgrades | No risk: read only | Section skipped |
| `pods` (metrics.k8s.io) | get, list | Current CPU and memory, if metrics-server is installed | No risk: read only | No "current usage" line |
| `nodes/proxy` | get | Disk usage of Weaviate's volumes (optional) | Risk: see below | No disk usage |
| `secrets` | list | Helm release info, only with `--include-helm` | Risk: see below | No Helm section |

### Port-forward

`kubectl port-forward` opens a tunnel from your machine to a pod, so the tool
can call Weaviate's API at `http://127.0.0.1:<random port>`. Kubernetes lists
this as `create` on `pods/portforward` because it opens a connection. It does
not create, change or delete any object. The tool closes every tunnel when it
finishes, also on Ctrl-C or errors.

If your policy does not allow port-forward, point the tool at Weaviate with
`--weaviate-url`. Per-pod health checks and metrics then need port-forward and
are skipped.

### Disk usage: `nodes/proxy` (optional)

**Risk: this permission gives access to the kubelet API of a node, which can
also run commands in pods on that node.** The tool itself only reads two
paths, `stats/summary` and `healthz`; its safety gate refuses anything else.

Weaviate's API does not report disk usage, and the tool never runs commands
inside your pods, so the kubelet's stats are the only read-only source. The
bundle keeps only size, used, free and % used per Weaviate volume.

If you grant it, use [`rbac/optional-disk-usage.yaml`](../rbac/optional-disk-usage.yaml):
it limits the permission to the nodes that run Weaviate, and you remove it
after the run. If you do not grant it, disk usage is skipped and support can
ask for the numbers from your own monitoring (for example the
`kubelet_volume_stats_*` metrics).

A cluster-admin user already has this permission; the approval screen says
so. Use `--skip disk` to leave it out.

### Helm: `secrets` (optional, `--include-helm` only)

**Risk: Kubernetes cannot limit this to Helm's Secrets by name, so the
permission allows reading all Secrets in the namespace.** The tool only reads
Helm's release Secrets (label `owner=helm`), redacts the values, and never
writes the rendered manifest or any other Secret.

See [`rbac/optional-helm.yaml`](../rbac/optional-helm.yaml). Without
`--include-helm`, the tool never reads Secrets.

## Weaviate API

All calls are HTTP `GET`. Weaviate needs an API key unless anonymous access
is enabled. Use a **read-only** key:

- **RBAC enabled** (`AUTHORIZATION_RBAC_ENABLED=true`): a user with the
  built-in `viewer` role.
- **Admin list**: a key that maps to a user in
  `AUTHORIZATION_ADMINLIST_READONLY_USERS`.

Risk: low. A read-only key cannot change anything; the tool only reads
metadata (no objects, no vectors).

Pass the key with the `WEAVIATE_API_KEY` environment variable, or type it when
the tool asks (input is hidden). It is sent to curl through stdin, so it never
appears in the process list or your shell history, and it is scrubbed from
every file in the bundle.

| Endpoint | Used for |
|---|---|
| `/v1/meta` | Version, enabled modules |
| `/v1/nodes?output=verbose` | Node health, shard status, object counts, indexing queue |
| `/v1/cluster/statistics` | Raft: leader, voters, synchronized |
| `/v1/schema`, `/v1/schema/{collection}/shards`, `/v1/schema/{collection}/tenants` | Collection configuration, shard status, tenant counts by status |
| `/v1/aliases` | Collection aliases |
| `/v1/replication/replicate/list` | Replica copy/move operations |
| `/v1/backups/{backend}` | Backup list and status |
| `/v1/tasks` | Distributed tasks |
| `/v1/authz/roles` | Role definitions (RBAC only) |
| `/v1/users/own-info` | Which user the tool connected as |
| `/v1/.well-known/live`, `/v1/.well-known/ready` | Per-pod health |
| `:2112/metrics` | Prometheus metrics, if enabled |

The tool never calls Weaviate's debug port (6060), because some of its
endpoints change state. The safety gate blocks it.
