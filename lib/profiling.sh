# shellcheck shell=bash
# lib/profiling.sh: Go profiles from the Weaviate pods (only with
# --include-profiling).
#
# Reads the pprof endpoints on Weaviate's debug port through a port-forward.
# The gate (lib/guard.sh) allows only the exact GET paths used here, and only
# when the option was given. Every other path on that port stays blocked,
# because some of them change state.
#
#   pods/<pod>/profiles/cpu.pprof            CPU, sampled for --profile-seconds
#   pods/<pod>/profiles/goroutine.pprof      goroutines
#   pods/<pod>/profiles/goroutine.txt        goroutine stacks, readable
#   pods/<pod>/profiles/block.pprof          blocking (needs GO_BLOCK_PROFILE_RATE)
#   pods/<pod>/profiles/mutex.pprof          lock contention (needs GO_MUTEX_PROFILE_FRACTION)
#   pods/<pod>/profiles/threadcreate.pprof   OS thread creation
#   pods/<pod>/profiles/heap.pprof           only with --include-heap
#
# Binary .pprof files cannot be redacted; redactions.txt says so.

# Instant profiles: name, path and query, file name.
_profile_list() {
  printf '%s\n' \
    'goroutine /debug/pprof/goroutine goroutine.pprof' \
    'goroutine-text /debug/pprof/goroutine?debug=2 goroutine.txt' \
    'block /debug/pprof/block block.pprof' \
    'mutex /debug/pprof/mutex mutex.pprof' \
    'threadcreate /debug/pprof/threadcreate threadcreate.pprof'
  [ "${INCLUDE_HEAP:-0}" = 1 ] && printf '%s\n' 'heap /debug/pprof/heap heap.pprof'
  return 0
}

# Records a saved profile, or removes the file. Returns 0 saved, 10 empty,
# 11 refused, 13 no connection, 1 other.
_profile_result() {
  local pod="$1" name="$2" file="$3" code="$4" seconds="${5:-}"
  case "$code" in
    200)
      if [ ! -s "$file" ]; then rm -f "$file"; return 10; fi
      jq -cn --arg pod "$pod" --arg name "$name" --arg file "${file#"$STAGE"/}" --arg at "$(now_utc)" \
        --argjson bytes "$(wc -c < "$file" | tr -d ' ')" --arg s "$seconds" \
        '{pod: $pod, profile: $name, file: $file, bytes: $bytes, captured_at: $at}
         + (if $s == "" then {} else {seconds: ($s | tonumber)} end)' >> "$WORK/profiles-index.jsonl"
      return 0 ;;
    401|403) rm -f "$file"; return 11 ;;
    000|"")  rm -f "$file"; return 13 ;;
    *)       rm -f "$file"; return 1 ;;
  esac
}

_profiles_pod() {
  local pod="$1" port="$2" dir="$STAGE/pods/$1/profiles" name path file code rc got="" skipped=""
  _profile_result "$pod" cpu "$dir/cpu.pprof" "$(cat "$RAW/profile-$pod-cpu.code" 2>/dev/null)" "$PROFILE_SECONDS"
  rc=$?
  case "$rc" in 0) got="cpu" ;; 11) PROFILES_DENIED=1; step_detail "refused (HTTP 401/403)"; return 11 ;; 13) step_detail "no connection"; return 13 ;; *) skipped="cpu" ;; esac
  while read -r name path file; do
    # shellcheck disable=SC2034  # read by http_get through bash dynamic scoping
    code=$(HTTP_TIMEOUT=120 http_get "http://127.0.0.1:$port$path" "$dir/$file" noauth)
    _profile_result "$pod" "$name" "$dir/$file" "$code"
    rc=$?
    case "$rc" in
      0) got="$got $name" ;;
      11) PROFILES_DENIED=1; step_detail "refused (HTTP 401/403)"; return 11 ;;
      13) step_detail "lost the connection after:${got:- none}"; return 13 ;;
      *) skipped="$skipped $name" ;;
    esac
  done <<LIST
$(_profile_list)
LIST
  [ -n "$got" ] || { step_detail "no profile returned data"; return 13; }
  step_detail "${got# }${skipped:+; empty or unavailable:$skipped}"
  return 0
}

collect_profiles() {
  heading "Profiles"
  : > "$WORK/profiles-index.jsonl"
  if [ "$PF_PROFILING" != "ok" ]; then
    _noprofile() {
      step_detail "${PROFILING_ERROR:-not available}"
      case "$PF_PROFILING" in forbidden) return 11 ;; off) return 10 ;; *) return 13 ;; esac
    }
    run_step profiling "profiles" _noprofile
    return
  fi

  local pod rc pid port cpu_pids=""
  : > "$WORK/profile-tunnels.tsv"
  for pod in $SEL_WEAVIATE_PODS; do
    tunnel_open "$pod" "$WEAVIATE_DEBUG_PORT"; rc=$?
    if [ "$rc" -eq 0 ]; then
      printf '%s\t%s\t%s\n' "$pod" "$TUNNEL_PID" "$TUNNEL_PORTS" >> "$WORK/profile-tunnels.tsv"
    else
      _notunnel() { step_detail "$TUNNEL_ERROR"; return "$rc"; }
      run_step profiling "$pod" _notunnel
    fi
  done
  [ -s "$WORK/profile-tunnels.tsv" ] || return 0

  # CPU first and on all pods at once, so the samples cover the same window.
  info "Sampling CPU for ${PROFILE_SECONDS}s on all pods at once..."
  while IFS="$(printf '\t')" read -r pod pid port; do
    mkdir -p "$STAGE/pods/$pod/profiles"
    # shellcheck disable=SC2034  # read by http_get through bash dynamic scoping
    HTTP_TIMEOUT=$((PROFILE_SECONDS + 60)) http_get "http://127.0.0.1:$port/debug/pprof/profile?seconds=$PROFILE_SECONDS" \
      "$STAGE/pods/$pod/profiles/cpu.pprof" noauth > "$RAW/profile-$pod-cpu.code" &
    cpu_pids="$cpu_pids $!"
    echo "$!" >> "$WORK/tunnel-pids"
  done < "$WORK/profile-tunnels.tsv"
  # Only these jobs: the port-forwards are background jobs too and never end.
  # shellcheck disable=SC2086
  wait $cpu_pids

  # Then the instant profiles, one pod at a time.
  PROFILES_DENIED=0
  while IFS="$(printf '\t')" read -r pod pid port; do
    if [ "$PROFILES_DENIED" = 1 ]; then
      _denied() { step_detail "skipped: the debug port refused an earlier request"; return 11; }
      run_step profiling "$pod" _denied
    else
      run_step profiling "$pod" _profiles_pod "$pod" "$port"
    fi
    tunnel_close "$pid"
  done < "$WORK/profile-tunnels.tsv"
}
