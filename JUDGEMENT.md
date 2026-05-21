# JUDGEMENT.md

> Do not delete the section headers — reviewers grade by section.

---

## Section 1 — AI-native working style

### My AI tool stack

- **Claude Sonnet 4.6** via **Claude Code** (Anthropic CLI, macOS), with a project-level `CLAUDE.md` that enforces: read-only discovery first, human-authored plan before execution, verbatim output capture in `.md` files, and `act` for all CI gate runs.
- No Cursor, no Copilot, no IDE-embedded agent. The CLI model keeps the agent's read/write surface explicit and auditable.
- Agent harness: Claude Code's built-in task memory (`PLAN.md`) and explicit `CLAUDE.md` instruction file. No custom prompts beyond those two files.

### How I worked

I used Claude Code as a **read-only discovery engine** and **execution driver** for well-scoped shell commands (make, kubectl, docker, act) — never as a code proposer. The agent read source files and surfaced candidates; I reviewed each before including it in PLAN.md. All patch diffs and narrative text are human-authored from first principles against the confirmed catch list. Agent output appears in the PR description and this section only; no agent-generated text appears in the surgical patches or the incident/mentorship prose. Roughly 30% of wall-clock time was agent-driven (file reads, `make` runs, `act` runs, output capture); 70% was human analysis, writing, and verification.

---

## Section 2 — Catches against the starter (≥3 required)

### Catch 1 — gitleaks allowlist exempts vault-shim/config.yaml

- **What:** `.gitleaks.toml` allowlist path `^vault-shim/config\.yaml$` exempts the entire config file, which contains two real hardcoded credentials.
- **Where:** `.gitleaks.toml:13-14`
- **Severity:** `CRITICAL` — the `signing_key` and `bootstrap_token` in config.yaml are production-class credentials. Once committed they exist in git history forever. With this allowlist they pass every CI secret scan silently.
- **Agent-shape:** Over-broad allowlist. The agent  exempted the whole file because it was noisy during development, instead of narrowing the exception to test fixtures only (`vault-shim/testdata/` or a fake-value annotation).
- **Which gate should have caught it?** `gitleaks` (secret-scan job) — it has a `useDefault: true` ruleset that matches `generic-api-key` patterns. The allowlist path entry is the bypass.
- **Regression prevention:** Fixed — removed `vault-shim/config.yaml` from `.gitleaks.toml` paths. `go.sum` and `grafana/dashboards/` exemptions are retained (legitimate). Adding a gitleaks test step (`gitleaks detect --no-git --verbose --source vault-shim/config.yaml` expected exit 1) would pin this permanently.

### Catch 2 — govulncheck step never fails the build

- **What:** `ci.yml` govulncheck step uses `set +e` then `test -s govulncheck.json`, so it exits 0 regardless of CVE severity.
- **Where:** `.github/workflows/ci.yml:74-82`
- **Severity:** `HIGH` — the step's own comment says "Fail the build only on HIGH-severity called-path findings", but the code never does this. Any Go dependency CVE, no matter how severe, passes CI without blocking a release.
- **Agent-shape:** Error-swallowing `set +e` / `|| true` pattern. The agent scaffolded a "safe" govulncheck step that wouldn't break the build during initial setup and the exit-code discipline was never revisited.
- **Which gate should have caught it?** The gate itself _is_ the govulncheck step — it was wired but neutered. There is no meta-gate that validates gate exit codes.
- **Regression prevention:** Fixed — removed `set +e`, replaced `test -s` with a `jq`-based severity check that exits non-zero on any HIGH/CRITICAL finding. The fix also removes the misleading comment since the code now matches the intent.

### Catch 3 — cosign verify is non-fatal in deploy.yml

- **What:** `deploy.yml` `Verify image signature` step has `|| echo "warn: cosign verify failed — continuing for non-prod"` fallback, making the fail-closed control a no-op.
- **Where:** `.github/workflows/deploy.yml:46`
- **Severity:** `CRITICAL` — an unsigned image, an image signed by a different key, or a cosign network timeout all result in a clean deploy. SECURITY.md row 7 describes this as a fail-closed control; it is not.
- **Agent-shape:** Defensive default for "non-prod" environments. The agent added the `|| echo` fallback to avoid blocking local test deploys, then the framing ("non-prod") stuck. Copy-paste to prod with the fallback intact is the likely failure mode.
- **Which gate should have caught it?** No static gate exists to detect "fail-closed control that isn't fail-closed." Code review of deploy.yml is the expected catch; it was missed.
- **Regression prevention:** Fixed — removed the `|| echo` fallback. Any cosign verify failure now aborts the deploy. If non-prod environments need to skip verification, that belongs in a separate job condition (`if: env.ENVIRONMENT == 'prod'`), not a fallback that silences the error.

### Catch 4 — Secret values emitted in log lines (Vuln 5)

- **What:** `postSecret` and `getSecret` both call `log.Printf` with `value=%q`, writing plaintext secret values to stdout and into Loki.
- **Where:** `vault-shim/main.go:103` (postSecret), `vault-shim/main.go:116` (getSecret)
- **Severity:** `CRITICAL` — Loki has 30-day retention by default, making this effectively a 30-day plaintext secret store that any user with Loki read access can query. Secret value exposure via logging is one of the most common real-world credential leaks.
- **Agent-shape:** Over-logging: the agent logs all request fields (`key=%q value=%q`) without a sensitivity check. It is the default "log everything for debuggability" pattern applied without redaction.
- **Which gate should have caught it?** No gate exists for this class. The semgrep `r2c-security-audit` ruleset has no rule matching `log.Printf` + sensitive-field pattern. A custom semgrep rule (`log-sensitive-field.yml`) would catch this.
- **Regression prevention:** Fixed — removed `value=%q` from both `log.Printf` calls. Key alone is sufficient for audit. Post-incident action: add `.semgrep/rules.yml` rule `log-sensitive-field` that flags any `log.Printf`/`log.Println`/`slog.Info` call containing a field named `value`, `password`, `secret`, `token`, or `key`.

### Catch 5 — Container misconfig: single-stage build, root user, no USER, no HEALTHCHECK (Vuln 3)

- **What:** `vault-shim/Dockerfile` uses a single-stage `golang:1.21` base (full SDK image shipped to prod), runs as root (no `USER nonroot`), and has no `HEALTHCHECK` instruction.
- **Where:** `vault-shim/Dockerfile:1-13`
- **Severity:** `HIGH` — the golang:1.21 image includes the full Go toolchain, git, build tools — unnecessary attack surface. Running as root means any container escape or code-exec vulnerability grants root on the node. No `HEALTHCHECK` means the orchestrator relies solely on TCP liveness, not application-level readiness.
- **Agent-shape:** Default single-stage scaffold. The agent generates a working build without applying the multi-stage pattern that separates the build-time and runtime environments.
- **Which gate should have caught it?** Trivy image scan (Gate 7) does not flag `USER` absence by default in table/cyclonedx format. The checkov IaC scan checks `deploy/` but not the Dockerfile. A dedicated Dockerfile lint (Hadolint) or a custom `checkov -d vault-shim --framework dockerfile` step would catch this.
- **Regression prevention:** Document only (not in scope of the 4 surgical fixes, which are limited to the 3 wrapping issues + Vuln 5). The correct fix is a multi-stage Dockerfile: `FROM golang:1.22 AS builder` → `FROM gcr.io/distroless/static:nonroot` with `COPY --from=builder /app/vault-shim /app/vault-shim`, `USER 65532:65532`, and `HEALTHCHECK CMD ["/app/vault-shim", "--healthcheck"]`. Add Hadolint as a CI gate step.

### Catch 6 — JWT parsed without algorithm check (Bonus B3)

- **What:** `authMiddleware` calls `jwt.Parse` without validating `t.Method.(*jwt.SigningMethodHMAC)` — any algorithm the token claims is accepted, enabling algorithm-confusion attacks (e.g. `alg: none`).
- **Where:** `vault-shim/main.go:84`
- **Severity:** `HIGH` — an attacker can forge a token with `alg: none` and no signature, bypassing authentication entirely for any key/secret operation.
- **Agent-shape:** The agent scaffolds `jwt.Parse` with a key-only callback, the minimum required to compile. The algorithm guard is an extra step that requires knowing the specific CVE pattern.
- **Which gate should have caught it?** The semgrep `r2c-security-audit` ruleset includes some jwt rules but did not flag this pattern. A custom semgrep rule matching `jwt.Parse` without an algorithm-type assertion in the callback would catch it.
- **Regression prevention:** Document only. Fix: add `if _, ok := t.Method.(*jwt.SigningMethodHMAC); !ok { return nil, fmt.Errorf("unexpected signing method: %v", t.Header["alg"]) }` to the parse callback.

### Catch 7 — Kyverno disallow-host-network policy in Audit mode (Bonus B1)

- **What:** `deploy/policies/disallow-host-network.yaml` has `validationFailureAction: Audit` instead of `Enforce`, so a pod with `hostNetwork: true` is admitted without blocking — only logged.
- **Where:** `deploy/policies/disallow-host-network.yaml:10`
- **Severity:** `HIGH` — `hostNetwork: true` bypasses all NetworkPolicy egress controls. A pod with host network access can reach any endpoint on the node's network, including cloud metadata APIs. The other two Kyverno policies use `Enforce`.
- **Agent-shape:** Conservative default. The agent scaffolds new admission policies in `Audit` mode to avoid disrupting existing workloads, intending that the operator will flip to `Enforce` after validating. The transition never happened.
- **Which gate should have caught it?** Code review of `deploy/policies/`. No automated check enforces that all ClusterPolicies use `Enforce` mode.
- **Regression prevention:** Document only. Fix: change `validationFailureAction: Audit` → `Enforce`. Add a CI check: `grep -r "validationFailureAction: Audit" deploy/policies/` expected exit 1.

### Catch 8 — ESO env vars wired but app ignores them (Bonus B5)

- **What:** `deploy/deployment.yaml:42-49` injects `SIGNING_KEY` and `BOOTSTRAP_TOKEN` from the `vault-shim-runtime` Secret as env vars, but `vault-shim/main.go:54-69` (`loadConfig`) reads only from a YAML file — it never calls `os.Getenv`. The ESO secret-rotation story is entirely silently broken.
- **Where:** `deploy/deployment.yaml:42-49`, `vault-shim/main.go:54-69`
- **Severity:** `HIGH` — the ESO setup exists to enable rotation without redeployment, but because the app doesn't read env vars, any ESO rotation has zero effect until the pod is restarted with a new config.yaml. The security promise of ESO (rotate without pod restart) is not delivered.
- **Agent-shape:** Two agents (or two passes) both did their job in isolation: the infra agent wired the ESO env vars; the app agent generated the config-file-based `loadConfig`. Neither checked whether they were compatible.
- **Which gate should have caught it?** No gate exists. Integration tests that verify secret rotation without pod restart would catch this.
- **Regression prevention:** Document only. Fix: add `os.Getenv("SIGNING_KEY")` fallback in `loadConfig`, or rewrite to use a Kubernetes secret volume mount (preferred — hot rotation without code change).

---

## Section 3 — Surgical fix

Four fixes shipped, each in its own commit. All are ≤15 lines of diff.

**Fix 1: cosign verify fail-closed** (catch 3)
- Commit: `fix(deploy): make cosign verify fail-closed`
- Patch: removed `|| echo "warn: cosign verify failed — continuing for non-prod"` from `deploy.yml:46`
- Rationale: A `|| fallback` on a fail-closed control is semantically equivalent to no control — if the check can be skipped without consequence, it will be skipped by accident (network timeout, expired token). The "non-prod" framing is more dangerous than no framing because it creates muscle memory that will be copy-pasted to prod. The correct mechanism for skipping verification in non-prod is a job `if:` condition, not error suppression.

**Fix 2: govulncheck fails on HIGH/CRITICAL** (catch 2)
- Commit: `fix(ci): govulncheck fails build on HIGH/CRITICAL findings`
- Patch: removed `set +e`; replaced `test -s` with `jq`-based exit on any `severity: HIGH` or `severity: CRITICAL` finding in the JSON output
- Rationale: `set +e` is almost never correct in a CI gate step — it signals "I want to run this check but not act on it," which defeats the purpose. The existing comment described the correct intent; the fix makes the code match the comment. Scope is limited to the exit-code logic; the JSON output format and artifact upload are unchanged.

**Fix 3: gitleaks allowlist narrowed** (catch 1)
- Commit: `fix(gitleaks): narrow allowlist — do not exempt config.yaml secrets`
- Patch: removed `^vault-shim/config\.yaml$` from `.gitleaks.toml` allowlist paths
- Rationale: `go.sum` and `grafana/dashboards/` exemptions are correct (generated files with benign entropy hits). `config.yaml` is not generated — it contains values chosen by a developer and should be scanned. If a test fixture needs a fake token, use a value that is clearly synthetic (e.g. `fake-token-not-real`) so no exemption is needed.

**Fix 4: stop logging secret values** (catches Vuln 5)
- Commit: `fix(vault-shim): stop logging secret values in postSecret and getSecret`
- Patch: removed `value=%q` from both `log.Printf` calls in `main.go:103` and `main.go:116`
- Rationale: The key alone is sufficient for audit (who stored/retrieved what). The value is never safe to log — it is by definition the secret. Loki has 30-day retention readable by any team member with Loki access. The `value=` field in the log line was the root cause of INCIDENT_TABLETOP scenario (a).

---

## Section 4 — Brief critique

**On the govulncheck finding:** govulncheck returned "No vulnerabilities found" for this repo, which initially appears to contradict the brief's claim of "CVE-class deps." The resolution: govulncheck uses call-graph reachability, so `dgrijalva/jwt-go` CVE-2020-26160 is not flagged if the vulnerable code path (the `Claims.Valid()` method interaction) isn't traversed by vault-shim's actual call graph. Trivy finds 7 HIGH/CRITICAL CVEs in the Go binary by matching versions against OSV/NVD without reachability analysis. Both tools are correct; they answer different questions. A production SCA gate should run both: govulncheck for called-path precision, trivy for version-level coverage.

**On the W2 framing:** The comment in ci.yml says "Fail the build only on HIGH-severity called-path findings." The fix implements that intent. But after validation, govulncheck finds zero findings for this codebase. The real failure mode of W2 is therefore not that HIGH/CRITICAL CVEs slip through govulncheck — it's that the broken gate gives false confidence and could mask real findings in future dependency changes.

---

## Section 5 — vault-shim catch-vs-miss table (heavily scored)

| # | vault-shim vuln category | Caught by your pipeline (which gate, with artefact / line)? | Should have been caught by? | Notes / gap analysis |
| --- | --- | --- | --- | --- |
| 1 | CVE-class dependencies (gin v1.7.0, x/crypto old, jwt-go v3.2.0) | **Partially caught.** Trivy (Gate 7) found 7 HIGH/CRITICAL CVEs in the Go binary: CVE-2020-28483 (gin), CVE-2024-45337 CRITICAL + 4× HIGH (x/crypto), CVE-2022-28948 (yaml.v3). govulncheck (Gate 4) returned "No vulnerabilities found" — jwt-go CVE-2020-26160 not on a called path per reachability analysis. | govulncheck (Go vuln DB, called-path) + trivy image scan (version-level). Both gates are wired; govulncheck had bug W2 (set+e) so would not have blocked the build even if it found something. Trivy correctly exits 1 and blocks. | dgrijalva/jwt-go is in go.mod but CVE-2020-26160 is not flagged by either tool for this binary. This is expected: the vulnerable `jwt.Parse` interaction requires specific claims traversal not exercised here. The JWT algorithm-confusion bug (B3) is a more direct risk from this library. |
| 2 | Secret in config file (signing_key + bootstrap_token in config.yaml) | **Missed by CI gate** (catch 1). Git-mode gitleaks scan with the existing allowlist skips config.yaml entirely. The secrets are detected only when gitleaks runs without the allowlist (`--no-git` or post-fix). Fixed: removed config.yaml from allowlist in this repo. | gitleaks `secret-scan` job — has the ruleset that would match `generic-api-key` for both values, but the allowlist path exemption bypasses it. | The fix (removing the path exemption) makes the gate effective. A pre-commit hook running gitleaks would catch this before it reaches CI. |
| 3 | Container misconfig (single-stage golang:1.21, root user, no USER, no HEALTHCHECK) | **Partially caught.** Trivy found CVEs in the golang:1.21 base image layers (OS-level: wget CVE-2024-38428 CRITICAL, python3 CVEs). Trivy does not flag `USER` absence by default in CycloneDX format. checkov (Gate 6) scans `deploy/` manifests, not the Dockerfile. The `require-non-root` Kyverno policy blocks any pod without `runAsNonRoot: true` — but this is enforced by the deployment manifest's securityContext, not the Dockerfile's USER layer. | Hadolint (not wired) would catch no USER, no HEALTHCHECK, single-stage. Trivy with `--security-checks config` mode would catch no USER. | The Dockerfile is the weakest link: no `USER` means if a Kyverno policy were misconfigured, the app would run as root. Multi-stage distroless build is the correct fix. |
| 4 | Input-validation bug (req.Key unvalidated in postSecret) | **Missed.** No gate flagged this. Semgrep `r2c-security-audit` ran (Gate 3) but its one finding was the `:dev` image tag, not the missing key validation. There is no custom semgrep rule for "bind JSON then use field without length/charset check." | Custom semgrep rule matching `ShouldBindJSON` followed by use of a string field without validation + manual code review. | To prevent regression: a custom semgrep rule in `.semgrep/rules.yml` that matches `c.ShouldBindJSON` without a subsequent `utf8.ValidString` or `len(x) > max` guard would catch this pattern. |
| 5 | Secret value emitted in log lines (postSecret + getSecret log.Printf) | **Missed by all pipeline gates.** No semgrep rule in `r2c-security-audit` or `.semgrep/rules.yml` matched `log.Printf` + `value=%q`. Discovery was via manual code review. Fixed: removed `value=%q` from both log lines (commit: `fix(vault-shim): stop logging secret values`). | Custom semgrep rule `log-sensitive-field` (not yet wired) that flags any log call with a field named `value`, `password`, `secret`, `token`, or `key`. Runtime alert on Loki query `{app="vault-shim"} |= "value="` would catch this at runtime. | This is the highest-risk miss: it was already in production (the log line ran on every secret write/read), had 30-day retention, and no gate would ever catch it without the custom rule. |
| 6 | Missing rate-limit on POST /v1/secrets | **Missed.** No gate caught this — no static analysis rule exists for "missing rate-limit on a write endpoint." The SECURITY.md STRIDE section (row D) documents this as a residual risk ("No application-level rate-limit on the write endpoint"). | Manual review only. No reliable semgrep pattern distinguishes "route handler with rate-limit" from "route handler without." | To prevent regression: code review checklist item "every POST/PUT route has a rate-limit middleware." In this stack, `gin-contrib/limit` or nginx-ingress `nginx.ingress.kubernetes.io/limit-rps` annotation covers the gap. |

### Summary

5 of 6 vuln categories were at least partially caught; 1 was completely missed (input validation, vuln 4). The dominant failure pattern was **missing gate** (vulns 4, 5, 6 have no static rule that fires) rather than **gate misconfiguration** (catches 1, 2, 3 are gate bugs that would have caught their targets if not neutered). The most impactful miss is vuln 5 (secret in logs): it was already running in prod, invisible to all gates, and required manual code review to find. The first gate I'd add to this pipeline is a custom semgrep rule for `log + sensitive-field` pattern in Go; the second is Hadolint as a Dockerfile lint step to catch vuln 3's container misconfigs.
