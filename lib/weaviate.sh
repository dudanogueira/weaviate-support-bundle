# shellcheck shell=bash
# lib/weaviate.sh: Weaviate API collectors (section "weaviate").
#
# Only GET requests, only metadata: versions, node and Raft status, collection
# configuration, shard and tenant status. Never objects, vectors or queries.

# wget_json <path> <dest-file> [timeout]: GET $WEAVIATE_BASE<path> into dest.
# Returns a collector status code.
wget_json() {
  local path="$1" dest="$2" code
  # shellcheck disable=SC2034  # read by http_get through bash dynamic scoping
  local HTTP_TIMEOUT="${3:-60}"
  code=$(http_get "$WEAVIATE_BASE$path" "$RAW/http.out")
  case "$code" in
    200) if jq '.' "$RAW/http.out" > "$RAW/http.json" 2>/dev/null; then
           mkdir -p "$(dirname "$dest")"; mv "$RAW/http.json" "$dest"; return 0
         fi
         step_detail "response was not JSON"; return 1 ;;
    401|403) step_detail "HTTP $code: the API key cannot read this"; return 11 ;;
    404) step_detail "not available on this server"; return 12 ;;
    501|503) step_detail "HTTP $code: feature not enabled"; return 13 ;;
    000) step_detail "no connection"; return 1 ;;
    *) step_detail "HTTP $code"; return 1 ;;
  esac
}

w_meta()   { wget_json "/v1/meta" "$STAGE/weaviate/meta.json" && step_detail "v$(jq -r '.version' "$STAGE/weaviate/meta.json")"; }
w_nodes()  {
  wget_json "/v1/nodes?output=verbose" "$STAGE/weaviate/nodes.json" 120 || return $?
  step_detail "$(jq '.nodes | length' "$STAGE/weaviate/nodes.json") node(s), $(jq '[.nodes[].shards[]?] | length' "$STAGE/weaviate/nodes.json") shard(s)"
}
w_raft()   {
  wget_json "/v1/cluster/statistics" "$STAGE/weaviate/raft.json" || return $?
  step_detail "synchronized: $(jq -r '.synchronized' "$STAGE/weaviate/raft.json")"
}
w_aliases() { wget_json "/v1/aliases" "$STAGE/weaviate/aliases.json"; }
w_tasks()   { wget_json "/v1/tasks" "$STAGE/weaviate/tasks.json"; }
w_roles()   { wget_json "/v1/authz/roles" "$STAGE/weaviate/roles.json"; }
w_whoami()  { wget_json "/v1/users/own-info" "$STAGE/weaviate/whoami.json"; }
w_replication() {
  wget_json "/v1/replication/replicate/list" "$STAGE/weaviate/replication.json" || return $?
  step_detail "$(jq 'length' "$STAGE/weaviate/replication.json") operation(s)"
}

w_backups() {
  [ -f "$STAGE/weaviate/meta.json" ] || { step_detail "needs /v1/meta"; return 10; }
  local backends b got=0 rc=0
  backends=$(jq -r '.modules // {} | keys[] | select(startswith("backup-")) | sub("^backup-"; "")' "$STAGE/weaviate/meta.json")
  [ -n "$backends" ] || { step_detail "no backup module enabled"; return 10; }
  printf '{}' > "$RAW/backups.json"
  for b in $backends; do
    if wget_json "/v1/backups/$b" "$RAW/b.json" 120; then
      jq --arg b "$b" --slurpfile x "$RAW/b.json" '.[$b] = $x[0]' "$RAW/backups.json" > "$RAW/b2.json" && mv "$RAW/b2.json" "$RAW/backups.json"
      got=$((got + 1))
    else rc=$?; fi
  done
  [ "$got" -gt 0 ] || return "$rc"
  write_json "$STAGE/weaviate/backups.json" < "$RAW/backups.json"
  step_detail "backends: $(printf '%s' "$backends" | tr '\n' ' ')"
}

# One file per collection: its configuration plus shard or tenant status.
w_collections() {
  wget_json "/v1/schema" "$RAW/schema.json" 120 || return $?
  local classes c n=0 mt=0
  classes=$(jq -r '.classes[]?.class' "$RAW/schema.json")
  [ -n "$classes" ] || { step_detail "no collections"; mkdir -p "$STAGE/weaviate/collections"; return 0; }
  : > "$WORK/tenant-names"
  for c in $classes; do
    n=$((n + 1))
    jq --arg c "$c" '.classes[] | select(.class == $c)' "$RAW/schema.json" > "$RAW/class.json"
    printf 'null' > "$RAW/shards.json"; printf 'null' > "$RAW/tenants.json"
    if [ "$(jq -r '.multiTenancyConfig.enabled // false' "$RAW/class.json")" = "true" ]; then
      mt=$((mt + 1))
      if wget_json "/v1/schema/$c/tenants" "$RAW/tenant-list.json" 300; then
        jq -r '.[].name' "$RAW/tenant-list.json" >> "$WORK/tenant-names"
        # Counts by status; names only for tenants stuck in a transition.
        jq '{total: length,
             byStatus: (group_by(.activityStatus) | map({key: .[0].activityStatus, value: length}) | from_entries),
             inTransition: [.[] | select(.activityStatus | test("ING$")) | {name, activityStatus}][:200]}' \
          "$RAW/tenant-list.json" > "$RAW/tenants.json"
      else
        jq -n --arg e "$(cat "$WORK/.step-detail" 2>/dev/null)" '{error: $e}' > "$RAW/tenants.json"
        : > "$WORK/.step-detail"
      fi
    else
      if wget_json "/v1/schema/$c/shards" "$RAW/shard-list.json"; then
        cp "$RAW/shard-list.json" "$RAW/shards.json"
      else
        jq -n --arg e "$(cat "$WORK/.step-detail" 2>/dev/null)" '{error: $e}' > "$RAW/shards.json"
        : > "$WORK/.step-detail"
      fi
    fi
    jq -n --slurpfile cfg "$RAW/class.json" --slurpfile sh "$RAW/shards.json" --slurpfile tn "$RAW/tenants.json" \
      '{name: $cfg[0].class, config: $cfg[0], shards: $sh[0], tenants: $tn[0]}' \
      | write_json "$STAGE/weaviate/collections/$(safe_name "$c").json"
  done
  step_detail "$n collection(s), $mt multi-tenant"
}

collect_weaviate() {
  heading "Weaviate"
  if [ "$PF_WEAVIATE" != "ok" ]; then
    local st=13; [ "$PF_WEAVIATE" = "forbidden" ] && st=11
    _skip() { step_detail "${WEAVIATE_ERROR:-not connected}"; return "$st"; }
    run_step weaviate "Weaviate API" _skip
    return
  fi
  run_step weaviate "version and modules (/v1/meta)" w_meta
  run_step weaviate "nodes and shards (/v1/nodes)" w_nodes
  run_step weaviate "Raft cluster state (/v1/cluster/statistics)" w_raft
  run_step weaviate "collections" w_collections
  run_step weaviate "aliases" w_aliases
  run_step weaviate "replication operations" w_replication
  run_step weaviate "backups" w_backups
  run_step weaviate "distributed tasks" w_tasks
  run_step weaviate "roles" w_roles
  run_step weaviate "connected user" w_whoami
}
