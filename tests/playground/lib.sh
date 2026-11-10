# shellcheck shell=bash disable=SC1090,SC2034
# (SC1090: scenario files are sourced by name; SC2034: SC_* are read from them.)
# tests/playground/lib.sh: shared helpers for the playground (playground.sh)
# and the real-cluster test (tests/kind/run.sh).
#
# This code WRITES to a cluster: it creates a kind cluster, installs Weaviate
# and breaks it on purpose. It is test tooling, never part of collect.sh, and
# it only ever touches the kind cluster it created:
#   - kubectl always runs with its own KUBECONFIG file inside $PG_STATE and
#     with --context kind-$PG_CLUSTER,
#   - the cluster name must start with "wsb-",
#   - pg_guard refuses anything else before the first kubectl call.
#
# Requires: bash 3.2+, docker, kind, helm, kubectl, curl, jq.
#
# Callers set PG_CLUSTER and PG_STATE, then call pg_init.

PG_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PG_REPO="$(cd "$PG_LIB_DIR/../.." && pwd)"
PG_SCENARIOS="$PG_LIB_DIR/scenarios"
PG_NS=weaviate
PG_STS=weaviate
PG_CHART_REPO=https://weaviate.github.io/weaviate-helm

pg_say()  { printf '%s\n' "$*" >&2; }
pg_step() { printf '\n==> %s\n' "$*" >&2; }
pg_die()  { printf 'playground: %s\n' "$*" >&2; exit 1; }

# pg_init: derive context and kubeconfig from PG_CLUSTER and PG_STATE.
pg_init() {
  [ -n "${PG_CLUSTER:-}" ] && [ -n "${PG_STATE:-}" ] || pg_die "PG_CLUSTER and PG_STATE must be set"
  PG_CTX="kind-$PG_CLUSTER"
  export KUBECONFIG="$PG_STATE/kubeconfig"
  pg_guard
}

# The safety check: only a wsb-* kind cluster, only through our own kubeconfig.
pg_guard() {
  case "$PG_CLUSTER" in
    wsb-*) ;;
    *) pg_die "refusing cluster '$PG_CLUSTER': playground clusters must be named wsb-*" ;;
  esac
  [ "$PG_CTX" = "kind-$PG_CLUSTER" ] || pg_die "refusing context '$PG_CTX'"
  [ "$KUBECONFIG" = "$PG_STATE/kubeconfig" ] || pg_die "refusing KUBECONFIG '$KUBECONFIG' (must be $PG_STATE/kubeconfig)"
}

# k <kubectl args>: kubectl on the playground cluster only.
k() { pg_guard; kubectl --context "$PG_CTX" "$@"; }
kn() { k -n "$PG_NS" "$@"; }

# pg_lock: one command that changes the cluster at a time. Two at once restart
# each other's pods and corrupt the state files. A lock whose process is gone
# is taken over.
pg_lock() {
  ( umask 077; mkdir -p "$PG_STATE" )
  local holder
  if ! ( set -C; echo "$$" > "$PG_STATE/lock" ) 2> /dev/null; then
    holder=$(cat "$PG_STATE/lock" 2> /dev/null)
    if [ -n "$holder" ] && kill -0 "$holder" 2> /dev/null; then
      pg_die "another playground command is running (PID $holder). Wait for it, or stop it."
    fi
    echo "$$" > "$PG_STATE/lock"
  fi
  trap 'rm -f "$PG_STATE/lock"' EXIT
}

pg_require_tools() {
  local t missing=""
  for t in docker kind helm kubectl curl jq; do
    command -v "$t" > /dev/null 2>&1 || missing="$missing $t"
  done
  [ -z "$missing" ] || pg_die "missing tools:$missing"
  docker info > /dev/null 2>&1 || pg_die "docker is not running"
}

pg_cluster_exists() { kind get clusters 2> /dev/null | grep -qx "$PG_CLUSTER"; }

# ---------------------------------------------------------------------------
# Cluster and Weaviate
# ---------------------------------------------------------------------------

# pg_create_cluster [workers]: 1 control plane + N workers (default 3).
pg_create_cluster() {
  local workers="${1:-3}" i
  pg_step "Create kind cluster $PG_CLUSTER (1 control plane + $workers workers)"
  {
    printf 'kind: Cluster\napiVersion: kind.x-k8s.io/v1alpha4\nnodes:\n  - role: control-plane\n'
    i=0; while [ "$i" -lt "$workers" ]; do printf '  - role: worker\n'; i=$((i + 1)); done
  } > "$PG_STATE/kind.yaml"
  kind create cluster --name "$PG_CLUSTER" --config "$PG_STATE/kind.yaml" --kubeconfig "$KUBECONFIG" --wait 120s
}

pg_delete_cluster() {
  kind delete cluster --name "$PG_CLUSTER" --kubeconfig "$KUBECONFIG" > /dev/null 2>&1
}

# pg_install_weaviate: Helm install (WEAVIATE_VERSION / CHART_VERSION optional),
# then switch the StatefulSet to OnDelete so scenario changes to the template
# only reach the pods a scenario recreates on purpose.
pg_install_weaviate() {
  local admin_key
  admin_key="admin-$(date +%s)-$RANDOM$RANDOM$RANDOM"
  ( umask 077; printf '%s' "$admin_key" > "$PG_STATE/admin.key" )
  sed "s/__ADMIN_KEY__/$admin_key/" "$PG_LIB_DIR/values/base.yaml" > "$PG_STATE/values.yaml"
  chmod 600 "$PG_STATE/values.yaml"
  [ -n "${WEAVIATE_VERSION:-}" ] && printf 'image:\n  tag: "%s"\n' "$WEAVIATE_VERSION" >> "$PG_STATE/values.yaml"
  pg_step "Install Weaviate with the Helm chart${WEAVIATE_VERSION:+ (Weaviate $WEAVIATE_VERSION)}"
  helm --kube-context "$PG_CTX" install weaviate weaviate --repo "$PG_CHART_REPO" \
    ${CHART_VERSION:+--version "$CHART_VERSION"} -n "$PG_NS" --create-namespace \
    -f "$PG_STATE/values.yaml" --wait --timeout 15m || return 1
  kn rollout status "statefulset/$PG_STS" --timeout=600s || return 1
  kn patch statefulset "$PG_STS" --type merge \
    -p '{"spec":{"updateStrategy":{"type":"OnDelete","rollingUpdate":null}}}' > /dev/null || return 1
  # The Weaviate container's env and resources as installed: the base that
  # scenarios change and revert to.
  kn get statefulset "$PG_STS" -o json \
    | jq '.spec.template.spec.containers[] | select(.name == "weaviate") | {env: (.env // []), resources: (.resources // {})}' \
    > "$PG_STATE/base-container.json"
}

# ---------------------------------------------------------------------------
# Weaviate API (admin key, through a port-forward to the service)
# ---------------------------------------------------------------------------
PG_PF_PID=""

# pg_api_open [target] [port]: default the service; a scenario that freezes a
# pod names the pod to use instead.
# shellcheck disable=SC2120  # scenario files, sourced by name, pass the arguments
pg_api_open() {
  kn port-forward "${1:-svc/weaviate}" "${2:-:80}" > "$PG_STATE/pf.log" 2>&1 &
  PG_PF_PID=$!
  local port="" i=0
  while [ "$i" -lt 40 ]; do
    port=$(sed -n 's/^Forwarding from 127\.0\.0\.1:\([0-9]*\) .*/\1/p' "$PG_STATE/pf.log" | head -n 1)
    [ -n "$port" ] && break
    sleep 0.25; i=$((i + 1))
  done
  [ -n "$port" ] || { cat "$PG_STATE/pf.log" >&2; pg_api_close; return 1; }
  PG_BASE="http://127.0.0.1:$port"
}

pg_api_close() { [ -n "$PG_PF_PID" ] && kill "$PG_PF_PID" 2> /dev/null; PG_PF_PID=""; return 0; }

# pg_api <method> <path> [curl args]: prints the body; on HTTP errors also
# prints it to stderr and returns 1. The admin key goes through a private curl
# config file, never on the command line (stdin stays free for -d @-).
pg_api() {
  local m="$1" p="$2" code; shift 2
  if [ ! -f "$PG_STATE/admin.curlrc" ]; then
    ( umask 077; printf 'header = "Authorization: Bearer %s"\n' "$(cat "$PG_STATE/admin.key")" > "$PG_STATE/admin.curlrc" )
  fi
  code=$(curl -sS --config "$PG_STATE/admin.curlrc" -o "$PG_STATE/resp" -w '%{http_code}' -X "$m" \
        -H 'Content-Type: application/json' "$PG_BASE$p" "$@")
  case "$code" in
    2*) cat "$PG_STATE/resp" ;;
    *) pg_say "$m $p -> HTTP $code: $(head -c 400 "$PG_STATE/resp")"; return 1 ;;
  esac
}

# pg_vectors <class> <count> [tenant]: a batch request body with random vectors.
pg_vectors() {
  awk -v c="$1" -v n="$2" -v t="${3:-}" 'BEGIN { srand(7); printf "{\"objects\":[";
    for (i = 0; i < n; i++) { printf "%s{\"class\":\"%s\",%s\"properties\":{\"title\":\"item %d\"},\"vector\":[", (i ? "," : ""), c, (t != "" ? "\"tenant\":\"" t "\"," : ""), i;
      for (j = 0; j < 32; j++) printf "%s%.4f", (j ? "," : ""), rand(); printf "]}" }
    printf "]}" }'
}

# pg_seed_base: 3 collections (Article, Product, Tenanted with 12 tenants),
# sample objects, and a viewer user whose key is saved to reader.key.
pg_seed_base() {
  pg_step "Load sample data"
  pg_api_open || return 1
  pg_api POST /v1/schema -d '{"class":"Article","vectorizer":"none","vectorIndexType":"hnsw","vectorIndexConfig":{"distance":"cosine"},
    "replicationConfig":{"factor":3},"shardingConfig":{"desiredCount":3},"properties":[{"name":"title","dataType":["text"]}]}' > /dev/null || return 1
  pg_api POST /v1/schema -d '{"class":"Product","vectorizer":"none","vectorIndexType":"flat","vectorIndexConfig":{"bq":{"enabled":true}},
    "properties":[{"name":"title","dataType":["text"]}]}' > /dev/null || return 1
  pg_api POST /v1/schema -d '{"class":"Tenanted","vectorizer":"none","multiTenancyConfig":{"enabled":true,"autoTenantActivation":true},
    "replicationConfig":{"factor":2},"properties":[{"name":"title","dataType":["text"]}]}' > /dev/null || return 1
  local tenants t key
  tenants=$(seq 1 12 | awk '{ printf "%s{\"name\":\"AcmeCorp%02d\"}", (NR > 1 ? "," : ""), $1 }')
  pg_api POST /v1/schema/Tenanted/tenants -d "[$tenants]" > /dev/null || return 1
  pg_api PUT /v1/schema/Tenanted/tenants -d '[{"name":"AcmeCorp11","activityStatus":"INACTIVE"},{"name":"AcmeCorp12","activityStatus":"INACTIVE"}]' > /dev/null || return 1
  pg_vectors Article 600 | pg_api POST /v1/batch/objects -d @- > /dev/null || return 1
  pg_vectors Product 200 | pg_api POST /v1/batch/objects -d @- > /dev/null || return 1
  for t in 01 02 03; do pg_vectors Tenanted 20 "AcmeCorp$t" | pg_api POST /v1/batch/objects -d @- > /dev/null || return 1; done
  key=$(pg_api POST /v1/users/db/support-reader -d "{}" | jq -r '.apikey')
  [ -n "$key" ] && [ "$key" != "null" ] || { pg_say "could not create the reader user"; return 1; }
  ( umask 077; printf '%s' "$key" > "$PG_STATE/reader.key" )
  pg_api POST /v1/authz/users/support-reader/assign -d '{"roles":["viewer"],"userType":"db"}' > /dev/null || return 1
  pg_wait_raft
  pg_api_close
}

# pg_seed_more [tenants] [objects]: more tenants in Tenanted, more objects in Article.
pg_seed_more() {
  local nt="${1:-0}" no="${2:-0}" start tenants
  pg_api_open || return 1
  if [ "$nt" -gt 0 ]; then
    start=$(pg_api GET /v1/schema/Tenanted/tenants | jq 'length')
    tenants=$(awk -v s="$start" -v n="$nt" 'BEGIN { for (i = 1; i <= n; i++) printf "%s{\"name\":\"AcmeCorp%05d\"}", (i > 1 ? "," : ""), s + i }')
    pg_api POST /v1/schema/Tenanted/tenants -d "[$tenants]" > /dev/null || return 1
    pg_say "added $nt tenant(s)"
  fi
  while [ "$no" -gt 0 ]; do
    pg_vectors Article "$([ "$no" -gt 500 ] && echo 500 || echo "$no")" | pg_api POST /v1/batch/objects -d @- > /dev/null || return 1
    no=$((no - 500))
  done
  pg_api_close
}

pg_wait_raft_once() { [ "$(pg_api GET /v1/cluster/statistics 2> /dev/null | jq -r '.synchronized')" = "true" ]; }

# Let Raft settle after writes, so a healthy run sees a steady cluster.
pg_wait_raft() {
  local i=0
  while [ "$i" -lt 60 ]; do
    [ "$(pg_api GET /v1/cluster/statistics 2> /dev/null | jq -r '.synchronized')" = "true" ] && return 0
    sleep 2; i=$((i + 1))
  done
  pg_say "Raft did not report synchronized=true within 2 minutes"
  return 1
}

# ---------------------------------------------------------------------------
# Pods and nodes
# ---------------------------------------------------------------------------
pg_node_of() { kn get pod "$1" -o jsonpath='{.spec.nodeName}'; }

# pg_wait <seconds> <command...>: run the command every 2 s until it succeeds.
pg_wait() {
  local limit="$1" t=0; shift
  while [ "$t" -lt "$limit" ]; do
    "$@" && return 0
    sleep 2; t=$((t + 2))
  done
  return 1
}

pg_pod_ready() { kn wait --for=condition=Ready "pod/$1" --timeout="${2:-600}s" > /dev/null; }

pg_all_ready() {
  local want ready
  want=$(kn get statefulset "$PG_STS" -o jsonpath='{.spec.replicas}')
  ready=$(kn get statefulset "$PG_STS" -o jsonpath='{.status.readyReplicas}')
  [ "${ready:-0}" = "$want" ]
}

# ---------------------------------------------------------------------------
# Scenarios
#
# A scenario is tests/playground/scenarios/<name>.sh. It sets:
#   SC_DESC     one line
#   SC_KIND     pod | config | custom
#   SC_POD      pod:    the pod it breaks
#   SC_JQ       pod, config: jq program on the Weaviate container {env, resources}
#   SC_EXPECT   finding codes that must be in findings.json
#   SC_ABSENT   finding codes that must not be there
#   SC_NO_HIGH  1: no finding with severity "high" may be there
#   SC_COLLECT_ARGS  extra collect.sh options for "verify"
# and may define:
#   sc_wait     pod:    wait until the broken state shows (after the pod is recreated)
#   sc_apply / sc_revert   custom: do and undo the change
#   sc_check <bundle-dir>  extra checks on the bundle (return non-zero on failure)
#
# pod:    the template gets SC_JQ, SC_POD is recreated from it, then the
#         template goes back. The broken pod keeps its spec, so pod scenarios
#         on different pods can be combined. Revert recreates the pod.
# config: SC_JQ stays in the template while the scenario is active. Pods are
#         not recreated: the finding reads the template.
# ---------------------------------------------------------------------------
pg_sc_file() { printf '%s/%s.sh' "$PG_SCENARIOS" "$1"; }
pg_sc_exists() { [ -f "$(pg_sc_file "$1")" ]; }
pg_sc_names() { for f in "$PG_SCENARIOS"/*.sh; do basename "$f" .sh; done; }

# pg_sc_var <name> <VAR>: a variable of a scenario, without polluting this shell.
pg_sc_var() {
  ( SC_DESC=""; SC_KIND=""; SC_POD=""; SC_JQ=""; SC_EXPECT=""; SC_ABSENT=""; SC_NO_HIGH=""; SC_COLLECT_ARGS=""
    . "$(pg_sc_file "$1")"; eval "printf '%s' \"\${$2}\"" )
}

pg_active() { [ -f "$PG_STATE/active" ] && cat "$PG_STATE/active"; return 0; }
pg_is_active() { pg_active | grep -qx "$1"; }
pg_set_active() { pg_is_active "$1" || printf '%s\n' "$1" >> "$PG_STATE/active"; }
pg_unset_active() {
  [ -f "$PG_STATE/active" ] || return 0
  grep -vx "$1" "$PG_STATE/active" > "$PG_STATE/active.new"; mv "$PG_STATE/active.new" "$PG_STATE/active"
}

# pg_template [extra-jq]: StatefulSet template = base + active config
# scenarios + extra. Only env and resources of the Weaviate container change.
pg_template() {
  local prog="." n idx patch
  for n in $(pg_active); do
    [ "$(pg_sc_var "$n" SC_KIND)" = config ] && prog="$prog | $(pg_sc_var "$n" SC_JQ)"
  done
  [ -n "${1:-}" ] && prog="$prog | $1"
  jq "$prog" "$PG_STATE/base-container.json" > "$PG_STATE/container.json" || return 1
  idx=$(kn get statefulset "$PG_STS" -o json | jq '.spec.template.spec.containers | map(.name) | index("weaviate")')
  patch=$(jq -c --argjson i "$idx" '[
      {op: "replace", path: "/spec/template/spec/containers/\($i)/env", value: .env},
      {op: "replace", path: "/spec/template/spec/containers/\($i)/resources", value: .resources}]' "$PG_STATE/container.json")
  kn patch statefulset "$PG_STS" --type json -p "$patch" > /dev/null
}

pg_scenario_apply() {
  local name="$1" kind pod other
  pg_sc_exists "$name" || pg_die "no scenario '$name' (see: playground.sh list)"
  pg_is_active "$name" && { pg_say "$name is already active"; return 0; }
  kind=$(pg_sc_var "$name" SC_KIND)
  pg_step "Scenario $name: $(pg_sc_var "$name" SC_DESC)"
  case "$kind" in
    pod)
      pod=$(pg_sc_var "$name" SC_POD)
      for other in $(pg_active); do
        [ "$(pg_sc_var "$other" SC_KIND)" = pod ] && [ "$(pg_sc_var "$other" SC_POD)" = "$pod" ] \
          && pg_die "$other already breaks $pod; revert it first"
      done
      pg_template "$(pg_sc_var "$name" SC_JQ)" || return 1
      kn delete pod "$pod" --wait=false > /dev/null
      ( . "$(pg_sc_file "$name")"; if type sc_wait > /dev/null 2>&1; then sc_wait; fi ) \
        || pg_say "warning: $name did not reach its broken state in time"
      pg_template ;;
    config)
      pg_set_active "$name"
      pg_template || { pg_unset_active "$name"; return 1; }
      return 0 ;;
    custom)
      ( . "$(pg_sc_file "$name")"; sc_apply ) || { pg_say "$name: apply failed"; return 1; } ;;
    *) pg_die "scenario $name has an unknown SC_KIND '$kind'" ;;
  esac
  pg_set_active "$name"
}

pg_scenario_revert() {
  local name="$1" kind pod
  pg_is_active "$name" || { pg_say "$name is not active"; return 0; }
  kind=$(pg_sc_var "$name" SC_KIND)
  pg_step "Revert $name"
  pg_unset_active "$name"
  case "$kind" in
    pod)
      pod=$(pg_sc_var "$name" SC_POD)
      pg_template || return 1
      kn delete pod "$pod" --wait=false > /dev/null
      sleep 2
      pg_pod_ready "$pod" 600 ;;
    config) pg_template ;;
    custom) ( . "$(pg_sc_file "$name")"; sc_revert ) ;;
  esac
}

# ---------------------------------------------------------------------------
# Collect and check
# ---------------------------------------------------------------------------

# pg_collect <out-dir> [collect.sh args]: run collect.sh with the viewer key.
# Prints the bundle folder on stdout.
pg_collect() {
  local out="$1"; shift
  mkdir -p "$out"
  WEAVIATE_API_KEY="$(cat "$PG_STATE/reader.key")" "$PG_REPO/collect.sh" --context "$PG_CTX" --yes \
    -o "$out" "$@" > "$out/collect.out" 2>&1
  local rc=$?
  ls -d "$out"/weaviate-support-bundle-*/ 2> /dev/null | head -n 1 | sed 's:/$::'
  return "$rc"
}

pg_has_code() { jq -e --arg c "$2" 'any(.[]; .code == $c)' "$1/findings.json" > /dev/null; }

# pg_oom_flagged <bundle> <pod>: POD_OOMKILLED, or a restart with exit code 137
# (the container runtime reports a memory kill either way).
pg_oom_flagged() {
  pg_has_code "$1" POD_OOMKILLED \
    || jq -e --arg p "$2" 'any(.[]; .code == "POD_RESTARTS" and (.title | startswith($p + "/")) and (.detail | contains("code 137")))' "$1/findings.json" > /dev/null
}

# pg_scenario_check <name> <bundle>: the scenario's expectations. Prints one
# ok:/FAIL: line per check; returns non-zero if any failed.
pg_scenario_check() {
  ( name="$1" b="$2"
    SC_EXPECT=""; SC_ABSENT=""; SC_NO_HIGH=""
    . "$(pg_sc_file "$name")"
    rc=0
    for c in $SC_EXPECT; do
      if pg_has_code "$b" "$c"; then echo "ok: $name: flagged $c"; else echo "FAIL: $name: did not flag $c"; rc=1; fi
    done
    for c in $SC_ABSENT; do
      if pg_has_code "$b" "$c"; then echo "FAIL: $name: false alarm $c"; rc=1; else echo "ok: $name: no $c"; fi
    done
    if [ "$SC_NO_HIGH" = 1 ]; then
      high=$(jq -r '[.[] | select(.severity == "high") | .code] | join(", ")' "$b/findings.json")
      if [ -z "$high" ]; then echo "ok: $name: no high red flags"; else echo "FAIL: $name: high red flags: $high"; rc=1; fi
    fi
    if type sc_check > /dev/null 2>&1; then sc_check "$b" || rc=1; fi
    exit "$rc" )
}
