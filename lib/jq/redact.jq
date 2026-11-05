# lib/jq/redact.jq: redaction rules shared by every collector.
#
# Two kinds of rules:
#   1. By name: values of env vars / keys whose NAME looks secret
#      (PASSWORD, TOKEN, APIKEY, ALLOWED_KEYS, ...) are replaced, unless the
#      value is a plain boolean or number (e.g. AUTHENTICATION_APIKEY_ENABLED).
#   2. By content: anything that LOOKS like a secret wherever it appears
#      (bearer tokens, JWTs, private keys, cloud keys, credentials in URLs,
#      "password=..." pairs, and literal values already redacted elsewhere).
#
# Requires jq 1.6 or newer.

def mask: "[REDACTED]";

# Does this env var / key name look like it holds a secret?
# Names that end in USERS, GROUPS, ENABLED, CLAIM, FILE, PATH, ... describe
# settings, not secrets (e.g. AUTHENTICATION_APIKEY_USERS lists user names;
# --anonymize handles those).
def secret_name:
  ascii_upcase | gsub("[-_. ]"; "")
  | test("PASSWORD|PASSWD|PASSPHRASE|SECRET|TOKEN(?!IZ)|APIKEY|ACCESSKEY|PRIVATEKEY|CREDENTIAL|CONNECTIONSTRING|ALLOWEDKEYS|AUTHHEADER|CERTIFICATE|SIGNATURE|SASKEY|.+KEY$|.+KEYS$|.+KEYID$|DSN$")
    and (test("(USERS?|USERNAME|GROUPS?|ENABLED|DISABLED|CLAIM|ISSUER|FILE|PATH|REF)$") | not);

# Values that are safe to keep even under a secret-looking name.
def plain_value:
  (type == "boolean") or (type == "number") or (type == "null")
  or (type == "string" and test("^(true|false|yes|no|on|off|[0-9]+(\\.[0-9]+)?)?$"; "i"));

# Content-based scrubbing for any string (log lines, JSON strings, YAML text).
def scrub_text:
  if type != "string" then . else
    gsub("-----BEGIN [A-Z ]*PRIVATE KEY-----[\\s\\S]*?-----END [A-Z ]*PRIVATE KEY-----"; "[REDACTED PRIVATE KEY]")
    | gsub("(?<p>[Bb]earer\\s+)[A-Za-z0-9._~+/=-]{8,}"; "\(.p)[REDACTED]")
    | gsub("(?<p>[Bb]asic\\s+)[A-Za-z0-9+/=]{12,}"; "\(.p)[REDACTED]")
    | gsub("eyJ[A-Za-z0-9_-]{6,}\\.[A-Za-z0-9_-]{6,}\\.[A-Za-z0-9_-]{6,}"; "[REDACTED JWT]")
    | gsub("(?<![A-Za-z0-9])(AKIA|ASIA)[A-Z0-9]{16}(?![A-Za-z0-9])"; "[REDACTED AWS KEY]")
    | gsub("(?<![A-Za-z0-9])sk-[A-Za-z0-9_-]{16,}"; "[REDACTED]")
    | gsub("(?<p>://)[^/@:\\s\"']+:[^/@\\s\"']+@"; "\(.p)[REDACTED]@")
    | gsub("(?<k>(?i:accountkey|sharedaccesssignature|sharedaccesskey|password|passwd|pwd|secret|client_secret|clientsecret|token|access_token|refresh_token|api_key|api-key|apikey|access_key|secret_key)[\"']?\\s*[:=]\\s*[\"']?)[^\\s\"',;&}]{4,}"; "\(.k)[REDACTED]")
  end;

# Replace literal secret values (collected while redacting env vars).
def scrub_literals($secrets):
  if type != "string" then . else
    reduce ($secrets[] | select(length >= 6)) as $s (.; split($s) | join("[REDACTED]"))
  end;

# Replace tenant and user names with placeholders (only with --anonymize).
def anonymize($tenants; $users):
  if type != "string" then . else
    # Whole words first; then the parts of words joined with "_", because
    # Weaviate logs shard names such as "<collection>_<tenant>".
    (if ($tenants | length) > 0 then
       gsub("(?<t>[A-Za-z0-9_-]+)"; (.t as $w | $tenants[$w]
         // (if ($w | contains("_")) then ($w | split("_") | map($tenants[.] // .) | join("_")) else $w end)))
     else . end)
    | (if ($users | length) > 0 then gsub("(?<u>[A-Za-z0-9_.@+-]+)"; ($users[.u] // .u)) else . end)
  end;

# ---------------------------------------------------------------------------
# Structured redaction
# ---------------------------------------------------------------------------

# Every string leaf becomes [REDACTED].
def mask_all: walk(if type == "string" then mask else . end);

# Generic JSON tree (Helm values, JSON config files).
def redact_tree:
  if type == "object" then
    with_entries(
      if (.key | secret_name) and ((.value | plain_value) | not) then
        .value |= (if type == "string" then mask
                   elif type == "array" or type == "object" then mask_all
                   else . end)
      else .value |= redact_tree end)
  elif type == "array" then map(redact_tree)
  elif type == "string" then scrub_text
  else . end;

# Names of keys redact_tree would mask (for redactions.txt).
def secret_keys_in_tree:
  [.. | objects | to_entries[] | select((.key | secret_name) and ((.value | plain_value) | not)) | .key] | unique;

# Container env list: mask plain values with secret-looking names.
# Values coming from Secrets (valueFrom.secretKeyRef) only show the reference.
def redact_env:
  map(if has("value") and (.name | secret_name) and ((.value | plain_value) | not) then .value = mask
      elif has("value") then .value |= scrub_text
      else . end);

# Plain secret values found in container env (to scrub everywhere else too).
def env_secret_values:
  [.. | objects | select(has("env") and (.env | type) == "array") | .env[]
   | select(has("value") and (.name | secret_name) and ((.value | plain_value) | not))
   | .value | strings | split(",")[] | sub("^\\s+"; "") | sub("\\s+$"; "") | select(length >= 6)]
  | unique;

def env_secret_names:
  [.. | objects | select(has("env") and (.env | type) == "array") | .env[]
   | select(has("value") and (.name | secret_name) and ((.value | plain_value) | not)) | .name]
  | unique;

# Any Kubernetes object: drop noise and the last-applied annotation (it holds
# a full copy of the spec, env values included), then redact env vars.
def redact_k8s_object:
  del(.metadata.managedFields?)
  | del(.metadata.annotations["kubectl.kubernetes.io/last-applied-configuration"]?)
  | (.. | objects | select(has("env") and (.env | type) == "array") | .env) |= redact_env;

# YAML text (ConfigMap values). Line based; tracks parent keys by indentation.
#  - key: value      -> value masked if the key looks secret
#  - key:            -> list items directly under it masked if the key looks secret
#  - key: |          -> the whole block masked if the key looks secret
def redact_yaml_text:
  reduce (split("\n")[]) as $l ({out: [], st: []};
    ($l | match("^ *").length) as $ind
    | if ($l | test("^\\s*(#.*)?$")) then .out += [$l]
      else
        .st |= map(select(.i < $ind))
        | (.st | last) as $p
        | if ($p != null and $p.lit) then .out += [($l | sub("\\S.*$"; "[REDACTED]"))]
          else
            ([$l | capture("^ *(?<dash>- +)?(?<key>[A-Za-z0-9_./\"'-]+) *:( +(?<val>.*))?$")] | .[0]) as $m
            | if $m != null then
                ($m.key | gsub("[\"']"; "") | secret_name) as $sec
                | (($m.val // "") | sub(" +#.*$"; "")) as $v
                | if $v == "" then .st += [{i: $ind, s: $sec, lit: false}] | .out += [$l]
                  elif ($v | test("^[|>][-+0-9]*$")) then .st += [{i: $ind, s: $sec, lit: $sec}] | .out += [$l]
                  elif $sec and (($v | gsub("[\"']"; "") | plain_value) | not) then
                    .out += [($l | sub(": .*$"; ": [REDACTED]"))]
                  else .out += [($l | scrub_text)] end
              elif ($l | test("^ *- ")) and $p != null and $p.s then
                .out += [($l | sub("^(?<d> *- +).*$"; "\(.d)[REDACTED]"))]
              else .out += [($l | scrub_text)] end
          end
      end)
  | .out | join("\n");

# Keys that were actually masked, read back from REDACTED yaml text
# (for redactions.txt): "key: [REDACTED]" lines, plus the parent key of
# masked list items and masked literal blocks.
def masked_keys_in_yaml:
  reduce (split("\n")[]) as $l ({st: [], keys: []};
    ($l | match("^ *").length) as $ind
    | if ($l | test("^\\s*(#.*)?$")) then .
      else
        .st |= map(select(.i < $ind))
        | ([$l | capture("^ *(- +)?(?<key>[A-Za-z0-9_./\"'-]+) *:( +(?<val>.*))?$")] | .[0]) as $m
        | if $m != null then
            (if ($m.val // "") == "[REDACTED]" then .keys += [$m.key] else . end)
            | .st += [{i: $ind, k: $m.key}]
          elif ($l | test("\\[REDACTED\\]")) and ((.st | last) != null) then .keys += [(.st | last).k]
          else . end
      end)
  | .keys | map(gsub("[\"']"; "")) | unique;

# A ConfigMap value: JSON is redacted as a tree, everything else as YAML text.
def redact_config_value:
  if type != "string" then . else
    (try (fromjson | redact_tree | tojson) catch null) // redact_yaml_text
  end;

# Stream of raw text lines -> scrubbed lines (logs, final pass over files).
# Multi-line private key blocks are masked as a whole.
def scrub_lines($secrets; $tenants; $users):
  foreach inputs as $line ({key: false};
    if .key then
      .emit = false
      | if ($line | test("-----END [A-Z ]*PRIVATE KEY-----")) then .key = false else . end
    elif ($line | test("-----BEGIN [A-Z ]*PRIVATE KEY-----")) and (($line | test("-----END [A-Z ]*PRIVATE KEY-----")) | not) then
      .key = true | .emit = true | .out = "[REDACTED PRIVATE KEY]"
    else
      .emit = true
      | .out = ($line | scrub_literals($secrets) | scrub_text | anonymize($tenants; $users))
    end;
    if .emit then .out else empty end);
