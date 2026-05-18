# .security/EVIDENCE.md — auditor retrieval

For each CI gate, this file documents:

1. The tool the gate runs.
2. The artefact the gate produces.
3. Where the artefact is stored.
4. The retention window.
5. The exact command an auditor runs to retrieve evidence for build SHA `XYZ` six months from now.

5 of 9 rows are complete. The 4 stub rows are your work at this tier — see the rows marked `<TO COMPLETE>` below.

---

## Per-gate evidence

### Lint — `golangci-lint`

| Aspect | Value |
| --- | --- |
| Tool | `golangci-lint` v1.59.1 |
| Artefact | Workflow run console log (no separate artefact — lint output is in the job's log stream) |
| Storage | GitHub Actions workflow logs |
| Retention | 90 days (GitHub default; bumped to 400 days for `main`) |
| Auditor retrieval | `gh run view <run-id> --job <job-id> --log` filtered for `lint` job, OR for a specific SHA: `gh run list --commit XYZ --workflow ci.yml --json databaseId --jq '.[0].databaseId' \| xargs -I{} gh run view {} --log` |

### Unit tests — `go test`

| Aspect | Value |
| --- | --- |
| Tool | `go test ./... -race -cover -coverprofile=cover.out` |
| Artefact | `cover.out` (coverage profile) uploaded as `go-coverage` |
| Storage | Workflow run artefacts (S3-backed by GitHub) |
| Retention | 90 days (GitHub default) |
| Auditor retrieval | `gh run download <run-id> -n go-coverage` then `go tool cover -func=cover.out` |

### SAST — `semgrep`

| Aspect | Value |
| --- | --- |
| Tool | `semgrep` with `p/r2c-security-audit` registry config + `.semgrep/rules.yml` repo-local rules |
| Artefact | `semgrep.sarif` uploaded as `semgrep-sarif`; also pushed to GitHub Code Scanning |
| Storage | Workflow run artefacts + GitHub Security tab |
| Retention | 90 days (artefacts); GitHub Security tab retains indefinitely until the alert is dismissed/fixed |
| Auditor retrieval | GitHub Security tab → filter by SHA `XYZ`; OR `gh run download <run-id> -n semgrep-sarif` |

### Secret scan — `gitleaks`

| Aspect | Value |
| --- | --- |
| Tool | `gitleaks` v8.18.4 with `.gitleaks.toml` repo-local config |
| Artefact | `results.sarif` uploaded as `gitleaks-report` |
| Storage | Workflow run artefacts |
| Retention | 90 days |
| Auditor retrieval | `gh run download <run-id> -n gitleaks-report` then `jq '.runs[].results' results.sarif` |

### IaC scan — `checkov`

| Aspect | Value |
| --- | --- |
| Tool | `checkov` v3.2.34 with `--framework kubernetes` over `deploy/` |
| Artefact | `results_sarif.sarif` uploaded as `checkov-deploy` |
| Storage | Workflow run artefacts |
| Retention | 90 days |
| Auditor retrieval | `gh run download <run-id> -n checkov-deploy` then `jq '.runs[].results[] | {ruleId, message: .message.text, level}' results_sarif.sarif` |

---

### SCA — `govulncheck` `<TO COMPLETE>`

| Aspect | Value |
| --- | --- |
| Tool | `<fill in: govulncheck version + what it scans>` |
| Artefact | `<fill in: artefact name as uploaded by ci.yml>` |
| Storage | `<fill in>` |
| Retention | `<fill in>` |
| Auditor retrieval | `<fill in: the exact gh / jq command sequence to extract findings for SHA XYZ>` |

### Container scan + SBOM — `trivy` `<TO COMPLETE>`

| Aspect | Value |
| --- | --- |
| Tool | `<fill in: Trivy version, CycloneDX format>` |
| Artefact | `<fill in>` |
| Storage | `<fill in>` |
| Retention | `<fill in>` |
| Auditor retrieval | `<fill in>` |

### Image signing — `cosign` `<TO COMPLETE>`

| Aspect | Value |
| --- | --- |
| Tool | `<fill in: cosign version, keyless OIDC issuer>` |
| Artefact | `<fill in: signature blob + Rekor transparency log entry URL pattern>` |
| Storage | `<fill in: GitHub artefact + Rekor public log>` |
| Retention | `<fill in: Rekor is permanent; GitHub artefact is 90 days>` |
| Auditor retrieval | `<fill in: cosign verify command an auditor runs against `ghcr.io/.../vault-shim@<digest>`; how to look up the Rekor entry>` |

### Policy gate — Kyverno admission dry-run `<TO COMPLETE>`

| Aspect | Value |
| --- | --- |
| Tool | `<fill in: Kyverno version, which policies>` |
| Artefact | `<fill in: console log of the negative test? a dedicated upload?>` |
| Storage | `<fill in>` |
| Retention | `<fill in>` |
| Auditor retrieval | `<fill in: gh run log filtered for the policy-gate job + what the auditor confirms (negative test rejected; positive test passed)>` |

---

## Exceptions register

Documented at `.security/exceptions.yaml`. Each exception has an expiry date and a re-review owner. Empty by default (no findings accepted unless explicitly chosen). See `exceptions.yaml` for the schema.
