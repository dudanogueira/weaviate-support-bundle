# shellcheck shell=bash
# lib/helm.sh: Helm release information (only with --include-helm).
#
# Helm stores each release revision in a Kubernetes Secret
# (sh.helm.release.v1.<release>.v<N>). Reading it needs permission to read
# Secrets in the namespace, so this is off by default.
#
# Kept: chart name and version, app version, release status, revision history
# and the values the user set, redacted. Not kept: the rendered manifest
# and the chart's default values.

collect_helm() {
  heading "Helm"
  run_step helm "release" _helm_collect
}

_helm_collect() {
  if [ "$PF_HELM" = "forbidden" ]; then step_detail "no permission to read Secrets"; return 11; fi
  local release
  release="${HELM_RELEASE:-$(jq -r '.metadata.annotations["meta.helm.sh/release-name"] // empty' "$RAW/statefulset.json")}"
  [ -n "$release" ] || { step_detail "StatefulSet is not managed by Helm (use --helm-release to name it)"; return 12; }

  kget "$RAW/helm-secrets.json" secrets -n "$NAMESPACE" -l "owner=helm,name=$release" || return $?
  local count latest
  count=$(jq '.items | length' "$RAW/helm-secrets.json")
  [ "$count" -gt 0 ] || { step_detail "no release '$release' found"; return 12; }
  latest=$(jq -r '.items | sort_by(.metadata.labels.version | tonumber) | last | .metadata.name' "$RAW/helm-secrets.json")

  # Decode: Secret data (base64) -> Helm payload (base64) -> gzip -> JSON.
  jq -r --arg n "$latest" '.items[] | select(.metadata.name == $n) | .data.release' "$RAW/helm-secrets.json" \
    | base64 --decode 2>/dev/null | base64 --decode 2>/dev/null | gzip -dc > "$RAW/helm-release.json" 2>/dev/null
  if ! jq -e '.name' "$RAW/helm-release.json" > /dev/null 2>&1; then
    step_detail "could not decode the release"; return 1
  fi

  jq -L "$JQ_LIB" -r 'include "redact"; (.config // {}) | secret_keys_in_tree[] | "helm/values.json: \(.)"' \
    "$RAW/helm-release.json" >> "$WORK/redacted-fields" 2>/dev/null
  # The masked values themselves: scrubbed from every other file too.
  jq -L "$JQ_LIB" -r 'include "redact"; (.config // {}) | secret_values_in_tree[]' \
    "$RAW/helm-release.json" >> "$WORK/secret-values" 2>/dev/null

  jq -L "$JQ_LIB" -n --slurpfile r "$RAW/helm-release.json" --slurpfile s "$RAW/helm-secrets.json" 'include "redact";
    {release: $r[0].name,
     namespace: $r[0].namespace,
     revision: $r[0].version,
     status: $r[0].info.status,
     first_deployed: $r[0].info.first_deployed,
     last_deployed: $r[0].info.last_deployed,
     description: $r[0].info.description,
     chart: {name: $r[0].chart.metadata.name, version: $r[0].chart.metadata.version, appVersion: $r[0].chart.metadata.appVersion},
     history: [$s[0].items[] | {revision: (.metadata.labels.version | tonumber), status: .metadata.labels.status,
               created: .metadata.creationTimestamp}] | sort_by(.revision),
     values: (($r[0].config // {}) | redact_tree)}' \
    | write_json "$STAGE/helm/release.json" || return 1
  rm -f "$RAW/helm-release.json" "$RAW/helm-secrets.json"
  step_detail "$release, chart $(jq -r '.chart.version' "$STAGE/helm/release.json"), $count revision(s)"
}
