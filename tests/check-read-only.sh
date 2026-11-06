#!/usr/bin/env bash
#
# Static check: the tool must stay read-only.
#
#  1. Only lib/guard.sh may run kubectl or curl.
#  2. kc is only called with read verbs (get, logs, version, config).
#  3. No write verb or write HTTP method appears in code anywhere.
#
# Comments and quoted strings are ignored, so messages like
# "run kubectl config use-context" do not trigger false alarms.

set -u
cd "$(dirname "$0")/.." || exit 1
fail=0

code_only() {
  # Drop comments and quoted strings, keep line numbers.
  sed -e 's/^[[:space:]]*#.*$//' -e 's/[[:space:]]#[^"'"'"']*$//' \
      -e 's/"[^"]*"/""/g' -e "s/'[^']*'/''/g" "$1"
}

files=$(ls collect.sh lib/*.sh .agents/skills/*/scripts/*.sh)

# 1. kubectl / curl outside guard.sh
for f in $files; do
  [ "$f" = "lib/guard.sh" ] && continue
  hits=$(code_only "$f" | grep -nE '(^|[;&|(`]|\$\(|(then|do|else|if|while)[[:space:]])[[:space:]]*(command[[:space:]]+|exec[[:space:]]+)?(kubectl|curl)([[:space:]]|$)')
  if [ -n "$hits" ]; then
    echo "FAIL: $f runs kubectl/curl directly (use the wrappers in lib/guard.sh):"
    echo "$hits" | sed 's/^/    /'
    fail=1
  fi
done

# 2. kc verbs
for f in $files; do
  bad=$(code_only "$f" | grep -noE '(^|[^_a-zA-Z])kc[[:space:]]+[a-z-]+' | grep -vE 'kc[[:space:]]+(get|logs|version|config)$')
  if [ -n "$bad" ]; then
    echo "FAIL: $f calls kc with a verb that is not allowed:"
    echo "$bad" | sed 's/^/    /'
    fail=1
  fi
done

# 3. write verbs / methods anywhere in code
for f in $files; do
  bad=$(code_only "$f" | grep -nE '(kubectl|kc)[[:space:]]+[^|;]*\b(apply|create|delete|patch|edit|replace|scale|rollout|exec|cp|label|annotate|cordon|uncordon|drain|taint|set|run|debug|attach|expose|autoscale)\b' \
        | grep -vE 'port-forward')
  if [ -n "$bad" ]; then
    echo "FAIL: $f mentions a kubectl write verb in code:"
    echo "$bad" | sed 's/^/    /'
    fail=1
  fi
done

# The only curl call (http_get in lib/guard.sh) must be GET with no body.
curl_body=$(awk '/^http_get\(\) \{/,/^\}/' lib/guard.sh)
if ! printf '%s' "$curl_body" | grep -q -- '--request GET'; then
  echo "FAIL: http_get in lib/guard.sh must call curl with --request GET"
  fail=1
fi
bad=$(printf '%s\n' "$curl_body" | grep -nE -- '(-X|--request)[[:space:]]+(POST|PUT|PATCH|DELETE)|--data|--upload-file|--form|--json|[[:space:]]-d[[:space:]]|[[:space:]]-T[[:space:]]|[[:space:]]-F[[:space:]]')
if [ -n "$bad" ]; then
  echo "FAIL: http_get has an HTTP write option:"
  echo "$bad" | sed 's/^/    /'
  fail=1
fi

if [ "$fail" = 0 ]; then echo "ok: read-only static check passed"; fi
exit "$fail"
