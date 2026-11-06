# Instructions for AI agents

This folder is the Weaviate support bundle tool: `collect.sh` collects
read-only diagnostics from a Weaviate cluster on Kubernetes into one archive.

- **To collect a support bundle, or to read one:** follow
  [.agents/skills/weaviate-support-bundle/SKILL.md](.agents/skills/weaviate-support-bundle/SKILL.md).
  Its rules always apply: run only `collect.sh` and the skill's
  `read-bundle.sh`, show the preflight and wait for the user's yes before
  collecting, never handle API keys, and never send the bundle anywhere.
- **To change the code** (in the git repository): follow
  [CONTRIBUTING.md](CONTRIBUTING.md).
