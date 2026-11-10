# shellcheck shell=bash
# lib/discover.sh: find the Weaviate cluster, check what the tool is allowed
# to read, show the preflight table and ask for approval.
#
# Nothing here is saved to the bundle except the selected StatefulSet and pods.
# When the tool looks across namespaces, it only reads names and images.

WEAVIATE_IMAGE_RE='semitechnologies/weaviate[:@]'
MODULE_IMAGE_RE='semitechnologies/'

check_prerequisites() {
  local missing="" t
  for t in kubectl curl jq tar gzip base64 sed awk; do
    command -v "$t" >/dev/null 2>&1 || missing="$missing $t"
  done
  [ -z "$missing" ] || die "Missing required tools:$missing. See README.md > Requirements."
  local jqv
  jqv=$(jq --version 2>/dev/null | sed 's/^jq-//')
  case "$jqv" in
    1.[0-5]|1.[0-5].*) die "jq $jqv is too old; version 1.6 or newer is required." ;;
  esac
}

# ---------------------------------------------------------------------------
# Kubernetes connection
# ---------------------------------------------------------------------------
discover_cluster() {
  # With --context, that is the cluster every call goes to. `kubectl config
  # current-context` ignores --context and would name a different cluster.
  if [ -n "$KUBE_CONTEXT" ]; then
    CONTEXT_NAME="$KUBE_CONTEXT"
  else
    CONTEXT_NAME=$(kc config current-context 2>/dev/null)
    [ -n "$CONTEXT_NAME" ] || die "kubectl has no current context. Point kubectl at the cluster first (kubectl config use-context ...), or pass --context."
  fi
  if ! kc version -o json > "$RAW/version.json" 2> "$WORK/err"; then
    die "Cannot reach the Kubernetes API with context '$CONTEXT_NAME': $(short_error "$(cat "$WORK/err")")"
  fi
  SERVER_VERSION=$(jq -r '.serverVersion.gitVersion // "unknown"' "$RAW/version.json")
}

# ---------------------------------------------------------------------------
# Weaviate StatefulSet and pods
# ---------------------------------------------------------------------------
discover_statefulset() {
  local list="$RAW/sts-names.tsv" scope
  # jsonpath prints only namespace, name and images: other workloads' specs
  # are never written to disk.
  local jp='{range .items[*]}{.metadata.namespace}{"\t"}{.metadata.name}{"\t"}{range .spec.template.spec.containers[*]}{.image}{" "}{end}{"\n"}{end}'
  if [ -n "$NAMESPACE" ]; then
    scope="namespace '$NAMESPACE'"
    kc get statefulsets -n "$NAMESPACE" -o "jsonpath=$jp" > "$list" 2> "$WORK/err" \
      || die "Cannot list StatefulSets in $scope: $(short_error "$(cat "$WORK/err")")"
  else
    scope="any namespace"
    kc get statefulsets --all-namespaces -o "jsonpath=$jp" > "$list" 2> "$WORK/err" \
      || die "Cannot list StatefulSets across namespaces ($(short_error "$(cat "$WORK/err")")). Run again with --namespace <namespace>."
  fi

  local matches
  matches=$(awk -F '\t' -v re="$WEAVIATE_IMAGE_RE" -v want="$STS_NAME" \
    '$3 ~ re && (want == "" || $2 == want) { print $1 "/" $2 }' "$list")
  local count
  count=$(printf '%s' "$matches" | grep -c . )
  if [ "$count" -eq 0 ]; then
    die "No Weaviate StatefulSet found in $scope${STS_NAME:+ named '$STS_NAME'}. Check --namespace / --statefulset, or that kubectl points at the right cluster ($CONTEXT_NAME)."
  fi
  if [ "$count" -gt 1 ]; then
    say ""
    say "Found more than one Weaviate StatefulSet:"
    printf '%s\n' "$matches" | sed 's/^/    /' >&2
    die "Choose one with --namespace <namespace> (and --statefulset <name> if needed)."
  fi
  NAMESPACE="${matches%%/*}"
  STS_NAME="${matches#*/}"

  kc get statefulset "$STS_NAME" -n "$NAMESPACE" -o json > "$RAW/statefulset.json" 2> "$WORK/err" \
    || die "Cannot read StatefulSet $NAMESPACE/$STS_NAME: $(short_error "$(cat "$WORK/err")")"

  WEAVIATE_CONTAINER=$(jq -r --arg re "$WEAVIATE_IMAGE_RE" \
    '[.spec.template.spec.containers[] | select(.image | test($re)) | .name][0] // empty' "$RAW/statefulset.json")
  HTTP_PORT=$(jq -r --arg c "$WEAVIATE_CONTAINER" \
    '[.spec.template.spec.containers[] | select(.name == $c) | .ports[]? | select(.name == "http") | .containerPort][0] // 8080' \
    "$RAW/statefulset.json")
  local env_metrics env_metrics_port
  env_metrics=$(sts_env PROMETHEUS_MONITORING_ENABLED)
  env_metrics_port=$(sts_env PROMETHEUS_MONITORING_PORT)
  METRICS_ENABLED=false
  case "$env_metrics" in [Tt]rue|1|[Oo]n|[Yy]es) METRICS_ENABLED=true ;; esac
  METRICS_PORT="${env_metrics_port:-2112}"
  # Weaviate's debug port (pprof and admin endpoints): GO_PROFILING_PORT,
  # default 6060. The gate refuses to open a tunnel to it.
  local env_debug_port
  env_debug_port=$(sts_env GO_PROFILING_PORT)
  case "$env_debug_port" in ''|*[!0-9]*) ;; *) WEAVIATE_DEBUG_PORT="$env_debug_port" ;; esac
}

# Plain env value of the Weaviate container (empty if unset or from a Secret).
sts_env() {
  jq -r --arg c "$WEAVIATE_CONTAINER" --arg n "$1" \
    '.spec.template.spec.containers[] | select(.name == $c) | .env[]? | select(.name == $n) | .value // empty' \
    "$RAW/statefulset.json" 2>/dev/null | head -n 1
}

discover_pods() {
  local selector
  selector=$(jq -r '.spec.selector.matchLabels // {} | to_entries | map("\(.key)=\(.value)") | join(",")' "$RAW/statefulset.json")
  [ -n "$selector" ] || die "StatefulSet $STS_NAME has no matchLabels selector; cannot find its pods."
  kc get pods -n "$NAMESPACE" -l "$selector" -o json > "$RAW/weaviate-pods.json" 2> "$WORK/err" \
    || die "Cannot list Weaviate pods: $(short_error "$(cat "$WORK/err")")"
  WEAVIATE_PODS=$(jq -r '[.items[].metadata.name] | sort | join(" ")' "$RAW/weaviate-pods.json")

  # Module pods (text2vec-transformers, reranker, ...) in the same namespace,
  # recognised by their Weaviate images. Only names and images are read here.
  local jp='{range .items[*]}{.metadata.name}{"\t"}{range .spec.containers[*]}{.image}{" "}{end}{"\n"}{end}'
  MODULE_PODS=""
  if kc get pods -n "$NAMESPACE" -o "jsonpath=$jp" > "$RAW/pod-names.tsv" 2>/dev/null; then
    MODULE_PODS=$(awk -F '\t' -v re="$MODULE_IMAGE_RE" -v wre="$WEAVIATE_IMAGE_RE" -v skip=" $WEAVIATE_PODS " \
      '$2 ~ re && $2 !~ wre && index(skip, " " $1 " ") == 0 { print $1 }' "$RAW/pod-names.tsv" | sort | tr '\n' ' ')
    MODULE_PODS="${MODULE_PODS% }"
  fi

  # Apply --pods.
  if [ -n "$PODS_FILTER" ]; then
    local p sel_w="" sel_m=""
    for p in $(printf '%s' "$PODS_FILTER" | tr ',' ' '); do
      if list_has "$(printf '%s' "$WEAVIATE_PODS" | tr ' ' ',')" "$p"; then sel_w="$sel_w $p"
      elif list_has "$(printf '%s' "$MODULE_PODS" | tr ' ' ',')" "$p"; then sel_m="$sel_m $p"
      else warn "Pod '$p' (from --pods) is not a Weaviate or module pod in $NAMESPACE; ignoring it."
      fi
    done
    SEL_WEAVIATE_PODS="${sel_w# }"
    SEL_MODULE_PODS="${sel_m# }"
    [ -n "$SEL_WEAVIATE_PODS$SEL_MODULE_PODS" ] || die "None of the pods in --pods were found. Weaviate pods: ${WEAVIATE_PODS:-none}${MODULE_PODS:+; module pods: $MODULE_PODS}"
  else
    SEL_WEAVIATE_PODS="$WEAVIATE_PODS"
    SEL_MODULE_PODS="$MODULE_PODS"
  fi

  # Module pod objects (only the selected ones)
  local mp
  printf '{"items":[]}' > "$RAW/module-pods.json"
  for mp in $SEL_MODULE_PODS; do
    if kc get pod "$mp" -n "$NAMESPACE" -o json > "$RAW/mp.json" 2>/dev/null; then
      jq --slurpfile p "$RAW/mp.json" '.items += $p' "$RAW/module-pods.json" > "$RAW/mp2.json" \
        && mv "$RAW/mp2.json" "$RAW/module-pods.json"
    fi
  done

  # Nodes that run the selected pods
  POD_NODES=$(jq -r --arg sel " $SEL_WEAVIATE_PODS $SEL_MODULE_PODS " \
    '[.items[] | select(.metadata.name as $pn | $sel | contains(" " + $pn + " ")) | .spec.nodeName // empty] | unique | join(" ")' \
    "$RAW/weaviate-pods.json" 2>/dev/null)
  local mnodes
  mnodes=$(jq -r '[.items[].spec.nodeName // empty] | unique | join(" ")' "$RAW/module-pods.json" 2>/dev/null)
  POD_NODES=$(printf '%s %s' "$POD_NODES" "$mnodes" | tr ' ' '\n' | grep . | sort -u | tr '\n' ' ')
  POD_NODES="${POD_NODES% }"

  # Weaviate pods for cluster-wide API calls: Ready ones first, then Running.
  # The first that answers is used.
  API_PODS=$(jq -r '([.items[] | select(any(.status.conditions[]?; .type == "Ready" and .status == "True")) | .metadata.name] | sort)
      + ([.items[] | select(.status.phase == "Running") | .metadata.name] | sort)
      | reduce .[] as $p ([]; if index($p) then . else . + [$p] end) | join(" ")' "$RAW/weaviate-pods.json")
  API_POD="${API_PODS%% *}"
}

# ---------------------------------------------------------------------------
# Permission probes (all read-only GETs)
# Each sets PF_<NAME> to: ok | forbidden | unavailable | off | n/a
# ---------------------------------------------------------------------------
probe_get() {
  # probe_get <var> <kc get args...>
  local var="$1"; shift
  if kc get "$@" > /dev/null 2> "$WORK/err"; then eval "$var=ok"; return; fi
  kube_error_code "$(cat "$WORK/err")"
  case $? in 11) eval "$var=forbidden" ;; 12) eval "$var=ok" ;; *) eval "$var=unavailable" ;; esac
}

probe_permissions() {
  local first_node="${POD_NODES%% *}" first_pod="${SEL_WEAVIATE_PODS%% *}"
  [ -n "$first_pod" ] || first_pod="${SEL_MODULE_PODS%% *}"

  probe_get PF_EVENTS events -n "$NAMESPACE" --limit=1 -o name
  probe_get PF_PVC persistentvolumeclaims -n "$NAMESPACE" --limit=1 -o name
  probe_get PF_SERVICES services -n "$NAMESPACE" --limit=1 -o name
  if [ -n "$first_node" ]; then probe_get PF_NODES node "$first_node" -o name; else PF_NODES="n/a"; fi

  PF_LOGS="n/a"
  if [ -n "$first_pod" ]; then
    local cflag=""
    case " $SEL_WEAVIATE_PODS " in *" $first_pod "*) cflag="--container=$WEAVIATE_CONTAINER" ;; esac
    if kc logs -n "$NAMESPACE" "$first_pod" $cflag --tail=1 > /dev/null 2> "$WORK/err"; then
      PF_LOGS=ok
    else
      kube_error_code "$(cat "$WORK/err")"
      case $? in 11) PF_LOGS=forbidden ;; *) PF_LOGS=ok ;; esac   # e.g. container not started yet
    fi
  fi

  PF_DISK="off"
  if section_enabled disk && [ -n "$first_node" ]; then
    if kc_raw_get "/api/v1/nodes/$first_node/proxy/healthz" > /dev/null 2> "$WORK/err"; then PF_DISK=ok
    else
      kube_error_code "$(cat "$WORK/err")"
      case $? in 11) PF_DISK=forbidden ;; *) PF_DISK=unavailable ;; esac
    fi
  fi

  PF_TOP="unavailable"
  if kc_raw_get "/apis/metrics.k8s.io/v1beta1/namespaces/$NAMESPACE/pods" > /dev/null 2> "$WORK/err"; then PF_TOP=ok
  else
    kube_error_code "$(cat "$WORK/err")"
    [ $? -eq 11 ] && PF_TOP=forbidden
  fi

  PF_HELM="off"
  if [ "$INCLUDE_HELM" = "1" ]; then
    probe_get PF_HELM secrets -n "$NAMESPACE" -l owner=helm --limit=1 -o name
  fi
}

# ---------------------------------------------------------------------------
# Weaviate API connection (port-forward to one pod, or --weaviate-url)
# ---------------------------------------------------------------------------

# api_open_tunnel <pods>: tunnel to the first pod that answers. Sets API_POD,
# API_TUNNEL_PID and WEAVIATE_BASE, or PF_WEAVIATE and WEAVIATE_ERROR on failure.
api_open_tunnel() {
  local p rc code
  TUNNEL_ERROR=""
  for p in $1; do
    tunnel_open "$p" "$HTTP_PORT"; rc=$?
    if [ "$rc" -eq 11 ]; then
      PF_WEAVIATE="forbidden"; PF_PORTFORWARD="forbidden"; WEAVIATE_ERROR="port-forward not allowed"
      return 1
    fi
    if [ "$rc" -eq 0 ]; then
      code=$(HTTP_TIMEOUT=10 http_get "http://127.0.0.1:${TUNNEL_PORTS}/v1/.well-known/live" "$RAW/live-probe.out" noauth)
      if [ "$code" != "000" ]; then
        API_POD="$p"; API_TUNNEL_PID="$TUNNEL_PID"; WEAVIATE_BASE="http://127.0.0.1:${TUNNEL_PORTS}"
        return 0
      fi
      TUNNEL_ERROR="pod $p does not answer"
      tunnel_close "$TUNNEL_PID"
    fi
    log_line WARN "no connection through $p: ${TUNNEL_ERROR:-unknown}"
  done
  PF_WEAVIATE="unavailable"; WEAVIATE_ERROR="port-forward failed: ${TUNNEL_ERROR:-no pod answered}"
  return 1
}

# api_reconnect: the API tunnel was lost (pod restart, dropped connection).
# Open a new one, trying the other pods first. At most 3 times per run.
api_reconnect() {
  [ "${CONNECT_MODE:-}" = "port-forward" ] || return 1
  [ "${API_RECONNECTS:-0}" -lt 3 ] || return 1
  API_RECONNECTS=$(( ${API_RECONNECTS:-0} + 1 ))
  tunnel_close "${API_TUNNEL_PID:-}"
  local p before="" after="" seen=0
  for p in $API_PODS; do
    if [ "$p" = "$API_POD" ]; then seen=1
    elif [ "$seen" = 1 ]; then after="$after $p"
    else before="$before $p"; fi
  done
  info "Lost the connection to $API_POD; reconnecting..."
  api_open_tunnel "$after $before $API_POD"
}
connect_weaviate() {
  PF_WEAVIATE="off"
  CLEARTEXT_URL=0
  WEAVIATE_VERSION=""
  if ! section_enabled weaviate && ! section_enabled metrics; then return; fi

  if [ -n "$WEAVIATE_URL" ]; then
    WEAVIATE_BASE="${WEAVIATE_URL%/}"
    CONNECT_MODE="url"
    if url_is_cleartext_remote "$WEAVIATE_BASE"; then
      CLEARTEXT_URL=1
      [ -n "${WEAVIATE_API_KEY:-}" ] && confirm_cleartext_key
    fi
  else
    CONNECT_MODE="port-forward"
    if [ -z "$API_POD" ]; then PF_WEAVIATE="unavailable"; WEAVIATE_ERROR="no running Weaviate pod"; return; fi
    api_open_tunnel "$API_PODS" || return
  fi

  local code
  code=$(http_get "$WEAVIATE_BASE/v1/meta" "$RAW/meta-probe.json")
  if [ "$code" = "401" ] && [ -z "${WEAVIATE_API_KEY:-}" ] && is_interactive && [ "$ASSUME_YES" != "1" ]; then
    say ""
    say "  Weaviate needs an API key. Use a read-only key if you have one."
    [ "${CLEARTEXT_URL:-0}" = 1 ] && say "  Note: $WEAVIATE_URL uses http://, so the key is sent unencrypted."
    printf '  Weaviate API key (input hidden, Enter to skip): ' >&2
    read -r -s WEAVIATE_API_KEY
    say ""
    api_key_ok || die "The API key contains a control character. Run again and paste the key only."
    export WEAVIATE_API_KEY
    [ -n "$WEAVIATE_API_KEY" ] && code=$(http_get "$WEAVIATE_BASE/v1/meta" "$RAW/meta-probe.json")
  fi
  case "$code" in
    200) PF_WEAVIATE=ok
         WEAVIATE_VERSION=$(jq -r '.version // empty' "$RAW/meta-probe.json" 2>/dev/null) ;;
    401) PF_WEAVIATE="forbidden"; WEAVIATE_ERROR="API key missing or not accepted (set WEAVIATE_API_KEY)" ;;
    403) PF_WEAVIATE="forbidden"; WEAVIATE_ERROR="the API key has no read permission" ;;
    000) PF_WEAVIATE="unavailable"; WEAVIATE_ERROR="could not connect to $WEAVIATE_BASE" ;;
    *)   PF_WEAVIATE="unavailable"; WEAVIATE_ERROR="HTTP $code from /v1/meta" ;;
  esac
}

# url_is_cleartext_remote <url>: true for http:// to a host that is not this
# machine (localhost, 127.x, [::1]). The API key would cross the network
# unencrypted.
url_is_cleartext_remote() {
  local h
  case "$1" in http://*) ;; *) return 1 ;; esac
  h="${1#http://}"; h="${h%%/*}"; h="${h##*@}"
  case "$h" in \[*) h="${h%%]*}]" ;; *) h="${h%%:*}" ;; esac
  case "$h" in localhost|127.*|\[::1\]) return 1 ;; esac
  return 0
}

# Before the API key is sent over plain http: warn, and ask when someone is
# at the terminal and --yes was not given.
confirm_cleartext_key() {
  warn "$WEAVIATE_URL uses http:// to another machine: the API key is sent unencrypted. Use https:// if you can."
  if [ "$ASSUME_YES" != "1" ] && is_interactive; then
    printf '  Send the API key over http anyway? [y/N] ' >&2
    local answer
    read -r answer
    case "$answer" in
      y|Y|yes|YES|Yes) ;;
      *) die "Stopped before sending the API key. Use an https:// address, or leave out --weaviate-url to use a port-forward." ;;
    esac
  fi
}

# probe_profiling: with --include-profiling, can the debug port be read?
# Weaviate: GO_PROFILING_DISABLE stops the listener; DEBUG_ENDPOINTS_ENABLED
# off makes it answer 404 (the default since 1.36.18).
probe_profiling() {
  PF_PROFILING="none"
  PROFILING_ERROR=""
  [ "$INCLUDE_PROFILING" = 1 ] || return 0
  if ! section_enabled weaviate; then PF_PROFILING="skipped"; return 0; fi
  WEAVIATE_DEBUG_PORT="${WEAVIATE_DEBUG_PORT:-6060}"
  if [ -z "$API_POD" ]; then PF_PROFILING="unavailable"; PROFILING_ERROR="no running Weaviate pod"; return 0; fi
  case "$(sts_env GO_PROFILING_DISABLE)" in
    [Tt]rue|1|[Oo]n|[Yy]es) PF_PROFILING="off"; PROFILING_ERROR="the debug port is disabled in Weaviate (GO_PROFILING_DISABLE)"; return 0 ;;
  esac
  tunnel_open "$API_POD" "$WEAVIATE_DEBUG_PORT"
  case $? in
    0) ;;
    11) PF_PROFILING="forbidden"; PROFILING_ERROR="port-forward not allowed"; return 0 ;;
    *) PF_PROFILING="unavailable"; PROFILING_ERROR="port-forward failed: $TUNNEL_ERROR"; return 0 ;;
  esac
  local code
  code=$(HTTP_TIMEOUT=15 http_get "http://127.0.0.1:${TUNNEL_PORTS}/debug/pprof/threadcreate" "$RAW/profile-probe.out" noauth)
  tunnel_close "$TUNNEL_PID"
  case "$code" in
    200) PF_PROFILING="ok" ;;
    404) PF_PROFILING="off"; PROFILING_ERROR="debug endpoints are off in Weaviate (set DEBUG_ENDPOINTS_ENABLED=true)" ;;
    000) PF_PROFILING="unavailable"; PROFILING_ERROR="no answer on debug port $WEAVIATE_DEBUG_PORT" ;;
    *)   PF_PROFILING="unavailable"; PROFILING_ERROR="HTTP $code from the debug port" ;;
  esac
}

# ---------------------------------------------------------------------------
# Preflight table and approval
# ---------------------------------------------------------------------------
_row() {
  # _row <label> <status> <text>
  local mark
  case "$2" in
    ok)  mark="${C_GRN}✔${C_RST}" ;;
    off) mark="${C_DIM}–${C_RST}" ;;
    *)   mark="${C_YEL}✘${C_RST}" ;;
  esac
  printf '  %-16s %s %s\n' "$1" "$mark" "$3" >&2
}

_count_words() { set -- $1; echo $#; }

show_preflight() {
  local nw nm
  nw=$(_count_words "$SEL_WEAVIATE_PODS"); nm=$(_count_words "$SEL_MODULE_PODS")
  heading "Weaviate support bundle: preflight"
  printf '  %-16s %s\n' "Kube context" "$CONTEXT_NAME (Kubernetes $SERVER_VERSION)" >&2
  printf '  %-16s %s\n' "Namespace" "$NAMESPACE  (StatefulSet: $STS_NAME)" >&2
  printf '  %-16s %s\n' "Weaviate" "${WEAVIATE_VERSION:+v$WEAVIATE_VERSION · }$nw pod(s): ${SEL_WEAVIATE_PODS:-none}" >&2
  [ "$nm" -gt 0 ] && printf '  %-16s %s\n' "Module pods" "$SEL_MODULE_PODS" >&2
  if [ "$CONNECT_MODE" = "url" ]; then
    printf '  %-16s %s%s\n' "Connect via" "$WEAVIATE_URL" \
      "$([ "${CLEARTEXT_URL:-0}" = 1 ] && [ -n "${WEAVIATE_API_KEY:-}" ] && printf ' (http: the API key is sent unencrypted)')" >&2
  else
    printf '  %-16s %s\n' "Connect via" "temporary port-forward to $API_POD (closed at the end)" >&2
  fi
  printf '  %-16s %s\n' "Output" "$OUTPUT_DIR/$BUNDLE_NAME.tar.gz" >&2
  say ""

  local k8s_status="ok" k8s_text="can read the StatefulSet and pods"
  local missing=""
  [ "$PF_EVENTS" = "forbidden" ] && missing="$missing events"
  [ "$PF_PVC" = "forbidden" ] && missing="$missing volumes"
  [ "$PF_NODES" = "forbidden" ] && missing="$missing nodes"
  [ "$PF_SERVICES" = "forbidden" ] && missing="$missing services"
  if [ -n "$missing" ]; then k8s_status="partial"; k8s_text="can read the StatefulSet and pods; no permission for:$missing"; fi
  if section_enabled kubernetes; then _row "Kubernetes" "$k8s_status" "$k8s_text"; else _row "Kubernetes" off "skipped (--skip/--only)"; fi

  if section_enabled weaviate; then
    case "$PF_WEAVIATE" in
      ok) _row "Weaviate API" ok "connected${WEAVIATE_API_KEY:+, API key accepted}" ;;
      *)  _row "Weaviate API" "$PF_WEAVIATE" "${WEAVIATE_ERROR:-not available} → will skip" ;;
    esac
  else _row "Weaviate API" off "skipped (--skip/--only)"; fi

  if section_enabled logs; then
    case "$PF_LOGS" in
      ok) _row "Logs" ok "$((nw + nm)) pod(s), current + previous container, $(log_window_text)" ;;
      *)  _row "Logs" "$PF_LOGS" "no permission to read pod logs → will skip" ;;
    esac
  else _row "Logs" off "skipped (--skip/--only)"; fi

  if section_enabled metrics; then
    if [ "$METRICS_ENABLED" != "true" ]; then _row "Metrics" off "not enabled in Weaviate (PROMETHEUS_MONITORING_ENABLED) → will skip"
    elif [ "${PF_PORTFORWARD:-}" = "forbidden" ]; then _row "Metrics" forbidden "needs port-forward → will skip"
    else _row "Metrics" ok "2 snapshots per pod, ${METRICS_INTERVAL}s apart (key metrics only)"; fi
  else _row "Metrics" off "skipped (--skip/--only)"; fi

  case "$PF_DISK" in
    ok)        _row "Disk usage" ok "used / available per volume (reads kubelet stats via nodes/proxy; --skip disk to opt out)" ;;
    off)       _row "Disk usage" off "skipped (--skip/--only)" ;;
    forbidden) _row "Disk usage" forbidden "needs 'nodes/proxy' permission → will skip (see docs/permissions.md)" ;;
    *)         _row "Disk usage" unavailable "node stats not reachable → will skip" ;;
  esac

  case "$PF_TOP" in
    ok) _row "CPU/memory now" ok "from metrics-server" ;;
    *)  _row "CPU/memory now" off "metrics-server not available → will skip" ;;
  esac

  case "$PF_HELM" in
    off)       _row "Helm" off "off (add --include-helm)" ;;
    ok)        _row "Helm" ok "chart version, history, values (redacted)" ;;
    forbidden) _row "Helm" forbidden "needs read access to Secrets → will skip" ;;
    *)         _row "Helm" unavailable "not available → will skip" ;;
  esac

  case "$PF_PROFILING" in
    none)    _row "Profiling" off "off (add --include-profiling)" ;;
    skipped) _row "Profiling" off "skipped (needs the weaviate section)" ;;
    ok)      _row "Profiling" ok "CPU for ${PROFILE_SECONDS}s + instant profiles per pod$([ "$INCLUDE_HEAP" = 1 ] && printf ', heap'); adds some CPU load for ${PROFILE_SECONDS}s" ;;
    *)       _row "Profiling" "$PF_PROFILING" "$PROFILING_ERROR → will skip" ;;
  esac

  if [ "$ANONYMIZE" = "1" ]; then _row "Anonymize" ok "tenant and user names replaced"
  else _row "Anonymize" off "off (add --anonymize)"; fi

  say ""
  say "  ${C_BLD}Nothing in your cluster or in Weaviate will be changed.${C_RST}"
  say "  Secrets are redacted. You can review everything before sending."
  if [ "$PF_PROFILING" = "ok" ]; then
    say "  Binary profiles (.pprof) cannot be redacted or anonymized: they hold function"
    say "  names and profile labels. Treat them as sensitive."
    [ "$INCLUDE_HEAP" = 1 ] && say "  The heap profile is included: leave out --include-heap if you do not need it."
  fi
}

ask_approval() {
  if [ "$ASSUME_YES" = "1" ]; then return 0; fi
  if ! is_interactive; then
    die "No terminal to ask for confirmation. Run again with --yes to skip the question."
  fi
  printf '\n  Proceed? [y/N] ' >&2
  local answer
  read -r answer
  case "$answer" in
    y|Y|yes|YES|Yes) return 0 ;;
    *) say ""; say "  Cancelled. Nothing was collected."; exit 0 ;;
  esac
}
