# shellcheck shell=bash
# lib/guard.sh: the read-only gate.
#
# This is the ONLY file allowed to run `kubectl` or `curl`. Every other file
# must call the wrappers below. tests/check-read-only.sh fails the build if
# that rule is broken.
#
#   kc <verb> ...         kubectl, limited to: get, logs, version,
#                         config current-context (local only); Secrets
#                         only with --include-helm (Helm release info)
#   kc_raw_get <path>     GET of an allow-listed raw API path
#   tunnel_open ...       kubectl port-forward (opens a local tunnel; it does
#                         not create or change anything in the cluster)
#   http_get <url> <out>  HTTP GET only, never another method, never the
#                         Weaviate debug port
#
# If anything tries to do more, the tool stops before running it.

# kubectl --context comes from KUBE_CONTEXT (set by collect.sh from --context).
# Expanded as ${KUBE_CONTEXT:+"--context=$KUBE_CONTEXT"}: one quoted word when set,
# nothing when empty, so a context name with spaces stays intact.

guard_violation() {
  printf '\n%sStopped:%s the tool tried an action outside its read-only limits (%s). Nothing was changed. Please report this to Weaviate support.\n' \
    "${C_RED:-}" "${C_RST:-}" "$*" >&2
  log_line ERROR "stopped by the read-only gate: $*"
  if [ -n "${TOOL_PID:-}" ]; then kill -TERM "$TOOL_PID" 2>/dev/null; fi
  exit 99
}

# Raw API paths the tool may read. Anything else is refused.
# The variable part (a node name or a namespace) must be exactly one name:
# lowercase letters, digits, "-" and "." (Kubernetes names), so it cannot
# reach another kubelet or API path ("a/b", "..", "?x", ...).
_raw_path_allowed() {
  local name
  case "$1" in
    /api/v1/nodes/*/proxy/stats/summary)
      name="${1#/api/v1/nodes/}"; name="${name%/proxy/stats/summary}" ;;
    /api/v1/nodes/*/proxy/healthz)
      name="${1#/api/v1/nodes/}"; name="${name%/proxy/healthz}" ;;
    /apis/metrics.k8s.io/v1beta1/namespaces/*/pods)
      name="${1#/apis/metrics.k8s.io/v1beta1/namespaces/}"; name="${name%/pods}" ;;
    *) return 1 ;;
  esac
  case "$name" in ''|*[!a-z0-9.-]*|*..*) return 1 ;; esac
  return 0
}

# _kc_get_reads_secrets <get args>: does this `kubectl get` read Secrets?
# Looks at the resource type: the first argument that is not an option or an
# option's value ("secrets", "secret/x", "pods,secrets", "Secret.v1"...).
# Names of other objects are not looked at, so a ConfigMap named "secrets"
# is fine.
_kc_get_reads_secrets() {
  local a skip=0 r
  for a in "$@"; do
    if [ "$skip" = 1 ]; then skip=0; continue; fi
    case "$a" in
      -n|-l|-o|-L|--namespace|--selector|--output|--field-selector|--limit|--sort-by|--chunk-size|--template|--label-columns)
        skip=1; continue ;;
      -*) continue ;;
    esac
    for r in $(printf '%s' "$a" | tr ',' ' '); do
      r=$(printf '%s' "${r%%/*}" | tr 'A-Z' 'a-z')
      case "$r" in secret|secrets|secret.*|secrets.*) return 0 ;; esac
    done
    return 1
  done
  return 1
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
      done
      shift
      if _kc_get_reads_secrets "$@" && [ "${INCLUDE_HELM:-0}" != "1" ]; then
        guard_violation "kubectl get secrets without --include-helm"
      fi
      set -- get "$@" ;;
    logs)
      timeout="300s"
      for a in "$@"; do
        case "$a" in -f|--follow|--follow=*) guard_violation "kubectl logs --follow" ;; esac
      done ;;
    version) timeout="15s" ;;
    config)
      [ "$#" -eq 2 ] && [ "${2:-}" = "current-context" ] || guard_violation "kubectl config ${2:-}"
      command kubectl ${KUBE_CONTEXT:+"--context=$KUBE_CONTEXT"} config current-context
      return ;;
    *) guard_violation "kubectl $verb" ;;
  esac
  command kubectl ${KUBE_CONTEXT:+"--context=$KUBE_CONTEXT"} --request-timeout="$timeout" "$@"
}

# kc_raw_get <path>: GET an allow-listed API path through the API server.
kc_raw_get() {
  _raw_path_allowed "$1" || guard_violation "kubectl get --raw $1"
  command kubectl ${KUBE_CONTEXT:+"--context=$KUBE_CONTEXT"} --request-timeout=30s get --raw "$1"
}

# ---------------------------------------------------------------------------
# Port-forward tunnels
#
# tunnel_open <pod> <remote_port> [<remote_port>...]
#   Opens one tunnel to the pod on 127.0.0.1 with random local ports.
#   Sets TUNNEL_PID and TUNNEL_PORTS (local ports, same order as requested).
#   Returns 0 ok, 11 forbidden, 13 could not connect.
#   Never to Weaviate's debug port (WEAVIATE_DEBUG_PORT, GO_PROFILING_PORT in
#   Weaviate, default 6060): through a tunnel the URL shows a random local
#   port, so http_get's :6060 check alone would not see it.
#   The one exception is --include-profiling (PROFILING_ALLOWED=1).
# ---------------------------------------------------------------------------
tunnel_open() {
  local pod="$1"; shift
  local log specs="" p n i
  for p in "$@"; do
    case "$p" in ''|*[!0-9]*) guard_violation "port-forward to a port that is not a number: $p" ;; esac
    [ "$p" = "${WEAVIATE_DEBUG_PORT:-6060}" ] && [ "${PROFILING_ALLOWED:-0}" != "1" ] \
      && guard_violation "port-forward to Weaviate's debug port $p"
  done
  log="$WORK/tunnel-$(safe_name "$pod")-$$-$RANDOM.log"
  for p in "$@"; do specs="$specs :$p"; done
  # shellcheck disable=SC2086
  command kubectl ${KUBE_CONTEXT:+"--context=$KUBE_CONTEXT"} port-forward -n "$NAMESPACE" "pod/$pod" \
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
#   process list or in shell history. A key with control characters is never
#   sent (see api_key_ok): the request is skipped and "000" is printed.
#   Only Weaviate's REST API (/v1/...) and Prometheus metrics (/metrics), below
#   any base path a --weaviate-url may have; never the debug endpoints, except
#   the exact pprof GETs of --include-profiling (see _pprof_allowed).
# ---------------------------------------------------------------------------

# api_key_ok: the key has no control characters (line breaks, tabs, ...).
# The key goes into a curl config line, where a line break would start a new
# curl option (for example another request method), so such a key is refused.
api_key_ok() {
  case "${WEAVIATE_API_KEY:-}" in *[[:cntrl:]]*) return 1 ;; esac
  return 0
}

# _pprof_allowed <url>: the one exception to "never the debug port". Only with
# --include-profiling, only through a local tunnel, only these exact GETs.
# Never cmdline (process arguments can hold secrets), never trace, never any
# other /debug path: some of them change state.
_pprof_allowed() {
  [ "${PROFILING_ALLOWED:-0}" = "1" ] || return 1
  case "$1" in http://127.0.0.1:*/*) ;; *) return 1 ;; esac
  local rest="${1#http://127.0.0.1:}" port pq seconds
  port="${rest%%/*}"
  case "$port" in ''|*[!0-9]*) return 1 ;; esac
  pq="/${rest#*/}"
  case "$pq" in
    /debug/pprof/goroutine|/debug/pprof/goroutine\?debug=2|/debug/pprof/block|/debug/pprof/mutex|/debug/pprof/threadcreate) return 0 ;;
    /debug/pprof/heap) [ "${INCLUDE_HEAP:-0}" = "1" ]; return ;;
    /debug/pprof/profile\?seconds=*)
      seconds="${pq#*seconds=}"
      case "$seconds" in ''|*[!0-9]*) return 1 ;; esac
      [ "$seconds" -ge 5 ] && [ "$seconds" -le 120 ]; return ;;
  esac
  return 1
}

http_get() {
  local url="$1" out="$2" mode="${3:-auth}" path
  if [ "$mode" = "auth" ] && ! api_key_ok; then
    log_line ERROR "WEAVIATE_API_KEY contains control characters; request not sent"
    printf '000'
    return 1
  fi
  case "$url" in http://*|https://*) ;; *) guard_violation "non-HTTP URL: $url" ;; esac
  if _pprof_allowed "$url"; then
    mode="noauth"   # the debug port has no authentication: never send the key
  else
    case "$url" in
      */debug|*/debug/*|*/debug\?*|*:6060|*:6060/*) guard_violation "Weaviate debug endpoint: $url" ;;
    esac
    path="${url#*://}"
    case "$path" in */*) path="/${path#*/}" ;; *) path="/" ;; esac
    path="${path%%\?*}"
    case "$path" in
      */v1/*|*/metrics) ;;
      *) guard_violation "HTTP path outside Weaviate's API and metrics: $path" ;;
    esac
  fi
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
