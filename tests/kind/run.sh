#!/usr/bin/env bash
#
# Real-cluster test.
#
# Creates a throwaway kind cluster (1 control plane + 3 workers), installs
# Weaviate with the official Helm chart (3 replicas, API keys + RBAC, metrics,
# backup module), loads sample data, and runs collect.sh three times:
#   1. healthy cluster, with a read-only (viewer) API key
#   2. healthy cluster, with --anonymize, --only and --pods
#   3. after breaking two pods on purpose (OOM kill, crash loop)
# Then deletes the cluster.
#
# This script writes to the test cluster it creates (that is the point of a
# test setup). It uses its own temporary kubeconfig, so your ~/.kube/config and
# your current kubectl context are never touched, and no other cluster is used.
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

CLUSTER="${CLUSTER:-wsb-test}"
CTX="kind-$CLUSTER"
NS=weaviate
CHART_REPO=https://weaviate.github.io/weaviate-helm
WORKDIR=$(mktemp -d "${TMPDIR:-/tmp}/wsb-kind.XXXXXX")
OUT="${OUT:-$WORKDIR/bundles}"
ADMIN_KEY="admin-$(date +%s)-$RANDOM$RANDOM$RANDOM"
PF_PID=""
fail=0
export KUBECONFIG="$WORKDIR/kubeconfig"

step() { printf '\n==> %s\n' "$*"; }
pass() { echo "ok: $1"; }
bad()  { echo "FAIL: $1"; fail=1; }
k()    { kubectl --context "$CTX" "$@"; }

cleanup() {
  [ -n "$PF_PID" ] && kill "$PF_PID" 2>/dev/null
  if [ "${KEEP_CLUSTER:-0}" != "1" ]; then
    kind delete cluster --name "$CLUSTER" --kubeconfig "$KUBECONFIG" > /dev/null 2>&1 && echo "cluster $CLUSTER deleted"
  fi
  rm -rf "$WORKDIR"
}
trap cleanup EXIT

for t in docker kind helm kubectl curl jq; do
  command -v "$t" > /dev/null || { echo "missing tool: $t"; exit 1; }
done
if kind get clusters 2>/dev/null | grep -qx "$CLUSTER"; then
  echo "A kind cluster named '$CLUSTER' already exists. Delete it or set CLUSTER=<other name>."
  trap - EXIT; rm -rf "$WORKDIR"; exit 1
fi
mkdir -p "$OUT"

# ---------------------------------------------------------------------------
step "Create kind cluster $CLUSTER (1 control plane + 3 workers)"
cat > "$WORKDIR/kind.yaml" <<'EOF'
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
nodes:
  - role: control-plane
  - role: worker
  - role: worker
  - role: worker
EOF
kind create cluster --name "$CLUSTER" --config "$WORKDIR/kind.yaml" --kubeconfig "$KUBECONFIG" --wait 120s || exit 1

# ---------------------------------------------------------------------------
step "Install Weaviate with the Helm chart (3 replicas)"
cat > "$WORKDIR/values.yaml" <<EOF
replicas: 3
resources:
  requests: {cpu: 100m, memory: 512Mi}
  limits: {memory: 1Gi}
storage:
  size: 2Gi
service:
  type: ClusterIP
grpcService:
  type: ClusterIP
authentication:
  anonymous_access:
    enabled: false
  apikey:
    enabled: true
    allowed_keys: ["$ADMIN_KEY"]
    users: ["admin"]
authorization:
  rbac:
    enabled: true
    root_users: ["admin"]
backups:
  filesystem:
    enabled: true
env:
  PROMETHEUS_MONITORING_ENABLED: true
  GOMEMLIMIT: 800MiB
  AUTHENTICATION_DB_USERS_ENABLED: true
EOF
[ -n "${WEAVIATE_VERSION:-}" ] && printf 'image:\n  tag: "%s"\n' "$WEAVIATE_VERSION" >> "$WORKDIR/values.yaml"
helm --kube-context "$CTX" install weaviate weaviate --repo "$CHART_REPO" ${CHART_VERSION:+--version "$CHART_VERSION"} \
  -n "$NS" --create-namespace -f "$WORKDIR/values.yaml" --wait --timeout 15m || exit 1
k -n "$NS" rollout status statefulset/weaviate --timeout=600s || exit 1

# ---------------------------------------------------------------------------
step "Load sample data"
k -n "$NS" port-forward svc/weaviate :80 > "$WORKDIR/pf.log" 2>&1 &
PF_PID=$!
for _ in $(seq 1 40); do grep -q 'Forwarding from 127.0.0.1' "$WORKDIR/pf.log" && break; sleep 0.25; done
PORT=$(sed -n 's/^Forwarding from 127\.0\.0\.1:\([0-9]*\) .*/\1/p' "$WORKDIR/pf.log" | head -n 1)
[ -n "$PORT" ] || { echo "port-forward failed"; cat "$WORKDIR/pf.log"; exit 1; }
BASE="http://127.0.0.1:$PORT"
api() {  # api <method> <path> [curl args]: prints the body; on HTTP errors also prints it to stderr
  local m="$1" p="$2" code; shift 2
  code=$(curl -sS -o "$WORKDIR/resp" -w '%{http_code}' -X "$m" -H "Authorization: Bearer $ADMIN_KEY" \
    -H 'Content-Type: application/json' "$BASE$p" "$@")
  case "$code" in
    2*) cat "$WORKDIR/resp" ;;
    *) echo "$m $p -> HTTP $code: $(head -c 400 "$WORKDIR/resp")" >&2; return 1 ;;
  esac
}

vectors() {  # vectors <class> <count> [tenant]
  awk -v c="$1" -v n="$2" -v t="${3:-}" 'BEGIN { srand(7); printf "{\"objects\":[";
    for (i = 0; i < n; i++) { printf "%s{\"class\":\"%s\",%s\"properties\":{\"title\":\"item %d\"},\"vector\":[", (i ? "," : ""), c, (t != "" ? "\"tenant\":\"" t "\"," : ""), i;
      for (j = 0; j < 32; j++) printf "%s%.4f", (j ? "," : ""), rand(); printf "]}" }
    printf "]}" }'
}

api POST /v1/schema -d '{"class":"Article","vectorizer":"none","vectorIndexType":"hnsw","vectorIndexConfig":{"distance":"cosine"},
  "replicationConfig":{"factor":3},"shardingConfig":{"desiredCount":3},"properties":[{"name":"title","dataType":["text"]}]}' > /dev/null || exit 1
api POST /v1/schema -d '{"class":"Product","vectorizer":"none","vectorIndexType":"flat","vectorIndexConfig":{"bq":{"enabled":true}},
  "properties":[{"name":"title","dataType":["text"]}]}' > /dev/null || exit 1
api POST /v1/schema -d '{"class":"Tenanted","vectorizer":"none","multiTenancyConfig":{"enabled":true,"autoTenantActivation":true},
  "replicationConfig":{"factor":2},"properties":[{"name":"title","dataType":["text"]}]}' > /dev/null || exit 1
tenants=$(seq 1 12 | awk '{ printf "%s{\"name\":\"AcmeCorp%02d\"}", (NR > 1 ? "," : ""), $1 }')
api POST /v1/schema/Tenanted/tenants -d "[$tenants]" > /dev/null || exit 1
api PUT /v1/schema/Tenanted/tenants -d '[{"name":"AcmeCorp11","activityStatus":"INACTIVE"},{"name":"AcmeCorp12","activityStatus":"INACTIVE"}]' > /dev/null || exit 1

vectors Article 600 | api POST /v1/batch/objects -d @- > /dev/null || exit 1
vectors Product 200 | api POST /v1/batch/objects -d @- > /dev/null || exit 1
for t in 01 02 03; do vectors Tenanted 20 "AcmeCorp$t" | api POST /v1/batch/objects -d @- > /dev/null || exit 1; done

READER_KEY=$(api POST /v1/users/db/support-reader -d "{}" | jq -r '.apikey')
[ -n "$READER_KEY" ] && [ "$READER_KEY" != "null" ] || { echo "could not create the reader user"; exit 1; }
api POST /v1/authz/users/support-reader/assign -d '{"roles":["viewer"],"userType":"db"}' > /dev/null || exit 1

# Let Raft settle after the writes, so run 1 sees a steady healthy cluster.
for _ in $(seq 1 60); do
  [ "$(api GET /v1/cluster/statistics | jq -r '.synchronized')" = "true" ] && break; sleep 2
done
kill "$PF_PID" 2>/dev/null; PF_PID=""
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
  > "$WORKDIR/run1.out" 2>&1
rc=$?
B1=$(ls -d "$OUT"/1-healthy/weaviate-support-bundle-*/ 2>/dev/null | head -n 1)
[ "$rc" -eq 0 ] && [ -n "$B1" ] && pass "run 1 finished" || { bad "run 1 failed (exit $rc)"; tail -40 "$WORKDIR/run1.out"; }
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
  -o "$OUT/2-options" > "$WORKDIR/run2.out" 2>&1
rc=$?
B3=$(ls -d "$OUT"/2-options/weaviate-support-bundle-*/ 2>/dev/null | head -n 1)
[ "$rc" -eq 0 ] && [ -n "$B3" ] && pass "run 2 finished" || { bad "run 2 failed (exit $rc)"; tail -40 "$WORKDIR/run2.out"; }
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
k -n "$NS" patch statefulset weaviate --type merge -p '{"spec":{"updateStrategy":{"type":"OnDelete","rollingUpdate":null}}}' > /dev/null
# weaviate-1: memory limit far below what Weaviate needs -> OOM killed
k -n "$NS" patch statefulset weaviate --type json \
  -p '[{"op":"replace","path":"/spec/template/spec/containers/0/resources/limits/memory","value":"40Mi"},
       {"op":"replace","path":"/spec/template/spec/containers/0/resources/requests/memory","value":"40Mi"}]' > /dev/null
k -n "$NS" delete pod weaviate-1 --wait=false > /dev/null
for _ in $(seq 1 90); do
  r=$(k -n "$NS" get pod weaviate-1 -o jsonpath='{.status.containerStatuses[0].lastState.terminated.reason}' 2>/dev/null)
  [ "$r" = "OOMKilled" ] && break; sleep 2
done
echo "weaviate-1 last termination: ${r:-none}"
# weaviate-2: invalid setting -> exits at startup (crash loop); memory back to normal
k -n "$NS" patch statefulset weaviate --type json \
  -p '[{"op":"replace","path":"/spec/template/spec/containers/0/resources/limits/memory","value":"1Gi"},
       {"op":"replace","path":"/spec/template/spec/containers/0/resources/requests/memory","value":"512Mi"},
       {"op":"add","path":"/spec/template/spec/containers/0/env/-","value":{"name":"QUERY_DEFAULTS_LIMIT","value":"not-a-number"}}]' > /dev/null
k -n "$NS" delete pod weaviate-2 --wait=false > /dev/null
for _ in $(seq 1 90); do
  c=$(k -n "$NS" get pod weaviate-2 -o jsonpath='{.status.containerStatuses[0].restartCount}' 2>/dev/null)
  [ "${c:-0}" -ge 2 ] && break; sleep 2
done
echo "weaviate-2 restarts: ${c:-0}"

# ---------------------------------------------------------------------------
step "Run 3: broken cluster"
WEAVIATE_API_KEY="$READER_KEY" ./collect.sh --context "$CTX" --yes --metrics-interval 5 -o "$OUT/3-broken" > "$WORKDIR/run3.out" 2>&1
rc=$?
B2=$(ls -d "$OUT"/3-broken/weaviate-support-bundle-*/ 2>/dev/null | head -n 1)
[ "$rc" -eq 0 ] && [ -n "$B2" ] && pass "run 3 finished on a broken cluster" || { bad "run 3 failed (exit $rc)"; tail -40 "$WORKDIR/run3.out"; }
if [ -n "$B2" ]; then
  has_code "$B2" POD_OOMKILLED && pass "flags the OOM kill" || bad "did not flag POD_OOMKILLED"
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
