# shellcheck shell=bash disable=SC2034
# The kind node that runs weaviate-2 is frozen (docker pause): its kubelet and
# the Weaviate pod on it stop answering.
SC_DESC="freeze the node of weaviate-2 (docker pause) -> NotReady"
SC_KIND=custom
SC_EXPECT="K8S_NODE_CONDITION STATEFULSET_NOT_READY"
sc_apply() {
  local node
  node=$(pg_node_of weaviate-2) || return 1
  # kind node names are the docker container names; only pause our own.
  case "$node" in "$PG_CLUSTER"-*) ;; *) pg_say "refusing to pause '$node'"; return 1 ;; esac
  printf '%s' "$node" > "$PG_STATE/node-down.node"
  docker pause "$node" > /dev/null || return 1
  _notready() { [ "$(k get node "$node" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}')" != True ]; }
  pg_wait 180 _notready || pg_say "warning: $node is still Ready"
}
sc_revert() {
  local node
  node=$(cat "$PG_STATE/node-down.node") || return 1
  docker unpause "$node" > /dev/null
  _ready() { [ "$(k get node "$node" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}')" = True ]; }
  pg_wait 180 _ready && pg_pod_ready weaviate-2 600 && rm -f "$PG_STATE/node-down.node"
}
