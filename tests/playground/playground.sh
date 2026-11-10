#!/usr/bin/env bash
#
# Playground: a local kind cluster with Weaviate, sample data and scenarios
# that break it in known ways, to see what collect.sh shows and to prove that
# fixes work.
#
# For people working on this repository. It WRITES to the kind cluster it
# creates (that is the point) and never to any other cluster: it uses its own
# kubeconfig in .playground/ and only a kind cluster named wsb-*.
# Do not run it from the support skill.
#
#   tests/playground/playground.sh up              # create the cluster (~5 min)
#   tests/playground/playground.sh list            # scenarios
#   tests/playground/playground.sh scenario oom    # break something
#   tests/playground/playground.sh collect         # run collect.sh on it
#   tests/playground/playground.sh revert oom
#   tests/playground/playground.sh verify oom crashloop   # apply, collect, check, revert
#   tests/playground/playground.sh down
#
# Environment: PLAYGROUND_CLUSTER (default wsb-playground), PLAYGROUND_DIR
# (default <repo>/.playground), WEAVIATE_VERSION, CHART_VERSION.

set -o pipefail
. "$(cd "$(dirname "$0")" && pwd)/lib.sh"

PG_CLUSTER="${PLAYGROUND_CLUSTER:-wsb-playground}"
PG_STATE="${PLAYGROUND_DIR:-$PG_REPO/.playground}"
pg_init

usage() {
  cat <<'EOF'
Usage: tests/playground/playground.sh COMMAND [args]

  up [--workers N]               Create the kind cluster, install Weaviate, load sample data
  down                           Delete the cluster and the .playground folder
  status                         Nodes, pods and active scenarios
  seed [--tenants N] [--objects N]   Add tenants to Tenanted / objects to Article
  list                           Scenarios and what each one should flag
  scenario NAME...               Break the cluster (see list)
  revert NAME...|--all           Undo scenarios
  collect [collect.sh options]   Run collect.sh on the cluster with a read-only (viewer) key
  verify NAME...|--all           For each: apply, collect, check the findings, revert
  shell-env                      Print exports to use kubectl / collect.sh by hand

Environment: PLAYGROUND_CLUSTER (default wsb-playground), PLAYGROUND_DIR,
WEAVIATE_VERSION, CHART_VERSION.
EOF
}

need_up() {
  pg_cluster_exists && [ -f "$PG_STATE/reader.key" ] || pg_die "the playground is not up (run: playground.sh up)"
}

cmd_up() {
  local workers=3
  while [ $# -gt 0 ]; do
    case "$1" in
      --workers) workers="${2:-}"; shift 2 ;;
      *) pg_die "unknown option for up: $1" ;;
    esac
  done
  case "$workers" in ''|*[!0-9]*) pg_die "--workers needs a number" ;; esac
  pg_require_tools
  if pg_cluster_exists; then
    [ -f "$PG_STATE/reader.key" ] && { pg_say "The playground is already up."; cmd_status; return 0; }
    pg_die "a kind cluster named $PG_CLUSTER exists but was not made by this playground. Delete it or set PLAYGROUND_CLUSTER."
  fi
  ( umask 077; mkdir -p "$PG_STATE" )
  : > "$PG_STATE/active"
  pg_create_cluster "$workers" || pg_die "could not create the cluster"
  pg_install_weaviate || pg_die "could not install Weaviate"
  pg_seed_base || pg_die "could not load sample data"
  pg_say ""
  pg_say "Playground is up. Next: playground.sh list, or playground.sh collect"
}

cmd_down() {
  pg_step "Delete cluster $PG_CLUSTER"
  pg_delete_cluster
  # Only remove our own state folder.
  case "$PG_STATE" in */.playground|*/.playground/) rm -rf "$PG_STATE" ;; *) pg_say "kept $PG_STATE (not a .playground folder)" ;; esac
  pg_say "done"
}

cmd_status() {
  need_up
  pg_say "Cluster:   $PG_CLUSTER (context $PG_CTX, kubeconfig $KUBECONFIG)"
  pg_say "Active:    $(pg_active | tr '\n' ' ')"
  pg_say ""
  k get nodes -o wide >&2
  pg_say ""
  kn get pods -o wide >&2
}

cmd_seed() {
  need_up
  local nt=0 no=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --tenants) nt="${2:-}"; shift 2 ;;
      --objects) no="${2:-}"; shift 2 ;;
      *) pg_die "unknown option for seed: $1" ;;
    esac
  done
  case "$nt$no" in *[!0-9]*) pg_die "--tenants and --objects need numbers" ;; esac
  pg_seed_more "$nt" "$no"
}

cmd_list() {
  local n
  printf '%-18s %-7s %s\n' SCENARIO KIND "DESCRIPTION / EXPECTS"
  for n in $(pg_sc_names); do
    printf '%-18s %-7s %s\n' "$n" "$(pg_sc_var "$n" SC_KIND)" "$(pg_sc_var "$n" SC_DESC)"
    printf '%-18s %-7s   expects: %s%s\n' "" "" "$(pg_sc_var "$n" SC_EXPECT)" \
      "$([ "$(pg_sc_var "$n" SC_NO_HIGH)" = 1 ] && printf ' (no high red flags)')"
  done
}

cmd_scenario() {
  need_up
  [ $# -gt 0 ] || pg_die "name a scenario (see: playground.sh list)"
  local n
  for n in "$@"; do pg_scenario_apply "$n" || pg_die "scenario $n failed"; done
}

cmd_revert() {
  need_up
  local n names="$*"
  [ "$names" = "--all" ] && names=$(pg_active | tr '\n' ' ')
  [ -n "$names" ] || pg_die "name a scenario, or --all"
  for n in $names; do pg_scenario_revert "$n" || pg_die "revert $n failed"; done
}

cmd_collect() {
  need_up
  local out b
  out="$PG_STATE/bundles/$(date -u +%Y%m%d-%H%M%S)"
  b=$(pg_collect "$out" "$@")
  local rc=$?
  tail -n 15 "$out/collect.out" >&2
  [ -n "$b" ] && pg_say "" && pg_say "Bundle: $b"
  return "$rc"
}

cmd_verify() {
  need_up
  local names="$*" n out b fail=0 summary=""
  [ "$names" = "--all" ] && names=$(pg_sc_names | tr '\n' ' ')
  [ -n "$names" ] || pg_die "name a scenario, or --all"
  for n in $names; do
    pg_sc_exists "$n" || pg_die "no scenario '$n'"
  done
  for n in $names; do
    if ! pg_scenario_apply "$n"; then
      fail=1; summary="$summary\nFAIL $n (apply)"; continue
    fi
    out="$PG_STATE/bundles/verify-$n-$(date -u +%Y%m%d-%H%M%S)"
    pg_step "Collect ($n)"
    # shellcheck disable=SC2046
    b=$(pg_collect "$out" --metrics-interval 5 $(pg_sc_var "$n" SC_COLLECT_ARGS))
    if [ -z "$b" ]; then
      echo "FAIL: $n: collect.sh produced no bundle (see $out/collect.out)"; tail -n 20 "$out/collect.out" >&2
      fail=1; summary="$summary\nFAIL $n (no bundle)"
    elif pg_scenario_check "$n" "$b"; then
      summary="$summary\nok   $n  ($b)"
    else
      fail=1; summary="$summary\nFAIL $n  ($b)"
    fi
    pg_scenario_revert "$n" || { fail=1; summary="$summary\nFAIL $n (revert)"; }
  done
  printf '\n== verify%b\n' "$summary"
  [ "$fail" = 0 ] && echo "VERIFY PASSED" || echo "VERIFY FAILED"
  return "$fail"
}

cmd_shell_env() {
  need_up
  # The key is read from its file when you run the line; it is never printed.
  printf 'export KUBECONFIG=%q\n' "$KUBECONFIG"
  printf 'export WEAVIATE_API_KEY="$(cat %q)"   # read-only (viewer) key\n' "$PG_STATE/reader.key"
  printf '# then: ./collect.sh --context %s\n' "$PG_CTX"
}

cmd="${1:-}"; [ $# -gt 0 ] && shift
case "$cmd" in
  up)        cmd_up "$@" ;;
  down)      cmd_down ;;
  status)    cmd_status ;;
  seed)      cmd_seed "$@" ;;
  list)      cmd_list ;;
  scenario)  cmd_scenario "$@" ;;
  revert)    cmd_revert "$@" ;;
  collect)   cmd_collect "$@" ;;
  verify)    cmd_verify "$@" ;;
  shell-env) cmd_shell_env ;;
  -h|--help|help|"") usage ;;
  *) usage; exit 1 ;;
esac
