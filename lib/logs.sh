# shellcheck shell=bash
# lib/logs.sh: container logs (section "logs").
#
# For every selected pod and container:
#   pods/<pod>/logs/<container>.log            current container, time window
#   pods/<pod>/logs/<container>.previous.log   previous container (after a
#                                              restart), last 5,000 lines
# Logs are scrubbed for secrets later, in the final pass (finalize.sh).
#
# Kubernetes keeps only recent logs on the node (by default about the last
# 10 MB per container), so a long window may come back shorter. The real time
# range covered is recorded in manifest.json and shown in SUMMARY.md.

PREVIOUS_LOG_LINES=5000

log_window_text() {
  if [ -n "$LOG_FROM" ]; then
    printf 'from %s to %s' "$LOG_FROM" "${LOG_TO:-now}"
  else
    printf 'last %s' "$LOG_SINCE"
  fi
}

# Writes one log file. Returns 0 if written, 12 if there is nothing (no
# previous container), 11 forbidden, 1 error.
fetch_log() {
  local pod="$1" container="$2" kind="$3" dest="$4"
  local args="--timestamps --limit-bytes=$((MAX_LOG_MB * 1024 * 1024))"
  if [ "$kind" = "previous" ]; then
    args="$args --previous --tail=$PREVIOUS_LOG_LINES"
  elif [ -n "$LOG_FROM" ]; then
    args="$args --since-time=$LOG_FROM"
  else
    args="$args --since=$LOG_SINCE"
  fi
  # shellcheck disable=SC2086
  if ! kc logs -n "$NAMESPACE" "$pod" --container="$container" $args > "$RAW/log.raw" 2> "$WORK/err"; then
    local msg; msg=$(cat "$WORK/err")
    case "$msg" in *"previous terminated container"*|*"not found"*|*"waiting to start"*|*"is waiting"*) return 12 ;; esac
    kube_error_code "$msg"; return $?
  fi
  [ -s "$RAW/log.raw" ] || return 12

  # Apply --to (logs are in UTC, and RFC 3339 timestamps sort as text),
  # record the covered range, then drop the kubelet timestamp prefix so each
  # line is exactly what the container printed.
  local to="${LOG_TO:-}"
  awk -v to="$to" -v kind="$kind" \
    'to != "" && kind != "previous" && substr($1, 1, 19) > substr(to, 1, 19) { next } { print }' \
    "$RAW/log.raw" > "$RAW/log.win"
  local first last lines bytes
  first=$(head -n 1 "$RAW/log.win" | awk '{print $1}')
  last=$(tail -n 1 "$RAW/log.win" | awk '{print $1}')
  lines=$(wc -l < "$RAW/log.win" | tr -d ' ')
  bytes=$(wc -c < "$RAW/log.raw" | tr -d ' ')
  mkdir -p "$(dirname "$dest")"
  sed 's/^[^ ]* //' "$RAW/log.win" > "$dest"
  local truncated=false
  [ "$bytes" -ge $((MAX_LOG_MB * 1024 * 1024)) ] && truncated=true
  jq -cn --arg pod "$pod" --arg c "$container" --arg k "$kind" --arg f "${first:-}" --arg l "${last:-}" \
    --argjson n "${lines:-0}" --argjson t "$truncated" --arg file "${dest#"$STAGE"/}" \
    '{pod: $pod, container: $c, kind: $k, file: $file, lines: $n, first: (if $f == "" then null else $f end),
      last: (if $l == "" then null else $l end), truncated: $t}' >> "$WORK/logs-index.jsonl"
  return 0
}

collect_pod_logs() {
  local pod="$1" containers c got=0 denied=0 prev=0 rc
  containers=$(jq -r --arg p "$pod" '(.items[] | select(.metadata.name == $p) | [.spec.initContainers[]?.name, .spec.containers[].name] | .[])' \
    "$RAW/weaviate-pods.json" "$RAW/module-pods.json" 2>/dev/null | sort -u)
  [ -n "$containers" ] || { step_detail "pod not found"; return 12; }
  for c in $containers; do
    fetch_log "$pod" "$c" current "$STAGE/pods/$pod/logs/$c.log"; rc=$?
    [ "$rc" -eq 0 ] && got=$((got + 1))
    [ "$rc" -eq 11 ] && denied=1
    fetch_log "$pod" "$c" previous "$STAGE/pods/$pod/logs/$c.previous.log"
    [ $? -eq 0 ] && prev=$((prev + 1))
  done
  [ "$denied" = 1 ] && [ "$got" -eq 0 ] && return 11
  step_detail "$got container log(s)$([ "$prev" -gt 0 ] && printf ', %s previous (restarted)' "$prev")"
  return 0
}

collect_logs() {
  heading "Logs ($(log_window_text))"
  : > "$WORK/logs-index.jsonl"
  if [ "$PF_LOGS" = "forbidden" ]; then
    _nolog() { step_detail "no permission to read pod logs"; return 11; }
    run_step logs "pod logs" _nolog
    return
  fi
  local p
  for p in $SEL_WEAVIATE_PODS $SEL_MODULE_PODS; do
    run_step logs "$p" collect_pod_logs "$p"
  done
}
