# How to use the Weaviate support bundle

A step-by-step guide. It takes about 5 minutes, most of it reading.

**Contents:**
[Before you start](#before-you-start) ·
[Step 1: get the tool](#step-1-get-the-tool) ·
[Step 2: point kubectl at the cluster](#step-2-point-kubectl-at-the-cluster) ·
[Step 3: give it a Weaviate API key](#step-3-give-it-a-weaviate-api-key) ·
[Step 4: run it](#step-4-run-it) ·
[Step 5: review](#step-5-review-the-result) ·
[Step 6: send](#step-6-send-it-to-weaviate-support) ·
[Use it with an AI agent](#use-it-with-an-ai-agent) ·
[Options](#options) ·
[High-security environments](#high-security-environments) ·
[Troubleshooting](#troubleshooting)

## Before you start

Run the tool on the machine you already use to manage the cluster (your laptop
or a jump host). Nothing is installed in your cluster.

You need:

| Tool | Check with | Install |
|---|---|---|
| `bash` 3.2+ | `bash --version` | preinstalled on macOS and Linux |
| `kubectl` | `kubectl version --client` | you already use it for the cluster |
| `curl` | `curl --version` | preinstalled on macOS and most Linux |
| `jq` 1.6+ | `jq --version` | `brew install jq`, `apt install jq` or `yum install jq` |

The tool checks these when it starts and tells you if something is missing.

## Step 1: get the tool

```bash
git clone https://github.com/weaviate/weaviate-support-bundle.git
cd weaviate-support-bundle
```

No git? Download the latest release from
<https://github.com/weaviate/weaviate-support-bundle/releases>, unpack it, and
open a terminal in that folder.

## Step 2: point kubectl at the cluster

```bash
kubectl config current-context
```

This must be the cluster where Weaviate runs. If not, switch with
`kubectl config use-context <name>`, or pass `--context <name>` in step 4.

## Step 3: give it a Weaviate API key

Skip this step if your Weaviate allows anonymous access.

Use a **read-only** key if you have one:
- with RBAC: a user with the built-in `viewer` role,
- with admin lists: a user listed in `AUTHORIZATION_ADMINLIST_READONLY_USERS`.

```bash
export WEAVIATE_API_KEY='<your read-only API key>'
```

If you skip this and Weaviate needs a key, the tool asks for it (typing is
hidden). The key never appears in the bundle.

## Step 4: run it

```bash
./collect.sh
```

The tool finds Weaviate, checks what it is allowed to read, and shows a summary
**before collecting anything**:

```
Weaviate support bundle: preflight
  Kube context     prod-eu-1 (Kubernetes v1.31.2)
  Namespace        weaviate  (StatefulSet: weaviate)
  Weaviate         v1.40.3 · 3 pod(s): weaviate-0 weaviate-1 weaviate-2
  Connect via      temporary port-forward to weaviate-0 (closed at the end)
  Output           /home/me/weaviate-support-bundle-20261105-143000.tar.gz

  Kubernetes       ✔ can read the StatefulSet and pods
  Weaviate API     ✔ connected, API key accepted
  Logs             ✔ 3 pod(s), current + previous container, last 24h
  Metrics          ✔ 2 snapshots per pod, 30s apart (key metrics only)
  Disk usage       ✘ needs 'nodes/proxy' permission → will skip
  CPU/memory now   – metrics-server not available → will skip
  Helm             – off (add --include-helm)
  Anonymize        – off (add --anonymize)

  Nothing in your cluster or in Weaviate will be changed.
  Proceed? [y/N]
```

- ✔ will be collected, ✘ cannot be collected (and why), – is turned off.
- Type `y` to start. A run usually takes 1 to 3 minutes.
- Anything else cancels; nothing is collected.

**Something you want is ✘?** See [Permissions](#permissions) below. You can
also just continue: support can work with a partial bundle.

**How the tool reaches Weaviate.** By default it opens a temporary
`kubectl port-forward` to one Weaviate pod and closes it at the end. If you
prefer to use an address you already have (load balancer, ingress, IP, or a
port-forward you started yourself):

```bash
./collect.sh --weaviate-url https://weaviate.internal.example.com
./collect.sh --weaviate-url http://localhost:8080
```

Add `--insecure` if that address uses a self-signed certificate.

## Step 5: review the result

When it finishes, the tool prints two paths:

```
1. Review:  /home/me/weaviate-support-bundle-20261105-143000/
2. Send:    /home/me/weaviate-support-bundle-20261105-143000.tar.gz
```

Open the folder:

- **`SUMMARY.md`**: start here. Versions, health, red flags, and tables of
  pods, collections, settings and logs.
- **`redactions.txt`**: what was hidden (names and counts, never the values).
- Everything else is plain JSON and text. You can open any file.

If you remove or change a file, rebuild the archive with the command the tool
prints at the end.

## Step 6: send it to Weaviate support

Attach the `.tar.gz` to your support ticket. That is all.

The temporary files and port-forwards are already gone. To clean up after
support is done, delete the folder and the `.tar.gz`.

---

## Use it with an AI agent

Optional. If you use an AI coding agent, it can run the steps above for you
and explain the result. The tool ships with an agent skill
([`.agents/skills/weaviate-support-bundle`](.agents/skills/weaviate-support-bundle/SKILL.md))
in the open Agent Skills format, which Claude Code, GitHub Copilot, Codex
and other agents can read.

1. Set the API key in your terminal first (step 3), then start your agent
   **from that terminal**, inside the tool folder. Never paste the key into
   the chat.
2. Ask, for example: *"Collect a Weaviate support bundle for namespace
   weaviate, logs from the last 6 hours."*
3. The agent runs `./collect.sh --preflight-only`, shows you the preflight
   table and waits. Nothing is collected until you say yes.
4. It then collects the bundle and explains `SUMMARY.md`: health, red flags,
   what was not collected, and what to check next.
5. You still review the bundle and send it to support yourself (steps 5
   and 6). The agent never sends it anywhere.

**Agents that do not find the skill on their own:** most read
[`AGENTS.md`](AGENTS.md), which points them to it. To use the skill outside
this folder, copy `.agents/skills/weaviate-support-bundle` to your agent's
personal skills folder (for example `~/.claude/skills/` or `~/.copilot/skills/`).

**Privacy.** Whatever the agent reads, for example the preflight output and
parts of the bundle, is sent to your agent's AI provider. The bundle is
already redacted. Use `--anonymize` if tenant or user names must not leave your
machine, and follow your company's rules for AI tools.

The skill has strict rules: it only runs `collect.sh` and its own read-only
reader script, never runs other commands against your cluster, never handles
your API key, and never opens the anonymization map.

---

## Options

| Option | What it does | Default |
|---|---|---|
| `-n`, `--namespace NAME` | Namespace of the Weaviate StatefulSet | found automatically |
| `--statefulset NAME` | StatefulSet name, if a namespace has more than one Weaviate, or if your Weaviate image comes from a private registry under another name | found automatically |
| `--container NAME` | Weaviate container in the StatefulSet, if it cannot be found automatically | found automatically |
| `--context NAME` | kubectl context to use | current context |
| `--weaviate-url URL` | Reach Weaviate at this URL instead of a port-forward | port-forward |
| `--insecure` | Skip TLS certificate checks for `--weaviate-url` | off |
| `--pods LIST` | Only these pods, comma-separated, e.g. `weaviate-1,weaviate-2` | all Weaviate and module pods |
| `--only LIST` | Only these sections: `kubernetes`, `weaviate`, `logs`, `metrics`, `disk` | all |
| `--skip LIST` | All sections except these | none |
| `--since DURATION` | Logs from the last `30m`, `6h`, `24h`, `3d`, ... | `24h` |
| `--from TIME` | Logs from this time (UTC), e.g. `2026-11-01T08:00` or `2026-11-01` | – |
| `--to TIME` | Logs until this time (UTC). Use with `--from`. | now |
| `--max-log-mb N` | Size cap per container log, in MB | `100` |
| `--include-helm` | Also read Helm release info: chart version, history, your values (redacted). Needs read access to Secrets. | off |
| `--helm-release NAME` | Helm release name, if it cannot be found automatically (implies `--include-helm`) | found automatically |
| `--anonymize` | Replace tenant names and user names with placeholders | off |
| `--metrics-interval N` | Seconds between the two metrics snapshots | `30` |
| `-o`, `--output DIR` | Where to write the bundle | current folder |
| `--preflight-only` | Show the preflight table, then stop. Nothing is collected. | off |
| `-y`, `--yes` | Do not ask for confirmation (for scripts and CI) | ask |
| `-h`, `--help` | Show help | |
| `--version` | Show the tool version | |

### Examples

```bash
./collect.sh                                                  # everything, last 24h of logs
./collect.sh -n weaviate --since 6h                           # one namespace, last 6 hours
./collect.sh -n weaviate --from 2026-11-01T08:00 --to 2026-11-01T12:00   # the incident window
./collect.sh -n weaviate --pods weaviate-1,weaviate-2 --only logs        # logs of two pods only
./collect.sh -n weaviate --skip metrics --weaviate-url https://weaviate.example.com
```

### Log time windows

Kubernetes keeps only recent logs on each node (by default about the last
10 MB per container), so a long window can come back shorter than requested.
`SUMMARY.md` shows the real time range of every log file. For older logs,
export them from the system where you keep your logs and attach them to
the ticket.

For a pod that restarted, the log of the **previous** container is collected
too (its last 5,000 lines, whatever the window). That is usually where the
crash reason is.

## High-security environments

- **Anonymize names.** `--anonymize` replaces tenant names (often your own
  end users' IDs) and user names with placeholders such as `tenant-000001` and
  `user-001`. The mapping is written **next to** the archive
  (`...anonymization-map.txt`), never inside it. Keep it to translate the
  placeholders when support refers to them. Do not send it.
- **Review before sending.** Everything is plain JSON and text. Remove what you
  do not want to share, then rebuild the archive.
- **Collect less.** Use `--skip` or `--only`, for example `--skip logs`.
- **Use a dedicated read-only account.** See [Permissions](#permissions).
- **Read the code.** It is plain bash. Every call to the cluster and to
  Weaviate goes through one file, [`lib/guard.sh`](lib/guard.sh), which only
  allows reads.

## Permissions

Your normal kubectl user is usually enough. If something is not allowed, the
tool skips that part, keeps going, and says so in the bundle.

| What | Needs | Risk |
|---|---|---|
| Everything except the two below | read access to the StatefulSet, pods, logs, nodes, volumes, services, events; port-forward | No risk: read only. Port-forward opens a temporary connection and changes nothing. |
| Disk usage (optional) | `get` on `nodes/proxy` | Risk: the permission can also run commands in pods through the kubelet. The tool only reads disk stats. Limit it to Weaviate's nodes and remove it after the run, or use `--skip disk`. |
| Helm info (optional, `--include-helm`) | `list` on Secrets in the namespace | Risk: allows reading all Secrets in the namespace. The tool only reads Helm's release Secrets and redacts them. |

Ready-to-use files: [`rbac/read-only.yaml`](rbac/read-only.yaml),
[`rbac/optional-disk-usage.yaml`](rbac/optional-disk-usage.yaml),
[`rbac/optional-helm.yaml`](rbac/optional-helm.yaml).
Every permission is explained in [`docs/permissions.md`](docs/permissions.md).

## Troubleshooting

| Message | What to do |
|---|---|
| `No Weaviate StatefulSet found` | Check `kubectl config current-context`, or pass `--namespace` (and `--statefulset`). If your Weaviate image comes from a private registry under another name, pass `--namespace` and `--statefulset`. |
| `Cannot tell which container ... runs Weaviate` | Pass `--container` with the name of the Weaviate container. |
| `Found more than one Weaviate StatefulSet` | Pass `--namespace` (and `--statefulset`) to choose one. |
| `Cannot list StatefulSets across namespaces` | Your user cannot search all namespaces. Pass `--namespace`. |
| `Weaviate API ✘ API key missing or not accepted` | Set `WEAVIATE_API_KEY`, or check the key. |
| `Weaviate API ✘ port-forward not allowed` | Use `--weaviate-url`. |
| `No terminal to ask for confirmation` | Add `--yes` when running from a script or CI job. |
| `jq ... is too old` | Install jq 1.6 or newer. |
| The run is slow, with several `HTTP 500` lines | Normal when Weaviate is unhealthy (for example it lost Raft quorum): each failing call can take about 20 seconds. Let it finish; those failures are useful to support. |

The tool never stops because one part failed. If something looks wrong, send
the bundle anyway: `run.log` and `manifest.json` show what happened.
