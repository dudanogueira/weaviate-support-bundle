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
#
# When a log is bigger than --max-log-mb, the NEWEST part is kept: the end of
# a log is what explains an incident. (`kubectl logs --limit-bytes` would keep
# the oldest part.) The stream goes through tail, so disk use stays at the cap.
fetch_log() {
  local pod="$1" container="$2" kind="$3" dest="$4"
  local limit=$((MAX_LOG_MB * 1024 * 1024))
  local args="--timestamps"
  if [ "$kind" = "previous" ]; then
    args="$args --previous --tail=$PREVIOUS_LOG_LINES"
  elif [ -n "$LOG_FROM" ]; then
    args="$args --since-time=$LOG_FROM"
  else
    args="$args --since=$LOG_SINCE"
  fi
  # Apply --to before the cut, so the newest lines kept are inside the window
  # (logs are in UTC, and RFC 3339 timestamps sort as text).
  local to="${LOG_TO:-}" partial=false
  [ "$kind" = "previous" ] && to=""
  # shellcheck disable=SC2086
  if ! kc logs -n "$NAMESPACE" "$pod" --container="$container" $args 2> "$WORK/err" \
      | LC_ALL=C awk -v to="$to" 'to != "" && substr($1, 1, 19) > substr(to, 1, 19) { next } { print }' \
      | tail -c $((limit + 1)) > "$RAW/log.win"; then
    local msg; msg=$(cat "$WORK/err")
    case "$msg" in *"previous terminated container"*|*"not found"*|*"waiting to start"*|*"is waiting"*) return 12 ;; esac
    # kubectl stopped partway (timeout, lost connection): keep what arrived.
    if [ -s "$RAW/log.win" ]; then
      partial=true
      log_line WARN "$pod/$container ($kind): log is partial: $(short_error "$msg")"
    else
      kube_error_code "$msg"; return $?
    fi
  fi
  [ -s "$RAW/log.win" ] || return 12

  # Over the cap: keep the last $limit bytes, without the first (cut) line.
  local truncated=false
  if [ "$(wc -c < "$RAW/log.win" | tr -d ' ')" -gt "$limit" ]; then
    tail -c "$limit" "$RAW/log.win" | tail -n +2 > "$RAW/log.cut" && mv "$RAW/log.cut" "$RAW/log.win"
    truncated=true
  fi

  # Record the covered range, then drop the kubelet timestamp prefix so each
  # line is exactly what the container printed.
  local first last lines
  first=$(head -n 1 "$RAW/log.win" | awk '{print $1}')
  last=$(tail -n 1 "$RAW/log.win" | awk '{print $1}')
  lines=$(wc -l < "$RAW/log.win" | tr -d ' ')
  mkdir -p "$(dirname "$dest")"
  sed 's/^[^ ]* //' "$RAW/log.win" > "$dest"
  jq -cn --arg pod "$pod" --arg c "$container" --arg k "$kind" --arg f "${first:-}" --arg l "${last:-}" \
    --argjson n "${lines:-0}" --argjson t "$truncated" --argjson p "$partial" --arg file "${dest#"$STAGE"/}" \
    '{pod: $pod, container: $c, kind: $k, file: $file, lines: $n, first: (if $f == "" then null else $f end),
      last: (if $l == "" then null else $l end), truncated: $t}
     + (if $t then {kept: "newest"} else {} end)
     + (if $p then {partial: true} else {} end)' >> "$WORK/logs-index.jsonl"
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
