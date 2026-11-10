#!/usr/bin/env bash
#
# The read-only gate must block anything that is not a read, before kubectl
# or curl is even started. Uses fake kubectl/curl that only record their calls.

set -u
cd "$(dirname "$0")/.." || exit 1
T=$(mktemp -d "${TMPDIR:-/tmp}/wsb-guard-test.XXXXXX")
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin"
cat > "$T/bin/kubectl" <<'EOF'
#!/usr/bin/env bash
echo "kubectl $*" >> "$CALLS"
EOF
cat > "$T/bin/curl" <<'EOF'
#!/usr/bin/env bash
echo "curl $*" >> "$CALLS"
cat > "$CALLS.stdin"
printf '200'
EOF
chmod +x "$T/bin/kubectl" "$T/bin/curl"
export CALLS="$T/calls" PATH="$T/bin:$PATH"

fail=0
pass() { echo "ok: $1"; }
bad()  { echo "FAIL: $1"; fail=1; }

run_guarded() {
  # Runs a snippet with the guard loaded; prints its exit code.
  : > "$CALLS"
  ( WORK="$T"; TOOL_PID=""; . lib/common.sh; . lib/guard.sh; eval "$1" ) > /dev/null 2>&1
  echo $?
}

for cmd in "kc delete pod x" "kc apply -f x.yaml" "kc exec weaviate-0 -- ls" "kc patch sts x" \
           "kc scale sts x --replicas=0" "kc config use-context other" "kc get --raw /api/v1/namespaces/x/secrets" \
           "kc get pods --watch" "kc logs x -f" "kc_raw_get /api/v1/namespaces/x/secrets" \
           "kc_raw_get /api/v1/nodes/n/proxy/../../secrets" \
           "kc_raw_get /api/v1/nodes/a/proxy/configz/x/proxy/stats/summary" "kc_raw_get /api/v1/nodes/n/proxy/logs/proxy/healthz" \
           "kc_raw_get /apis/metrics.k8s.io/v1beta1/namespaces/a/b/pods" "kc_raw_get /api/v1/nodes/N%2F1/proxy/healthz" \
           "kc get secrets -n x" "kc get secret/helm-x -n x -o json" "kc get pods,secrets -n x" "kc get -n x Secrets.v1" \
           "http_get http://127.0.0.1:6060/debug/config $T/out" "http_get http://h:8080/debug/index/rebuild/vector $T/out" \
           "http_get file:///etc/passwd $T/out" \
           "tunnel_open weaviate-0 8080 6060" "WEAVIATE_DEBUG_PORT=7777 tunnel_open weaviate-0 8080 7777" "tunnel_open weaviate-0 ':80'" \
           "http_get http://127.0.0.1:1234/ $T/out" "http_get http://127.0.0.1:1234 $T/out" "http_get http://h:8080/admin/x $T/out" \
           "http_get http://h:8080/debug?x=1 $T/out" "http_get http://h:8080/v2/meta $T/out"; do
  rc=$(run_guarded "$cmd")
  if [ "$rc" = "99" ] && [ ! -s "$CALLS" ]; then pass "blocked: $cmd"; else bad "not blocked (rc=$rc): $cmd"; fi
done

for cmd in "kc get pods -n x -o json" "kc logs -n x weaviate-0 --tail=1" "kc version -o json" \
           "kc config current-context" "kc_raw_get /api/v1/nodes/node-1/proxy/stats/summary" \
           "kc_raw_get /apis/metrics.k8s.io/v1beta1/namespaces/weaviate/pods" "kc_raw_get /api/v1/nodes/ip-10-0-1-2.ec2.internal/proxy/healthz" \
           "INCLUDE_HELM=1 kc get secrets -n x -l owner=helm -o json" "kc get configmap secrets -n x -o json" "kc get pods -n secrets -o json"; do
  rc=$(run_guarded "$cmd")
  if [ "$rc" = "0" ] && grep -q '^kubectl ' "$CALLS"; then pass "allowed: $cmd"; else bad "should be allowed (rc=$rc): $cmd"; fi
done

# Allowed HTTP paths: the REST API (also below a base path) and metrics.
for cmd in "http_get https://h/prefix/v1/nodes?output=verbose $T/out" "http_get http://127.0.0.1:5/metrics $T/out noauth" \
           "http_get http://127.0.0.1:5/v1/.well-known/live $T/out noauth"; do
  rc=$(run_guarded "$cmd")
  if [ "$rc" = "0" ] && grep -q '^curl ' "$CALLS"; then pass "allowed: $cmd"; else bad "should be allowed (rc=$rc): $cmd"; fi
done

# Port 6060 is fine when Weaviate's debug port was moved elsewhere.
rc=$(run_guarded "NAMESPACE=x; WEAVIATE_DEBUG_PORT=7777 tunnel_open weaviate-0 8080 6060")
if [ "$rc" != "99" ] && grep -q 'port-forward' "$CALLS"; then pass "tunnel to 6060 allowed when the debug port is 7777"
else bad "tunnel to 6060 refused although the debug port is 7777 (rc=$rc)"; fi

# Profiling: the debug port stays closed without the option. With it, only the
# exact pprof GETs pass, only through a local tunnel, never with the API key.
PP="PROFILING_ALLOWED=1"
for cmd in "http_get http://127.0.0.1:5/debug/pprof/goroutine $T/out noauth" "http_get http://127.0.0.1:5/debug/pprof/heap $T/out noauth" \
           "NAMESPACE=x; tunnel_open weaviate-0 6060" \
           "$PP; http_get http://127.0.0.1:5/debug/pprof/cmdline $T/out noauth" "$PP; http_get http://127.0.0.1:5/debug/pprof/trace $T/out noauth" \
           "$PP; http_get http://127.0.0.1:5/debug/pprof/ $T/out noauth" "$PP; http_get http://127.0.0.1:5/debug/index/rebuild/vector $T/out noauth" \
           "$PP; http_get http://127.0.0.1:5/debug/pprof/heap $T/out noauth" "$PP; http_get http://127.0.0.1:5/debug/pprof/profile?seconds=1 $T/out noauth" \
           "$PP; http_get http://127.0.0.1:5/debug/pprof/profile?seconds=999 $T/out noauth" "$PP; http_get 'http://127.0.0.1:5/debug/pprof/profile?seconds=30;x' $T/out noauth" \
           "$PP; http_get http://127.0.0.1:5/debug/pprof/goroutine?debug=1 $T/out noauth" "$PP; http_get http://10.0.0.1:5/debug/pprof/goroutine $T/out noauth" \
           "$PP; http_get http://127.0.0.1.evil.example/debug/pprof/goroutine $T/out noauth"; do
  rc=$(run_guarded "$cmd")
  if [ "$rc" = "99" ] && [ ! -s "$CALLS" ]; then pass "blocked: $cmd"; else bad "not blocked (rc=$rc): $cmd"; fi
done
for cmd in "$PP; http_get http://127.0.0.1:5/debug/pprof/goroutine $T/out noauth" "$PP; http_get http://127.0.0.1:5/debug/pprof/goroutine?debug=2 $T/out noauth" \
           "$PP; http_get http://127.0.0.1:5/debug/pprof/block $T/out noauth" "$PP; http_get http://127.0.0.1:5/debug/pprof/mutex $T/out noauth" \
           "$PP; http_get http://127.0.0.1:5/debug/pprof/threadcreate $T/out noauth" "$PP; http_get http://127.0.0.1:5/debug/pprof/profile?seconds=30 $T/out noauth" \
           "$PP; INCLUDE_HEAP=1; http_get http://127.0.0.1:5/debug/pprof/heap $T/out noauth"; do
  rc=$(run_guarded "$cmd")
  if [ "$rc" = "0" ] && grep -q '^curl ' "$CALLS"; then pass "allowed: $cmd"; else bad "should be allowed (rc=$rc): $cmd"; fi
done
rm -f "$CALLS.stdin"
rc=$(run_guarded "$PP; WEAVIATE_API_KEY=test-key-1234567 http_get http://127.0.0.1:5/debug/pprof/goroutine $T/out")
if ! grep -q 'test-key-1234567' "$CALLS.stdin" 2>/dev/null; then pass "pprof requests never carry the API key"; else bad "the API key was sent to the debug port"; fi
rc=$(run_guarded "$PP; NAMESPACE=x; tunnel_open weaviate-0 6060")
if [ "$rc" != "99" ] && grep -q 'port-forward' "$CALLS"; then pass "tunnel to the debug port allowed with --include-profiling"; else bad "tunnel to the debug port refused with --include-profiling (rc=$rc)"; fi

# HTTP: GET only, API key never on the command line.
rc=$(run_guarded "WEAVIATE_API_KEY=test-key-1234567 http_get http://127.0.0.1:8080/v1/meta $T/out")
if grep -q -- '--request GET' "$CALLS" && ! grep -q 'test-key-1234567' "$CALLS" && grep -q 'test-key-1234567' "$CALLS.stdin"; then
  pass "http_get uses GET and passes the API key via stdin only"
else
  bad "http_get must use GET and keep the API key off the command line"
fi

# A key with a line break could add curl options (for example another method)
# through the curl config: it must never reach curl.
rm -f "$CALLS.stdin"
rc=$(run_guarded "WEAVIATE_API_KEY=\"\$(printf 'k1\\nrequest = POST')\" http_get http://127.0.0.1:8080/v1/meta $T/out")
if [ ! -s "$CALLS" ] && [ ! -e "$CALLS.stdin" ]; then
  pass "http_get refuses an API key with a line break (curl not run)"
else
  bad "http_get sent an API key with a line break to curl (rc=$rc)"
fi

exit "$fail"
