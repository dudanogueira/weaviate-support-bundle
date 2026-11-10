#!/usr/bin/env bash
#
# Read a Weaviate support bundle made by collect.sh: an overview first, then
# single files, log searches and jq queries.
#
# Works on the .tar.gz or on its unpacked folder. Read-only: it never unpacks
# files to disk, never changes the bundle, and never contacts a cluster or
# Weaviate. It only reads files listed in the bundle's manifest.json.
#
# Requires bash 3.2+, jq 1.6+, tar, gzip, awk and grep.

set -o pipefail

PAGE=300
MAX_TAIL=1000
MAX_MATCHES=200
SHOW_LINE_CHARS=2000
SEARCH_LINE_CHARS=500
KNOWN_SCHEMA="1"

usage() {
  cat <<'EOF'
Read a Weaviate support bundle (the .tar.gz or its folder). Read-only.

Usage:
  read-bundle.sh BUNDLE                        Overview: run details, gaps, red flags, logs
  read-bundle.sh BUNDLE --files                Every file in the bundle, with its size
  read-bundle.sh BUNDLE --show FILE [LINE]     A file, 300 lines at a time, from LINE (default 1)
  read-bundle.sh BUNDLE --tail FILE [N]        The last N lines of a file (default 100, max 1000)
  read-bundle.sh BUNDLE --query FILE FILTER    A jq filter on a JSON file
  read-bundle.sh BUNDLE --search REGEX [FILE]  Lines matching REGEX in all logs, or in FILE
                                               (extended regex, case-insensitive)

FILE is a path inside the bundle, as listed by --files, e.g. SUMMARY.md or
pods/weaviate-0/logs/weaviate.log.
EOF
}

die() { printf 'read-bundle: %s\n' "$*" >&2; exit 1; }

# Bundle text is untrusted: drop control characters (terminal escapes and
# similar), keep tabs and newlines.
clean() { LC_ALL=C tr -d '\000-\010\013-\037\177'; }

is_number() { case "$1" in ''|*[!0-9]*) return 1 ;; *) return 0 ;; esac; }

open_bundle() {
  local src="$1" list
  case "$src" in
    *.anonymization-map.txt)
      die "this is the anonymization map. It stays with the user and is never read." ;;
  esac
  if [ -d "$src" ]; then
    MODE=dir
    ROOT=$(cd "$src" && pwd -P) || die "cannot open $src"
    BUNDLE_NAME=$(basename "$ROOT")
    [ -f "$ROOT/manifest.json" ] && [ ! -L "$ROOT/manifest.json" ] \
      || die "$src is not a support bundle folder (no manifest.json)."
  elif [ -f "$src" ]; then
    MODE=tar
    ARCHIVE="$src"
    list=$(tar -tzf "$src" 2>/dev/null) || die "$src is not a readable .tar.gz file."
    TOP=$(printf '%s\n' "$list" | head -1 | cut -d/ -f1)
    printf '%s' "$TOP" | grep -qE '^weaviate-support-bundle-[A-Za-z0-9._-]+$' \
      || die "$src is not a support bundle archive (unexpected top folder)."
    if printf '%s\n' "$list" | grep -vE "^$TOP(/|$)" | grep -q .; then
      die "$src has files outside its top folder; not reading it."
    fi
    if printf '%s\n' "$list" | grep -qE '(^|/)\.\.(/|$)'; then
      die "$src has '..' in a file path; not reading it."
    fi
    if tar -tvzf "$src" 2>/dev/null | cut -c1 | grep -qv '^[-d]$'; then
      die "$src contains links or special files; not reading it."
    fi
    BUNDLE_NAME="$TOP"
  else
    die "$src not found."
  fi
  MANIFEST=$(raw_member manifest.json) || die "cannot read manifest.json."
  printf '%s' "$MANIFEST" | jq -e 'type == "object"' > /dev/null 2>&1 \
    || die "manifest.json is not valid JSON."
}

raw_member() {
  if [ "$MODE" = dir ]; then cat "$ROOT/$1"; else tar -xzOf "$ARCHIVE" "$TOP/$1" 2>/dev/null; fi
}

listed_files() { printf '%s' "$MANIFEST" | jq -r '.files[]?.path | strings'; }

# Only plain files listed in the manifest are read, and in a folder only
# files that are really inside it (no symlinks, no "..").
#   returns 0 ok, 1 bad path, 2 not listed, 3 missing or not a plain file
path_ok() {
  local p="$1" real
  case "$p" in ''|/*|..|../*|*/..|*/../*) return 1 ;; esac
  if [ "$p" != manifest.json ] && ! listed_files | grep -qxF -- "$p"; then return 2; fi
  if [ "$MODE" = dir ]; then
    [ -f "$ROOT/$p" ] && [ ! -L "$ROOT/$p" ] || return 3
    real=$(cd "$(dirname "$ROOT/$p")" && pwd -P) || return 3
    case "$real/" in "$ROOT"/*) ;; *) return 1 ;; esac
  fi
  return 0
}

check_file() {
  path_ok "$1"
  case $? in
    0) ;;
    2) die "$1: not a file in this bundle (see --files)." ;;
    3) die "$1: missing from the folder, or not a plain file." ;;
    *) die "$1: not a file in this bundle." ;;
  esac
}

refuse_binary() {
  case "$1" in *.pprof) die "$1 is a binary profile. Open it with: go tool pprof -http=: $1" ;; esac
}

cut_lines() { LC_ALL=C awk -v cap="$1" '{ if (length($0) > cap) $0 = substr($0, 1, cap) " ...[line cut]"; print }'; }

overview() {
  local findings=""
  path_ok findings.json && findings=$(raw_member findings.json 2>/dev/null)
  printf '%s' "$findings" | jq -e 'type == "array"' > /dev/null 2>&1 || findings='null'
  printf '%s' "$MANIFEST" | jq -r --argjson f "$findings" --arg known "$KNOWN_SCHEMA" --arg name "$BUNDLE_NAME" '
    def s: if . == null then "?" else tostring end;
    def yn: if . == true then "yes" elif . == false then "no" else "?" end;
    def pad($w): s | . + (" " * ($w - length));
    def count($sev): [$f[] | select(.severity == $sev)] | length;
    . as $m
    | (if ($m.schema_version | s) != $known then
         "Note: bundle format \($m.schema_version | s); this script reads format \($known). Some details may be missing.", ""
       else empty end),
      "Bundle     \($name)",
      "Tool       \($m.tool.name | s) \($m.tool.version | s), bundle format \($m.schema_version | s)",
      "Created    \($m.created_at | s)",
      "Cluster    context \($m.target.context | s), Kubernetes \($m.target.kubernetes_version | s), namespace \($m.target.namespace | s), StatefulSet \($m.target.statefulset | s)",
      "Weaviate   \(if ($m.target.weaviate_version // "") == "" then "version unknown" else $m.target.weaviate_version end), \(($m.run.weaviate_pods // []) | length) pod(s): \(($m.run.weaviate_pods // []) | join(", "))",
      "Modules    \(if (($m.run.module_pods // []) | length) > 0 then ($m.run.module_pods | join(", ")) else "none" end)",
      "Collected  \(($m.run.sections // []) | join(", ")); logs: \($m.run.log_window | s); anonymized: \($m.run.anonymized | yn); Helm: \($m.run.include_helm | yn)",
      "",
      ([$m.steps[]? | select(.status != "ok")] as $gaps
       | "Not collected or partial (\($gaps | length))",
         ($gaps[] | "  \(.status | pad(12)) \(.section | s) / \(.name | s)\(if (.detail // "") != "" then ": \(.detail)" else "" end)")),
      "",
      (if $f == null then "Red flags: findings.json is missing or unreadable."
       else
         "Red flags (\($f | length)): \(count("high")) high, \(count("warn")) warn, \(count("info")) info",
         ($f[] | "  [\(.severity | s)] \(.code | s): \(.title | s)",
                 (if (.detail // "") != "" then "         \(.detail)" else empty end),
                 "         Evidence: \(.file | s)")
       end),
      "",
      "Logs (\(($m.logs // []) | length))",
      ($m.logs[]? | "  \(.file | s): \(.lines | s) lines, \(.first // "?") to \(.last // "?")\(if .truncated == true then ", cut at the size limit, newest lines kept" else "" end)\(if .partial == true then ", partial: reading it stopped early" else "" end)")
  ' | clean
}

list_files() {
  printf '%s' "$MANIFEST" | jq -r '.files[]? | "\(.bytes)\t\(.path)"' \
    | awk -F '\t' '{ b = $1 + 0
        if (b >= 1048576) s = sprintf("%.1f MB", b / 1048576)
        else if (b >= 1024) s = sprintf("%.1f KB", b / 1024)
        else s = b " B"
        printf "%10s  %s\n", s, $2 }' | clean
}

show_file() {
  local p="$1" start="${2:-1}" total end
  is_number "$start" && [ "$start" -ge 1 ] || die "LINE must be a number from 1."
  check_file "$p"
  refuse_binary "$p"
  total=$(raw_member "$p" | awk 'END { print NR }')
  [ "$start" -le "$total" ] || [ "$total" -eq 0 ] || die "$p has $total lines; LINE $start is past the end."
  end=$((start + PAGE - 1)); [ "$end" -gt "$total" ] && end=$total
  printf '== %s: lines %s-%s of %s ==\n' "$p" "$start" "$end" "$total"
  raw_member "$p" | awk -v s="$start" -v e="$end" 'NR >= s && NR <= e' | cut_lines "$SHOW_LINE_CHARS" | clean
  [ "$end" -lt "$total" ] && printf '== more: --show %s %s ==\n' "$p" "$((end + 1))"
  return 0
}

tail_file() {
  local p="$1" n="${2:-100}" total
  is_number "$n" && [ "$n" -ge 1 ] || die "N must be a number from 1."
  [ "$n" -le "$MAX_TAIL" ] || n=$MAX_TAIL
  check_file "$p"
  refuse_binary "$p"
  total=$(raw_member "$p" | awk 'END { print NR }')
  [ "$n" -le "$total" ] || n=$total
  printf '== %s: last %s of %s lines ==\n' "$p" "$n" "$total"
  raw_member "$p" | tail -n "$n" | cut_lines "$SHOW_LINE_CHARS" | clean
}

query_file() {
  local p="$1" filter="$2" out rc
  case "$p" in *.json) ;; *) die "--query works on .json files only." ;; esac
  case "$filter" in -*) die "FILTER must not start with '-'." ;; esac
  check_file "$p"
  # No environment for jq: a filter cannot read $ENV (for example an API key).
  out=$(raw_member "$p" | env -i PATH="$PATH" jq "$filter" 2>&1); rc=$?
  if [ "$rc" -ne 0 ]; then printf '%s\n' "$out" | head -5 | clean >&2; exit 1; fi
  printf '%s\n' "$out" | awk -v max="$PAGE" 'NR <= max { print } END { if (NR > max) printf "== output cut at %d of %d lines; narrow the filter ==\n", max, NR }' \
    | cut_lines "$SHOW_LINE_CHARS" | clean
}

search_files() {
  local re="$1" target="${2:-}" f
  printf '' | grep -E -e "$re" > /dev/null 2>&1; [ $? -eq 2 ] && die "invalid regular expression: $re"
  if [ -n "$target" ]; then
    check_file "$target"
    refuse_binary "$target"
  fi
  {
    if [ -n "$target" ]; then printf '%s\n' "$target"; else listed_files | grep '\.log$'; fi
  } | while IFS= read -r f; do
    path_ok "$f" || continue
    raw_member "$f" | LC_ALL=C grep -n -i -E -e "$re" | F="$f" awk '{ print ENVIRON["F"] ":" $0 }'
  done | awk -v max="$MAX_MATCHES" 'NR <= max { print }
      END { if (NR == 0) print "No matching lines."
            else if (NR > max) printf "== %d more matching lines not shown; narrow the search or name a FILE ==\n", NR - max }' \
    | cut_lines "$SEARCH_LINE_CHARS" | clean
}

main() {
  [ $# -ge 1 ] || { usage; exit 1; }
  case "$1" in -h|--help) usage; exit 0 ;; esac
  command -v jq > /dev/null || die "jq is required (jq 1.6 or newer)."
  open_bundle "$1"; shift
  case "${1:-}" in
    "")       overview ;;
    --files)  list_files ;;
    --show)   [ -n "${2:-}" ] || die "--show needs a FILE."; show_file "$2" "${3:-}" ;;
    --tail)   [ -n "${2:-}" ] || die "--tail needs a FILE."; tail_file "$2" "${3:-}" ;;
    --query)  [ -n "${2:-}" ] && [ -n "${3:-}" ] || die "--query needs a FILE and a FILTER."; query_file "$2" "$3" ;;
    --search) [ -n "${2:-}" ] || die "--search needs a REGEX."; search_files "$2" "${3:-}" ;;
    *)        die "unknown option '$1'. See --help." ;;
  esac
}

main "$@"
