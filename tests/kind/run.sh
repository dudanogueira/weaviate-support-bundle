#!/usr/bin/env bash
#
# Real-cluster test.
#
# Creates a throwaway kind cluster (1 control plane + 3 workers), installs
# Weaviate with the official Helm chart (3 replicas, API keys + RBAC, metrics,
# backup module), loads sample data, and runs collect.sh three times:
#   1. healthy cluster, with a read-only (viewer) API key
#   2. healthy cluster, with --anonymize, --only and --pods
#   3. after breaking two pods on purpose (the playground's oom and crashloop
#      scenarios)
# Then deletes the cluster.
#
# It shares its setup with the playground (tests/playground/lib.sh). It writes
# to the test cluster it creates (that is the point of a test setup). It uses
# its own temporary kubeconfig, so your ~/.kube/config and your current kubectl
# context are never touched, and no other cluster is used.
#
# Requires: docker, kind, helm, kubectl, curl, jq.
#
# Environment:
#   WEAVIATE_VERSION   Weaviate image tag (default: the chart's default)
#   CHART_VERSION      Helm chart version (default: latest)
#   KEEP_CLUSTER=1     do not delete the cluster at the end
#   OUT=<dir>          keep the produced bundles in this folder

set -u -o pipefail
cd "$(dirname "$0")/../.." || exit 1
. tests/playground/lib.sh

PG_CLUSTER="${CLUSTER:-wsb-test}"
PG_STATE=$(mktemp -d "${TMPDIR:-/tmp}/wsb-kind.XXXXXX")
pg_init
OUT="${OUT:-$PG_STATE/bundles}"
CTX="$PG_CTX"
fail=0

pass() { echo "ok: $1"; }
bad()  { echo "FAIL: $1"; fail=1; }
step() { pg_step "$@"; }

cleanup() {
  pg_api_close
  if [ "${KEEP_CLUSTER:-0}" != "1" ]; then
    pg_delete_cluster && echo "cluster $PG_CLUSTER deleted"
  fi
  rm -rf "$PG_STATE"
}
trap cleanup EXIT

pg_require_tools
if pg_cluster_exists; then
  echo "A kind cluster named '$PG_CLUSTER' already exists. Delete it or set CLUSTER=<other name>."
  trap - EXIT; rm -rf "$PG_STATE"; exit 1
fi
mkdir -p "$OUT"

pg_create_cluster 3 || exit 1
pg_install_weaviate || exit 1
pg_seed_base || exit 1
ADMIN_KEY=$(cat "$PG_STATE/admin.key")
READER_KEY=$(cat "$PG_STATE/reader.key")
pass "data loaded: 3 collections, 12 tenants, a viewer user"

leak_check() {  # leak_check <bundle dir> <label>
  local hits
  hits=$(grep -rlF -e "$ADMIN_KEY" -e "$READER_KEY" "$1" "${1%/}.tar.gz" 2>/dev/null)
  [ -z "$hits" ] && pass "$2: no API key in the bundle" || bad "$2: API key found in: $hits"
}
has_code() { jq -e --arg c "$2" 'any(.[]; .code == $c)' "$1/findings.json" > /dev/null; }
step_status() { jq -r --arg n "$2" '[.steps[] | select(.name == $n) | .status][0] // "missing"' "$1/manifest.json"; }

# ---------------------------------------------------------------------------
step "Run 1: healthy cluster, read-only (viewer) key"
WEAVIATE_API_KEY="$READER_KEY" ./collect.sh --context "$CTX" --yes --include-helm --metrics-interval 10 -o "$OUT/1-healthy" \
  > "$PG_STATE/run1.out" 2>&1
rc=$?
B1=$(ls -d "$OUT"/1-healthy/weaviate-support-bundle-*/ 2>/dev/null | head -n 1)
[ "$rc" -eq 0 ] && [ -n "$B1" ] && pass "run 1 finished" || { bad "run 1 failed (exit $rc)"; tail -40 "$PG_STATE/run1.out"; }
if [ -n "$B1" ]; then
  for s in "version and modules (/v1/meta)" "nodes and shards (/v1/nodes)" "Raft cluster state (/v1/cluster/statistics)" \
           "collections" "pods" "statefulset + settings" "volume usage" "release"; do
    st=$(step_status "$B1" "$s")
    [ "$st" = "ok" ] && pass "viewer key: '$s' ok" || bad "'$s' is $st"
  done
  for f in weaviate/collections/Article.json weaviate/collections/Product.json weaviate/collections/Tenanted.json \
           pods/weaviate-0/metrics.json pods/weaviate-2/logs/weaviate.log kubernetes/disk-usage.json helm/release.json; do
    [ -s "$B1/$f" ] && pass "has $f" || bad "missing $f"
  done
  jq -e '.tenants.total == 12 and ((.tenants.byStatus.INACTIVE // .tenants.byStatus.COLD) == 2)' "$B1/weaviate/collections/Tenanted.json" > /dev/null \
    && pass "tenant counts correct" || bad "tenant counts wrong"
  high=$(jq -r '[.[] | select(.severity == "high") | .code] | join(", ")' "$B1/findings.json")
  [ -z "$high" ] && pass "healthy cluster has no high red flags" || bad "unexpected high red flags: $high"
  leak_check "$B1" "run 1"
  cp "$B1/SUMMARY.md" "$OUT/1-healthy-SUMMARY.md"
fi

# ---------------------------------------------------------------------------
step "Run 2: --anonymize --only weaviate,logs --pods weaviate-0 (healthy cluster)"
WEAVIATE_API_KEY="$READER_KEY" ./collect.sh --context "$CTX" --yes --anonymize --only weaviate,logs --pods weaviate-0 --since 30m \
  -o "$OUT/2-options" > "$PG_STATE/run2.out" 2>&1
rc=$?
B3=$(ls -d "$OUT"/2-options/weaviate-support-bundle-*/ 2>/dev/null | head -n 1)
[ "$rc" -eq 0 ] && [ -n "$B3" ] && pass "run 2 finished" || { bad "run 2 failed (exit $rc)"; tail -40 "$PG_STATE/run2.out"; }
if [ -n "$B3" ]; then
  if grep -rqE 'AcmeCorp[0-9]+|support-reader' "$B3"; then
    bad "--anonymize left tenant or user names:"
    grep -rhoE '.{0,60}(AcmeCorp[0-9]+|support-reader).{0,40}' "$B3" | head -5 | sed 's/^/    /'
  else
    pass "--anonymize removed tenant and user names"
  fi
  [ ! -d "$B3/pods/weaviate-1" ] && pass "--pods limited per-pod data" || bad "--pods did not limit per-pod data"
  [ ! -d "$B3/kubernetes" ] || [ -z "$(ls -A "$B3/kubernetes" 2>/dev/null)" ] && pass "--only skipped the kubernetes section" || bad "--only did not skip kubernetes"
fi

# ---------------------------------------------------------------------------
step "Break two pods on purpose"
pg_scenario_apply oom
echo "weaviate-1 last termination: $(kn get pod weaviate-1 -o jsonpath='{.status.containerStatuses[0].lastState.terminated.reason}' 2>/dev/null)"
pg_scenario_apply crashloop
echo "weaviate-2 restarts: $(kn get pod weaviate-2 -o jsonpath='{.status.containerStatuses[0].restartCount}' 2>/dev/null)"

# ---------------------------------------------------------------------------
step "Run 3: broken cluster"
WEAVIATE_API_KEY="$READER_KEY" ./collect.sh --context "$CTX" --yes --metrics-interval 5 -o "$OUT/3-broken" > "$PG_STATE/run3.out" 2>&1
rc=$?
B2=$(ls -d "$OUT"/3-broken/weaviate-support-bundle-*/ 2>/dev/null | head -n 1)
[ "$rc" -eq 0 ] && [ -n "$B2" ] && pass "run 3 finished on a broken cluster" || { bad "run 3 failed (exit $rc)"; tail -40 "$PG_STATE/run3.out"; }
if [ -n "$B2" ]; then
  pg_oom_flagged "$B2" weaviate-1 && pass "flags the OOM kill" || bad "did not flag the OOM kill (POD_OOMKILLED, or a restart with exit code 137)"
  { has_code "$B2" POD_CRASHLOOP || has_code "$B2" POD_RESTARTS; } && pass "flags the crash loop" || bad "did not flag the crashing pod"
  has_code "$B2" STATEFULSET_NOT_READY && pass "flags the StatefulSet not ready" || bad "did not flag STATEFULSET_NOT_READY"
  # Whether Raft reports "not synchronized" here depends on restart timing, so
  # only check that the Raft state was collected and recorded.
  [ "$(step_status "$B2" "Raft cluster state (/v1/cluster/statistics)")" != "missing" ] \
    && pass "Raft state recorded on a broken cluster" || bad "Raft step missing on a broken cluster"
  has_code "$B2" WEAVIATE_VERSION_MISMATCH && bad "false alarm: version mismatch on a single-version cluster" || pass "no false version-mismatch alarm"
  [ -s "$B2/pods/weaviate-2/logs/weaviate.previous.log" ] && pass "previous log of the crashing pod collected" || bad "no previous log for weaviate-2"
  grep -q 'QUERY_DEFAULTS_LIMIT' "$B2/pods/weaviate-2/logs/weaviate.previous.log" 2>/dev/null \
    && pass "crash reason visible in the previous log" || bad "crash reason not in the previous log"
  leak_check "$B2" "run 3"
  cp "$B2/SUMMARY.md" "$OUT/3-broken-SUMMARY.md"
fi


echo
[ "$fail" = 0 ] && echo "KIND TEST PASSED" || echo "KIND TEST FAILED"
exit "$fail"
