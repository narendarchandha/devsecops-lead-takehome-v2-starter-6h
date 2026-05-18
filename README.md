# HydraX DevSecOps Lead take-home — v2 6h starter

> **You are here:** the Hardened Kubernetes Pipeline + Incident Response (v2) 6-hour starter for the HydraX DevSecOps Lead (Singapore) take-home. Brief: `th-devsecops-lead-v2-6h.md` (in your invite email).
> Time-box: 3 working days, ~5.5–6 hrs.

This is a **6-hour judgement + validation exercise**, not a build exercise. The starter ships a complete-looking K8s + LGTM + DevSecOps setup: `vault-shim` deployable to a local kind cluster with PSS Restricted, default-deny NetworkPolicy, ExternalSecret, Kyverno policies, 9 CI gates all wired with artefacts, Loki + Tempo + Mimir + Grafana + Promtail + OTel Collector + RED + security-event dashboards. **It is also wrong in specific, plausible ways** — the kind of issues an agent generates and a junior reviewer misses.

Your job: bring it up, read every config, find what's wrong, validate end-to-end, document for the next on-call engineer + next junior hire.

**Read the brief (`th-devsecops-lead-v2-6h.md`) before you read anything else here.**

---

## Quick start (5 minutes)

```bash
# 1. Bring up the LGTM stack on the host (Loki/Tempo/Mimir/Grafana/Promtail/OTel Collector)
make observability-up
# Grafana → http://localhost:3000 (anonymous)

# 2. Create kind cluster + install ingress-nginx + Kyverno + ESO
make cluster-up

# 3. Build vault-shim image, load into kind, apply deploy/ + policies
make deploy

# 4. Add to /etc/hosts: 127.0.0.1 vault-shim.localtest.me
# Then:
curl http://vault-shim.localtest.me/healthz
curl http://vault-shim.localtest.me/readyz

# 5. Open Grafana → vault-shim — RED dashboard. You should see request rate + latency.

# 6. Run the negative tests (pod can't reach 1.1.1.1; bad manifest rejected)
make validate-negative-tests
```

Or one-shot: `make up`. Teardown: `make down`.

---

## What's in this repo

```
.
├── README.md                          this file
├── th-devsecops-lead-v2-6h.md         the brief (sent with your invite)
├── SECURITY.md                        controls matrix (MAS TRM / ISO 27001 / SOC 2)
├── RUNBOOK.md                         topology + how-to-debug + ops + handoff
├── INCIDENT_TABLETOP.md               skeleton — 1 scenario fleshed, 2 stubs (you flesh 1)
├── MENTORSHIP_GUIDE.md                skeleton — day 1-7 path filled; "lessons" section is your stub
├── JUDGEMENT.md.template              copy to JUDGEMENT.md; Section 5 catch-vs-miss heavily scored
├── VALIDATION.md.template             copy to VALIDATION.md; commit BEFORE patching anything
├── Makefile                           make help
├── docker-compose.yml                 vault-shim inner-loop dev
├── kind-config.yaml                   kind cluster config (1 control + 2 workers + ingress mappings)
├── .gitleaks.toml                     gitleaks config (read carefully)
├── .semgrep/rules.yml                 semgrep custom rules (read carefully; ruleset is sparse)
├── .security/
│   └── EVIDENCE.md                    auditor-retrieval per gate (5 of 9 rows; you complete 4)
├── .github/workflows/
│   ├── ci.yml                         9 gates: lint, test, semgrep, govulncheck, gitleaks, checkov, trivy, cosign, kyverno
│   └── deploy.yml                     cosign-verified deploy to local kind (read carefully)
├── vault-shim/                        the deliberately-vulnerable Go service (provided)
│   ├── main.go                        DO NOT REWRITE (≤80 LoC patches allowed)
│   ├── config.yaml
│   ├── go.mod / go.sum
│   └── Dockerfile
├── deploy/
│   ├── kustomization.yaml             kustomize entry for the namespaced resources
│   ├── namespace.yaml                 PSS Restricted enforced
│   ├── serviceaccount.yaml            namespace-scoped Role + RoleBinding; no cluster bindings
│   ├── externalsecret.yaml            fake-provider SecretStore + ExternalSecret
│   ├── deployment.yaml                hardened securityContext + probes + image-by-tag (read carefully)
│   ├── service.yaml
│   ├── ingress.yaml                   nginx-ingress at vault-shim.localtest.me
│   ├── networkpolicy.yaml             default-deny + 3 allow rules (read carefully)
│   ├── pdb-hpa.yaml
│   └── policies/
│       ├── require-non-root.yaml
│       ├── disallow-host-network.yaml          (read carefully)
│       └── disallow-privilege-escalation.yaml
└── observability/
    ├── README.md                      LGTM stack + cross-boundary networking notes
    ├── docker-compose.observability.yml
    ├── loki/, tempo/, mimir/, promtail/, otel-collector/
    ├── grafana/
    │   ├── provisioning/
    │   └── dashboards/
    │       ├── red.json               RED — provisioned
    │       └── security-event.json    failed-auth + secret-access by actor + NetworkPolicy denies
    └── alerts/alerts.yaml             3 alert rules with runbook_url annotations
```

---

## What you write (6 hours of work)

Order matters. The brief explains why each item is in the order it is.

1. **`VALIDATION.md`** (~45 min) — copy `VALIDATION.md.template`. Bring up the stack. Run the negative tests. Trace one request through LGTM. Run each CI gate (locally or trigger the workflow). Paste evidence. **Commit BEFORE patching anything.**
2. **`JUDGEMENT.md` Section 1, Section 2, Section 5** (~2 hr) — copy `JUDGEMENT.md.template`. Read every workflow YAML, every manifest, every Kyverno policy, every `vault-shim/` file. List ≥3 catches in Section 2 with file:line + severity + agent-shape + which-gate-missed-it. Fill Section 5 catch-vs-miss table against vault-shim's 6 deliberate vulns.
3. **One surgical fix** (~30 min) — pick one catch. Patch. Commit. Add 3-line rationale.
4. **`INCIDENT_TABLETOP.md` scenario (a)** (~1 hr) — flesh out the "secret in logs" scenario in detail. Specific `kubectl` + `logcli` commands. Real log group names from the starter.
5. **`MENTORSHIP_GUIDE.md` lessons section** (~30 min) — top 5 operating-discipline lessons in your voice. Sound like a person who's been on-call, not a doc generator.
6. **`.security/EVIDENCE.md`** (~30 min) — complete the 4 missing rows (SCA, container scan, image signing, policy gate). Each row: gate × tool × artefact path × retention × auditor-retrieval command.
7. **Final read-through** (~30 min) — re-read everything. Submit.

If you find yourself rewriting Kyverno policies or the OTel pipeline, stop. The exercise is judgement.

---

## What you do NOT write

- New deploy manifests.
- New observability stack.
- New CI workflows.
- The MAS TRM controls matrix (in `SECURITY.md`).
- The day 1–7 onboarding path (in `MENTORSHIP_GUIDE.md` skeleton).
- The vault-shim service itself (≤80 LoC of patches if you fix one of its vulns as your surgical fix).

---

## Constraints (from the brief)

- Kubernetes only. Local kind cluster only at this tier — no EKS.
- Do not rewrite the starter. Diff outside the docs must stay under ~60 lines.
- Do not silently fix planted issues without naming them in `JUDGEMENT.md` first.
- Disclose your AI tool stack in `JUDGEMENT.md` Section 1.

---

## If you're stuck

- Stuck on `make cluster-up`? It depends on `docker`, `kind`, `helm`, `kubectl`. The starter assumes recent versions of each on macOS / Linux. File any setup blocker in `VALIDATION.md` "Bring-up issues".
- Stuck on Grafana showing nothing? Check both ends — the OTel Collector logs (`docker logs obs-otel-collector`) and the vault-shim pod (`kubectl -n vault-shim logs deployment/vault-shim`). If the pod sees no errors and the Collector sees no spans, the path between them is broken. (Hint: read `observability/README.md` "cross-boundary path" section and then `deploy/networkpolicy.yaml`.)
- Stuck on the catch-vs-miss table in `JUDGEMENT.md` Section 5? Read every gate's artefact (in the CI workflow run page). The catalogue says certain vault-shim vulns _should_ be caught by certain gates — diff against the artefacts.
