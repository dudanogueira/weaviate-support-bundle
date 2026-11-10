# shellcheck shell=bash disable=SC2034
# Debug endpoints on, then a run with --include-profiling.
SC_DESC="DEBUG_ENDPOINTS_ENABLED=true, collect with --include-profiling"
SC_KIND=custom
SC_COLLECT_ARGS="--include-profiling --profile-seconds 5"
_restart_all() {
  local p
  for p in weaviate-0 weaviate-1 weaviate-2; do
    kn delete pod "$p" --wait=true > /dev/null || return 1
    sleep 2
    pg_pod_ready "$p" 600 || return 1
  done
}
sc_apply() { kn set env "statefulset/$PG_STS" DEBUG_ENDPOINTS_ENABLED=true > /dev/null && _restart_all; }
sc_revert() { kn set env "statefulset/$PG_STS" DEBUG_ENDPOINTS_ENABLED- > /dev/null && _restart_all; }
sc_check() {
  local rc=0 f
  for f in cpu.pprof goroutine.pprof goroutine.txt threadcreate.pprof; do
    if [ -s "$1/pods/weaviate-0/profiles/$f" ]; then echo "ok: profiling: has $f"; else echo "FAIL: profiling: missing $f"; rc=1; fi
  done
  if gzip -t "$1/pods/weaviate-0/profiles/cpu.pprof" 2> /dev/null; then echo "ok: profiling: cpu.pprof is gzip"; else echo "FAIL: profiling: cpu.pprof is not gzip"; rc=1; fi
  return "$rc"
}
