# shellcheck shell=bash
# lib/summary.sh: manifest.json, findings.json and SUMMARY.md.

write_manifest() {
  local sections="" s
  for s in kubernetes weaviate logs metrics disk; do
    section_enabled "$s" && sections="$sections $s"
  done
  jq -s '.' "$WORK/steps.jsonl" > "$WORK/steps.json"
  jq -s '.' "$WORK/logs-index.jsonl" > "$WORK/logs-index.json" 2>/dev/null || printf '[]' > "$WORK/logs-index.json"
  jq -s '.' "$WORK/profiles-index.jsonl" > "$WORK/profiles-index.json" 2>/dev/null || printf '[]' > "$WORK/profiles-index.json"
  jq -n \
    --arg schema "$BUNDLE_SCHEMA_VERSION" --arg name "$TOOL_NAME" --arg version "$TOOL_VERSION" \
    --arg created "$CREATED_AT" --arg ctx "$CONTEXT_NAME" --arg ns "$NAMESPACE" --arg sts "$STS_NAME" \
    --arg kver "$SERVER_VERSION" --arg wver "$WEAVIATE_VERSION" \
    --arg sections "$sections" --arg wpods "$SEL_WEAVIATE_PODS" --arg mpods "$SEL_MODULE_PODS" \
    --arg window "$(log_window_text)" --arg since "$LOG_SINCE" --arg from "$LOG_FROM" --arg to "$LOG_TO" \
    --argjson prev "$PREVIOUS_LOG_LINES" --argjson interval "$METRICS_INTERVAL" --argjson maxlog "$MAX_LOG_MB" \
    --arg connect "$CONNECT_MODE" --argjson anon "$([ "$ANONYMIZE" = 1 ] && echo true || echo false)" \
    --argjson helm "$([ "$INCLUDE_HELM" = 1 ] && echo true || echo false)" \
    --argjson profiling "$([ "$INCLUDE_PROFILING" = 1 ] && echo true || echo false)" \
    --slurpfile steps "$WORK/steps.json" --slurpfile logs "$WORK/logs-index.json" --slurpfile profiles "$WORK/profiles-index.json" \
    'def words: split(" ") | map(select(length > 0));
     def opt: if . == "" then null else . end;
     {schema_version: $schema,
      tool: {name: $name, version: $version},
      created_at: $created,
      target: {context: $ctx, namespace: $ns, statefulset: $sts,
               kubernetes_version: ($kver | opt), weaviate_version: ($wver | opt)},
      run: {sections: ($sections | words), weaviate_pods: ($wpods | words), module_pods: ($mpods | words),
            log_window: $window, log_since: (if $from == "" then $since else null end),
            log_from: ($from | opt), log_to: ($to | opt), previous_log_lines: $prev,
            max_log_mb_per_container: $maxlog, metrics_interval_seconds: $interval,
            connect_mode: $connect, anonymized: $anon, include_helm: $helm, include_profiling: $profiling},
      steps: $steps[0],
      logs: $logs[0],
      profiles: $profiles[0],
      files: []}' > "$STAGE/manifest.json"
}

# Path of a bundle file, or of a file that holds `null` when it was not collected.
_fact_file() { if [ -f "$STAGE/$1" ]; then printf '%s' "$STAGE/$1"; else printf '%s' "$WORK/null.json"; fi; }

build_facts() {
  printf 'null' > "$WORK/null.json"
  if [ -d "$STAGE/weaviate/collections" ]; then
    find "$STAGE/weaviate/collections" -name '*.json' -type f -exec cat {} + | jq -s 'sort_by(.name)' > "$WORK/collections.json"
  else
    printf 'null' > "$WORK/collections.json"
  fi
  printf '[]' > "$WORK/metrics.json"
  local m pod
  for m in $(find "$STAGE/pods" -name metrics.json -type f 2>/dev/null | sort); do
    pod=$(basename "$(dirname "$m")")
    jq --arg p "$pod" --slurpfile d "$m" '. + [{pod: $p, data: $d[0]}]' "$WORK/metrics.json" > "$WORK/m2.json" && mv "$WORK/m2.json" "$WORK/metrics.json"
  done
  jq -n \
    --slurpfile manifest "$STAGE/manifest.json" \
    --slurpfile cluster "$(_fact_file kubernetes/cluster.json)" \
    --slurpfile env "$(_fact_file config/env.json)" \
    --slurpfile statefulset "$(_fact_file kubernetes/statefulset.json)" \
    --slurpfile pods "$(_fact_file kubernetes/pods.json)" \
    --slurpfile k8s_nodes "$(_fact_file kubernetes/nodes.json)" \
    --slurpfile events "$(_fact_file kubernetes/events.json)" \
    --slurpfile disk "$(_fact_file kubernetes/disk-usage.json)" \
    --slurpfile top "$(_fact_file kubernetes/top.json)" \
    --slurpfile meta "$(_fact_file weaviate/meta.json)" \
    --slurpfile nodes "$(_fact_file weaviate/nodes.json)" \
    --slurpfile raft "$(_fact_file weaviate/raft.json)" \
    --slurpfile replication "$(_fact_file weaviate/replication.json)" \
    --slurpfile backups "$(_fact_file weaviate/backups.json)" \
    --slurpfile collections "$WORK/collections.json" \
    --slurpfile metrics "$WORK/metrics.json" \
    '{manifest: $manifest[0], cluster: $cluster[0], env: $env[0], statefulset: $statefulset[0],
      pods: $pods[0], k8s_nodes: $k8s_nodes[0], events: $events[0], disk: $disk[0], top: $top[0],
      meta: $meta[0], nodes: $nodes[0], raft: $raft[0], replication: $replication[0],
      backups: $backups[0], collections: $collections[0], metrics: $metrics[0],
      logs: $manifest[0].logs}' > "$WORK/facts.json"
}

write_summary() {
  heading "Summary"
  build_facts
  if jq -L "$JQ_LIB" 'include "findings"; findings(.)' "$WORK/facts.json" > "$WORK/findings.json" 2>> "$WORK/run.log"; then
    write_json "$STAGE/findings.json" < "$WORK/findings.json"
  else
    printf '[]' > "$WORK/findings.json"; cp "$WORK/findings.json" "$STAGE/findings.json"
    fail "Could not compute red flags (see run.log)"
  fi
  if jq -L "$JQ_LIB" -r --slurpfile fd "$WORK/findings.json" 'include "summary"; summary(.; $fd[0])' "$WORK/facts.json" \
       > "$STAGE/SUMMARY.md" 2>> "$WORK/run.log"; then
    local high warn
    high=$(jq '[.[] | select(.severity == "high")] | length' "$WORK/findings.json")
    warn=$(jq '[.[] | select(.severity == "warn")] | length' "$WORK/findings.json")
    ok "SUMMARY.md written: $high high, $warn warning red flag(s)"
  else
    printf '# Weaviate support bundle\n\nSUMMARY.md could not be generated; see run.log. All collected files are still in this folder.\n' > "$STAGE/SUMMARY.md"
    fail "Could not render SUMMARY.md (see run.log)"
  fi
}
