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
cleanup() { kill "$SERVER" 2>/dev/null; pkill -f "$T/bin/kubectl port-forward" 2>/dev/null; rm -rf "$T"; }
trap cleanup EXIT
sleep 1

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
            SHARDS_READONLY VECTOR_QUEUE_BACKLOG REPLICATION_FACTOR_TOO_HIGH TENANTS_IN_TRANSITION BACKUP_FAILED \
            DISK_ALMOST_FULL K8S_NODE_CONDITION STATEFULSET_NOT_READY REPLICATION_OP_ERRORS K8S_WARNING_EVENTS; do
  jq -e --arg c "$code" 'any(.[]; .code == $c)' "$B/findings.json" > /dev/null && pass "flagged $code" || bad "did not flag $code"
done

jq -e 'any(.[]; .code == "WEAVIATE_VERSION_MISMATCH")' "$B/findings.json" > /dev/null \
  && bad "false alarm: version mismatch when a down node reports no version" || pass "no false version-mismatch alarm"

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
  ls "$T"/out2/*.anonymization-map.txt > /dev/null 2>&1 && pass "anonymization map kept outside the bundle" || bad "no anonymization map"
  tar -tzf "${B2%/}.tar.gz" | grep -q anonymization-map && bad "map inside archive" || pass "map not in archive"
else
  bad "anonymized run produced no bundle"; tail -20 "$T/stderr2"
fi

# Anonymized run while Weaviate cannot answer schema calls (lost quorum)
PORT2=$((PORT + 1))
python3 tests/fake/weaviate_server.py "$PORT2" "$T/http-violations" schema-down &
SERVER2=$!
sleep 1
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

# Weaviate image from a private registry (mirror), found automatically
FAKE_WEAVIATE_IMAGE="registry.example.com/mirror/weaviate:1.40.3" \
  ./collect.sh --yes --only kubernetes --output "$T/out5" > /dev/null 2> "$T/stderr5"
B5=$(ls -d "$T"/out5/weaviate-support-bundle-*/ 2>/dev/null | head -1)
[ -n "$B5" ] && jq -e '.container == "weaviate" and (.image | startswith("registry.example.com/"))' "$B5/config/env.json" > /dev/null \
  && pass "mirrored Weaviate image found automatically" || { bad "mirrored Weaviate image not found"; tail -10 "$T/stderr5"; }

# Image with another name: not guessed, but --statefulset selects it by name
FAKE_WEAVIATE_IMAGE="registry.example.com/db/vectorstore:1.40.3" \
  ./collect.sh --yes --only kubernetes --output "$T/out6" > /dev/null 2> "$T/stderr6"
[ $? -ne 0 ] && grep -q -- '--statefulset' "$T/stderr6" \
  && pass "unknown image: stops and suggests --statefulset" || bad "unknown image: no stop or no hint"
FAKE_WEAVIATE_IMAGE="registry.example.com/db/vectorstore:1.40.3" \
  ./collect.sh --yes --only kubernetes -n weaviate --statefulset weaviate --output "$T/out7" > /dev/null 2> "$T/stderr7"
B7=$(ls -d "$T"/out7/weaviate-support-bundle-*/ 2>/dev/null | head -1)
[ -n "$B7" ] && jq -e '.container == "weaviate"' "$B7/config/env.json" > /dev/null \
  && pass "--statefulset selects a StatefulSet with any image" || { bad "--statefulset with another image name"; tail -10 "$T/stderr7"; }
./collect.sh --yes --only kubernetes --container nope --output "$T/out8" > /dev/null 2> "$T/stderr8"
[ $? -ne 0 ] && grep -q "has no container 'nope'" "$T/stderr8" \
  && pass "--container with a wrong name stops" || bad "--container with a wrong name did not stop"

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

[ "$fail" = 0 ] && echo "E2E PASSED" || { echo "E2E FAILED (rerun with KEEP=/some/dir to keep the bundle)"; }
[ -n "${KEEP:-}" ] && cp -R "$B" "$KEEP" && echo "bundle copied to $KEEP"
exit "$fail"
