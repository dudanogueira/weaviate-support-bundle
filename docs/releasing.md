# Releasing

For maintainers. Customers do not need this page.

## Versions

Versions follow [semantic versioning](https://semver.org): `MAJOR.MINOR.PATCH`.

| Change | Example | Bump |
|---|---|---|
| Bug fix, wording, a new red flag, a new field in a file | 1.0.0 → 1.0.1 | PATCH |
| New collector, new option, new file in the bundle | 1.0.1 → 1.1.0 | MINOR |
| Something that breaks people or tools reading bundles: a file or field renamed or removed, an option removed | 1.1.0 → 2.0.0 | MAJOR (also bump `BUNDLE_SCHEMA_VERSION`) |

The version lives in one place: `TOOL_VERSION` in `lib/common.sh`. Every
bundle records it in `manifest.json`, so support always knows which version
produced a bundle.

`CHANGELOG.md` lists what changed in each version. With every change, add a line
under `## Unreleased` at the top of the file (create that heading if it is
not there yet). It collects what the next version will contain.

## Make a release

1. **Prepare** (in a pull request):
   - In `lib/common.sh`, set `TOOL_VERSION="1.1.0"`.
   - In `CHANGELOG.md`, rename `## Unreleased` to `## 1.1.0 (YYYY-MM-DD)`.
   - Merge the pull request once CI is green.
2. **Tag** the merged commit on `main`:
   ```bash
   git checkout main && git pull
   git tag v1.1.0
   git push origin v1.1.0
   ```
3. **Done.** The `Release` workflow runs all tests again, checks that the tag
   matches `TOOL_VERSION` and that `CHANGELOG.md` has a section for it, then
   publishes a GitHub release with the notes and a download
   (`weaviate-support-bundle-1.1.0.tar.gz` + `.sha256`).

If the workflow fails (for example the tag does not match the version), delete
the tag, fix, and tag again:

```bash
git tag -d v1.1.0 && git push origin :refs/tags/v1.1.0
```

## Compare versions

- What changed: `CHANGELOG.md`, or the release notes on GitHub.
- Exact code changes between two versions:
  ```bash
  git diff v1.0.0 v1.1.0
  ```
  or on GitHub: `https://github.com/weaviate/weaviate-support-bundle/compare/v1.0.0...v1.1.0`

## CI

`.github/workflows/ci.yml` runs on every pull request and every push to `main`:

| Job | What it checks |
|---|---|
| Lint (shellcheck) | Shell mistakes |
| Tests (ubuntu-latest) | Read-only static check, guard, redaction, offline end-to-end, with bash 5 and GNU tools |
| Tests (macos-latest) | The same with bash 3.2 and BSD tools (what most customers on a Mac have) |
| Real cluster (kind, 3 Weaviate replicas) | `tests/kind/run.sh`: a real Kubernetes cluster with the official Helm chart, sample data, a viewer API key, two broken pods |

Run the same locally:

```bash
bash tests/run-all.sh          # a few seconds, no cluster
bash tests/kind/run.sh         # about 5 minutes; needs docker, kind, helm
```

## Protect main

Once more people contribute, require pull requests with one approval and
green CI. This needs **Admin** on the repository.

On GitHub: **Settings → Rules → Rulesets → New ruleset → New branch ruleset**

1. Name: `main`. Enforcement status: **Active**.
2. Target branches: **Add target → Include default branch**.
3. Turn on:
   - **Restrict deletions**
   - **Block force pushes**
   - **Require a pull request before merging**, with
     **Required approvals: 1** and **Dismiss stale pull request approvals when new commits are pushed**
   - **Require status checks to pass**: add `Lint (shellcheck)`,
     `Tests (ubuntu-latest)`, `Tests (macos-latest)` and
     `Real cluster (kind, 3 Weaviate replicas)`
     (they appear in the list after CI has run once).
4. **Create**.

After that, nobody can push straight to `main`; every change goes through a
reviewed pull request with passing tests.
