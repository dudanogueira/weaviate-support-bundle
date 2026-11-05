# shellcheck shell=bash
# lib/finalize.sh: last redaction pass, optional anonymization, packing.
#
# Every text file in the bundle goes through the same scrub before it leaves
# the temporary folder:
#   - literal secret values found earlier (e.g. API keys from env vars)
#   - content patterns (bearer tokens, JWTs, private keys, cloud keys,
#     credentials in URLs, "password=..." pairs)
#   - with --anonymize: tenant and user names -> placeholders

# Words never treated as tenant/user names, to avoid replacing common terms.
ANON_RESERVED='["default","weaviate","true","false","null","none","admin","ACTIVE","INACTIVE","HOT","COLD","FROZEN","OFFLOADED","READY","READONLY","INDEXING","HEALTHY"]'

# Values of JSON log fields whose name matches a regex (case-insensitive),
# from every collected log. Weaviate logs one JSON object per line.
log_field_values() {
  find "$STAGE/pods" -name '*.log' -type f -exec cat {} + 2>/dev/null \
    | jq -R -r --arg re "$1" 'fromjson? | .. | objects | to_entries[]
        | select(.key | test($re; "i")) | .value | if type == "array" then .[] else . end | strings' 2>/dev/null
}

build_anonymize_maps() {
  printf '{}' > "$WORK/tenant-map.json"
  printf '{}' > "$WORK/user-map.json"
  ANON_WARNING=""
  [ "$ANONYMIZE" = "1" ] || return 0

  # Tenant names come from three places, so anonymization still works when
  # Weaviate cannot answer schema calls (for example during an outage):
  #   1. the tenant lists of multi-tenant collections,
  #   2. shard names in /v1/nodes: those of multi-tenant collections, or all
  #      of them when the schema could not be read,
  #   3. log fields whose name contains "tenant" or "shard" (lists included).
  [ -f "$WORK/tenant-names" ] || : > "$WORK/tenant-names"
  if [ -f "$STAGE/weaviate/nodes.json" ]; then
    jq -r --slurpfile c "$WORK/collections.json" \
      '($c[0] // []) as $cols
       | (if ($cols | length) == 0 then null
          else [$cols[] | select(.config.multiTenancyConfig.enabled == true) | .name] end) as $mt
       | .nodes[].shards[]? | select($mt == null or (.class as $k | $mt | index($k))) | .name' \
      "$STAGE/weaviate/nodes.json" >> "$WORK/tenant-names" 2>/dev/null
  fi
  log_field_values '(tenant|shard)' >> "$WORK/tenant-names"
  jq -R -s --argjson r "$ANON_RESERVED" \
    'split("\n") | map(select(length >= 3)) | unique | map(select(. as $x | $r | index($x) | not))
     | to_entries | map({key: .value, value: ("tenant-" + (("00000" + ((.key + 1) | tostring))[-6:]))}) | from_entries' \
    "$WORK/tenant-names" > "$WORK/tenant-map.json"

  # User names: user lists in env vars, the connected user, and user fields
  # in the logs.
  {
    jq -r '.. | objects | select(has("env")) | .env[]? | select((.name | test("USERS$")) and (.value // "") != "") | .value | split(",")[]' \
      "$RAW/statefulset.json" 2>/dev/null
    jq -r '.username // empty' "$STAGE/weaviate/whoami.json" 2>/dev/null
    log_field_values '^(user|username|user_?id|principal)$'
  } | sed 's/^ *//; s/ *$//' > "$WORK/user-names"
  jq -R -s --argjson r "$ANON_RESERVED" \
    'split("\n") | map(select(length >= 3)) | unique | map(select(. as $x | $r | index($x) | not))
     | to_entries | map({key: .value, value: ("user-" + (("00" + ((.key + 1) | tostring))[-3:]))}) | from_entries' \
    "$WORK/user-names" > "$WORK/user-map.json"

  # Tell the user when the tenant list was not available.
  if [ "$(jq -r 'if . == null then "missing" elif any(.[]; (.tenants.error? // null) != null) then "partial" else "ok" end' "$WORK/collections.json" 2>/dev/null)" != "ok" ]; then
    ANON_WARNING="Weaviate could not list all tenants, so only tenant names found in /v1/nodes and in the logs were replaced. Please check the logs before sending."
    warn "$ANON_WARNING"
  fi
}

scrub_file() {
  local f="$1"
  jq -L "$JQ_LIB" -nRr --slurpfile s "$WORK/secrets.json" --slurpfile t "$WORK/tenant-map.json" --slurpfile u "$WORK/user-map.json" \
    'include "redact"; scrub_lines($s[0]; $t[0]; $u[0])' < "$f" > "$f.scrub" 2>> "$WORK/run.log" || { rm -f "$f.scrub"; return 1; }
  case "$f" in
    *.json)
      if ! jq empty "$f.scrub" 2>/dev/null; then
        # Should not happen; never ship a half-scrubbed file.
        printf '{"error": "file removed: it could not be safely redacted"}\n' > "$f.scrub"
        log_line WARN "scrub broke JSON in ${f#"$STAGE"/}; replaced with an error note"
      fi ;;
  esac
  mv "$f.scrub" "$f"
}

scrub_bundle() {
  heading "Redacting"
  sed 's/^ *//; s/ *$//' "$WORK/secret-values" | jq -R -s 'split("\n") | map(select(length >= 6)) | unique' > "$WORK/secrets.json"
  build_anonymize_maps
  cp "$WORK/run.log" "$STAGE/run.log"
  local f n=0 failed=0
  while IFS= read -r f; do
    if scrub_file "$f"; then n=$((n + 1)); else failed=$((failed + 1)); rm -f "$f"; fi
  done <<EOF
$(find "$STAGE" -type f \( -name '*.json' -o -name '*.log' -o -name '*.md' -o -name '*.txt' \) | sort)
EOF
  [ "$failed" -eq 0 ] || warn "$failed file(s) could not be redacted and were removed"

  # redactions.txt: what was hidden, never the values.
  {
    printf 'Redactions in this bundle\n'
    printf '=========================\n\n'
    printf 'Values were replaced with [REDACTED]. This file lists WHAT was hidden, never the value.\n\n'
    printf 'Fields hidden because their name looks secret:\n'
    if [ -s "$WORK/redacted-fields" ]; then sort -u "$WORK/redacted-fields" | sed 's/^/  - /'; else printf '  (none)\n'; fi
    printf '\nNumber of [REDACTED] markers per file:\n'
    local c
    find "$STAGE" -type f | sort | while IFS= read -r f; do
      c=$(grep -o '\[REDACTED' "$f" 2>/dev/null | wc -l | tr -d ' ')
      [ "${c:-0}" -gt 0 ] && printf '  %6s  %s\n' "$c" "${f#"$STAGE"/}"
    done
    if [ "$ANONYMIZE" = "1" ]; then
      printf '\nAnonymization: %s tenant name(s) and %s user name(s) were replaced with placeholders.\n' \
        "$(jq 'length' "$WORK/tenant-map.json")" "$(jq 'length' "$WORK/user-map.json")"
      printf 'The mapping stays on your machine (see the end of the tool output) and is NOT in this bundle.\n'
      [ -z "$ANON_WARNING" ] || printf 'Warning: %s\n' "$ANON_WARNING"
    fi
  } > "$STAGE/redactions.txt"
  ok "$n file(s) checked; see redactions.txt"
}

pack_bundle() {
  # Final file list in the manifest.
  find "$STAGE" -type f ! -name manifest.json | sort | while IFS= read -r f; do
    printf '%s\t%s\n' "${f#"$STAGE"/}" "$(wc -c < "$f" | tr -d ' ')"
  done | jq -R -s 'split("\n") | map(select(length > 0) | split("\t") | {path: .[0], bytes: (.[1] | tonumber)})' > "$WORK/files.json"
  jq --slurpfile f "$WORK/files.json" '.files = $f[0]' "$STAGE/manifest.json" > "$WORK/manifest.json" \
    && mv "$WORK/manifest.json" "$STAGE/manifest.json"

  local dest="$OUTPUT_DIR/$BUNDLE_NAME"
  [ ! -e "$dest" ] || die "$dest already exists."
  mkdir -p "$OUTPUT_DIR" || die "Cannot create output folder $OUTPUT_DIR"
  cp -R "$STAGE" "$dest" || die "Cannot write to $OUTPUT_DIR"
  ( cd "$OUTPUT_DIR" && COPYFILE_DISABLE=1 tar -czf "$BUNDLE_NAME.tar.gz" "$BUNDLE_NAME" ) || die "Could not create the archive."

  ANON_MAP_FILE=""
  if [ "$ANONYMIZE" = "1" ]; then
    ANON_MAP_FILE="$OUTPUT_DIR/$BUNDLE_NAME.anonymization-map.txt"
    {
      printf '# Anonymization map for %s\n' "$BUNDLE_NAME"
      printf '# KEEP THIS FILE. DO NOT SEND IT. Use it to translate placeholders in replies from Weaviate support.\n\n'
      jq -r 'to_entries[] | "\(.value)\t\(.key)"' "$WORK/tenant-map.json"
      jq -r 'to_entries[] | "\(.value)\t\(.key)"' "$WORK/user-map.json"
    } > "$ANON_MAP_FILE"
  fi
}

print_done() {
  local size
  size=$(du -h "$OUTPUT_DIR/$BUNDLE_NAME.tar.gz" 2>/dev/null | awk '{print $1}')
  say ""
  say "${C_BLD}Done.${C_RST}"
  say ""
  say "  1. Review:  $OUTPUT_DIR/$BUNDLE_NAME/"
  say "              Start with SUMMARY.md and redactions.txt."
  say "  2. Send:    $OUTPUT_DIR/$BUNDLE_NAME.tar.gz ($size) to Weaviate support."
  if [ -n "$ANON_MAP_FILE" ]; then
    say ""
    say "  Anonymization map (keep it, do NOT send it):"
    say "              $ANON_MAP_FILE"
  fi
  say ""
  say "  If you remove or change anything in the folder, rebuild the archive with:"
  say "    tar -czf \"$BUNDLE_NAME.tar.gz\" \"$BUNDLE_NAME\"     (run it in $OUTPUT_DIR)"
  say ""
  say "  Temporary files and port-forwards have been removed."
}
