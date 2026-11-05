# shellcheck shell=bash
# lib/metrics.sh: per-pod health checks and metrics (sections "weaviate" and
# "metrics").
#
# Opens one temporary port-forward per Weaviate pod, then:
#   pods/<pod>/health.json    /v1/.well-known/live and /ready status codes
#   pods/<pod>/metrics.json   key metrics, two snapshots METRICS_INTERVAL apart
# All tunnels are closed afterwards (and on exit, by the cleanup trap).

# Metrics support looks at; everything else is dropped. Names are matched
# after removing the optional custom metrics prefix.
METRICS_KEEP='^(go_memstats_heap_inuse_bytes|go_memstats_heap_alloc_bytes|go_memstats_sys_bytes|go_goroutines|go_gc_duration_seconds_(sum|count)|process_resident_memory_bytes|process_cpu_seconds_total|process_open_fds|object_count|weaviate_shards|shards_(loaded|loading|unloaded|unloading)|vector_index_size|vector_index_tombstones|vector_index_queue_(insert|delete)_count|queue_(size|disk_usage|paused|count)|async_operations_running|concurrent_queries_count|concurrent_goroutines|requests_total|(queries|batch|objects|batch_delete)_durations_ms_(sum|count)|lsm_(segment_count|segment_size|active_segments|memtable_size)|startup_progress|weaviate_startup_shards_(loaded|to_load)|weaviate_vector_index_memory_allocation_rejected_total|weaviate_module_(requests_total|error_total|call_error_total)|schema_leader_query_failures_total|http_requests_inflight|grpc_server_requests_inflight)$'

# Custom metric prefix, if the cluster sets one (env PROMETHEUS_*NAMESPACE).
metrics_prefix() {
  jq -r --arg c "$WEAVIATE_CONTAINER" \
    '[.spec.template.spec.containers[] | select(.name == $c) | .env[]? | select((.name | test("^PROMETHEUS.*NAMESPACE$")) and (.value // "") != "") | .value][0] // empty' \
    "$RAW/statefulset.json" 2>/dev/null
}

# Raw /metrics text -> "name<TAB>labels<TAB>value" for kept metrics only.
filter_metrics() {
  awk -v keep="$METRICS_KEEP" -v prefix="$(metrics_prefix)" '
    /^#/ || NF == 0 { next }
    {
      line = $0; b = index(line, "{"); sp = index(line, " ")
      if (b > 0 && b < sp) {
        name = substr(line, 1, b - 1); e = index(line, "} ")
        if (e == 0) next
        labels = substr(line, b + 1, e - b - 1); rest = substr(line, e + 2)
      } else {
        name = substr(line, 1, sp - 1); labels = ""; rest = substr(line, sp + 1)
      }
      if (prefix != "" && index(name, prefix "_") == 1) name = substr(name, length(prefix) + 2)
      if (name !~ keep) next
      split(rest, parts, " ")
      print name "\t" labels "\t" parts[1]
    }' "$1"
}

collect_pod_probes() {
  local want_metrics=0 want_health=0
  section_enabled metrics && [ "$METRICS_ENABLED" = "true" ] && want_metrics=1
  section_enabled weaviate && want_health=1
  [ "$want_metrics" = 1 ] || [ "$want_health" = 1 ] || return 0

  if [ "$want_metrics" = 1 ] && [ "$want_health" = 1 ]; then heading "Per-pod health and metrics"
  elif [ "$want_metrics" = 1 ]; then heading "Per-pod metrics"
  else heading "Per-pod health"; fi
  if section_enabled metrics && [ "$METRICS_ENABLED" != "true" ]; then
    _nometrics() { step_detail "PROMETHEUS_MONITORING_ENABLED is not true"; return 10; }
    run_step metrics "metrics" _nometrics
    want_metrics=0
  fi

  # Open one tunnel per pod.
  : > "$WORK/tunnels.tsv"
  local pod rc
  for pod in $SEL_WEAVIATE_PODS; do
    if [ "$want_metrics" = 1 ]; then tunnel_open "$pod" "$HTTP_PORT" "$METRICS_PORT"; else tunnel_open "$pod" "$HTTP_PORT"; fi
    rc=$?
    if [ "$rc" -eq 0 ]; then
      set -- $TUNNEL_PORTS
      printf '%s\t%s\t%s\t%s\n' "$pod" "$TUNNEL_PID" "$1" "${2:-}" >> "$WORK/tunnels.tsv"
    else
      _notunnel() { step_detail "$TUNNEL_ERROR"; return "$rc"; }
      run_step weaviate "$pod: port-forward" _notunnel
    fi
  done
  [ -s "$WORK/tunnels.tsv" ] || return 0

  local pid hp mp code_live code_ready
  # Health checks and first metrics snapshot.
  while IFS="$(printf '\t')" read -r pod pid hp mp; do
    if [ "$want_health" = 1 ]; then
      code_live=$(http_get "http://127.0.0.1:$hp/v1/.well-known/live" "$RAW/live.out" noauth)
      code_ready=$(http_get "http://127.0.0.1:$hp/v1/.well-known/ready" "$RAW/ready.out" noauth)
      jq -n --arg l "$code_live" --arg r "$code_ready" --arg t "$(now_utc)" \
        '{checked_at: $t, live: {http_status: ($l | tonumber? // $l), ok: ($l == "200")},
          ready: {http_status: ($r | tonumber? // $r), ok: ($r == "200")}}' \
        | write_json "$STAGE/pods/$pod/health.json"
    fi
    if [ "$want_metrics" = 1 ]; then
      http_get "http://127.0.0.1:$mp/metrics" "$RAW/metrics-$pod-0.txt" noauth > "$RAW/metrics-$pod-0.code"
    fi
  done < "$WORK/tunnels.tsv"

  if [ "$want_metrics" = 1 ]; then
    info "Waiting ${METRICS_INTERVAL}s for the second metrics snapshot..."
    sleep "$METRICS_INTERVAL"
    while IFS="$(printf '\t')" read -r pod pid hp mp; do
      http_get "http://127.0.0.1:$mp/metrics" "$RAW/metrics-$pod-1.txt" noauth > "$RAW/metrics-$pod-1.code"
    done < "$WORK/tunnels.tsv"
  fi

  # Close tunnels, then build the files.
  while IFS="$(printf '\t')" read -r pod pid hp mp; do tunnel_close "$pid"; done < "$WORK/tunnels.tsv"

  while IFS="$(printf '\t')" read -r pod pid hp mp; do
    [ "$want_health" = 1 ] && run_step weaviate "$pod: live/ready" _health_detail "$pod"
    [ "$want_metrics" = 1 ] && run_step metrics "$pod" _metrics_build "$pod"
  done < "$WORK/tunnels.tsv"
}

_health_detail() {
  local f="$STAGE/pods/$1/health.json"
  [ -f "$f" ] || return 1
  step_detail "live $(jq -r '.live.http_status' "$f"), ready $(jq -r '.ready.http_status' "$f")"
  return 0
}

_metrics_build() {
  local pod="$1" c0 c1
  c0=$(cat "$RAW/metrics-$pod-0.code" 2>/dev/null); c1=$(cat "$RAW/metrics-$pod-1.code" 2>/dev/null)
  if [ "$c0" != "200" ] || [ "$c1" != "200" ]; then
    step_detail "metrics endpoint returned HTTP ${c0:-none}/${c1:-none}"
    return 13
  fi
  filter_metrics "$RAW/metrics-$pod-0.txt" | jq -L "$JQ_LIB" -nR 'include "metrics"; parse_samples' > "$RAW/m0.json"
  filter_metrics "$RAW/metrics-$pod-1.txt" | jq -L "$JQ_LIB" -nR 'include "metrics"; parse_samples' > "$RAW/m1.json"
  jq -L "$JQ_LIB" -n --slurpfile a "$RAW/m0.json" --slurpfile b "$RAW/m1.json" --argjson i "$METRICS_INTERVAL" \
    'include "metrics"; summarize($a[0]; $b[0]; $i)' | write_json "$STAGE/pods/$pod/metrics.json" || return 1
  step_detail "$(jq '.metrics | length' "$STAGE/pods/$pod/metrics.json") metrics"
}
