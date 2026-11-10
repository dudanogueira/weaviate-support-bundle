# lib/jq/findings.jq: red flags, computed from the collected files.
#
# Input: the "facts" object built by summary.sh (one key per bundle file,
# null when the file was not collected).
# Output: array of findings, most severe first:
#   {severity: "high"|"warn"|"info", code, title, detail, file}
# Codes are stable; tools that read bundles (agents, the Console) rely on them.

def f($sev; $code; $title; $detail; $file):
  {severity: $sev, code: $code, title: $title, detail: $detail, file: $file};

def rank: {"high": 0, "warn": 1, "info": 2}[.severity];

# "6GiB", "6144Mi", "6G", "6442450944" -> bytes (null if unknown)
def bytes:
  if . == null then null
  elif type == "number" then .
  else
    (capture("^(?<n>[0-9.]+)\\s*(?<u>[A-Za-z]*)$") // null) as $m
    | if $m == null then null else
        ($m.n | tonumber) * ({"": 1, "B": 1,
          "K": 1000, "KB": 1000, "Ki": 1024, "KiB": 1024,
          "M": 1000000, "MB": 1000000, "Mi": 1048576, "MiB": 1048576,
          "G": 1000000000, "GB": 1000000000, "Gi": 1073741824, "GiB": 1073741824,
          "T": 1000000000000, "TB": 1000000000000, "Ti": 1099511627776, "TiB": 1099511627776}[$m.u] // null)
      end
  end;

def human:
  if . == null then "?" else
    if . >= 1073741824 then "\((. / 1073741824 * 10 | round) / 10) GiB"
    elif . >= 1048576 then "\((. / 1048576 | round)) MiB"
    else "\(.) B" end
  end;

def envv($facts; $k): ($facts.env.env[$k] // null) | if type == "string" then . else null end;
def truthy: . != null and (ascii_downcase | test("^(true|1|on|yes)$"));

# Fingerprint of a collection's properties: name, tokenization and data types,
# sorted by name, nested properties included. Same rule as Weaviate Studio's
# multi-tenancy check. Blank tokenization counts as the default, "word".
def props_fingerprint:
  def one:
    "\(.name)|\(if ((.tokenization // "") | test("\\S")) then .tokenization else "word" end)|\((.dataType // []) | if type == "array" then sort | join("+") else . end)"
    + (if ((.nestedProperties // []) | length) > 0 then "{" + (.nestedProperties | props_fingerprint) + "}" else "" end);
  sort_by(.name) | map(one) | join(";");

def findings($facts):
  ($facts.pods.weaviate // []) as $wpods
  | (($facts.pods.weaviate // []) + ($facts.pods.modules // [])) as $allpods
  | ($facts.nodes.nodes // []) as $wnodes
  | [
    # ---- versions and node health (Weaviate) -------------------------------
    ( ([$wnodes[].version | select(. != null and . != "")] | unique) as $vers
      | if ($vers | length) > 1 then f("high"; "WEAVIATE_VERSION_MISMATCH"; "Nodes run different Weaviate versions";
          "Versions: \($vers | join(", ")). Mixed versions are only expected during a rolling upgrade."; "weaviate/nodes.json") else empty end ),

    ( $wnodes[] | select(.status != "HEALTHY")
      | f("high"; "NODE_NOT_HEALTHY"; "Weaviate node \(.name) is \(.status)"; "Reported by /v1/nodes."; "weaviate/nodes.json") ),

    ( $wnodes[] | select(.operationalMode != null and .operationalMode != "ReadWrite")
      | f("warn"; "NODE_OPERATIONAL_MODE"; "Node \(.name) is in \(.operationalMode) mode"; "The node does not accept both reads and writes."; "weaviate/nodes.json") ),

    # ---- Raft ----------------------------------------------------------------
    ( if $facts.raft != null and $facts.raft.synchronized == false then
        f("high"; "RAFT_NOT_SYNCED"; "Raft cluster is not synchronized";
          "Nodes do not agree on the cluster state (synchronized=false)."; "weaviate/raft.json") else empty end ),

    ( if $facts.raft != null and ([$facts.raft.statistics[]? | .leaderId // "" | select(. != "")] | length) == 0 then
        f("high"; "RAFT_NO_LEADER"; "No Raft leader reported"; "No node reports a leader ID."; "weaviate/raft.json") else empty end ),

    ( $facts.raft.statistics[]? | select(.status != null and .status != "HEALTHY")
      | f("high"; "RAFT_MEMBER_NOT_HEALTHY"; "Raft member \(.name) is \(.status)"; "Reported by /v1/cluster/statistics."; "weaviate/raft.json") ),

    ( if $facts.raft != null and $facts.statefulset != null
         and (($facts.raft.statistics // []) | length) != ($facts.statefulset.spec.replicas // 0) then
        f("warn"; "RAFT_MEMBER_COUNT"; "Raft reports \(($facts.raft.statistics // []) | length) member(s), StatefulSet wants \($facts.statefulset.spec.replicas)";
          "Members that are missing or extra can block consensus."; "weaviate/raft.json") else empty end ),

    ( envv($facts; "RAFT_JOIN") as $join | envv($facts; "RAFT_BOOTSTRAP_EXPECT") as $exp
      | if $join != null and $exp != null and (($join | split(",") | map(select(length > 0)) | length) != ($exp | tonumber? // -1)) then
          f("warn"; "RAFT_BOOTSTRAP_MISMATCH"; "RAFT_JOIN lists \($join | split(",") | length) node(s) but RAFT_BOOTSTRAP_EXPECT is \($exp)";
            "These must match, or the cluster waits for voters that never arrive."; "config/env.json") else empty end ),

    # ---- Pods ------------------------------------------------------------------
    ( $allpods[] | . as $p
      | ( if .phase == "Pending" then f("high"; "POD_PENDING"; "Pod \(.name) is Pending";
            ([.conditions[]? | select(.status != "True") | .message // .reason // empty] | first // "Not scheduled or not started."); "kubernetes/pods.json")
          else empty end ),
        ( .containerStatuses[]?
          | ( if .state.waiting.reason == "CrashLoopBackOff" then
                f("high"; "POD_CRASHLOOP"; "\($p.name)/\(.name) is in CrashLoopBackOff"; "Restarted \(.restartCount) time(s). See the previous log."; "pods/\($p.name)/logs/\(.name).previous.log")
              elif (.state.waiting.reason // "") | test("ImagePull|ErrImage|CreateContainer") then
                f("high"; "POD_CANNOT_START"; "\($p.name)/\(.name): \(.state.waiting.reason)"; (.state.waiting.message // ""); "kubernetes/pods.json")
              else empty end ),
            ( if (.lastState.terminated.reason // "") == "OOMKilled" or (.state.terminated.reason // "") == "OOMKilled" then
                f("high"; "POD_OOMKILLED"; "\($p.name)/\(.name) was OOMKilled";
                  "Last killed at \(.lastState.terminated.finishedAt // .state.terminated.finishedAt // "?"). The memory limit was reached."; "kubernetes/pods.json")
              else empty end ),
            ( if (.restartCount // 0) > 0 and (.lastState.terminated.reason // "") != "OOMKilled" then
                f("warn"; "POD_RESTARTS"; "\($p.name)/\(.name) restarted \(.restartCount) time(s)";
                  "Last exit: \(.lastState.terminated.reason // "unknown") (code \(.lastState.terminated.exitCode // "?")) at \(.lastState.terminated.finishedAt // "?")."; "pods/\($p.name)/logs/\(.name).previous.log")
              else empty end ),
            ( if .ready == false and $p.phase == "Running" and (.state.waiting.reason // "") != "CrashLoopBackOff" then
                f("high"; "POD_NOT_READY"; "\($p.name)/\(.name) is not ready"; "The readiness probe is failing."; "kubernetes/pods.json")
              else empty end ) ) ),

    ( if $facts.statefulset != null and (($facts.statefulset.status.readyReplicas // 0) < ($facts.statefulset.spec.replicas // 0)) then
        f("high"; "STATEFULSET_NOT_READY"; "StatefulSet has \($facts.statefulset.status.readyReplicas // 0)/\($facts.statefulset.spec.replicas) ready replicas"; ""; "kubernetes/statefulset.json")
      else empty end ),

    # ---- Memory settings -------------------------------------------------------
    ( ($facts.env.resources.limits.memory // null) as $lim
      | (envv($facts; "GOMEMLIMIT")) as $gml
      | (envv($facts; "LIMIT_RESOURCES") | truthy) as $lr
      | ( if $facts.env != null and $lim == null then
            f("warn"; "MEMORY_LIMIT_MISSING"; "Weaviate has no memory limit"; "Without a limit, Weaviate can use all memory on the node."; "config/env.json") else empty end ),
        ( if $facts.env != null and $gml == null and ($lr | not) then
            f("warn"; "GOMEMLIMIT_NOT_SET"; "GOMEMLIMIT is not set (and LIMIT_RESOURCES is not true)";
              "Weaviate logs a warning at startup: memory-pressure checks are inert without a soft memory limit."; "config/env.json") else empty end ),
        ( if $gml != null and $lim != null and ($gml | bytes) != null and ($lim | bytes) != null then
            (($gml | bytes) / ($lim | bytes)) as $r
            | if $r >= 1 then f("high"; "GOMEMLIMIT_ABOVE_LIMIT"; "GOMEMLIMIT (\($gml)) is at or above the memory limit (\($lim))";
                "The pod will be OOMKilled before the Go runtime reacts. Usually 80-90% of the limit."; "config/env.json")
              elif $r > 0.9 then f("warn"; "GOMEMLIMIT_HIGH"; "GOMEMLIMIT (\($gml)) is \(($r * 100) | round)% of the memory limit (\($lim))";
                "Little headroom for memory outside the Go heap."; "config/env.json")
              else empty end
          else empty end ),
        ( ($facts.env.resources.requests.memory // null) as $req
          | if $lim != null and $req != null and ($req | bytes) != null and ($lim | bytes) != null and ($req | bytes) < ($lim | bytes) then
              f("info"; "MEMORY_REQUEST_BELOW_LIMIT"; "Memory request (\($req)) is lower than the limit (\($lim))";
                "The node may not have the full limit available; equal values are safer for a database."; "config/env.json")
            else empty end ) ),

    # ---- Shards, indexing, replication ---------------------------------------
    ( [$wnodes[] | .name as $n | .shards[]? | select(.vectorIndexingStatus == "READONLY") | "\(.class)/\(.name) on \($n)"] as $ro
      | if ($ro | length) > 0 then f("high"; "SHARDS_READONLY"; "\($ro | length) shard(s) are READONLY";
          "Writes are rejected. Often caused by disk or memory thresholds. First: \($ro[:5] | join(", "))"; "weaviate/nodes.json") else empty end ),

    ( ([$wnodes[].shards[]?.vectorQueueLength // 0] | add // 0) as $q
      | if $q >= 100000 then f("warn"; "VECTOR_QUEUE_BACKLOG"; "\($q) vectors are waiting to be indexed";
          "Async indexing is behind. Search results may be incomplete until the queue drains."; "weaviate/nodes.json") else empty end ),

    ( ($wnodes | length) as $nn
      | $facts.collections[]? | select((.config.replicationConfig.factor // 1) > $nn and $nn > 0)
      | f("high"; "REPLICATION_FACTOR_TOO_HIGH"; "\(.name): replication factor \(.config.replicationConfig.factor) > \($nn) node(s)";
          "Writes cannot reach the requested consistency."; "weaviate/collections/\(.name).json") ),

    ( $facts.collections[]? | select(.tenants != null and ((.tenants.inTransition // []) | length) > 0)
      | f("warn"; "TENANTS_IN_TRANSITION"; "\(.name): \(.tenants.inTransition | length) tenant(s) are changing state";
          "States: \([.tenants.inTransition[].activityStatus] | unique | join(", ")). Check if they stay stuck."; "weaviate/collections/\(.name).json") ),

    ( ([$wnodes[].shards[]? | {class, n: (.objectCount // 0)}] | group_by(.class)
       | map({key: .[0].class, value: (map(.n) | add)}) | from_entries) as $counts
      | [$facts.collections[]? | select(.config.multiTenancyConfig.enabled != true and ((.config.properties // []) | length) > 0)
         | {name, fp: (.config.properties | props_fingerprint), objects: ($counts[.name] // 0)}]
      | group_by(.fp) | map(select(length >= 2) | sort_by(-.objects)) | sort_by(-(map(.objects) | add)) | .[]
      | f("info"; "SCHEMA_MT_CANDIDATES"; "\(length) collections have the same properties";
          "They could be one multi-tenant collection: \(.[:5] | map("\(.name) (\(.objects) objects incl. replicas)") | join(", "))\(if length > 5 then ", ..." else "" end).";
          "weaviate/collections/\(.[0].name).json") ),

    ( if $facts.collections == null then empty else
        ([$facts.collections[] | select(.config.multiTenancyConfig.enabled == true) | .name]) as $mt
        | [$wnodes[] | .name as $n | .shards[]? | select(.objectCount == 0 and .loaded != false and (.class as $c | $mt | index($c) | not))
           | {class, ref: "\(.name)@\($n)"}]
        | group_by(.class)[]
        | f("info"; "EMPTY_SHARDS"; "\(.[0].class): \(length) shard(s) hold no objects";
            "First: \(.[:5] | map(.ref) | join(", ")). Counts in /v1/nodes update in the background, so very recent writes may not show yet."; "weaviate/nodes.json")
      end ),

    ( [$wnodes[] | .name as $n | .shards[]? | select(.loaded != false) | {class, shard: .name, node: $n, n: (.objectCount // 0)}]
      | group_by(.class)[]
      | .[0].class as $c
      | (group_by(.shard) | map(select(length >= 2 and (map(.n) | unique | length) > 1))) as $bad
      | select(($bad | length) > 0)
      | f("warn"; "REPLICA_OBJECT_COUNT_MISMATCH"; "\($c): \($bad | length) shard(s) have different object counts across replicas";
          "\($bad[:5] | map("\(.[0].shard) (\(map("\(.node): \(.n)") | join(", ")))") | join("; ")). Counts in /v1/nodes lag a little, so small differences right after writes are normal. A lasting difference can mean async replication is off or behind."; "weaviate/nodes.json") ),

    ( $facts.replication[]? | select((.status.errors // []) | length > 0)
      | f("warn"; "REPLICATION_OP_ERRORS"; "Replica \(.type // "operation") for \(.collection)/\(.shard) has errors";
          (.status.errors | last | .message // ""); "weaviate/replication.json") ),

    # ---- Backups -----------------------------------------------------------------
    ( $facts.backups // {} | to_entries[] | .key as $b | .value[]? | select(.status == "FAILED")
      | f("warn"; "BACKUP_FAILED"; "Backup \(.id) on \($b) FAILED"; (if .startedAt then "Started \(.startedAt)." else "" end); "weaviate/backups.json") ),

    # ---- Disk ---------------------------------------------------------------------
    ( ((envv($facts; "DISK_USE_WARNING_PERCENTAGE") | tonumber?) // 80) as $warnp
      | ((envv($facts; "DISK_USE_READONLY_PERCENTAGE") | tonumber?) // 90) as $rop
      | $facts.disk[]? | select(.used_percent != null)
      | if .used_percent >= $rop then f("high"; "DISK_ALMOST_FULL"; "\(.pvc) is \(.used_percent)% full";
          "At \($rop)% Weaviate marks shards read-only. \(.available_bytes | human) free."; "kubernetes/disk-usage.json")
        elif .used_percent >= $warnp then f("warn"; "DISK_HIGH"; "\(.pvc) is \(.used_percent)% full";
          "Weaviate warns at \($warnp)% and goes read-only at \($rop)%. \(.available_bytes | human) free."; "kubernetes/disk-usage.json")
        else empty end ),

    # ---- Nodes ----------------------------------------------------------------------
    ( $facts.k8s_nodes[]? | .name as $n | .conditions[]?
      | select((.type == "Ready" and .status != "True") or (.type != "Ready" and (.type | test("Pressure|Unavailable")) and .status == "True"))
      | f("high"; "K8S_NODE_CONDITION"; "Node \($n): \(.type)=\(.status)"; (.message // ""); "kubernetes/nodes.json") ),

    ( $facts.k8s_nodes[]? | select(.unschedulable == true)
      | f("warn"; "K8S_NODE_CORDONED"; "Node \(.name) is cordoned (unschedulable)"; ""; "kubernetes/nodes.json") ),

    # ---- Events ----------------------------------------------------------------------
    ( [$facts.events[]? | select(.type == "Warning")] | group_by(.reason)
      | map({reason: .[0].reason, count: (map(.count) | add), objects: ([.[].object] | unique), last: (map(.last) | max), msg: (last.message)})
      | sort_by(-.count) | .[:10][]
      | f(if (.reason | test("OOM|Evict|FailedScheduling|FailedMount|FailedAttach|BackOff|Unhealthy|NodeNotReady")) then "warn" else "info" end;
          "K8S_WARNING_EVENTS"; "\(.count)× \(.reason) (\(.objects[:3] | join(", ")))"; "Last at \(.last): \(.msg // "" | .[:200])"; "kubernetes/events.json") ),

    # ---- Observability gaps ---------------------------------------------------------------
    ( if $facts.env != null and ((envv($facts; "PROMETHEUS_MONITORING_ENABLED") | truthy) | not) then
        f("info"; "METRICS_DISABLED"; "Prometheus metrics are disabled"; "Set PROMETHEUS_MONITORING_ENABLED=true to get metrics in future bundles."; "config/env.json")
      else empty end )
  ]
  | sort_by(rank);
