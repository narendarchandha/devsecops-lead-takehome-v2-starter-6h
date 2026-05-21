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

### SCA — `govulncheck`

| Aspect | Value |
| --- | --- |
| Tool | `govulncheck v1.1.3` installed via `go install golang.org/x/vuln/cmd/govulncheck@v1.1.3`; scans the vault-shim Go module for called-path vulnerabilities using the Go vulnerability database (vuln.go.dev) |
| Artefact | `govulncheck.json` (NDJSON, one JSON object per line) uploaded as `govulncheck-report` |
| Storage | GitHub Actions workflow run artefacts (S3-backed by GitHub) |
| Retention | 90 days (GitHub default); bump to 400 days for `main` branch runs via repo settings → Actions → Artifact and log retention |
| Auditor retrieval | `gh run list --commit XYZ --workflow ci.yml --json databaseId --jq '.[0].databaseId' \| xargs -I{} gh run download {} -n govulncheck-report && jq '[.[] \| select(.osv) \| {id: .osv.id, summary: .osv.summary, severity: .osv.severity}]' govulncheck.json` |

### Container scan + SBOM — `trivy`

| Aspect | Value |
| --- | --- |
| Tool | `aquasecurity/trivy-action@0.20.0`; image scan in CycloneDX format; severity filter HIGH,CRITICAL; ignore-unfixed: true; exit-code: 1 (fails build on findings) |
| Artefact | `vault-shim.cdx.json` (CycloneDX SBOM with embedded vulnerability data) uploaded as `trivy-cyclonedx-sbom` |
| Storage | GitHub Actions workflow run artefacts (S3-backed by GitHub) |
| Retention | 90 days (GitHub default) |
| Auditor retrieval | `gh run list --commit XYZ --workflow ci.yml --json databaseId --jq '.[0].databaseId' \| xargs -I{} gh run download {} -n trivy-cyclonedx-sbom && jq '.vulnerabilities[] \| {id: .id, severity: .ratings[0].severity, pkg: .affects[0].ref}' vault-shim.cdx.json` |

### Image signing — `cosign`

| Aspect | Value |
| --- | --- |
| Tool | `sigstore/cosign-installer@e1523de7571e31dbe865fd2e80c5c7c23ae71eb4` (v3.4.0); keyless OIDC signing via `token.actions.githubusercontent.com`; `COSIGN_EXPERIMENTAL=1` |
| Artefact | In production: OCI signature layer attached to the image digest in `ghcr.io/<repo>/vault-shim@<digest>` + Rekor transparency log entry. In this take-home: stub `cosign-attestation.txt` uploaded as `cosign-attestation` (actual registry push not wired) |
| Storage | Production: OCI registry (GitHub Container Registry) + Rekor public log (permanent, append-only). Take-home: GitHub Actions workflow run artefact (90 days) |
| Retention | Rekor entry is permanent (append-only transparency log). GitHub artefact: 90 days |
| Auditor retrieval | Production: `cosign verify --certificate-identity-regexp "https://github.com/<repo>/.*" --certificate-oidc-issuer "https://token.actions.githubusercontent.com" ghcr.io/<repo>/vault-shim@<digest>` — prints the verified certificate chain + Rekor bundle. Rekor lookup: `rekor-cli get --rekor_server https://rekor.sigstore.dev --uuid <uuid-from-cosign-verify-output>`. Take-home stub: `gh run list --commit XYZ --workflow ci.yml --json databaseId --jq '.[0].databaseId' \| xargs -I{} gh run download {} -n cosign-attestation` |

### Policy gate — Kyverno admission dry-run

| Aspect | Value |
| --- | --- |
| Tool | Kyverno v1.12.0; policies: `disallow-privilege-escalation` (Enforce), `require-non-root` (Enforce), `disallow-host-network` (Audit — see catch B1 in JUDGEMENT.md); negative test applies a bad pod manifest with `allowPrivilegeEscalation: true` and expects non-zero exit |
| Artefact | Console log of the `policy-gate` CI job (no separate artefact upload — the negative test output is in the job's log stream) |
| Storage | GitHub Actions workflow run logs (streamed; not a downloadable artefact) |
| Retention | 90 days (GitHub default) |
| Auditor retrieval | `gh run list --commit XYZ --workflow ci.yml --json databaseId --jq '.[0].databaseId' \| xargs -I{} gh run view {} --log --job "kyverno admission dry-run on kind" \| grep -E "rejected\|Forbidden\|Policy gate"`. Auditor confirms: (1) the bad manifest apply returned non-zero exit; (2) the error message includes the Kyverno/PSA policy name; (3) the job step "Negative test — bad manifest must be rejected" shows "Policy gate rejected as expected." |

---

## Exceptions register

Documented at `.security/exceptions.yaml`. Each exception has an expiry date and a re-review owner. Empty by default (no findings accepted unless explicitly chosen). See `exceptions.yaml` for the schema.
