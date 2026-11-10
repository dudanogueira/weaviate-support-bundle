# shellcheck shell=bash disable=SC2034
# weaviate-2 gets an invalid setting: it exits at startup, again and again.
SC_DESC="weaviate-2 invalid QUERY_DEFAULTS_LIMIT -> crash loop"
SC_KIND=pod
SC_POD=weaviate-2
SC_JQ='.env += [{"name": "QUERY_DEFAULTS_LIMIT", "value": "not-a-number"}]'
SC_EXPECT="STATEFULSET_NOT_READY"
sc_wait() {
  _restarts() { [ "$(kn get pod weaviate-2 -o jsonpath='{.status.containerStatuses[0].restartCount}' 2> /dev/null || echo 0)" -ge 2 ]; }
  pg_wait 180 _restarts
}
sc_check() {
  local rc=0
  # CrashLoopBackOff or plain restarts, depending on timing.
  if pg_has_code "$1" POD_CRASHLOOP || pg_has_code "$1" POD_RESTARTS; then echo "ok: crashloop: flags the crashing pod"
  else echo "FAIL: crashloop: did not flag the crashing pod"; rc=1; fi
  if grep -q 'QUERY_DEFAULTS_LIMIT' "$1/pods/weaviate-2/logs/weaviate.previous.log" 2> /dev/null; then
    echo "ok: crashloop: crash reason visible in the previous log"
  else echo "FAIL: crashloop: crash reason not in the previous log"; rc=1; fi
  return "$rc"
}
