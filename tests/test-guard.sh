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
           "http_get http://127.0.0.1:6060/debug/config $T/out" "http_get http://h:8080/debug/index/rebuild/vector $T/out" \
           "http_get file:///etc/passwd $T/out"; do
  rc=$(run_guarded "$cmd")
  if [ "$rc" = "99" ] && [ ! -s "$CALLS" ]; then pass "blocked: $cmd"; else bad "not blocked (rc=$rc): $cmd"; fi
done

for cmd in "kc get pods -n x -o json" "kc logs -n x weaviate-0 --tail=1" "kc version -o json" \
           "kc config current-context" "kc_raw_get /api/v1/nodes/node-1/proxy/stats/summary"; do
  rc=$(run_guarded "$cmd")
  if [ "$rc" = "0" ] && grep -q '^kubectl ' "$CALLS"; then pass "allowed: $cmd"; else bad "should be allowed (rc=$rc): $cmd"; fi
done

# HTTP: GET only, API key never on the command line.
rc=$(run_guarded "WEAVIATE_API_KEY=test-key-1234567 http_get http://127.0.0.1:8080/v1/meta $T/out")
if grep -q -- '--request GET' "$CALLS" && ! grep -q 'test-key-1234567' "$CALLS" && grep -q 'test-key-1234567' "$CALLS.stdin"; then
  pass "http_get uses GET and passes the API key via stdin only"
else
  bad "http_get must use GET and keep the API key off the command line"
fi

exit "$fail"
