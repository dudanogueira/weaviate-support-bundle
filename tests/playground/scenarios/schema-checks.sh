# shellcheck shell=bash disable=SC2034
# The schema red flags, on real data: the sample data already has two
# collections with the same properties (Article, Product). This adds an empty
# collection, and a collection whose replicas are out of step: async replication
# off, one replica frozen for a moment, objects written with consistency ONE.
SC_DESC="identical collections, an empty collection, replicas out of step"
SC_KIND=custom
SC_EXPECT="SCHEMA_MT_CANDIDATES EMPTY_SHARDS REPLICA_OBJECT_COUNT_MISMATCH"

_restart_all() {
  local p
  for p in weaviate-0 weaviate-1 weaviate-2; do
    kn delete pod "$p" --wait=true > /dev/null || return 1
    sleep 2
    pg_pod_ready "$p" 600 || return 1
  done
}

# _signal <pod> <STOP|CONT>: signal the Weaviate process from its kind node.
_signal() {
  local node pod_id cid pid
  node=$(pg_node_of "$1") || return 1
  case "$node" in "$PG_CLUSTER"-*) ;; *) pg_say "refusing node '$node'"; return 1 ;; esac
  pod_id=$(docker exec "$node" crictl pods --name "^$1\$" --state Ready -q | head -n 1)
  cid=$(docker exec "$node" crictl ps --pod "$pod_id" --name '^weaviate$' -q | head -n 1)
  pid=$(docker exec "$node" crictl inspect -o go-template --template '{{.info.pid}}' "$cid")
  [ -n "$pid" ] || { pg_say "no process found for $1"; return 1; }
  docker exec "$node" kill "-$2" "$pid"
}

_drift_seen() {
  pg_api GET '/v1/nodes?output=verbose' 2> /dev/null \
    | jq -e '[.nodes[].shards[]? | select(.class == "DemoDrift") | .objectCount] | (length >= 2) and (unique | length > 1)' > /dev/null
}

_set_async_off() {
  jq '.env |= (map(select(.name != "ASYNC_REPLICATION_DISABLED")) + [{"name": "ASYNC_REPLICATION_DISABLED", "value": "true"}])' \
    "$PG_STATE/base-container.json" > "$PG_STATE/base.new" && mv "$PG_STATE/base.new" "$PG_STATE/base-container.json"
}

_create_and_drift() {
  # Safe to run again after a failed attempt.
  pg_api DELETE /v1/schema/DemoEmpty > /dev/null 2>&1
  pg_api DELETE /v1/schema/DemoDrift > /dev/null 2>&1
  pg_wait 120 pg_wait_raft_once || pg_say "warning: Raft is not synchronized yet"
  pg_api POST /v1/schema -d '{"class":"DemoEmpty","vectorizer":"none","shardingConfig":{"desiredCount":3},
    "properties":[{"name":"sku","dataType":["text"]},{"name":"price","dataType":["number"]}]}' > /dev/null || return 1
  pg_api POST /v1/schema -d '{"class":"DemoDrift","vectorizer":"none","replicationConfig":{"factor":3},"shardingConfig":{"desiredCount":1},
    "properties":[{"name":"body","dataType":["text"]},{"name":"title","dataType":["text"]}]}' > /dev/null || return 1
  pg_vectors DemoDrift 50 | pg_api POST /v1/batch/objects -d @- > /dev/null || return 1
  # Freeze a replica that is not the Raft leader: writes need the leader. Only
  # weaviate-0 or -1, so the drift stays visible if weaviate-2 is broken later.
  local leader frozen=weaviate-0
  leader=$(pg_api GET /v1/cluster/statistics | jq -r '[.statistics[].leaderId // empty][0]')
  [ "$leader" = weaviate-0 ] && frozen=weaviate-1
  pg_say "Raft leader: $leader; freezing $frozen for a moment"
  _signal "$frozen" STOP || return 1
  pg_vectors DemoDrift 50 | pg_api POST '/v1/batch/objects?consistency_level=ONE' -d @- > /dev/null
  local rc=$?
  # Longer than Weaviate's 20 s replication timeout. A shorter freeze changes
  # nothing: the replica wakes up and finishes the write.
  sleep 30
  _signal "$frozen" CONT
  [ "$rc" -eq 0 ] || return 1
  pg_wait 120 _drift_seen || pg_say "warning: no replica drift visible yet"
}

sc_apply() {
  # In the base template, so later scenarios keep it. Async replication would
  # repair the drift before a bundle can show it.
  _set_async_off
  pg_template && _restart_all || return 1
  pg_api_open pod/weaviate-2 :8080 || return 1
  _create_and_drift
  local rc=$?
  pg_api_close
  return "$rc"
}

sc_revert() {
  pg_api_open pod/weaviate-0 :8080 && {
    pg_api DELETE /v1/schema/DemoEmpty > /dev/null
    pg_api DELETE /v1/schema/DemoDrift > /dev/null
    pg_api_close
  }
  jq '.env |= map(select(.name != "ASYNC_REPLICATION_DISABLED"))' "$PG_STATE/base-container.json" > "$PG_STATE/base.new" \
    && mv "$PG_STATE/base.new" "$PG_STATE/base-container.json"
  pg_template && _restart_all
}
