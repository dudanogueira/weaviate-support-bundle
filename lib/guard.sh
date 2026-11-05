# shellcheck shell=bash
# lib/guard.sh: the read-only gate.
#
# This is the ONLY file allowed to run `kubectl` or `curl`. Every other file
# must call the wrappers below. tests/check-read-only.sh fails the build if
# that rule is broken.
#
#   kc <verb> ...         kubectl, limited to: get, logs, version,
#                         config current-context (local only)
#   kc_raw_get <path>     GET of an allow-listed raw API path
#   tunnel_open ...       kubectl port-forward (opens a local tunnel; it does
#                         not create or change anything in the cluster)
#   http_get <url> <out>  HTTP GET only, never another method, never the
#                         Weaviate debug port
#
# If anything tries to do more, the tool stops before running it.

KC_GLOBAL_ARGS=""   # set by collect.sh, e.g. "--context=my-cluster"

guard_violation() {
  printf '\n%sStopped:%s the tool tried an action that is not read-only (%s). Nothing was changed. Please report this to Weaviate support.\n' \
    "${C_RED:-}" "${C_RST:-}" "$*" >&2
  log_line ERROR "stopped by the read-only gate: $*"
  if [ -n "${TOOL_PID:-}" ]; then kill -TERM "$TOOL_PID" 2>/dev/null; fi
  exit 99
}

# Raw API paths the tool may read. Anything else is refused.
_raw_path_allowed() {
  case "$1" in
    /api/v1/nodes/*/proxy/stats/summary) ;;
    /api/v1/nodes/*/proxy/healthz) ;;
    /apis/metrics.k8s.io/v1beta1/namespaces/*/pods) ;;
    *) return 1 ;;
  esac
  # No path traversal or query tricks.
  case "$1" in *..*|*\?*|*'#'*) return 1 ;; esac
  return 0
}

# kc <verb> [args...]: read-only kubectl.
kc() {
  local verb="${1:-}" timeout="30s" a
  case "$verb" in
    get)
      for a in "$@"; do
        case "$a" in
          --raw|--raw=*) guard_violation "kubectl get --raw (use kc_raw_get)" ;;
          -w|--watch|--watch=*|--watch-only*) guard_violation "kubectl get --watch" ;;
        esac
      done ;;
    logs)
      timeout="300s"
      for a in "$@"; do
        case "$a" in -f|--follow|--follow=*) guard_violation "kubectl logs --follow" ;; esac
      done ;;
    version) timeout="15s" ;;
    config)
      [ "$#" -eq 2 ] && [ "${2:-}" = "current-context" ] || guard_violation "kubectl config ${2:-}"
      # shellcheck disable=SC2086
      command kubectl $KC_GLOBAL_ARGS config current-context
      return ;;
    *) guard_violation "kubectl $verb" ;;
  esac
  # shellcheck disable=SC2086
  command kubectl $KC_GLOBAL_ARGS --request-timeout="$timeout" "$@"
}

# kc_raw_get <path>: GET an allow-listed API path through the API server.
kc_raw_get() {
  _raw_path_allowed "$1" || guard_violation "kubectl get --raw $1"
  # shellcheck disable=SC2086
  command kubectl $KC_GLOBAL_ARGS --request-timeout=30s get --raw "$1"
}

# ---------------------------------------------------------------------------
# Port-forward tunnels
#
# tunnel_open <pod> <remote_port> [<remote_port>...]
#   Opens one tunnel to the pod on 127.0.0.1 with random local ports.
#   Sets TUNNEL_PID and TUNNEL_PORTS (local ports, same order as requested).
#   Returns 0 ok, 11 forbidden, 13 could not connect.
# ---------------------------------------------------------------------------
tunnel_open() {
  local pod="$1"; shift
  local log specs="" p n i
  log="$WORK/tunnel-$(safe_name "$pod")-$$-$RANDOM.log"
  for p in "$@"; do specs="$specs :$p"; done
  # shellcheck disable=SC2086
  command kubectl $KC_GLOBAL_ARGS port-forward -n "$NAMESPACE" "pod/$pod" \
    --address 127.0.0.1 $specs > "$log" 2>&1 < /dev/null &
  TUNNEL_PID=$!
  echo "$TUNNEL_PID" >> "$WORK/tunnel-pids"
  TUNNEL_PORTS=""
  i=0
  while [ "$i" -lt 40 ]; do
    n=$(grep -c '^Forwarding from 127.0.0.1:' "$log" 2>/dev/null)
    [ "${n:-0}" -ge "$#" ] && break
    kill -0 "$TUNNEL_PID" 2>/dev/null || break
    sleep 0.25
    i=$((i + 1))
  done
  for p in "$@"; do
    n=$(sed -n "s/^Forwarding from 127\.0\.0\.1:\([0-9][0-9]*\) -> $p\$/\1/p" "$log" | head -n 1)
    if [ -z "$n" ]; then
      TUNNEL_ERROR=$(short_error "$(cat "$log" 2>/dev/null)")
      tunnel_close "$TUNNEL_PID"
      TUNNEL_PID=""
      case "$TUNNEL_ERROR" in *[Ff]orbidden*) return 11 ;; esac
      return 13
    fi
    TUNNEL_PORTS="$TUNNEL_PORTS $n"
  done
  TUNNEL_PORTS="${TUNNEL_PORTS# }"
  return 0
}

tunnel_close() {
  [ -n "${1:-}" ] || return 0
  kill "$1" 2>/dev/null
  wait "$1" 2>/dev/null
  return 0
}

stop_all_tunnels() {
  [ -n "${WORK:-}" ] && [ -f "$WORK/tunnel-pids" ] || return 0
  local pid
  while read -r pid; do
    [ -n "$pid" ] && kill "$pid" 2>/dev/null
  done < "$WORK/tunnel-pids"
  return 0
}

# ---------------------------------------------------------------------------
# HTTP
#
# http_get <url> <outfile> [noauth]
#   GET only. Prints the HTTP status code ("000" if there was no connection).
#   The API key is passed to curl through stdin, so it never shows up in the
#   process list or in shell history.
# ---------------------------------------------------------------------------
http_get() {
  local url="$1" out="$2" mode="${3:-auth}"
  case "$url" in http://*|https://*) ;; *) guard_violation "non-HTTP URL: $url" ;; esac
  case "$url" in
    */debug|*/debug/*|*:6060|*:6060/*) guard_violation "Weaviate debug endpoint: $url" ;;
  esac
  local tls_flag=""
  [ "${INSECURE_TLS:-0}" = "1" ] && tls_flag="--insecure"
  {
    if [ "$mode" = "auth" ] && [ -n "${WEAVIATE_API_KEY:-}" ]; then
      printf 'header = "Authorization: Bearer %s"\n' \
        "$(printf '%s' "$WEAVIATE_API_KEY" | sed 's/\\/\\\\/g; s/"/\\"/g')"
    fi
  } | command curl --silent --show-error --globoff --proto '=http,https' \
        --request GET --max-time "${HTTP_TIMEOUT:-60}" --connect-timeout 10 \
        --max-filesize 1073741824 $tls_flag --config - \
        --output "$out" --write-out '%{http_code}' "$url" 2>> "$WORK/run.log"
}
