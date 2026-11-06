# Weaviate support bundle

Collects diagnostic information about a **Weaviate cluster running on
Kubernetes** into one archive. You review it and send it to Weaviate support,
so support can start investigating right away instead of asking you for
things one at a time.

```bash
git clone https://github.com/weaviate/weaviate-support-bundle.git
cd weaviate-support-bundle
./collect.sh
```

**👉 Step-by-step guide: [USAGE.md](USAGE.md)**

**Prefer to use an AI agent?** Open this folder in Claude Code, GitHub
Copilot, Codex or a similar agent and ask it to collect a support bundle. It
follows the same steps, asks before collecting, and explains the result. See
[USAGE.md](USAGE.md#use-it-with-an-ai-agent).

## What it does, and what it never does

**It does:**
- read your Weaviate StatefulSet, pods, nodes, volumes, services and events,
- read Weaviate's own status through its API: version, nodes, Raft cluster
  state, collection settings, shard and tenant status, backups,
- read recent logs and key metrics from each Weaviate pod,
- write everything into one folder and one `.tar.gz` on your machine, with a
  `SUMMARY.md` that lists versions, health and red flags.

**It never:**
- changes anything in your cluster or in Weaviate. Every Kubernetes call is a
  read, and every Weaviate call is an HTTP `GET`. A safety gate in the code
  refuses anything else.
- reads your data: no objects, no vectors, no query results.
- runs commands inside your pods.
- reads Kubernetes Secrets (unless you add `--include-helm`).
- sends anything anywhere. The archive stays on your machine until you send it.
- leaves anything behind: temporary files and port-forwards are removed at the
  end, also if you press Ctrl-C.

**Secrets are redacted** before anything is written: API keys, passwords,
tokens, connection strings, private keys and similar values become
`[REDACTED]`. `redactions.txt` in the bundle lists what was hidden.

## Requirements

`bash`, `kubectl` (pointed at the cluster), `curl` and `jq` 1.6+, on the
machine you already use to manage the cluster. Nothing is installed in the
cluster. Works with Weaviate on Kubernetes, deployed with the official Helm
chart or your own manifests.

## Documentation

| | |
|---|---|
| [USAGE.md](USAGE.md) | How to run it, options, examples, high-security tips, troubleshooting |
| [docs/permissions.md](docs/permissions.md) | Every permission the tool can use, why, and its risk |
| [docs/bundle-format.md](docs/bundle-format.md) | Every file in the bundle (for support and tools that read bundles) |
| [Agent skill](.agents/skills/weaviate-support-bundle/SKILL.md) | How AI agents collect and read bundles, and the rules they follow |
| [CHANGELOG.md](CHANGELOG.md) | What changed in each version |
| [TODO.md](TODO.md) | Planned work |

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for how the code is organised and the rules every
change must follow, and [docs/releasing.md](docs/releasing.md) for releases.
Run the tests with `bash tests/run-all.sh` (no cluster needed).

## License

BSD 3-Clause. See [LICENSE](LICENSE).
