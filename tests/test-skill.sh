#!/usr/bin/env bash
#
# The agent skill (.agents/skills/weaviate-support-bundle):
#   - SKILL.md follows the Agent Skills format and is visible to Claude Code
#     through .claude/skills,
#   - every finding code is documented for agents and in the bundle format,
#   - read-bundle.sh reads a bundle (archive and folder) and refuses anything
#     outside it: symlinks, "..", absolute paths, files not in the manifest.
# Requires python3 (test-only dependency) to build hostile archives.

set -u
cd "$(dirname "$0")/.." || exit 1

SKILL=.agents/skills/weaviate-support-bundle
READ="$SKILL/scripts/read-bundle.sh"
fail=0
pass() { echo "ok: $1"; }
bad()  { echo "FAIL: $1"; fail=1; }

# ---- SKILL.md format ---------------------------------------------------------
front=$(awk 'NR == 1 && $0 == "---" { on = 1; next } on && $0 == "---" { exit } on' "$SKILL/SKILL.md")
name=$(printf '%s\n' "$front" | sed -n 's/^name: *//p')
desc=$(printf '%s\n' "$front" | sed -n 's/^description: *//p')
[ "$name" = "$(basename "$SKILL")" ] && pass "skill name matches its folder" || bad "skill name '$name' does not match its folder"
printf '%s' "$name" | grep -qE '^[a-z0-9]+(-[a-z0-9]+)*$' && [ "${#name}" -le 64 ] \
  && pass "skill name format" || bad "skill name must be lowercase letters, digits and single hyphens, max 64"
[ -n "$desc" ] && [ "${#desc}" -le 1024 ] && pass "skill description present, at most 1024 characters" \
  || bad "skill description missing or longer than 1024 characters (${#desc})"
[ "$(wc -l < "$SKILL/SKILL.md")" -lt 500 ] && pass "SKILL.md under 500 lines" || bad "SKILL.md has 500 lines or more"
for ref in $(grep -oE '\((references|scripts)/[^)]+\)' "$SKILL/SKILL.md" | tr -d '()' | sort -u); do
  [ -f "$SKILL/$ref" ] && pass "SKILL.md link $ref exists" || bad "SKILL.md links to missing $ref"
done
[ -x "$READ" ] && pass "read-bundle.sh is executable" || bad "read-bundle.sh is not executable"
[ "$(cd .claude/skills/weaviate-support-bundle 2>/dev/null && pwd -P)" = "$(cd "$SKILL" && pwd -P)" ] \
  && pass ".claude/skills points at the skill" || bad ".claude/skills/weaviate-support-bundle does not point at $SKILL"
grep -n -i 'customer' "$SKILL"/SKILL.md "$SKILL"/references/*.md AGENTS.md > /dev/null \
  && bad "skill text says 'customer' (use 'user')" || pass "skill text uses 'user'"

# ---- every finding code is documented ------------------------------------------
codes=$(grep -oE '"[A-Z][A-Z0-9]*(_[A-Z0-9]+)+";' lib/jq/findings.jq | tr -d '";' | sort -u)
[ -n "$codes" ] || bad "no finding codes found in lib/jq/findings.jq"
for c in $codes; do
  grep -q "^## $c\$" "$SKILL/references/findings.md" || bad "$c missing from $SKILL/references/findings.md"
  grep -q "\`$c\`" docs/bundle-format.md || bad "$c missing from docs/bundle-format.md"
done
for c in $(sed -n 's/^## \([A-Z0-9_]*\)$/\1/p' "$SKILL/references/findings.md"); do
  printf '%s\n' "$codes" | grep -qx "$c" || bad "$c is in references/findings.md but not in lib/jq/findings.jq"
done
[ "$fail" = 0 ] && pass "all $(printf '%s\n' "$codes" | wc -l | tr -d ' ') finding codes documented"

# ---- read-bundle.sh on a synthetic bundle -----------------------------------------
command -v python3 > /dev/null || { echo "skip: python3 not installed (read-bundle.sh checks)"; exit "$fail"; }
T=$(mktemp -d "${TMPDIR:-/tmp}/wsb-skill.XXXXXX")
trap 'rm -rf "$T"' EXIT

N=weaviate-support-bundle-20261106-120000
D="$T/ok/$N"
mkdir -p "$D/pods/weaviate-0/logs" "$D/weaviate"
cat > "$D/manifest.json" <<'EOF'
{"schema_version": "1", "tool": {"name": "weaviate-support-bundle", "version": "1.1.0"},
 "created_at": "2026-11-06T12:00:00Z",
 "target": {"context": "test", "namespace": "weaviate", "statefulset": "weaviate",
            "kubernetes_version": "v1.31.2", "weaviate_version": "1.40.3"},
 "run": {"sections": ["kubernetes", "weaviate", "logs"], "weaviate_pods": ["weaviate-0"], "module_pods": [],
         "log_window": "last 24h", "anonymized": false, "include_helm": false},
 "steps": [{"section": "kubernetes", "name": "pods", "status": "ok", "detail": "1 Weaviate"},
           {"section": "disk", "name": "disk usage", "status": "forbidden", "detail": "no nodes/proxy"}],
 "logs": [{"file": "pods/weaviate-0/logs/weaviate.log", "lines": 3, "first": "2026-11-06T11:00:00Z",
           "last": "2026-11-06T11:59:00Z", "truncated": false}],
 "files": [{"path": "findings.json", "bytes": 10}, {"path": "SUMMARY.md", "bytes": 10},
           {"path": "weaviate/nodes.json", "bytes": 10}, {"path": "pods/weaviate-0/logs/weaviate.log", "bytes": 10}]}
EOF
printf '[{"severity":"high","code":"POD_OOMKILLED","title":"weaviate-0/weaviate was OOMKilled","detail":"Limit reached.\\u001b[31m","file":"kubernetes/pods.json"}]\n' > "$D/findings.json"
printf '# Weaviate support bundle\n' > "$D/SUMMARY.md"
printf '{"nodes": [{"name": "weaviate-0", "status": "HEALTHY"}]}\n' > "$D/weaviate/nodes.json"
printf '{"level":"info","msg":"started"}\n{"level":"error","msg":"disk full"}\n{"level":"info","msg":"done"}\n' > "$D/pods/weaviate-0/logs/weaviate.log"
(cd "$T/ok" && COPYFILE_DISABLE=1 tar -czf "$T/ok.tar.gz" "$N")

for src in "$T/ok.tar.gz" "$D"; do
  kind=$([ -d "$src" ] && echo folder || echo archive)
  out=$("$READ" "$src" 2>&1)
  printf '%s' "$out" | grep -q 'POD_OOMKILLED' && printf '%s' "$out" | grep -q 'forbidden *disk / disk usage' \
    && pass "overview of the $kind shows red flags and gaps" || bad "overview of the $kind: $out"
  printf '%s' "$out" | LC_ALL=C grep -q "$(printf '\033')" && bad "overview of the $kind passes terminal escapes through" \
    || pass "overview of the $kind strips control characters"
  "$READ" "$src" --search 'level":"error' | grep -q '^pods/weaviate-0/logs/weaviate.log:2:' \
    && pass "search in the $kind" || bad "search in the $kind"
  [ "$("$READ" "$src" --query weaviate/nodes.json '.nodes[0].status')" = '"HEALTHY"' ] \
    && pass "query in the $kind" || bad "query in the $kind"
  "$READ" "$src" --tail pods/weaviate-0/logs/weaviate.log 1 | grep -q '"done"' \
    && pass "tail in the $kind" || bad "tail in the $kind"
done

refuses() {  # description, then the command; passes when it fails with a message
  local what="$1"; shift
  if "$@" > "$T/refuse.out" 2>&1; then bad "did not refuse: $what"; else pass "refuses $what"; fi
}
refuses "a path with .."               "$READ" "$D" --show ../../../etc/passwd
refuses "an absolute path"             "$READ" "$T/ok.tar.gz" --show /etc/passwd
refuses "a file not in the manifest"   "$READ" "$D" --show pods/weaviate-0/logs/other.log
refuses "the anonymization map"        "$READ" "$T/$N.anonymization-map.txt"
refuses "a jq filter that is an option" "$READ" "$D" --query weaviate/nodes.json '-n'
WEAVIATE_API_KEY=planted-key-4711 "$READ" "$D" --query weaviate/nodes.json '$ENV.WEAVIATE_API_KEY' | grep -q 'planted-key-4711' \
  && bad "jq filters can read environment variables" || pass "jq filters cannot read environment variables"

# Folder: a listed file that is a symlink, or inside a symlinked folder
printf 'secret-outside-4711\n' > "$T/outside.txt"
cp -R "$D" "$T/link-file"; rm "$T/link-file/SUMMARY.md"; ln -s "$T/outside.txt" "$T/link-file/SUMMARY.md"
refuses "a symlinked file in a folder" "$READ" "$T/link-file" --show SUMMARY.md
cp -R "$D" "$T/link-dir"; rm -rf "$T/link-dir/weaviate"; mkdir -p "$T/elsewhere"
printf '{"nodes": []}\n' > "$T/elsewhere/nodes.json"; ln -s "$T/elsewhere" "$T/link-dir/weaviate"
refuses "a file in a symlinked folder" "$READ" "$T/link-dir" --show weaviate/nodes.json
cp -R "$D" "$T/link-findings"; rm "$T/link-findings/findings.json"; ln -s "$T/outside.txt" "$T/link-findings/findings.json"
"$READ" "$T/link-findings" 2>&1 | grep -q 'secret-outside-4711' && bad "overview follows a symlinked findings.json" \
  || pass "overview ignores a symlinked findings.json"

# Hostile archives
python3 - "$T" "$N" <<'EOF'
import io, sys, tarfile
t, n = sys.argv[1], sys.argv[2]
manifest = open(f"{t}/ok/{n}/manifest.json", "rb").read()
def build(name, extra):
    with tarfile.open(f"{t}/{name}.tar.gz", "w:gz") as tf:
        info = tarfile.TarInfo(f"{n}/manifest.json"); info.size = len(manifest)
        tf.addfile(info, io.BytesIO(manifest))
        for e in extra:
            tf.addfile(e, io.BytesIO(b"x") if e.isfile() else None)
def reg(path):
    i = tarfile.TarInfo(path); i.size = 1; return i
def link(path, target):
    i = tarfile.TarInfo(path); i.type = tarfile.SYMTYPE; i.linkname = target; return i
build("dotdot", [reg(f"{n}/../evil.txt")])
build("absolute", [reg("/tmp/evil.txt")])
build("outside", [reg("other-folder/evil.txt")])
build("symlink", [link(f"{n}/SUMMARY.md", "/etc/passwd")])
EOF
for h in dotdot absolute outside symlink; do
  refuses "an archive with a $h entry" "$READ" "$T/$h.tar.gz"
done

[ "$fail" = 0 ] && echo "SKILL TESTS PASSED" || echo "SKILL TESTS FAILED"
exit "$fail"
