#!/usr/bin/env bash
#
# End-to-end run of collect.sh against a fake kubectl and a fake Weaviate API
# (tests/fake/). No cluster needed. Requires python3 (test-only dependency).
#
# Checks: the run completes, the bundle has the expected layout, planted
# problems are flagged, planted secrets never reach the bundle, nothing but
# reads was attempted, and no temporary files or tunnels are left behind.

set -u
cd "$(dirname "$0")/.." || exit 1
command -v python3 >/dev/null || { echo "skip: python3 not installed"; exit 0; }

T=$(mktemp -d "${TMPDIR:-/tmp}/wsb-e2e.XXXXXX")
PORT=$((20000 + RANDOM % 20000))
python3 tests/fake/weaviate_server.py "$PORT" "$T/http-violations" &
SERVER=$!
# wait_server <port>: a slow machine can take more than a moment to start python.
wait_server() {
  local i=0
  while [ "$i" -lt 150 ]; do
    curl -s -o /dev/null --max-time 2 "http://127.0.0.1:$1/v1/.well-known/live" && return 0
    sleep 0.2; i=$((i + 1))
  done
  echo "FAIL: the fake Weaviate on port $1 did not start"; fail=1
}
cleanup() { kill "$SERVER" 2>/dev/null; pkill -f "$T/bin/kubectl port-forward" 2>/dev/null; rm -rf "$T"; }
trap cleanup EXIT
wait_server "$PORT"

mkdir -p "$T/bin" "$T/out" "$T/tmp"
ln -s "$PWD/tests/fake/kubectl" "$T/bin/kubectl"
export PATH="$T/bin:$PATH" FAKE_CALLS="$T/kubectl-calls" FAKE_WEAVIATE_PORT="$PORT"
export WEAVIATE_API_KEY="e2e-fixture-apikey-9001" TMPDIR="$T/tmp/"

fail=0
pass() { echo "ok: $1"; }
bad()  { echo "FAIL: $1"; fail=1; }

./collect.sh --yes --include-helm --metrics-interval 5 --output "$T/out" > "$T/stdout" 2> "$T/stderr"
rc=$?
[ "$rc" -eq 0 ] && pass "collect.sh exited 0" || { bad "collect.sh exited $rc"; tail -30 "$T/stderr"; }

B=$(ls -d "$T"/out/weaviate-support-bundle-*/ 2>/dev/null | head -1)
[ -n "$B" ] && [ -f "${B%/}.tar.gz" ] && pass "bundle folder and archive created" || { bad "no bundle"; tail -30 "$T/stderr"; exit 1; }

for f in SUMMARY.md manifest.json findings.json redactions.txt run.log config/env.json \
         kubernetes/cluster.json kubernetes/statefulset.json kubernetes/pods.json kubernetes/nodes.json \
         kubernetes/storage.json kubernetes/services.json kubernetes/events.json kubernetes/configmaps.json \
         kubernetes/disk-usage.json kubernetes/top.json helm/release.json \
         weaviate/meta.json weaviate/nodes.json weaviate/raft.json weaviate/collections/Article.json \
         weaviate/collections/Tenanted.json weaviate/backups.json weaviate/replication.json \
         pods/weaviate-0/status.json pods/weaviate-0/health.json pods/weaviate-0/metrics.json \
         pods/weaviate-0/logs/weaviate.log pods/weaviate-1/logs/weaviate.previous.log \
         pods/transformers-inference-abc/logs/t2v.log; do
  [ -s "$B/$f" ] && pass "has $f" || bad "missing $f"
done

for code in POD_OOMKILLED POD_CRASHLOOP GOMEMLIMIT_ABOVE_LIMIT RAFT_NOT_SYNCED RAFT_MEMBER_COUNT NODE_NOT_HEALTHY \
            SCHEMA_MT_CANDIDATES EMPTY_SHARDS REPLICA_OBJECT_COUNT_MISMATCH SHARDS_READONLY VECTOR_QUEUE_BACKLOG REPLICATION_FACTOR_TOO_HIGH TENANTS_IN_TRANSITION BACKUP_FAILED \
            DISK_ALMOST_FULL K8S_NODE_CONDITION STATEFULSET_NOT_READY REPLICATION_OP_ERRORS K8S_WARNING_EVENTS; do
  jq -e --arg c "$code" 'any(.[]; .code == $c)' "$B/findings.json" > /dev/null && pass "flagged $code" || bad "did not flag $code"
done

jq -e 'any(.[]; .code == "WEAVIATE_VERSION_MISMATCH")' "$B/findings.json" > /dev/null \
  && bad "false alarm: version mismatch when a down node reports no version" || pass "no false version-mismatch alarm"

jq -e '.weaviate[0].annotations["prometheus.io/port"] == "2112" and .weaviate[0].annotations["backup.example.com/encryption-passphrase"] == "[REDACTED]"' "$B/kubernetes/pods.json" > /dev/null \
  && pass "pod annotations: secret one masked, plain one kept" || bad "pod annotations not redacted as expected"
grep -q 'annotation backup.example.com/encryption-passphrase' "$B/redactions.txt" \
  && pass "redactions.txt lists the masked annotation" || bad "redactions.txt does not list the masked annotation"

leaks=$(grep -rhoE 'e2e-fixture-[a-z]+-[0-9]{4}|sk-e2efixture[a-z0-9]+|abcdefghijkl123456' "$B" | sort -u)
[ -z "$leaks" ] && pass "no planted secret in the bundle" || bad "secrets leaked: $leaks"
tar -xzOf "${B%/}.tar.gz" | grep -qE 'e2e-fixture-[a-z]+-[0-9]{4}' && bad "secret in archive" || pass "no planted secret in the archive"

grep -q 'shop-app\|other-app\|postgres' -r "$B" && bad "data from non-Weaviate workloads in bundle" || pass "only Weaviate workloads collected"
[ ! -s "$T/kubectl-calls.violations" ] && pass "no kubectl write attempted" || bad "kubectl write attempted: $(cat "$T/kubectl-calls.violations")"
[ ! -s "$T/http-violations" ] && pass "only HTTP GET used" || bad "non-GET HTTP: $(cat "$T/http-violations")"
[ -z "$(ls -A "$T/tmp" 2>/dev/null)" ] && pass "temporary folder removed" || bad "temp files left: $(ls "$T/tmp")"
sleep 0.5
pgrep -f "$T/bin/kubectl port-forward" > /dev/null && bad "port-forward still running" || pass "all port-forwards closed"

jq -e '.schema_version == "1" and (.files | length) > 10 and (.steps | length) > 10' "$B/manifest.json" > /dev/null \
  && pass "manifest has schema version, steps and files" || bad "manifest incomplete"
jq -e 'any(.steps[]; .name == "network policies" and .status == "forbidden")' "$B/manifest.json" > /dev/null && pass "forbidden step recorded in manifest" || bad "forbidden step not recorded"

# Anonymized run
./collect.sh --yes --anonymize --only weaviate,logs --metrics-interval 5 --output "$T/out2" > /dev/null 2> "$T/stderr2"
B2=$(ls -d "$T"/out2/weaviate-support-bundle-*/ 2>/dev/null | head -1)
if [ -n "$B2" ]; then
  grep -rqE 'TenantAlpha|TenantGamma|TenantDelta|alice@example.com|bob@example.com' "$B2" && bad "--anonymize left names: $(grep -rlE 'TenantAlpha|TenantGamma|TenantDelta|alice@example.com|bob@example.com' "$B2")" || pass "--anonymize removed tenant and user names"
  leaks2=$(grep -rhoE 'e2e-fixture-(apikey|modtoken)-[0-9]{4}' "$B2" | sort -u)
  [ -z "$leaks2" ] && pass "--only weaviate,logs: no planted secret (module pod env included)" || bad "--only weaviate,logs leaked: $leaks2"
  jq -e '.nodes[0] | has("name") and has("status")' "$B2/weaviate/nodes.json" > /dev/null \
    && pass "--anonymize keeps JSON keys (a tenant is named \"name\")" || bad "--anonymize rewrote JSON keys"
  bad_json=$(find "$B2" -name '*.json' -type f -exec sh -c 'jq empty "$1" 2>/dev/null || echo "$1"' _ {} \;)
  [ -z "$bad_json" ] && pass "--anonymize: every JSON file is valid" || bad "--anonymize broke: $bad_json"
  grep -rq 'file removed: it could not be safely redacted' "$B2" && bad "--anonymize replaced a file with an error note" || pass "--anonymize replaced no file with an error note"
  .agents/skills/weaviate-support-bundle/scripts/read-bundle.sh "$B2" | grep -q '^Collected' && pass "read-bundle.sh reads an anonymized bundle" || bad "read-bundle.sh cannot read the anonymized bundle"
  grep -q '^Not anonymized: collection names' "$B2/redactions.txt" && pass "redactions.txt says what is not anonymized" || bad "redactions.txt does not say what is not anonymized"
  grep -rq 'e2e-fixture-cmkey-9006' "$B2" && bad "--only weaviate,logs: a config map secret leaked" || pass "--only weaviate,logs: config map secrets are scrubbed"
  ls "$T"/out2/*.anonymization-map.txt > /dev/null 2>&1 && pass "anonymization map kept outside the bundle" || bad "no anonymization map"
  tar -tzf "${B2%/}.tar.gz" | grep -q anonymization-map && bad "map inside archive" || pass "map not in archive"
else
  bad "anonymized run produced no bundle"; tail -20 "$T/stderr2"
fi

# Anonymized run while Weaviate cannot answer schema calls (lost quorum)
PORT2=$((PORT + 1))
python3 tests/fake/weaviate_server.py "$PORT2" "$T/http-violations" schema-down &
SERVER2=$!
wait_server "$PORT2"
FAKE_WEAVIATE_PORT="$PORT2" ./collect.sh --yes --anonymize --only weaviate,logs --metrics-interval 5 --output "$T/out3" > /dev/null 2> "$T/stderr3"
kill "$SERVER2" 2>/dev/null
B3=$(ls -d "$T"/out3/weaviate-support-bundle-*/ 2>/dev/null | head -1)
if [ -n "$B3" ]; then
  grep -rqE 'TenantAlpha|TenantBeta|TenantDelta|alice@example.com|bob@example.com' "$B3" \
    && bad "--anonymize during an outage left names: $(grep -rlE 'TenantAlpha|TenantBeta|TenantDelta|alice@example.com|bob@example.com' "$B3")" \
    || pass "--anonymize works when Weaviate cannot list tenants"
  grep -q '^Warning:' "$B3/redactions.txt" && pass "redactions.txt warns that the tenant list was unavailable" \
    || bad "no warning about the missing tenant list"
else
  bad "outage run produced no bundle"; tail -20 "$T/stderr3"
fi

# The skill's reader on the real bundle, as archive and as folder
READ=.agents/skills/weaviate-support-bundle/scripts/read-bundle.sh
for src in "${B%/}.tar.gz" "${B%/}"; do
  "$READ" "$src" | grep -q 'POD_OOMKILLED' && pass "read-bundle.sh overview of $(basename "$src")" \
    || bad "read-bundle.sh overview of $(basename "$src")"
done

# Preflight only: shows the table, then stops without collecting
./collect.sh --preflight-only --output "$T/out4" > /dev/null 2> "$T/stderr4"
rc=$?
[ "$rc" -eq 0 ] && grep -q 'Preflight only: nothing was collected' "$T/stderr4" && grep -q 'preflight' "$T/stderr4" \
  && pass "--preflight-only shows the preflight and stops" || { bad "--preflight-only (exit $rc)"; tail -10 "$T/stderr4"; }
[ -z "$(ls -A "$T/out4" 2>/dev/null)" ] && pass "--preflight-only writes no bundle" || bad "--preflight-only wrote: $(ls "$T/out4")"
grep -q "Terminated" "$T/stderr4" && bad "--preflight-only prints a job message: $(grep Terminated "$T/stderr4")" || pass "--preflight-only output is clean"
[ -z "$(ls -A "$T/tmp" 2>/dev/null)" ] && pass "--preflight-only leaves no temporary files" || bad "temp files left: $(ls "$T/tmp")"
sleep 0.5
pgrep -f "$T/bin/kubectl port-forward" > /dev/null && bad "--preflight-only left a port-forward" || pass "--preflight-only closes its port-forward"

# --context: the preflight names that context (not kubectl's current context),
# and every kubectl call gets it as one argument, even with spaces in the name.
rm -f "$FAKE_CALLS.contexts"
./collect.sh --preflight-only --context "e2e other ctx" --output "$T/out5" > /dev/null 2> "$T/stderr5"
grep -q 'Kube context *e2e other ctx ' "$T/stderr5" && ! grep -q 'e2e-fake-context' "$T/stderr5" \
  && pass "--context: preflight shows the chosen context" || { bad "--context: preflight shows the wrong context"; grep 'Kube context' "$T/stderr5"; }
[ -s "$FAKE_CALLS.contexts" ] && [ -z "$(grep -vx -- '--context=e2e other ctx' "$FAKE_CALLS.contexts")" ] \
  && pass "--context: every kubectl call targets the chosen context" || bad "--context not passed intact: $(sort -u "$FAKE_CALLS.contexts" 2>/dev/null)"
sleep 0.5
pgrep -f "$T/bin/kubectl --context=e2e other ctx port-forward" > /dev/null && bad "--context run left a port-forward" || pass "--context run closes its port-forward"
# An API key with a line break: stop at once, with a clear message.
WEAVIATE_API_KEY="$(printf 'k1\nrequest = POST')" ./collect.sh --preflight-only --output "$T/out6" > /dev/null 2> "$T/stderr6"
rc=$?
[ "$rc" -eq 1 ] && grep -q 'WEAVIATE_API_KEY contains a line break' "$T/stderr6" \
  && pass "a key with a line break stops the run with a clear message" || { bad "key with a line break (exit $rc)"; tail -3 "$T/stderr6"; }
# --weaviate-url over plain http to another machine: warn before the key is sent.
./collect.sh --preflight-only --weaviate-url http://example.invalid:8080 --output "$T/out7" > /dev/null 2> "$T/stderr7"
grep -q 'uses http:// to another machine: the API key is sent unencrypted' "$T/stderr7" \
  && pass "http:// to a remote host: warns that the key is sent unencrypted" || { bad "no cleartext warning"; tail -5 "$T/stderr7"; }
./collect.sh --preflight-only --weaviate-url "http://127.0.0.1:$PORT" --output "$T/out8" > /dev/null 2> "$T/stderr8"
grep -q 'unencrypted' "$T/stderr8" && bad "false cleartext warning for 127.0.0.1" || pass "no cleartext warning for a local address"
for u in http://localhost:8080 http://127.0.0.1 "http://[::1]:8080/x" https://weaviate.example.com; do
  ( . lib/common.sh; . lib/discover.sh; url_is_cleartext_remote "$u" ) && bad "$u counted as remote http" || pass "$u is not remote http"
done
for u in http://weaviate.example.com http://10.0.0.5:8080 "http://[2001:db8::1]:8080" http://user:pw@10.1.1.1/; do
  ( . lib/common.sh; . lib/discover.sh; url_is_cleartext_remote "$u" ) && pass "$u is remote http" || bad "$u not counted as remote http"
done
# A log over --max-log-mb keeps its newest lines, not its oldest.
FAKE_BIG_LOG=1 ./collect.sh --yes --only logs --pods weaviate-0 --max-log-mb 1 --output "$T/out9" > /dev/null 2> "$T/stderr9"
B9=$(ls -d "$T"/out9/weaviate-support-bundle-*/ 2>/dev/null | head -1)
L9="$B9/pods/weaviate-0/logs/weaviate.log"
grep -q 'seq 029999' "$L9" && pass "big log: the newest line is kept" || bad "big log: the newest line was cut"
grep -q 'seq 000000' "$L9" && bad "big log: the oldest line was kept" || pass "big log: the oldest lines are cut"
head -n 1 "$L9" | grep -q '^{"msg":"seq ' && pass "big log: starts with a complete line" || bad "big log: first line is cut: $(head -c 80 "$L9")"
[ "$(wc -c < "$L9" | tr -d ' ')" -le 1048576 ] && pass "big log: within the size cap" || bad "big log: over the size cap"
jq -e '.logs[] | select(.pod == "weaviate-0" and .kind == "current") | .truncated == true and .kept == "newest"' "$B9/manifest.json" > /dev/null \
  && pass "big log: manifest says truncated, newest kept" || bad "big log: manifest does not say it was cut"

# --to is applied before the cut: the window keeps its own newest lines.
FAKE_BIG_LOG=1 ./collect.sh --yes --only logs --pods weaviate-0 --max-log-mb 1 --from 2026-11-05T00:00 --to 2026-11-05T02:00 --output "$T/out10" > /dev/null 2> "$T/stderr10"
B10=$(ls -d "$T"/out10/weaviate-support-bundle-*/ 2>/dev/null | head -1)
L10="$B10/pods/weaviate-0/logs/weaviate.log"
grep -q 'seq 007199' "$L10" && ! grep -q 'seq 007201' "$L10" \
  && pass "big log with --to: keeps the end of the window, nothing after it" || bad "big log with --to: wrong lines ($(tail -n 1 "$L10" 2>/dev/null | cut -c1-60))"

# kubectl fails partway through a log: keep what arrived, and say so.
FAKE_LOG_FAIL=1 ./collect.sh --yes --only logs --pods weaviate-1 --output "$T/out11" > /dev/null 2> "$T/stderr11"
B11=$(ls -d "$T"/out11/weaviate-support-bundle-*/ 2>/dev/null | head -1)
grep -q 'partial line two' "$B11/pods/weaviate-1/logs/weaviate.log" 2>/dev/null \
  && pass "a log that fails partway keeps what arrived" || bad "a log that failed partway was thrown away"
jq -e '.logs[] | select(.pod == "weaviate-1" and .kind == "current") | .partial == true' "$B11/manifest.json" > /dev/null \
  && pass "manifest marks the log as partial" || bad "manifest does not mark the log as partial"
# Repeated API failures: stop calling, keep what is known, report the rest.
PORT3=$((PORT + 2))
python3 tests/fake/weaviate_server.py "$PORT3" "$T/http-violations3" api-failing &
SERVER3=$!
wait_server "$PORT3"
FAKE_WEAVIATE_PORT="$PORT3" ./collect.sh --yes --only weaviate --metrics-interval 5 --output "$T/out12" > /dev/null 2> "$T/stderr12"
kill "$SERVER3" 2>/dev/null
B12=$(ls -d "$T"/out12/weaviate-support-bundle-*/ 2>/dev/null | head -1)
grep -q '/shards' "$T/http-violations3.calls" && ! grep -qE '/v1/tasks|/v1/authz/roles|/v1/users/own-info' "$T/http-violations3.calls" \
  && pass "API failures: calls stop after 3 failures in a row" || { bad "API failures: calls did not stop: $(tr '\n' ' ' < "$T/http-violations3.calls" 2>/dev/null)"; tail -25 "$T/stderr12"; }
jq -e 'any(.steps[]; .name == "roles" and .status == "unavailable" and (.detail | test("skipped after 3")))' "$B12/manifest.json" > /dev/null \
  && pass "API failures: skipped steps are reported" || bad "API failures: skipped steps not reported"
jq -e '.config.class == "Article" and (.shards.error | test("500"))' "$B12/weaviate/collections/Article.json" > /dev/null \
  && pass "API failures: collection config is still saved" || bad "API failures: collection config lost"

# The time budget: no call once it is used up.
rc=$( ( T2="$T/budget"; mkdir -p "$T2/bin"; printf '#!/usr/bin/env bash\ntouch "%s/curl-ran"; printf 200\n' "$T2" > "$T2/bin/curl"; chmod +x "$T2/bin/curl"
        PATH="$T2/bin:$PATH"; WORK="$T2"; RAW="$T2"; STAGE="$T2"; WEAVIATE_BASE=http://127.0.0.1:1
        . lib/common.sh; . lib/guard.sh; . lib/weaviate.sh; API_DEADLINE=1; wget_json /v1/meta "$T2/x"; echo $? ) )
[ "$rc" = 13 ] && [ ! -e "$T/budget/curl-ran" ] && pass "time budget: no API call once it is used up" || bad "time budget not honoured (rc=$rc)"

# The first pod cannot be reached: the API goes through the next one.
for mode in FAKE_PF_FAIL FAKE_PF_DEAD; do
  env "$mode=weaviate-0" ./collect.sh --preflight-only --output "$T/out13" > /dev/null 2> "$T/stderr13"
  grep -q 'port-forward to weaviate-1 ' "$T/stderr13" && grep -q 'Weaviate API *.* connected' "$T/stderr13" \
    && pass "$mode: the API goes through the next pod" || { bad "$mode: no failover"; grep -E 'Connect via|Weaviate API' "$T/stderr13"; }
done

# A lost connection is retried once, after reconnecting; a timeout is not.
retry_check() {  # retry_check <curl exit code of the first try>: prints "<calls> <reconnects> <status>"
  ( T2="$T/retry-$1"; mkdir -p "$T2"; WORK="$T2"; RAW="$T2"; STAGE="$T2"; WEAVIATE_BASE=http://127.0.0.1:1; FIRST_RC="$1"
    . lib/common.sh; . lib/guard.sh; . lib/weaviate.sh
    : > "$T2/calls"; : > "$T2/reconnects"
    http_get() { echo x >> "$T2/calls"
      if [ "$(wc -l < "$T2/calls")" -eq 1 ]; then printf 000; return "$FIRST_RC"; fi
      printf '{}' > "$2"; printf 200; }
    api_reconnect() { echo x >> "$T2/reconnects"; return 0; }
    wget_json /v1/meta "$T2/x"; rc=$?
    echo "$(wc -l < "$T2/calls" | tr -d ' ') $(wc -l < "$T2/reconnects" | tr -d ' ') $rc" )
}
[ "$(retry_check 7)" = "2 1 0" ] && pass "a lost connection is retried after reconnecting" || bad "lost connection: $(retry_check 7)"
[ "$(retry_check 28)" = "1 0 1" ] && pass "a timeout is not retried" || bad "timeout: $(retry_check 28)"
# Without --include-profiling, no request goes near the debug port.
[ ! -e "$T/http-violations.debug" ] && pass "no /debug request without --include-profiling" || bad "/debug requested without the option: $(cat "$T/http-violations.debug")"
grep -q ':6060' "$FAKE_CALLS" && bad "tunnel to the debug port without the option" || pass "no tunnel to the debug port without the option"

# --include-profiling: profiles per pod, the sensitive one only on request.
./collect.sh --yes --include-profiling --profile-seconds 5 --only weaviate --metrics-interval 5 --output "$T/out14" > /dev/null 2> "$T/stderr14"
rc=$?
B14=$(ls -d "$T"/out14/weaviate-support-bundle-*/ 2>/dev/null | head -1)
[ "$rc" -eq 0 ] && [ -n "$B14" ] && pass "--include-profiling: run finished" || { bad "--include-profiling (exit $rc)"; tail -10 "$T/stderr14"; }
for p in weaviate-0 weaviate-2; do
  for f in cpu.pprof goroutine.pprof goroutine.txt mutex.pprof threadcreate.pprof; do
    [ -s "$B14/pods/$p/profiles/$f" ] && pass "has $p/profiles/$f" || bad "missing $p/profiles/$f"
  done
done
[ ! -e "$B14/pods/weaviate-0/profiles/heap.pprof" ] && pass "no heap profile without --include-heap" || bad "heap profile without --include-heap"
[ ! -e "$B14/pods/weaviate-0/profiles/block.pprof" ] && pass "an empty profile is not saved" || bad "an empty profile was saved"
gzip -t "$B14/pods/weaviate-0/profiles/cpu.pprof" 2>/dev/null && pass "binary profiles are left untouched by the scrub" || bad "binary profile was changed"
grep -q 'e2e-fixture-apikey' "$B14/pods/weaviate-0/profiles/goroutine.txt" && bad "goroutine.txt not scrubbed" || pass "goroutine.txt is scrubbed"
grep -q 'Not redacted (binary profiles' "$B14/redactions.txt" && grep -q 'pods/weaviate-0/profiles/cpu.pprof' "$B14/redactions.txt" \
  && pass "redactions.txt lists the binary profiles" || bad "redactions.txt does not list the binary profiles"
jq -e '[.profiles[] | select(.pod == "weaviate-0")] | length == 5 and (map(select(.profile == "cpu"))[0].seconds == 5)' "$B14/manifest.json" > /dev/null \
  && pass "manifest lists the profiles" || bad "manifest does not list the profiles"
grep -q '^## Profiles' "$B14/SUMMARY.md" && pass "SUMMARY.md lists the profiles" || bad "SUMMARY.md has no Profiles section"
[ ! -s "$T/http-violations" ] && pass "only allow-listed /debug paths, without the API key" || bad "debug violations: $(cat "$T/http-violations")"
READ14=.agents/skills/weaviate-support-bundle/scripts/read-bundle.sh
"$READ14" "$B14" --show pods/weaviate-0/profiles/cpu.pprof 2>&1 | grep -q 'binary profile' && pass "read-bundle.sh refuses a binary profile" || bad "read-bundle.sh showed a binary profile"

./collect.sh --yes --include-profiling --include-heap --profile-seconds 5 --only weaviate --pods weaviate-0 --metrics-interval 5 --output "$T/out15" > /dev/null 2> "$T/stderr15"
B15=$(ls -d "$T"/out15/weaviate-support-bundle-*/ 2>/dev/null | head -1)
[ -s "$B15/pods/weaviate-0/profiles/heap.pprof" ] && pass "--include-heap adds the heap profile" || bad "--include-heap: no heap profile"

./collect.sh --include-heap --preflight-only --output "$T/out16" > /dev/null 2> "$T/stderr16"
[ $? -eq 1 ] && grep -q 'needs --include-profiling' "$T/stderr16" && pass "--include-heap alone is refused" || bad "--include-heap alone was accepted"
./collect.sh --include-profiling --profile-seconds 500 --preflight-only --output "$T/out16" > /dev/null 2> "$T/stderr16"
[ $? -eq 1 ] && grep -q 'between 5 and 120' "$T/stderr16" && pass "--profile-seconds out of range is refused" || bad "--profile-seconds 500 was accepted"

# Debug endpoints off in Weaviate: say so, skip, and finish the run.
PORT4=$((PORT + 3))
python3 tests/fake/weaviate_server.py "$PORT4" "$T/http-violations4" debug-off &
SERVER4=$!
wait_server "$PORT4"
FAKE_WEAVIATE_PORT="$PORT4" ./collect.sh --yes --include-profiling --profile-seconds 5 --only weaviate --metrics-interval 5 --output "$T/out17" > /dev/null 2> "$T/stderr17"
rc=$?
kill "$SERVER4" 2>/dev/null
B17=$(ls -d "$T"/out17/weaviate-support-bundle-*/ 2>/dev/null | head -1)
grep -q 'debug endpoints are off in Weaviate' "$T/stderr17" && pass "preflight says the debug endpoints are off" || bad "preflight does not say the debug endpoints are off"
[ "$rc" -eq 0 ] && jq -e 'any(.steps[]; .name == "profiles" and .status == "skipped")' "$B17/manifest.json" > /dev/null \
  && pass "debug endpoints off: profiles skipped, run finished" || bad "debug endpoints off: exit $rc"

[ "$fail" = 0 ] && echo "E2E PASSED" || { echo "E2E FAILED (rerun with KEEP=/some/dir to keep the bundle)"; }
[ -n "${KEEP:-}" ] && cp -R "$B" "$KEEP" && echo "bundle copied to $KEEP"
exit "$fail"
