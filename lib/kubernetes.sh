# shellcheck shell=bash
# lib/kubernetes.sh: Kubernetes collectors (section "kubernetes").
#
# Every collector:
#   - reads with kc (read-only), keeps only the fields support needs,
#   - redacts env vars and config values before writing into $STAGE,
#   - returns a status code (see run_step in common.sh).

# jq with the redaction library loaded.
jqr() { jq -L "$JQ_LIB" "$@"; }

# kget <outfile> <kc get args...>: kc get -o json into a file; maps errors to codes.
kget() {
  local out="$1"; shift
  if kc get "$@" -o json > "$out" 2> "$WORK/err"; then return 0; fi
  local msg; msg=$(cat "$WORK/err")
  step_detail "$(short_error "$msg")"
  kube_error_code "$msg"
}

# Remember plain secret values found in env, so they are scrubbed from every
# other file too (logs, config maps, ...). Also note which fields were hidden.
remember_env_secrets() {
  local src="$1" where="$2"
  jqr -r 'include "redact"; env_secret_values[]' "$src" >> "$WORK/secret-values" 2>/dev/null
  jqr -r --arg w "$where" 'include "redact"; env_secret_names[] | "\($w): env \(.)"' "$src" >> "$WORK/redacted-fields" 2>/dev/null
}

# ---------------------------------------------------------------------------
collect_k8s_cluster() {
  jq -n --slurpfile v "$RAW/version.json" \
    --arg ctx "$CONTEXT_NAME" --arg ns "$NAMESPACE" --arg sts "$STS_NAME" \
    --arg nodes "$POD_NODES" \
    '{context: $ctx,
      kubernetes_version: ($v[0].serverVersion.gitVersion // null),
      platform: ($v[0].serverVersion.platform // null),
      namespace: $ns,
      statefulset: $sts,
      nodes_running_weaviate: ($nodes | split(" ") | map(select(length > 0)))}' \
    | write_json "$STAGE/kubernetes/cluster.json"
}

collect_k8s_statefulset() {
  remember_env_secrets "$RAW/statefulset.json" "kubernetes/statefulset.json"
  jqr 'include "redact"; redact_k8s_object | del(.metadata.uid, .metadata.resourceVersion, .metadata.selfLink)' \
    "$RAW/statefulset.json" | write_json "$STAGE/kubernetes/statefulset.json" || return 1

  # config/env.json: the Weaviate container's settings, easy to read.
  jqr --arg c "$WEAVIATE_CONTAINER" 'include "redact";
    .spec.template.spec.containers[] | select(.name == $c)
    | {container: .name,
       image: .image,
       command: (.command // null),
       args: (.args // null),
       env: ((.env // []) | redact_env | map({key: .name, value:
              (if has("value") then .value
               elif .valueFrom.secretKeyRef then {fromSecret: "\(.valueFrom.secretKeyRef.name)/\(.valueFrom.secretKeyRef.key)"}
               elif .valueFrom.configMapKeyRef then {fromConfigMap: "\(.valueFrom.configMapKeyRef.name)/\(.valueFrom.configMapKeyRef.key)"}
               elif .valueFrom.fieldRef then {fromField: .valueFrom.fieldRef.fieldPath}
               elif .valueFrom.resourceFieldRef then {fromResource: .valueFrom.resourceFieldRef.resource}
               else .valueFrom end)}) | sort_by(.key) | from_entries),
       envFrom: (.envFrom // []),
       resources: (.resources // {})}' \
    "$RAW/statefulset.json" | write_json "$STAGE/config/env.json"
  step_detail "$STS_NAME, $(jq -r '.spec.replicas // 0' "$RAW/statefulset.json") replicas"
}

# Slim pod view: status, restarts, crash reasons, placement, resources.
POD_FILTER='
  {name: .metadata.name,
   labels: .metadata.labels,
   annotations: ((.metadata.annotations // {}) | del(.["kubectl.kubernetes.io/last-applied-configuration"]) | redact_tree),
   created: .metadata.creationTimestamp,
   owner: ((.metadata.ownerReferences // [])[0] | if . then "\(.kind)/\(.name)" else null end),
   node: .spec.nodeName,
   serviceAccount: .spec.serviceAccountName,
   priorityClass: .spec.priorityClassName,
   qosClass: .status.qosClass,
   phase: .status.phase,
   reason: .status.reason,
   message: .status.message,
   startTime: .status.startTime,
   conditions: [.status.conditions[]? | {type, status, reason, message, lastTransitionTime}],
   containers: [.spec.containers[] | {name, image, resources, ports, livenessProbe, readinessProbe, startupProbe}],
   initContainers: [.spec.initContainers[]? | {name, image, resources}],
   volumes: [.spec.volumes[]? | {name} + (if .persistentVolumeClaim then {pvc: .persistentVolumeClaim.claimName}
                                          elif .configMap then {configMap: .configMap.name}
                                          elif .secret then {secret: .secret.secretName}
                                          elif .emptyDir then {emptyDir: .emptyDir}
                                          else {other: (keys - ["name"])} end)],
   containerStatuses: [.status.containerStatuses[]? | {name, ready, started, restartCount, image, state, lastState}],
   initContainerStatuses: [.status.initContainerStatuses[]? | {name, ready, restartCount, state, lastState}]}'

collect_k8s_pods() {
  remember_env_secrets "$RAW/weaviate-pods.json" "pods"
  remember_env_secrets "$RAW/module-pods.json" "pods"
  # Pod annotations can hold secrets (vault, backup tools, ...): note which
  # ones are masked by name, for redactions.txt.
  jqr -r 'include "redact"; [.items[] | .metadata.annotations // {} | secret_keys_in_tree[]] | unique[] | "kubernetes/pods.json: annotation \(.)"' \
    "$RAW/weaviate-pods.json" "$RAW/module-pods.json" >> "$WORK/redacted-fields" 2>/dev/null
  jqr --arg sel " $SEL_WEAVIATE_PODS " --arg mods " $SEL_MODULE_PODS " -n \
    --slurpfile w "$RAW/weaviate-pods.json" --slurpfile m "$RAW/module-pods.json" \
    "include \"redact\";
     def slim: $POD_FILTER;
     {weaviate: [\$w[0].items[] | select(.metadata.name as \$pn | \$sel | contains(\" \" + \$pn + \" \")) | slim] | sort_by(.name),
      modules:  [\$m[0].items[] | slim] | sort_by(.name)}" \
    | write_json "$STAGE/kubernetes/pods.json" || return 1
  # Per-pod status files sit next to the pod's logs and metrics.
  local p
  for p in $SEL_WEAVIATE_PODS $SEL_MODULE_PODS; do
    jq --arg p "$p" '(.weaviate + .modules)[] | select(.name == $p)' "$STAGE/kubernetes/pods.json" \
      | write_json "$STAGE/pods/$p/status.json"
  done
  step_detail "$(_count_words "$SEL_WEAVIATE_PODS") Weaviate, $(_count_words "$SEL_MODULE_PODS") module"
}

collect_k8s_nodes() {
  [ -n "$POD_NODES" ] || { step_detail "no nodes (pods not scheduled)"; return 10; }
  printf '[]' > "$RAW/nodes.json"
  local n rc=0 got=0 denied=0
  for n in $POD_NODES; do
    if kget "$RAW/node.json" node "$n"; then
      jq --slurpfile x "$RAW/node.json" '. + $x' "$RAW/nodes.json" > "$RAW/nodes2.json" && mv "$RAW/nodes2.json" "$RAW/nodes.json"
      got=$((got + 1))
    else
      rc=$?; [ "$rc" -eq 11 ] && denied=1
    fi
  done
  [ "$got" -gt 0 ] || { [ "$denied" = 1 ] && return 11; return "$rc"; }
  jq 'map({
        name: .metadata.name,
        labels: (.metadata.labels | with_entries(select(.key | test("topology.kubernetes.io|failure-domain|instance-type|instance_type|nodepool|node-pool|nodegroup|agentpool|kubernetes.io/arch|kubernetes.io/os|karpenter|capacity-type|lifecycle|spot")))),
        unschedulable: (.spec.unschedulable // false),
        taints: (.spec.taints // []),
        capacity: .status.capacity,
        allocatable: .status.allocatable,
        conditions: [.status.conditions[]? | {type, status, reason, message, lastTransitionTime}],
        nodeInfo: (.status.nodeInfo | {kubeletVersion, containerRuntimeVersion, osImage, kernelVersion, architecture}),
        created: .metadata.creationTimestamp
      })' "$RAW/nodes.json" | write_json "$STAGE/kubernetes/nodes.json"
  step_detail "$got node(s)"
}

collect_k8s_storage() {
  local claims
  claims=$(jq -r '.weaviate[], .modules[] | .volumes[] | .pvc // empty' "$STAGE/kubernetes/pods.json" 2>/dev/null | sort -u)
  [ -n "$claims" ] || { step_detail "no persistent volumes"; return 10; }
  printf '[]' > "$RAW/pvcs.json"; printf '[]' > "$RAW/pvs.json"; printf '[]' > "$RAW/scs.json"
  local c pv sc rc=0 got=0
  for c in $claims; do
    if kget "$RAW/x.json" pvc "$c" -n "$NAMESPACE"; then
      jq --slurpfile x "$RAW/x.json" '. + $x' "$RAW/pvcs.json" > "$RAW/y.json" && mv "$RAW/y.json" "$RAW/pvcs.json"
      got=$((got + 1))
    else rc=$?; fi
  done
  [ "$got" -gt 0 ] || return "$rc"
  for pv in $(jq -r '.[].spec.volumeName // empty' "$RAW/pvcs.json" | sort -u); do
    kget "$RAW/x.json" pv "$pv" && jq --slurpfile x "$RAW/x.json" '. + $x' "$RAW/pvs.json" > "$RAW/y.json" && mv "$RAW/y.json" "$RAW/pvs.json"
  done
  for sc in $(jq -r '.[].spec.storageClassName // empty' "$RAW/pvcs.json" | sort -u); do
    kget "$RAW/x.json" storageclass "$sc" && jq --slurpfile x "$RAW/x.json" '. + $x' "$RAW/scs.json" > "$RAW/y.json" && mv "$RAW/y.json" "$RAW/scs.json"
  done
  jqr -n --slurpfile pvc "$RAW/pvcs.json" --slurpfile pv "$RAW/pvs.json" --slurpfile sc "$RAW/scs.json" 'include "redact";
    {persistentVolumeClaims: [$pvc[0][] | {name: .metadata.name, storageClass: .spec.storageClassName,
        requested: .spec.resources.requests.storage, capacity: .status.capacity.storage,
        accessModes: .spec.accessModes, volumeMode: .spec.volumeMode, phase: .status.phase,
        volume: .spec.volumeName, conditions: (.status.conditions // [])}],
     persistentVolumes: [$pv[0][] | {name: .metadata.name, capacity: .spec.capacity.storage,
        reclaimPolicy: .spec.persistentVolumeReclaimPolicy, storageClass: .spec.storageClassName,
        driver: (.spec.csi.driver // null), phase: .status.phase,
        nodeAffinity: .spec.nodeAffinity}],
     storageClasses: [$sc[0][] | {name: .metadata.name, provisioner, reclaimPolicy, volumeBindingMode,
        allowVolumeExpansion: (.allowVolumeExpansion // false), parameters: ((.parameters // {}) | redact_tree)}]}' \
    | write_json "$STAGE/kubernetes/storage.json"
  step_detail "$got volume claim(s)"
}

collect_k8s_services() {
  kget "$RAW/services.json" services -n "$NAMESPACE" || return $?
  local podlabels
  podlabels=$(jq -c '.spec.template.metadata.labels // {}' "$RAW/statefulset.json")
  jq --argjson pl "$podlabels" '[.items[] | select(.spec.selector != null and (.spec.selector | to_entries | all(. as $e | $pl[$e.key] == $e.value)))]' \
    "$RAW/services.json" > "$RAW/our-services.json"
  printf '{}' > "$RAW/slices.json"
  local s
  for s in $(jq -r '.[].metadata.name' "$RAW/our-services.json"); do
    if kc get endpointslices -n "$NAMESPACE" -l "kubernetes.io/service-name=$s" -o json > "$RAW/x.json" 2>/dev/null; then
      jq --arg s "$s" --slurpfile x "$RAW/x.json" \
        '.[$s] = {ready: ([$x[0].items[].endpoints[]? | select(.conditions.ready == true)] | length),
                  notReady: ([$x[0].items[].endpoints[]? | select(.conditions.ready != true)] | length),
                  ports: ([$x[0].items[].ports[]?] | unique)}' "$RAW/slices.json" > "$RAW/y.json" && mv "$RAW/y.json" "$RAW/slices.json"
    fi
  done
  jqr --slurpfile sl "$RAW/slices.json" 'include "redact";
    map({name: .metadata.name, type: .spec.type, ports: .spec.ports, selector: .spec.selector,
         headless: (.spec.clusterIP == "None"), publishNotReadyAddresses: (.spec.publishNotReadyAddresses // false),
         sessionAffinity: .spec.sessionAffinity, externalTrafficPolicy: .spec.externalTrafficPolicy,
         annotations: ((.metadata.annotations // {}) | del(.["kubectl.kubernetes.io/last-applied-configuration"]) | redact_tree),
         endpoints: ($sl[0][.metadata.name] // null)})' "$RAW/our-services.json" \
    | write_json "$STAGE/kubernetes/services.json"
  step_detail "$(jq 'length' "$RAW/our-services.json") service(s)"
}

collect_k8s_netpol() {
  kget "$RAW/np.json" networkpolicies -n "$NAMESPACE" || return $?
  jq '[.items[] | {name: .metadata.name, spec}]' "$RAW/np.json" | write_json "$STAGE/kubernetes/network-policies.json" || return 1
  step_detail "$(jq '.items | length' "$RAW/np.json") in the namespace"
}

collect_k8s_policies() {
  local podlabels got="" denied=""
  podlabels=$(jq -c '.spec.template.metadata.labels // {}' "$RAW/statefulset.json")
  printf '{}' > "$RAW/policies.json"
  _add_policy() {  # _add_policy <key> <file> <jq filter>
    jq --arg k "$1" --slurpfile x "$2" --argjson pl "$podlabels" ".[\$k] = (\$x[0].items | $3)" \
      "$RAW/policies.json" > "$RAW/y.json" && mv "$RAW/y.json" "$RAW/policies.json"
  }
  if kget "$RAW/pdb.json" poddisruptionbudgets -n "$NAMESPACE"; then
    _add_policy podDisruptionBudgets "$RAW/pdb.json" \
      'map(select((.spec.selector.matchLabels // {}) | to_entries | all(. as $e | $pl[$e.key] == $e.value)) | {name: .metadata.name, spec, status})'
    got="$got disruption-budgets"
  else denied="$denied disruption-budgets"; fi
  if kget "$RAW/rq.json" resourcequotas -n "$NAMESPACE"; then
    _add_policy resourceQuotas "$RAW/rq.json" 'map({name: .metadata.name, hard: .status.hard, used: .status.used})'
    got="$got quotas"
  else denied="$denied quotas"; fi
  if kget "$RAW/lr.json" limitranges -n "$NAMESPACE"; then
    _add_policy limitRanges "$RAW/lr.json" 'map({name: .metadata.name, limits: .spec.limits})'
    got="$got limit-ranges"
  else denied="$denied limit-ranges"; fi
  [ -n "$got" ] || { step_detail "no permission"; return 11; }
  write_json "$STAGE/kubernetes/policies.json" < "$RAW/policies.json"
  [ -z "$denied" ] || step_detail "not readable:$denied"
  return 0
}

EVENT_FILTER='{type, reason, message,
   object: "\(.involvedObject.kind)/\(.involvedObject.name)",
   count: (.count // .series.count // 1),
   first: (.firstTimestamp // .eventTime // .metadata.creationTimestamp),
   last: (.lastTimestamp // .series.lastObservedTime // .eventTime // .metadata.creationTimestamp),
   source: (.source.component // .reportingComponent // null)}'

collect_k8s_events() {
  kget "$RAW/events.json" events -n "$NAMESPACE" || return $?
  # Keep only events about Weaviate's own objects.
  local names
  names=$(printf '%s %s %s %s' "$SEL_WEAVIATE_PODS" "$SEL_MODULE_PODS" "$STS_NAME" \
    "$(jq -r '[.weaviate[], .modules[] | .volumes[] | .pvc // empty] | unique | join(" ")' "$STAGE/kubernetes/pods.json" 2>/dev/null)")
  jq --arg names " $names " "[.items[] | select(.involvedObject.name as \$on | \$names | contains(\" \" + \$on + \" \")) | $EVENT_FILTER] | sort_by(.last)" \
    "$RAW/events.json" > "$RAW/our-events.json"
  # Events about the nodes Weaviate runs on (needs cluster-wide event access).
  local node_note=""
  if [ -n "$POD_NODES" ] && kc get events --all-namespaces --field-selector involvedObject.kind=Node -o json > "$RAW/node-events.json" 2>/dev/null; then
    jq --arg nodes " $POD_NODES " "[.items[] | select(.involvedObject.name as \$on | \$nodes | contains(\" \" + \$on + \" \")) | $EVENT_FILTER]" \
      "$RAW/node-events.json" > "$RAW/our-node-events.json"
  else
    printf '[]' > "$RAW/our-node-events.json"; node_note=", node events not readable"
  fi
  jq -n --slurpfile a "$RAW/our-events.json" --slurpfile b "$RAW/our-node-events.json" '($a[0] + $b[0]) | sort_by(.last)' \
    | write_json "$STAGE/kubernetes/events.json"
  step_detail "$(jq 'length' "$STAGE/kubernetes/events.json") event(s)$node_note"
}

# Names of the config maps the Weaviate StatefulSet uses.
weaviate_configmaps() {
  jq -r '.spec.template.spec | ([.volumes[]? | .configMap.name // empty]
         + [.containers[], (.initContainers // [])[] | (.envFrom // [])[] | .configMapRef.name // empty]
         + [.containers[] | (.env // [])[] | .valueFrom.configMapKeyRef.name // empty]) | unique | .[]' \
    "$RAW/statefulset.json"
}

# Secret values in those config maps go on the scrub list, whatever sections
# run: with --only logs the config maps are not collected, but a log can still
# print a value from them.
remember_configmap_secrets() {
  local c
  for c in $(weaviate_configmaps); do
    kc get configmap "$c" -n "$NAMESPACE" -o json 2>/dev/null \
      | jqr -r 'include "redact"; (.data // {})[] | secret_values_in_config_value[]' >> "$WORK/secret-values" 2>/dev/null
  done
  return 0
}

collect_k8s_configmaps() {
  local cms
  cms=$(weaviate_configmaps)
  [ -n "$cms" ] || { step_detail "none mounted"; return 10; }
  printf '{}' > "$RAW/cms.json"
  local c got=0 rc=0
  for c in $cms; do
    if kget "$RAW/x.json" configmap "$c" -n "$NAMESPACE"; then
      jqr --arg c "$c" --slurpfile x "$RAW/x.json" 'include "redact"; .[$c] = (($x[0].data // {}) | map_values(redact_config_value))' \
        "$RAW/cms.json" > "$RAW/y.json" && mv "$RAW/y.json" "$RAW/cms.json"
      jqr -r --arg c "$c" 'include "redact"; (.data // {}) | to_entries[] | .key as $k
          | (.value | redact_config_value | masked_keys_in_yaml[]) | "kubernetes/configmaps.json: \($c)/\($k): \(.)"' \
        "$RAW/x.json" >> "$WORK/redacted-fields" 2>/dev/null
      got=$((got + 1))
    else rc=$?; fi
  done
  [ "$got" -gt 0 ] || return "$rc"
  write_json "$STAGE/kubernetes/configmaps.json" < "$RAW/cms.json"
  step_detail "$got config map(s), values redacted"
}

collect_k8s_top() {
  if ! kc_raw_get "/apis/metrics.k8s.io/v1beta1/namespaces/$NAMESPACE/pods" > "$RAW/top.json" 2> "$WORK/err"; then
    step_detail "metrics-server not available"
    return 13
  fi
  jq --arg sel " $SEL_WEAVIATE_PODS $SEL_MODULE_PODS " \
    '{timestamp: (.items[0].timestamp // null),
      pods: [.items[] | select(.metadata.name as $pn | $sel | contains(" " + $pn + " ")) | {name: .metadata.name, window, containers: [.containers[] | {name, cpu: .usage.cpu, memory: .usage.memory}]}] | sort_by(.name)}' \
    "$RAW/top.json" | write_json "$STAGE/kubernetes/top.json"
}

collect_kubernetes() {
  heading "Kubernetes"
  run_step kubernetes "cluster info" collect_k8s_cluster
  run_step kubernetes "statefulset + settings" collect_k8s_statefulset
  run_step kubernetes "pods" collect_k8s_pods
  run_step kubernetes "nodes" collect_k8s_nodes
  run_step kubernetes "storage" collect_k8s_storage
  run_step kubernetes "services" collect_k8s_services
  run_step kubernetes "network policies" collect_k8s_netpol
  run_step kubernetes "disruption budgets, quotas, limits" collect_k8s_policies
  run_step kubernetes "events" collect_k8s_events
  run_step kubernetes "config maps" collect_k8s_configmaps
  run_step kubernetes "current CPU/memory" collect_k8s_top
}
