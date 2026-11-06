# shellcheck shell=bash
# lib/common.sh: shared helpers for terminal output, the temporary workspace,
# step tracking and cleanup.
#
# Sourced by collect.sh. Must stay compatible with bash 3.2 (macOS default):
# no associative arrays, no ${var,,}, no mapfile, no `set -u` with empty arrays.

TOOL_NAME="weaviate-support-bundle"
TOOL_VERSION="1.1.0"
BUNDLE_SCHEMA_VERSION="1"

# ---------------------------------------------------------------------------
# Terminal output (all human-facing output goes to stderr)
# ---------------------------------------------------------------------------
if [ -t 2 ] && [ -z "${NO_COLOR:-}" ]; then
  C_RED=$'\033[31m'; C_YEL=$'\033[33m'; C_GRN=$'\033[32m'
  C_DIM=$'\033[2m';  C_BLD=$'\033[1m';  C_RST=$'\033[0m'
else
  C_RED=""; C_YEL=""; C_GRN=""; C_DIM=""; C_BLD=""; C_RST=""
fi

log_line() {
  # Append to the run log that ships in the bundle (run.log). Never log secrets.
  if [ -n "${WORK:-}" ] && [ -d "$WORK" ]; then
    printf '%s %-5s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$1" "$2" >> "$WORK/run.log"
  fi
}

say()     { printf '%s\n' "$*" >&2; }
heading() { printf '\n%s%s%s\n' "$C_BLD" "$*" "$C_RST" >&2; log_line INFO "== $* =="; }
info()    { printf '  %s\n' "$*" >&2; log_line INFO "$*"; }
ok()      { printf '  %s✔%s %s\n' "$C_GRN" "$C_RST" "$*" >&2; log_line OK "$*"; }
note()    { printf '  %s–%s %s\n' "$C_DIM" "$C_RST" "$*" >&2; log_line NOTE "$*"; }
warn()    { printf '  %s!%s %s\n' "$C_YEL" "$C_RST" "$*" >&2; log_line WARN "$*"; }
fail()    { printf '  %s✘%s %s\n' "$C_RED" "$C_RST" "$*" >&2; log_line ERROR "$*"; }
die()     { printf '\n%sError:%s %s\n' "$C_RED" "$C_RST" "$*" >&2; log_line ERROR "$*"; exit 1; }

is_interactive() { [ -t 0 ] && [ -t 2 ]; }

# ---------------------------------------------------------------------------
# Temporary workspace
#
# Everything is collected into $WORK (a private temp folder, mode 700) and only
# moved to the output folder after redaction. The trap removes $WORK on exit,
# on Ctrl-C and on errors, so nothing unredacted is ever left behind.
# ---------------------------------------------------------------------------
make_workspace() {
  umask 077
  WORK=$(mktemp -d "${TMPDIR:-/tmp}/weaviate-support-bundle.XXXXXX") \
    || die "Could not create a temporary folder."
  STAGE="$WORK/bundle"      # the bundle being built (copied out at the end)
  RAW="$WORK/raw"           # raw API responses, never copied out
  mkdir -p "$STAGE" "$RAW"
  : > "$WORK/run.log"
  : > "$WORK/steps.jsonl"
  : > "$WORK/tunnel-pids"
  : > "$WORK/secret-values"     # literal secret values to scrub everywhere
  : > "$WORK/redacted-fields"   # names of fields/env vars that were redacted
}

cleanup() {
  local rc=$?
  trap - EXIT INT TERM
  stop_all_tunnels 2>/dev/null
  if [ -n "${WORK:-}" ] && [ -d "$WORK" ]; then
    rm -rf "$WORK"
  fi
  exit "$rc"
}

on_interrupt() {
  say ""
  say "Interrupted. Closing tunnels and removing temporary files..."
  exit 130
}

# ---------------------------------------------------------------------------
# Step tracking
#
# Every collector runs through run_step, which records its outcome in
# manifest.json. A failing step never stops the run.
#
# Collector return codes:
#   0 ok | 10 skipped | 11 forbidden | 12 not_found | 13 unavailable | * error
# Collectors may describe the outcome in one line with: step_detail "text"
# ---------------------------------------------------------------------------
step_detail() { printf '%s' "$*" > "$WORK/.step-detail"; }

record_step() {
  jq -cn --arg section "$1" --arg name "$2" --arg status "$3" --arg detail "$4" \
    '{section: $section, name: $name, status: $status, detail: $detail}' >> "$WORK/steps.jsonl"
}

run_step() {
  local section="$1" name="$2"; shift 2
  : > "$WORK/.step-detail"
  "$@"
  local rc=$? status detail
  detail=$(cat "$WORK/.step-detail" 2>/dev/null)
  case "$rc" in
    0)  status=ok ;;
    10) status=skipped ;;
    11) status=forbidden ;;
    12) status=not_found ;;
    13) status=unavailable ;;
    *)  status=error ;;
  esac
  record_step "$section" "$name" "$status" "$detail"
  local label="$name${detail:+ ($detail)}"
  case "$status" in
    ok)          ok "$label" ;;
    skipped)     note "$label" ;;
    not_found)   note "$label" ;;
    forbidden)   warn "$name: no permission${detail:+ ($detail)}" ;;
    unavailable) warn "$label" ;;
    *)           fail "$name failed${detail:+ ($detail)}" ;;
  esac
  return 0
}

# Classify a kubectl error message into a collector return code.
kube_error_code() {
  local msg="$1"
  case "$msg" in
    *[Ff]orbidden*|*"cannot get"*|*"cannot list"*|*"cannot create"*) return 11 ;;
    *NotFound*|*"not found"*|*"doesn't have a resource type"*|*"could not find the requested resource"*) return 12 ;;
    *"ServiceUnavailable"*|*"service unavailable"*|*"the server is currently unable"*) return 13 ;;
    *) return 1 ;;
  esac
}

# Short, single-line version of an error message for the manifest.
short_error() {
  printf '%s' "$1" | tr '\n' ' ' | sed 's/^error: //; s/^Error from server ([A-Za-z]*): //' | cut -c1-200
}

# ---------------------------------------------------------------------------
# Sections (--only / --skip)
# ---------------------------------------------------------------------------
section_enabled() {
  if [ -n "${ONLY_SECTIONS:-}" ]; then
    case ",$ONLY_SECTIONS," in *",$1,"*) ;; *) return 1 ;; esac
  fi
  case ",${SKIP_SECTIONS:-}," in *",$1,"*) return 1 ;; esac
  return 0
}

# ---------------------------------------------------------------------------
# Small utilities
# ---------------------------------------------------------------------------
now_utc()   { date -u +%Y-%m-%dT%H:%M:%SZ; }
stamp_utc() { date -u +%Y%m%d-%H%M%S; }

# Safe file name for a Kubernetes object name (they are already DNS-safe,
# this only guards against surprises).
safe_name() { printf '%s' "$1" | tr -c 'A-Za-z0-9._-' '_'; }

# Pretty-print JSON from stdin into a file. Returns non-zero if it is not JSON.
write_json() {
  local dest="$1"
  mkdir -p "$(dirname "$dest")"
  jq '.' > "$dest.tmp" 2>/dev/null && mv "$dest.tmp" "$dest" || { rm -f "$dest.tmp"; return 1; }
}

# Comma-separated list contains value?
list_has() { case ",$1," in *",$2,"*) return 0 ;; esac; return 1; }
