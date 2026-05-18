# SECURITY.md — vault-shim controls matrix and threat model

Mapped to MAS TRM Guidelines, ISO 27001 Annex A, and SOC 2 Trust Service Criteria. ≥12 rows.

## Controls matrix

| # | Control | MAS TRM | ISO 27001 | SOC 2 | Enforcement | Evidence artefact |
| --- | --- | --- | --- | --- | --- | --- |
| 1 | **Pod Security Standards — Restricted, enforced at namespace** | §8 System Security | A.8.9 Configuration mgmt | CC6.1 Logical access | `deploy/namespace.yaml` `pod-security.kubernetes.io/enforce: restricted` | `kubectl get ns vault-shim -o yaml` |
| 2 | **Containers run as non-root with read-only root FS** | §8 System Security | A.8.32 Change mgmt | CC6.1 | `deploy/deployment.yaml` pod + container `securityContext` | `kubectl -n vault-shim get pod -l app.kubernetes.io/name=vault-shim -o yaml \| yq '.spec.securityContext'` |
| 3 | **Default-deny NetworkPolicy + explicit allow-list** | §8 Network Security | A.8.20 Networks security | CC6.6 | `deploy/networkpolicy.yaml` | `kubectl -n vault-shim get networkpolicy` |
| 4 | **No cluster-wide RBAC bindings** | §11 IAM | A.5.15 Access control | CC6.3 | `deploy/serviceaccount.yaml` (RoleBinding only, no ClusterRoleBinding) | `kubectl get clusterrolebindings \| grep vault-shim` (expected: empty) |
| 5 | **Secrets via External Secrets Operator — no `kind: Secret` in repo** | §13 Cryptography | A.5.17 Authentication info | CC6.1 | `deploy/externalsecret.yaml`; `.semgrep/rules.yml` `deploy-no-plain-k8s-secret` rule | grep `^kind: Secret` in `deploy/` (expected: only in `externalsecret.yaml` target) |
| 6 | **Image immutability — image referenced by digest in deploy.yml** | §13 Cryptography | A.8.30 Outsourced development | CC8.1 | `.github/workflows/deploy.yml` `image_digest` input | Workflow input + applied manifest spec |
| 7 | **Image signing — cosign keyless OIDC** | §13 Cryptography / §6 Change mgmt | A.5.21 Supply-chain security | CC8.1 | `.github/workflows/ci.yml` `container-scan-and-sign` job + `.github/workflows/deploy.yml` `Verify image signature` step | Workflow run artefact `cosign-attestation`; Rekor transparency log entry |
| 8 | **SAST — semgrep on every push** | §13 Vuln mgmt | A.8.28 Secure coding | CC7.1 | `.github/workflows/ci.yml` `sast-semgrep` job | Workflow run artefact `semgrep-sarif` |
| 9 | **SCA — govulncheck on every push** | §13 Vuln mgmt | A.8.8 Vulnerability mgmt | CC7.1 | `.github/workflows/ci.yml` `sca-govulncheck` job | Workflow run artefact `govulncheck-report` |
| 10 | **Secret scan — gitleaks on every push, with branch history** | §13 Vuln mgmt | A.5.17 Authentication info | CC7.1 | `.github/workflows/ci.yml` `secret-scan` job + `.gitleaks.toml` | Workflow run artefact `gitleaks-report` |
| 11 | **IaC scan — checkov on every push** | §13 Vuln mgmt | A.8.9 Configuration mgmt | CC7.1 | `.github/workflows/ci.yml` `iac-scan` job | Workflow run artefact `checkov-deploy` |
| 12 | **Container scan + CycloneDX SBOM — Trivy on every build** | §13 Vuln mgmt | A.8.30 Outsourced dev | CC7.1 | `.github/workflows/ci.yml` `container-scan-and-sign` job | Workflow run artefact `trivy-cyclonedx-sbom` |
| 13 | **Admission policy — Kyverno enforces ≥3 PSS rules at admission** | §8 System Security | A.8.9 | CC6.1 | `deploy/policies/*.yaml` + `.github/workflows/ci.yml` `policy-gate` job | `kubectl apply --dry-run=server` of a violating manifest (rejected) |
| 14 | **CI authentication — GitHub OIDC (no static cloud keys)** | §11 IAM | A.5.16 Identity mgmt | CC6.1 | `.github/workflows/*.yml` `permissions.id-token: write` + `aws-actions/configure-aws-credentials` with `role-to-assume` | Repo Settings → Secrets shows no static cloud keys |
| 15 | **Pinned GitHub Action SHAs (not `@latest`)** | §6 Change mgmt | A.5.21 Supply-chain security | CC8.1 | All `uses:` references in `.github/workflows/*.yml` pin a SHA | `grep -RE 'uses: .*@(v[0-9]+\\.[0-9]+\\.[0-9]+\|latest)' .github/workflows/` (expected: only with SHA prefix) |
| 16 | **Structured JSON logging with request_id + trace_id** | §13 Audit Logging | A.8.15 Logging | CC7.2 | vault-shim emits JSON logs with `request_id` + OTel `trace_id` correlated; Promtail tails container logs into Loki | `logcli query '{app="vault-shim"} \| json' --limit 5` |
| 17 | **Runbook-linked alerts — every alert has a runbook URL** | §13 Incident mgmt | A.5.24 Incident response planning | CC7.4 | `observability/alerts/alerts.yaml` `annotations.runbook_url` on each rule | Alertmanager UI shows each alert with link to `RUNBOOK.md#scenario-...` |

---

## STRIDE threat model — vault-shim

| Threat | Asset | Mitigation | Residual risk |
| --- | --- | --- | --- |
| **Spoofing** | Caller identity on `/v1/secrets/*` | `authMiddleware` validates bearer token signed with `signing_key` (from ExternalSecret). | A stolen bootstrap token grants full access until rotation — see incident scenario (c). |
| **Tampering** | Stored secret values | In-memory store; nothing persists across pod restarts. Production would back this with KMS-encrypted DynamoDB. | Pod compromise = full read of in-memory store. Mitigation: scope per-pod via SA + separate stores per tenant in prod. |
| **Repudiation** | Secret write actions | Every `POST /v1/secrets` logs `request_id`, `actor_id`, route, status to Loki. | The log line in vault-shim currently includes the secret value itself (see vault-shim notes). |
| **Information disclosure** | Secrets in logs | OTel trace events redact bearer values; Loki retention is 30d. | The application-side log line for `POST/GET /v1/secrets/...` is the weak link. |
| **Denial of service** | `POST /v1/secrets` endpoint | nginx-ingress proxy-body-size cap; ALB-tier rate limit (prod). | No application-level rate-limit on the write endpoint. Defence-in-depth gap. |
| **Elevation of privilege** | Service account | RoleBinding only — no ClusterRoleBinding. Read-only on a single ConfigMap. | RBAC drift over time. Mitigation: Kyverno policy denying cluster-wide bindings tagged with vault-shim namespace. |
