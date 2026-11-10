#!/usr/bin/env bash
#
# Red-flag rules (lib/jq/findings.jq) on small hand-written facts, for the edge
# cases the end-to-end fixtures do not cover.

set -u
cd "$(dirname "$0")/.." || exit 1
fail=0
pass() { echo "ok: $1"; }
bad()  { echo "FAIL: $1"; fail=1; }

# codes_for <facts json>: finding codes, space-separated, sorted.
codes_for() { printf '%s' "$1" | jq -L lib/jq -r 'include "findings"; [findings(.)[].code] | sort | join(" ")'; }

# col <name> <multi-tenant> <properties json>
col() { printf '{"name":"%s","config":{"class":"%s","multiTenancyConfig":{"enabled":%s},"properties":%s}}' "$1" "$1" "$2" "$3"; }

check() {  # check <label> <code> <yes|no> <facts>
  case " $(codes_for "$4") " in
    *" $2 "*) [ "$3" = yes ] && pass "$1" || bad "$1: $2 should not fire" ;;
    *)        [ "$3" = no ]  && pass "$1" || bad "$1: $2 should fire" ;;
  esac
}

# ---- SCHEMA_MT_CANDIDATES -----------------------------------------------------
P1='[{"name":"a","dataType":["text"],"tokenization":"word"},{"name":"b","dataType":["int"]}]'
P1_REORDERED='[{"name":"b","dataType":["int"],"tokenization":""},{"name":"a","dataType":["text"],"tokenization":null}]'
P2='[{"name":"a","dataType":["text"],"tokenization":"field"},{"name":"b","dataType":["int"]}]'
N1='[{"name":"o","dataType":["object"],"nestedProperties":[{"name":"x","dataType":["text"]},{"name":"y","dataType":["int"]}]}]'
N1_REORDERED='[{"name":"o","dataType":["object"],"nestedProperties":[{"name":"y","dataType":["int"]},{"name":"x","dataType":["text"]}]}]'
N2='[{"name":"o","dataType":["object"],"nestedProperties":[{"name":"x","dataType":["int"]},{"name":"y","dataType":["int"]}]}]'
C=SCHEMA_MT_CANDIDATES
check "same properties, any order, blank tokenization" $C yes "{\"collections\":[$(col A false "$P1"),$(col B false "$P1_REORDERED")]}"
check "different tokenization"                         $C no  "{\"collections\":[$(col A false "$P1"),$(col B false "$P2")]}"
check "same nested properties, any order"              $C yes "{\"collections\":[$(col A false "$N1"),$(col B false "$N1_REORDERED")]}"
check "different nested properties"                    $C no  "{\"collections\":[$(col A false "$N1"),$(col B false "$N2")]}"
check "multi-tenant collections are left out"          $C no  "{\"collections\":[$(col A true "$P1"),$(col B false "$P1")]}"
check "collections without properties are left out"   $C no  "{\"collections\":[$(col A false '[]'),$(col B false '[]')]}"
check "schema not collected"                           $C no  '{"collections":null}'
first=$(printf '%s' "{\"collections\":[$(col Small false "$P1"),$(col Big false "$P1")],\"nodes\":{\"nodes\":[{\"name\":\"n\",\"status\":\"HEALTHY\",\"shards\":[{\"class\":\"Big\",\"name\":\"s\",\"objectCount\":9},{\"class\":\"Small\",\"name\":\"t\",\"objectCount\":1}]}]}}" \
  | jq -L lib/jq -r 'include "findings"; findings(.)[] | select(.code == "SCHEMA_MT_CANDIDATES") | .file')
[ "$first" = "weaviate/collections/Big.json" ] && pass "the largest collection comes first" || bad "largest collection not first: $first"

# ---- EMPTY_SHARDS ----------------------------------------------------------------
# nodes_with <shards json>: facts with one healthy node holding these shards,
# and the collections Plain (not multi-tenant) and Mt (multi-tenant).
nodes_with() { printf '{"collections":[%s,%s],"nodes":{"nodes":[{"name":"n0","status":"HEALTHY","shards":%s}]}}' "$(col Plain false '[]')" "$(col Mt true '[]')" "$1"; }
E=EMPTY_SHARDS
check "an empty shard"                        $E yes "$(nodes_with '[{"class":"Plain","name":"s","objectCount":0,"loaded":true}]')"
check "a shard with objects"                  $E no  "$(nodes_with '[{"class":"Plain","name":"s","objectCount":3,"loaded":true}]')"
check "an empty tenant is left out"           $E no  "$(nodes_with '[{"class":"Mt","name":"t","objectCount":0,"loaded":true}]')"
check "an unloaded shard is left out"         $E no  "$(nodes_with '[{"class":"Plain","name":"s","objectCount":0,"loaded":false}]')"
check "unknown schema: no guess about tenants" $E no '{"collections":null,"nodes":{"nodes":[{"name":"n0","status":"HEALTHY","shards":[{"class":"X","name":"s","objectCount":0}]}]}}'

# ---- REPLICA_OBJECT_COUNT_MISMATCH -----------------------------------------------
# two_nodes <objects on n0> <objects on n1> [loaded on n1]
two_nodes() { printf '{"nodes":{"nodes":[{"name":"n0","status":"HEALTHY","shards":[{"class":"C","name":"s","objectCount":%s,"loaded":true}]},{"name":"n1","status":"HEALTHY","shards":[{"class":"C","name":"s","objectCount":%s,"loaded":%s}]}]}}' "$1" "$2" "${3:-true}"; }
R=REPLICA_OBJECT_COUNT_MISMATCH
check "replicas differ"                 $R yes "$(two_nodes 5 7)"
check "replicas match"                  $R no  "$(two_nodes 5 5)"
check "an unloaded replica is left out" $R no  "$(two_nodes 5 0 false)"
check "a single replica"                $R no  '{"nodes":{"nodes":[{"name":"n0","status":"HEALTHY","shards":[{"class":"C","name":"s","objectCount":5}]}]}}'
check "same shard name, other collection" $R no '{"nodes":{"nodes":[{"name":"n0","status":"HEALTHY","shards":[{"class":"A","name":"s","objectCount":1}]},{"name":"n1","status":"HEALTHY","shards":[{"class":"B","name":"s","objectCount":2}]}]}}'

[ "$fail" = 0 ] && echo "FINDINGS TESTS PASSED"
exit "$fail"
