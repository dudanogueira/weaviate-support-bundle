# shellcheck shell=bash disable=SC2034
# weaviate-1 gets a memory limit far below what Weaviate needs: OOM killed.
SC_DESC="weaviate-1 memory limit 40Mi -> OOMKilled"
SC_KIND=pod
SC_POD=weaviate-1
SC_JQ='.resources.limits.memory = "40Mi" | .resources.requests.memory = "40Mi"'
SC_EXPECT="STATEFULSET_NOT_READY"
sc_wait() {
  _oom() { [ "$(kn get pod weaviate-1 -o jsonpath='{.status.containerStatuses[0].lastState.terminated.reason}' 2> /dev/null)" = OOMKilled ]; }
  pg_wait 180 _oom
}
sc_check() {
  # The runtime reports a memory kill as OOMKilled on some restarts and as
  # Error with exit code 137 on others, so accept either.
  if pg_oom_flagged "$1" weaviate-1; then echo "ok: oom: flags the memory kill"
  else echo "FAIL: oom: did not flag the memory kill"; return 1; fi
}
