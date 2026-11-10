#!/usr/bin/env bash
#
# Redaction rules against fixtures with planted secrets.
# Every planted secret contains "fixture" + a 4-digit number, so a single grep
# proves none survived. Safe values must survive unchanged.

set -u
cd "$(dirname "$0")/.." || exit 1
L=lib/jq
F=tests/fixtures
T=$(mktemp -d "${TMPDIR:-/tmp}/wsb-redact-test.XXXXXX")
trap 'rm -rf "$T"' EXIT
fail=0
pass() { echo "ok: $1"; }
bad()  { echo "FAIL: $1"; fail=1; }

# StatefulSet env
jq -L $L 'include "redact"; redact_k8s_object' $F/statefulset.json > "$T/sts.json"
secrets=$(jq -L $L -c 'include "redact"; env_secret_values' $F/statefulset.json)

# YAML config
jq -L $L -Rrs 'include "redact"; redact_yaml_text' $F/conf.yaml > "$T/conf.yaml"

# Logs (with the literal secrets from env)
jq -L $L -nRr --argjson s "$secrets" 'include "redact"; scrub_lines($s; {}; {})' < $F/weaviate.log > "$T/weaviate.log"

# Helm-style values tree
mkdir -p "$T/in"  # inputs: not part of the leak scan below
cat > "$T/in/values.json" <<'EOF'
{"authentication": {"apikey": {"enabled": true, "allowed_keys": ["fixture-helm-key-0014"], "users": ["admin"]}},
 "modules": {"text2vec-openai": {"enabled": true, "apiKey": "fixture-helm-openai-0015"}},
 "backups": {"s3": {"envSecrets": {"AWS_SECRET_ACCESS_KEY": "s3-secret-name"}, "envconfig": {"BACKUP_S3_BUCKET": "bucket"}}},
 "tolerations": [{"key": "dedicated", "value": "weaviate"}],
 "collections": {"tokenization": "word"},
 "replicas": 3}
EOF
jq -L $L 'include "redact"; redact_tree' "$T/in/values.json" > "$T/values.json"

leaks=$(grep -hos 'fixture[-A-Za-z]*[0-9]\{4\}\|AKIAFIXTURE[A-Z0-9]*\|fixture[A-Za-z]*[0-9]\{4\}' "$T"/* | sort -u)
if [ -z "$leaks" ]; then pass "no planted secret survived"; else bad "secrets leaked: $leaks"; fi

check_kept() {  # check_kept <file> <text>
  if grep -qF -- "$2" "$1"; then pass "kept: $2"; else bad "lost a safe value in $(basename "$1"): $2"; fi
}
check_kept "$T/sts.json" '"6GiB"'
check_kept "$T/sts.json" '"admin,reader"'
check_kept "$T/sts.json" '"my-backups"'
check_kept "$T/sts.json" '"weaviate-cluster-api-basic-auth"'
check_kept "$T/sts.json" '"dedicated"'
check_kept "$T/conf.yaml" 'limit: 25'
check_kept "$T/conf.yaml" '- reader'
check_kept "$T/conf.yaml" 'enabled: true'
check_kept "$T/conf.yaml" 'certFile: /etc/tls/cert.pem'
check_kept "$T/weaviate.log" 'vectorIndexType=hnsw limit=25 shards=3'
check_kept "$T/values.json" '"word"'
check_kept "$T/values.json" '"dedicated"'
check_kept "$T/values.json" '"bucket"'

if ! grep -q 'last-applied-configuration' "$T/sts.json"; then pass "last-applied annotation removed"
else bad "last-applied annotation must be removed (it holds a full copy of env values)"; fi

# Anonymization
out=$(printf '%s\n' '{"tenant":"TenantAlpha","user":"alice@example.com","msg":"TenantAlpha ok"}' \
  | jq -L $L -nRr 'include "redact"; scrub_lines([]; {"TenantAlpha":"tenant-000001"}; {"alice@example.com":"user-001"})')
case "$out" in
  *TenantAlpha*|*alice@*) bad "anonymize left a name: $out" ;;
  *tenant-000001*user-001*) pass "anonymize replaces tenant and user names" ;;
  *) bad "anonymize output unexpected: $out" ;;
esac

# Values masked by name are returned, so they are scrubbed from every other file.
v=$(jq -L $L -c 'include "redact"; secret_values_in_tree' "$T/in/values.json" 2>/dev/null)
case "$v" in *fixture-helm-key-0014*fixture-helm-openai-0015*) pass "secret_values_in_tree returns the masked Helm values" ;; *) bad "secret_values_in_tree: $v" ;; esac
case "$v" in *bucket*|*word*|*admin*) bad "secret_values_in_tree returned a safe value: $v" ;; *) pass "secret_values_in_tree keeps safe values out" ;; esac
v=$(jq -L $L -Rrs 'include "redact"; secret_values_in_yaml | join(" ")' $F/conf.yaml)
case "$v" in *fixture-yaml-key-0006*fixture-yaml-key-0007*) pass "secret_values_in_yaml returns masked list items" ;; *) bad "secret_values_in_yaml list items: $v" ;; esac
case "$v" in *fixture-oidc-secret-0008*) pass "secret_values_in_yaml returns masked key values (unquoted)" ;; *) bad "secret_values_in_yaml key value: $v" ;; esac
case "$v" in *reader*|*cert.pem*|*BEGIN*|*\"*) bad "secret_values_in_yaml returned a safe value or quotes: $v" ;; *) pass "secret_values_in_yaml keeps safe values, markers and quotes out" ;; esac
v=$(jq -L $L -nc 'include "redact"; "{\"password\":\"fixture-json-pw-0042\",\"limit\":5}" | secret_values_in_config_value')
[ "$v" = '["fixture-json-pw-0042"]' ] && pass "secret_values_in_config_value reads JSON" || bad "secret_values_in_config_value JSON: $v"

exit "$fail"
