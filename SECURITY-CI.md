# Security CI

Three workflows check every pull request, every push to `upgrade/vault` and the default branch on a
schedule, beside `ci.yml` (lint, kubeconform, terraform validate, the yindex build and image). Results go
to the run summary and to GitHub code scanning (Security → Code scanning, one category per tool). Only
Semgrep and Dependabot ever open pull requests, and each keeps a fixed small number open, updated in place.

| Leg | Workflow / job | Gate on a PR | Results | Accept a finding |
|---|---|---|---|---|
| Semgrep (pinned community packs for Go, Terraform, Kubernetes YAML, Dockerfiles, shell, Python, browser JS, nginx, secrets, GitHub Actions; Trail of Bits Go/Python/generic/Actions; `contrib/semgrep/rules`) | `semgrep.yml` | fails on a new **critical** finding the PR adds | summary, code scanning `semgrep`, at most four rolling PRs `semgrep/<bucket>` | `contrib/semgrep/accepted.json` (fingerprint or rule × paths, with reason), or `config.json` `exclude_rules` / `audit_rules` / `bucket_overrides` — see `contrib/semgrep/README.md` |
| Semgrep local rule tests | `secops.yml` `semgrep-rules` | fails when a rule in `contrib/semgrep/rules` misses or over-matches its annotated test file | log | fix the rule or its test (`<name>.yaml` beside `<name>.<ext>`) |
| CodeQL (`go`, `python`, `javascript-typescript`, `actions`; `security-extended`) | `codeql.yml` | never fails; new alerts show on the PR | code scanning `codeql-<language>` | dismiss the alert in code scanning with a reason |
| zizmor (workflow security) | `secops.yml` `zizmor` | fails on any finding in `.github/` | log, code scanning `zizmor` | fix the workflow; a justified exception is an inline `# zizmor: ignore[<audit>]` with the reason on the same line |
| gitleaks (secrets) | `secops.yml` `gitleaks` | fails on a leak in the PR's commits; nightly scans full history | code scanning `gitleaks` (values redacted) | test vectors, public constants and documentation examples only: add the fingerprint to `.gitleaksignore` under a reason comment. A real secret is rotated, never listed |
| OSV-Scanner (`yindex/go.mod`, the hash-locked scanner requirements) | `secops.yml` `osv-scanner` | fails on a known vulnerability | summary table, code scanning `osv-scanner` | fix it with a module/lockfile bump, or add `[[IgnoredVulns]]` to `osv-scanner.toml` with `reason` and `ignoreUntil` at most 90 days out |
| govulncheck (yindex, reachability; the Go toolchain's stdlib included) | `secops.yml` `govulncheck` | fails on a reachable vulnerability | log, code scanning `govulncheck` | bump the module or the Go version (`yindex/go.mod`, `images/yindex/Dockerfile`, `ci.yml`) |
| gosec (yindex) | `secops.yml` `gosec` | fails on any **HIGH** finding (none is open) | summary, code scanning `gosec` (every severity) | `// #nosec G<nnn> -- <reason>` on the line |
| Checkov (`infra/eks` Terraform, the chart rendered for kind and EKS, `images/*/Dockerfile`) | `secops.yml` `checkov` (`contrib/secops/checkov.sh`) | fails when the PR adds a failing check its base does not have (`contrib/secops/checkov-gate.py`; Checkov without a Prisma key has no severities, so "new failure" stands in for "new HIGH") | summary, code scanning `checkov`: the open failures are the hardening backlog | a policy-level exception goes in `.checkov.yaml` `skip-check` with its reason; one resource: a `#checkov:skip=<id>:<reason>` comment (Terraform, Dockerfile) or a `checkov.io/skip1: <id>=<reason>` annotation (Kubernetes) |
| Image pinning | `ci.yml` `lint` (`scripts/lint-images.sh`) and the Semgrep rules `ycash-infra.k8s.latest-image-tag`, `ycash-infra.docker.base-image-not-pinned-by-digest` | fails on `latest` or an untagged rendered image; base images are pinned by digest | log / Semgrep | — |
| Dependabot | `.github/dependabot.yml` | — | one grouped security PR per ecosystem (gomod, docker, terraform, pip, github-actions); version updates are off | close the PR with a reason |

Schedules: Semgrep 02:17 UTC nightly, secops 03:43 UTC nightly, CodeQL Mondays 04:41 UTC.

Tools are pinned: actions by commit SHA, release binaries by version and sha256 (in `secops.yml`),
govulncheck by module version (checked against the Go checksum database), pip installs hash-locked
(`contrib/semgrep/requirements.txt`, `contrib/secops/zizmor-requirements.txt`,
`contrib/secops/checkov-requirements.txt`). `contrib/semgrep/security-overrides.txt` and
`contrib/secops/checkov-overrides.txt` move a scanner's own transitive dependencies to fixed versions when
an advisory lands before the scanner releases a fix.

The repository's own invariants as Semgrep rules (`contrib/semgrep/rules/`): no `latest` image, base
images by digest, no host namespaces or privileged Pods in the chart, no credential in a ConfigMap or a
values file other than the kind regtest defaults (AGENTS.md rules 4, 7), and yindex never serving a
`YellowbackStreamer` method (AGENTS.md rule 1).

## Repository settings these need

- Code scanning results need GitHub code scanning (free on public repositories). Keep CodeQL **default
  setup off**: `codeql.yml` is an advanced configuration, and the two cannot run together.
- Settings → Code security: enable **Dependabot security updates** (Dependabot alerts on).
- Semgrep's rolling PRs: "Allow GitHub Actions to create and approve pull requests", and optionally the
  `SEMGREP_PR_TOKEN` secret (see the header of `semgrep.yml`).
