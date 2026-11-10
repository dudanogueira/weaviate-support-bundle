# shellcheck shell=bash disable=SC2034
# The node that runs weaviate-0 is cordoned (unschedulable).
SC_DESC="cordon the node of weaviate-0"
SC_KIND=custom
SC_EXPECT="K8S_NODE_CORDONED"
sc_apply() { pg_node_of weaviate-0 > "$PG_STATE/cordon.node" && k cordon "$(cat "$PG_STATE/cordon.node")" > /dev/null; }
sc_revert() { k uncordon "$(cat "$PG_STATE/cordon.node")" > /dev/null && rm -f "$PG_STATE/cordon.node"; }
