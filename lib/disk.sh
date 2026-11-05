# shellcheck shell=bash
# lib/disk.sh: disk usage of Weaviate's volumes (section "disk").
#
# Weaviate's API does not report disk usage, and the tool never runs commands
# inside pods. The only read-only source is the kubelet's stats summary,
# reached through the API server. That needs the "nodes/proxy" permission
# (rbac/optional-disk-usage.yaml). Without it this section is skipped and the
# bundle says so.
#
# Only these numbers are kept per volume: capacity, used, available, % used.

collect_disk_usage() {
  heading "Disk usage"
  if [ "$PF_DISK" != "ok" ]; then
    _nodisk() {
      case "$PF_DISK" in
        forbidden) step_detail "needs the nodes/proxy permission (see docs/permissions.md)"; return 11 ;;
        *) step_detail "node stats not reachable"; return 13 ;;
      esac
    }
    run_step disk "volume usage" _nodisk
    return
  fi
  run_step disk "volume usage" _disk_collect
}

_disk_collect() {
  printf '[]' > "$RAW/disk.json"
  local n got=0
  for n in $POD_NODES; do
    if kc_raw_get "/api/v1/nodes/$n/proxy/stats/summary" > "$RAW/summary.json" 2> "$WORK/err"; then
      jq --arg ns "$NAMESPACE" --arg sel " $SEL_WEAVIATE_PODS $SEL_MODULE_PODS " --arg node "$n" --slurpfile s "$RAW/summary.json" \
        '. + [$s[0].pods[]? | select(.podRef.namespace == $ns and (.podRef.name as $pn | $sel | contains(" " + $pn + " ")))
              | .podRef.name as $pod | .volume[]? | select(.pvcRef != null)
              | {pod: $pod, node: $node, pvc: .pvcRef.name,
                 capacity_bytes: .capacityBytes, used_bytes: .usedBytes, available_bytes: .availableBytes,
                 used_percent: (if (.capacityBytes // 0) > 0 then ((.usedBytes / .capacityBytes) * 1000 | round / 10) else null end),
                 inodes_used_percent: (if (.inodes // 0) > 0 then ((.inodesUsed / .inodes) * 1000 | round / 10) else null end)}]' \
        "$RAW/disk.json" > "$RAW/disk2.json" && mv "$RAW/disk2.json" "$RAW/disk.json"
      got=$((got + 1))
    fi
  done
  [ "$got" -gt 0 ] || { step_detail "$(short_error "$(cat "$WORK/err" 2>/dev/null)")"; return 1; }
  jq 'sort_by(.pod)' "$RAW/disk.json" | write_json "$STAGE/kubernetes/disk-usage.json"
  step_detail "$(jq 'length' "$STAGE/kubernetes/disk-usage.json") volume(s)"
}
