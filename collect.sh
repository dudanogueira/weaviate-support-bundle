#!/usr/bin/env bash
#
# Weaviate support bundle
#
# Collects diagnostic information about a Weaviate cluster running on
# Kubernetes into one archive you can review and send to Weaviate support.
#
# Read-only: it never changes anything in your cluster or in Weaviate.
# It never collects your objects or vectors. Secrets are redacted.
#
#   ./collect.sh --help
#
# Step-by-step guide: USAGE.md

set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$SCRIPT_DIR/lib"
JQ_LIB="$LIB_DIR/jq"

# shellcheck source=lib/common.sh
. "$LIB_DIR/common.sh"
# shellcheck source=lib/guard.sh
. "$LIB_DIR/guard.sh"
# shellcheck source=lib/discover.sh
. "$LIB_DIR/discover.sh"
# shellcheck source=lib/kubernetes.sh
. "$LIB_DIR/kubernetes.sh"
# shellcheck source=lib/weaviate.sh
. "$LIB_DIR/weaviate.sh"
# shellcheck source=lib/logs.sh
. "$LIB_DIR/logs.sh"
# shellcheck source=lib/metrics.sh
. "$LIB_DIR/metrics.sh"
# shellcheck source=lib/disk.sh
. "$LIB_DIR/disk.sh"
# shellcheck source=lib/helm.sh
. "$LIB_DIR/helm.sh"
# shellcheck source=lib/summary.sh
. "$LIB_DIR/summary.sh"
# shellcheck source=lib/finalize.sh
. "$LIB_DIR/finalize.sh"

ALL_SECTIONS="kubernetes,weaviate,logs,metrics,disk"

usage() {
  cat <<'EOF'
Weaviate support bundle: collect diagnostics from a Weaviate cluster on Kubernetes.

Read-only: nothing in your cluster or in Weaviate is changed. No objects or
vectors are collected. Secrets are redacted. You review the result before sending.

Usage:
  ./collect.sh [options]

Where is Weaviate?
  -n, --namespace NAME       Namespace of the Weaviate StatefulSet (default: found automatically)
      --statefulset NAME     StatefulSet name, if there is more than one (default: found automatically)
      --context NAME         kubectl context to use (default: the current context)

How to reach the Weaviate API
      (default)              A temporary port-forward to one Weaviate pod, closed at the end
      --weaviate-url URL     Use this URL instead (load balancer, ingress, IP, or your own port-forward)
      --insecure             Skip TLS certificate checks for --weaviate-url
  Credentials: set the WEAVIATE_API_KEY environment variable (an API key or an OIDC
  access token). If it is not set and Weaviate needs one, you are asked for it
  (input hidden). Use a read-only key if you have one.

What to collect
      --pods LIST            Only these pods, comma-separated (default: all Weaviate and module pods)
      --only LIST            Only these sections: kubernetes,weaviate,logs,metrics,disk
      --skip LIST            All sections except these
      --include-helm         Also read Helm release info (needs read access to Secrets; values are redacted)
      --helm-release NAME    Helm release name, if it cannot be found automatically

Logs
      --since DURATION       Logs from the last DURATION, e.g. 30m, 6h, 24h, 3d (default: 24h)
      --from TIME            Logs from TIME (UTC), e.g. 2026-11-01T08:00 or 2026-11-01
      --to TIME              Logs until TIME (UTC). Use with --from.
      --max-log-mb N         Size cap per container log in MB (default: 100)

Privacy
      --anonymize            Replace tenant names and user names with placeholders
                             (the mapping stays on your machine)

Other
      --metrics-interval N   Seconds between the two metrics snapshots (default: 30)
  -o, --output DIR           Where to write the bundle (default: current folder)
      --preflight-only       Show what would be collected, then stop (nothing is collected)
  -y, --yes                  Do not ask for confirmation (for scripts)
  -h, --help                 Show this help
      --version              Show the tool version

Examples:
  ./collect.sh
  ./collect.sh -n weaviate --since 6h
  ./collect.sh -n weaviate --pods weaviate-1,weaviate-2 --only logs
  ./collect.sh -n weaviate --from 2026-11-01T08:00 --to 2026-11-01T12:00
  WEAVIATE_API_KEY=... ./collect.sh -n weaviate --weaviate-url https://weaviate.example.com
EOF
}

# Normalise a time to RFC 3339 UTC: 2026-11-01 | 2026-11-01T08:00 | 2026-11-01 08:00:00 [Z]
normalize_time() {
  local t
  t=$(printf '%s' "$1" | tr ' ' 'T' | sed 's/Z$//')
  case "$t" in
    [0-9][0-9][0-9][0-9]-[0-1][0-9]-[0-3][0-9]) t="${t}T00:00:00" ;;
    [0-9][0-9][0-9][0-9]-[0-1][0-9]-[0-3][0-9]T[0-2][0-9]:[0-5][0-9]) t="${t}:00" ;;
    [0-9][0-9][0-9][0-9]-[0-1][0-9]-[0-3][0-9]T[0-2][0-9]:[0-5][0-9]:[0-5][0-9]) ;;
    *) return 1 ;;
  esac
  printf '%sZ' "$t"
}

validate_sections() {
  local s
  for s in $(printf '%s' "$1" | tr ',' ' '); do
    list_has "$ALL_SECTIONS" "$s" || die "Unknown section '$s'. Sections: $ALL_SECTIONS"
  done
}

need_value() { [ -n "${2:-}" ] && [ "${2#-}" = "$2" ] || die "Option $1 needs a value. See --help."; }

parse_args() {
  NAMESPACE=""; STS_NAME=""; KUBE_CONTEXT=""; PODS_FILTER=""; WEAVIATE_URL=""; INSECURE_TLS=0
  LOG_SINCE="24h"; LOG_FROM=""; LOG_TO=""; MAX_LOG_MB=100
  ONLY_SECTIONS=""; SKIP_SECTIONS=""; INCLUDE_HELM=0; HELM_RELEASE=""; ANONYMIZE=0
  METRICS_INTERVAL=30; OUTPUT_DIR="."; ASSUME_YES=0; PREFLIGHT_ONLY=0
  local since_set=0
  while [ $# -gt 0 ]; do
    case "$1" in
      -n|--namespace)       need_value "$1" "${2:-}"; NAMESPACE="$2"; shift 2 ;;
      --statefulset)        need_value "$1" "${2:-}"; STS_NAME="$2"; shift 2 ;;
      --context)            need_value "$1" "${2:-}"; KUBE_CONTEXT="$2"; shift 2 ;;
      --pods)               need_value "$1" "${2:-}"; PODS_FILTER="$2"; shift 2 ;;
      --weaviate-url)       need_value "$1" "${2:-}"; WEAVIATE_URL="$2"; shift 2 ;;
      --insecure)           INSECURE_TLS=1; shift ;;
      --since)              need_value "$1" "${2:-}"; LOG_SINCE="$2"; since_set=1; shift 2 ;;
      --from)               need_value "$1" "${2:-}"; LOG_FROM="$2"; shift 2 ;;
      --to)                 need_value "$1" "${2:-}"; LOG_TO="$2"; shift 2 ;;
      --max-log-mb)         need_value "$1" "${2:-}"; MAX_LOG_MB="$2"; shift 2 ;;
      --only)               need_value "$1" "${2:-}"; ONLY_SECTIONS="$2"; shift 2 ;;
      --skip)               need_value "$1" "${2:-}"; SKIP_SECTIONS="$2"; shift 2 ;;
      --include-helm)       INCLUDE_HELM=1; shift ;;
      --helm-release)       need_value "$1" "${2:-}"; HELM_RELEASE="$2"; INCLUDE_HELM=1; shift 2 ;;
      --anonymize)          ANONYMIZE=1; shift ;;
      --metrics-interval)   need_value "$1" "${2:-}"; METRICS_INTERVAL="$2"; shift 2 ;;
      -o|--output)          need_value "$1" "${2:-}"; OUTPUT_DIR="$2"; shift 2 ;;
      --preflight-only)     PREFLIGHT_ONLY=1; shift ;;
      -y|--yes)             ASSUME_YES=1; shift ;;
      -h|--help)            usage; exit 0 ;;
      --version)            printf '%s %s\n' "$TOOL_NAME" "$TOOL_VERSION"; exit 0 ;;
      *)                    die "Unknown option '$1'. See --help." ;;
    esac
  done

  [ -n "$ONLY_SECTIONS" ] && validate_sections "$ONLY_SECTIONS"
  [ -n "$SKIP_SECTIONS" ] && validate_sections "$SKIP_SECTIONS"

  case "$LOG_SINCE" in
    *[0-9]d) LOG_SINCE="$(( ${LOG_SINCE%d} * 24 ))h" ;;
  esac
  printf '%s' "$LOG_SINCE" | grep -Eq '^[0-9]+[smh]$' || die "--since must look like 30m, 6h, 24h or 3d."

  if [ -n "$LOG_FROM" ]; then
    [ "$since_set" = 0 ] || die "Use either --since or --from/--to, not both."
    LOG_FROM=$(normalize_time "$LOG_FROM") || die "--from must look like 2026-11-01 or 2026-11-01T08:00 (UTC)."
  fi
  if [ -n "$LOG_TO" ]; then
    [ -n "$LOG_FROM" ] || die "--to needs --from."
    LOG_TO=$(normalize_time "$LOG_TO") || die "--to must look like 2026-11-01 or 2026-11-01T12:00 (UTC)."
    [ "$LOG_TO" \> "$LOG_FROM" ] || die "--to must be after --from."
  fi

  printf '%s' "$METRICS_INTERVAL" | grep -Eq '^[0-9]+$' && [ "$METRICS_INTERVAL" -ge 5 ] && [ "$METRICS_INTERVAL" -le 600 ] \
    || die "--metrics-interval must be a number of seconds between 5 and 600."
  printf '%s' "$MAX_LOG_MB" | grep -Eq '^[0-9]+$' && [ "$MAX_LOG_MB" -ge 1 ] || die "--max-log-mb must be a positive number."

  if [ -n "$WEAVIATE_URL" ]; then
    case "$WEAVIATE_URL" in http://*|https://*) ;; *) die "--weaviate-url must start with http:// or https://" ;; esac
  fi
  [ -n "$KUBE_CONTEXT" ] && KC_GLOBAL_ARGS="--context=$KUBE_CONTEXT"
}

main() {
  parse_args "$@"
  check_prerequisites

  TOOL_PID=$$
  make_workspace
  trap cleanup EXIT
  trap on_interrupt INT TERM

  mkdir -p "$OUTPUT_DIR" 2>/dev/null || die "Cannot create output folder '$OUTPUT_DIR'."
  OUTPUT_DIR=$(cd "$OUTPUT_DIR" && pwd)
  CREATED_AT=$(now_utc)
  BUNDLE_NAME="weaviate-support-bundle-$(stamp_utc)"
  CONNECT_MODE="port-forward"

  heading "Checking access (read-only)"
  info "Finding the Weaviate cluster..."
  discover_cluster
  discover_statefulset
  discover_pods
  info "Checking what this account can read..."
  probe_permissions
  connect_weaviate

  # Secrets we already know, so they are scrubbed from every file.
  jq -L "$JQ_LIB" -r 'include "redact"; env_secret_values[]' "$RAW/statefulset.json" >> "$WORK/secret-values" 2>/dev/null
  [ -n "${WEAVIATE_API_KEY:-}" ] && printf '%s\n' "$WEAVIATE_API_KEY" >> "$WORK/secret-values"

  show_preflight
  if [ "$PREFLIGHT_ONLY" = 1 ]; then
    tunnel_close "${API_TUNNEL_PID:-}"
    say ""
    say "  Preflight only: nothing was collected."
    exit 0
  fi
  ask_approval

  log_line INFO "approved; collecting"
  section_enabled kubernetes && collect_kubernetes
  section_enabled weaviate && collect_weaviate
  collect_pod_probes
  section_enabled logs && collect_logs
  section_enabled disk && collect_disk_usage
  [ "$INCLUDE_HELM" = 1 ] && collect_helm
  tunnel_close "${API_TUNNEL_PID:-}"

  write_manifest
  write_summary
  scrub_bundle
  pack_bundle
  print_done
}

main "$@"
