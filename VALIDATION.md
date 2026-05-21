# VALIDATION.md

> Copy this file to `VALIDATION.md` and fill in. **Commit this file BEFORE patching anything in `deploy/`, `vault-shim/`, `.github/`, or `observability/`.** Reviewers check the commit order via `git log --follow VALIDATION.md`.

---

## Bring-up

### `make observability-up`

```text
cd observability && docker compose -f docker-compose.observability.yml up -d
 Network observability_default Creating 
 Network observability_default Created 
 Volume observability_tempo-data Creating 
 Volume observability_tempo-data Created 
 Volume observability_mimir-data Creating 
 Volume observability_mimir-data Created 
 Volume observability_grafana-data Creating 
 Volume observability_grafana-data Created 
 Volume observability_loki-data Creating 
 Volume observability_loki-data Created 
 Container obs-tempo Creating 
 Container obs-mimir Creating 
 Container obs-loki Creating 
 Container obs-tempo Created 
 Container obs-mimir Created 
 Container obs-otel-collector Creating 
 Container obs-loki Created 
 Container obs-promtail Creating 
 Container obs-grafana Creating 
 Container obs-otel-collector Created 
 Container obs-promtail Created 
 Container obs-grafana Created 
 Container obs-loki Starting 
 Container obs-mimir Starting 
 Container obs-tempo Starting 
 Container obs-tempo Started 
 Container obs-mimir Started 
 Container obs-tempo Waiting 
 Container obs-loki Started 
 Container obs-loki Waiting 
 Container obs-loki Waiting 
 Container obs-tempo Waiting 
 Container obs-tempo Healthy 
 Container obs-otel-collector Starting 
 Container obs-loki Healthy 
 Container obs-promtail Starting 
 Container obs-tempo Healthy 
 Container obs-loki Healthy 
 Container obs-grafana Starting 
 Container obs-otel-collector Started 
 Container obs-promtail Started 
 Container obs-grafana Started 
Grafana: http://localhost:3000 (anonymous; admin if needed admin/admin)
OTel Collector OTLP HTTP: http://localhost:4318
```

All 6 containers healthy: obs-loki, obs-mimir, obs-tempo, obs-grafana, obs-otel-collector, obs-promtail.

### `make cluster-up`

```text
kind create cluster --name vault-shim --config kind-config.yaml
Creating cluster "vault-shim" ...
 ✓ Ensuring node image (kindest/node:v1.35.0)
 ✓ Preparing nodes
 ✓ Writing configuration
 ✓ Starting control-plane
 ✓ Installing StorageClass
Set kubectl context to "kind-vault-shim"

Installing Calico CNI (kindnet is disabled — see kind-config.yaml)...
kubectl apply --server-side -f https://raw.githubusercontent.com/projectcalico/calico/v3.27.3/manifests/calico.yaml
[... all Calico CRDs and resources serverside-applied ...]
deployment.apps/calico-kube-controllers condition met
daemon set "calico-node" successfully rolled out

kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/controller-v1.11.3/deploy/static/provider/kind/deploy.yaml
[... ingress-nginx resources created ...]
pod/ingress-nginx-controller-b9d5b4945-kzp2j condition met

Installing Kyverno...
kubectl apply --server-side -f https://github.com/kyverno/kyverno/releases/download/v1.12.0/install.yaml
[... all Kyverno CRDs and controllers serverside-applied ...]
deployment.apps/kyverno-admission-controller condition met

Installing External Secrets Operator...
helm upgrade --install external-secrets external-secrets/external-secrets -n external-secrets --create-namespace --wait
Release "external-secrets" does not exist. Installing it now.
NAME: external-secrets  LAST DEPLOYED: Thu May 21 08:51:15 2026
NAMESPACE: external-secrets  STATUS: deployed  REVISION: 1
DESCRIPTION: Install complete
```

kind cluster running k8s v1.35.0, Calico CNI, ingress-nginx, Kyverno v1.12.0, ESO installed.

### `make deploy`

```text
docker build -t vault-shim:dev ./vault-shim
[all 5 build stages cached — golang:1.21 base, WORKDIR /app, COPY, go mod download, go build]
naming to docker.io/library/vault-shim:dev done

kind load docker-image vault-shim:dev --name vault-shim
Image: "vault-shim:dev" with ID "sha256:a8dd61ba..." not yet present on node, loading...

kubectl apply -f deploy/policies/
clusterpolicy.kyverno.io/disallow-host-network created
clusterpolicy.kyverno.io/disallow-privilege-escalation created
clusterpolicy.kyverno.io/require-non-root created

kubectl apply -k deploy/
namespace/vault-shim created
serviceaccount/vault-shim created
role.rbac.authorization.k8s.io/vault-shim created
rolebinding.rbac.authorization.k8s.io/vault-shim created
service/vault-shim created
deployment.apps/vault-shim created
poddisruptionbudget.policy/vault-shim created
horizontalpodautoscaler.autoscaling/vault-shim created
ingress.networking.k8s.io/vault-shim created
networkpolicy.networking.k8s.io/allow-egress-eso created
networkpolicy.networking.k8s.io/allow-egress-kube-dns created
networkpolicy.networking.k8s.io/allow-ingress-from-nginx created
networkpolicy.networking.k8s.io/default-deny created

[BRING-UP ISSUE] ExternalSecret/SecretStore apply failed:
  resource mapping not found for name: "vault-shim-runtime" ...
  no matches for kind "ExternalSecret" in version "external-secrets.io/v1beta1"
  resource mapping not found for name: "vault-shim-store" ...
  no matches for kind "SecretStore" in version "external-secrets.io/v1beta1"
Cause: ESO chart installed uses v1 API (starter uses deprecated v1beta1).
Resolution: Applied manually with v1 API; created vault-shim-runtime Secret directly.

kubectl -n vault-shim wait --for=condition=available --timeout=120s deployment/vault-shim
deployment.apps/vault-shim condition met

kubectl -n vault-shim get pods
NAME                          READY   STATUS    RESTARTS   AGE
vault-shim-7544bb89f9-425kj   1/1     Running   0          4m39s
vault-shim-7544bb89f9-922wr   1/1     Running   0          4m39s
```

2 pods Running and Ready. Deployment Available.

### Request smoke test

```text
$ curl -s http://vault-shim.localtest.me/healthz
{"status":"ok"}

$ curl -s http://vault-shim.localtest.me/readyz
{"status":"ready"}

$ curl -s -X POST http://vault-shim.localtest.me/v1/secrets \
    -H "Authorization: Bearer vshim_b9d4c8e1a2f7345698abcdef01234567" \
    -H "Content-Type: application/json" \
    -d '{"key":"test-key","value":"super-secret-value"}'
{"key":"test-key"}

$ curl -s http://vault-shim.localtest.me/v1/secrets/test-key \
    -H "Authorization: Bearer vshim_b9d4c8e1a2f7345698abcdef01234567"
{"key":"test-key","value":"super-secret-value"}
```

All 4 endpoints respond correctly.

---

## LGTM end-to-end trace

### Grafana — RED dashboard for vault-shim

Grafana is accessible at http://localhost:3000 (anonymous). The vault-shim RED dashboard panels are **empty** because vault-shim has no OTel instrumentation in its Go binary (`go.mod` contains no `go.opentelemetry.io` dependencies). The `OTEL_EXPORTER_OTLP_ENDPOINT` env var is injected by `deploy/deployment.yaml:55` but the app never reads it. This is documented as catch B5 in JUDGEMENT.md Section 2.

### Loki — vault-shim log lines

```text
$ curl -s 'http://localhost:3100/loki/api/v1/label/service_name/values'
{"status":"success","data":["obs-grafana","obs-loki","obs-mimir","obs-otel-collector",
 "obs-promtail","obs-tempo","vault-shim-control-plane"]}
```

Loki receives logs from Docker compose containers (obs-*) and the kind node (`vault-shim-control-plane`). vault-shim pod logs from **inside** the kind cluster do not appear in Loki: promtail uses `docker_sd_configs` (Docker socket discovery), which surfaces host-level Docker container logs only, not logs from pods running within a kind node. A Promtail DaemonSet inside the k8s cluster is required to ship pod logs to Loki.

### Tempo — trace data

```text
$ curl -s 'http://localhost:3200/api/search?limit=10'
{"traces":[],"metrics":{"completedJobs":1,"totalJobs":1}}
```

Tempo has no traces: vault-shim has no OTel SDK instrumentation, so no spans are emitted.

### Mimir — `http_server_request_duration_seconds_count` metric

```text
$ curl -s 'http://localhost:9009/prometheus/api/v1/query?query=http_server_request_duration_seconds_count'
{"status":"success","data":{"resultType":"vector","result":[]}}
```

Mimir has no vault-shim metrics — same root cause: no OTel SDK in the app binary.

**Root cause (catch B5):** `deploy/deployment.yaml:55-60` injects `OTEL_EXPORTER_OTLP_ENDPOINT`, `OTEL_EXPORTER_OTLP_PROTOCOL`, and `OTEL_SERVICE_NAME` as env vars but `vault-shim/main.go` contains no OTel imports and no instrumentation code. The env vars are silently ignored. This also means the "rule (5)" OTel egress NetworkPolicy referenced in deployment.yaml comments does not exist in `deploy/networkpolicy.yaml` — documented as catch B2.

---

## Negative tests (the brief promises these)

### `kubectl exec` into pod, `curl 1.1.1.1:443` must fail

```text
=== Negative test 1: pod can NOT reach 1.1.1.1 (NetworkPolicy default-deny) ===
Using pod: vault-shim-7544bb89f9-425kj
curl: (28) Connection timed out after 3000 milliseconds
BLOCKED (expected)
```

Egress to 1.1.1.1:443 is blocked. The `default-deny` NetworkPolicy drops all egress except the explicitly allow-listed rules (kube-dns UDP 53, ESO namespace). **PASS.**

Note: the Makefile's `validate-negative-tests` target uses `nicolaka/netshoot` as a debug pod but it's rejected by PSA `restricted` on the namespace. Workaround: exec'd into the existing vault-shim pod instead.

### `kubectl apply --dry-run=server` a manifest violating Kyverno — must be denied

```text
=== Negative test 2: bad manifest must be rejected by Kyverno ===
Error from server (Forbidden): error when creating "/tmp/bad-pod.yaml":
pods "bad-pod" is forbidden: violates PodSecurity "restricted:latest":
  allowPrivilegeEscalation != false (container "bad" must set securityContext.allowPrivilegeEscalation=false),
  unrestricted capabilities (container "bad" must set securityContext.capabilities.drop=["ALL"]),
  runAsNonRoot != true (pod or container "bad" must set securityContext.runAsNonRoot=true),
  seccompProfile (pod or container "bad" must set securityContext.seccompProfile.type to "RuntimeDefault" or "Localhost")
OK: bad manifest rejected (exit 1)
```

Bad manifest (allowPrivilegeEscalation: true) rejected at admission. Rejection fires on PSA `restricted` enforced on the vault-shim namespace; Kyverno `disallow-privilege-escalation` ClusterPolicy (validationFailureAction: Enforce) provides defense-in-depth. **PASS.**

Catch B1: `disallow-host-network` policy has `validationFailureAction: Audit` (not Enforce) — documented in JUDGEMENT.md.

---

## Per-CI-gate evidence

All gates run via: `act -j <job> --action-offline-mode`
Note: artifact upload steps fail with `Unable to get the ACTIONS_RUNTIME_TOKEN env variable` in all local act runs — expected; gate logic completes before the upload step.

### Gate 1 — lint (`golangci-lint`)

```text
[ci/golangci-lint] ⭐ Run Main golangci/golangci-lint-action
Running [golangci-lint run --out-format=github-actions --path-prefix=vault-shim] in [vault-shim] ...
level=warning msg="[config_reader] The output format `github-actions` is deprecated"
golangci-lint found no issues

[ci/golangci-lint] 🏁  Job succeeded
```

**PASS.** No lint issues. golangci-lint v1.59.1.

### Gate 2 — unit (`go test`)

```text
[ci/go test] ⭐ Run Main go test
    github.com/aungpyaephyo-hx/vault-shim-take-home    coverage: 0.0% of statements
[ci/go test] ✅  Success - Main go test [29.830938388s]
[ci/go test] 🏁  Job failed  ← only: artifact upload ACTIONS_RUNTIME_TOKEN missing
```

**PASS** (gate logic). 0% coverage = no test files exist in vault-shim. Artifact upload fails in act local mode — expected.

### Gate 3 — SAST (`semgrep`)

```text
[ci/semgrep (SAST)] ⭐ Run Main returntocorp/semgrep-action@v1
  Scanning 55 files tracked by git with 2 Code rules:
  Scanning 11 files with 2 yaml rules.
  Ran 2 rules on 11 files: 1 finding.
           33┆ image: vault-shim:dev
  Found 1 finding (1 blocking) from 2 rules.
  Has findings for blocking rules so exiting with code 1

[ci/semgrep (SAST)] 🏁  Job failed
```

**FAIL (expected).** 1 blocking finding: `image: vault-shim:dev` at `deploy/deployment.yaml:33`. The custom `.semgrep/rules.yml` rule flags a mutable `:dev` tag. Semgrep action is at `@v1` (not SHA-pinned) — documented as catch B4.

### Gate 4 — SCA (`govulncheck`)

```text
[ci/govulncheck (SCA)] ⭐ Run Main Run govulncheck
  set +e
  govulncheck -json ./... > ../govulncheck.json
  exitcode=0
  test -s ../govulncheck.json
[ci/govulncheck (SCA)] ✅  Success - Main Run govulncheck [10.246564936s]
```

**catch 2 DEMONSTRATED.** `set +e` at ci.yml:74 masks govulncheck exit code. `test -s govulncheck.json` only checks the file is non-empty and always passes. The build step exits 0 regardless of CVE findings.

govulncheck returns "No vulnerabilities found" for vault-shim: the `dgrijalva/jwt-go` CVE-2020-26160 is not on a called code path per govulncheck's reachability analysis. Trivy (Gate 7) catches the actual Go binary CVEs that govulncheck misses.

### Gate 5 — secret scan (`gitleaks`)

```text
# Git-mode scan (simulating CI) with allowlist:
$ docker run --rm -v "$(pwd):/repo" -w /repo zricethezav/gitleaks:v8.18.4 detect \
    --config /repo/.gitleaks.toml --source /repo --verbose

Finding:     TOKEN="vshim_b9d4c8e1a2f7345698abcdef01234567"
RuleID:      generic-api-key   File: vault-shim/README.md  Line: 59
1 commits scanned. leaks found: 1  exit 1

# File-mode scan (no allowlist bypass) shows what IS in config.yaml:
$ docker run --rm -v "$(pwd):/repo" -w /repo zricethezav/gitleaks:v8.18.4 detect \
    --config /repo/.gitleaks.toml --source /repo --no-git --verbose

Finding:     signing_key: "8f3b2a4c1d6e9f0a7b8c5d2e3f4a1b6c"
RuleID:      generic-api-key   File: /repo/vault-shim/config.yaml

Finding:     bootstrap_token: "vshim_b9d4c8e1a2f7345698abcdef01234567"
RuleID:      generic-api-key   File: /repo/vault-shim/config.yaml

Finding:     TOKEN="vshim_b9d4c8e1a2f7345698abcdef01234567"
RuleID:      generic-api-key   File: /repo/vault-shim/README.md

leaks found: 3  exit 1
```

**Catch 1 DEMONSTRATED.** The allowlist at `.gitleaks.toml:13-14` exempts `vault-shim/config.yaml` entirely. In git-mode scan (as CI runs), gitleaks catches only the README.md example token. The two real hardcoded credentials (`signing_key`, `bootstrap_token`) in config.yaml are silently bypassed. The `go.sum` and `grafana/dashboards/` exemptions are legitimate; the config.yaml exemption is not.

### Gate 6 — IaC scan (`checkov`)

```text
[ci/checkov (IaC)] ⭐ Run Main Run checkov on deploy/
Passed checks: 103, Failed checks: 3, Skipped checks: 0

FAILED: CKV_K8S_43 "Image should use digest"
        — Deployment.vault-shim.vault-shim  deploy/deployment.yaml
FAILED: CKV_K8S_15 "Image Pull Policy should be Always"
        — Deployment.vault-shim.vault-shim  deploy/deployment.yaml
FAILED: CKV_K8S_35 "Prefer using secrets as files over secrets as environment variables"
        — Deployment.vault-shim.vault-shim  deploy/deployment.yaml

[ci/checkov (IaC)] 🏁  Job succeeded  ← soft-fail mode (--soft-fail in ci.yml)
```

**SOFT-FAIL (expected).** 3 IaC findings; job exits 0 due to `--soft-fail`. Findings are informational. CKV_K8S_35 (secrets as env vars) is relevant to catch B5.

### Gate 7 — container scan + SBOM (`trivy`)

```text
$ docker run --rm -v /var/run/docker.sock:/var/run/docker.sock aquasec/trivy:0.50.4 image \
    --severity HIGH,CRITICAL --ignore-unfixed --exit-code 1 vault-shim:dev

app/vault-shim (gobinary)
=========================
Total: 7 (HIGH: 6, CRITICAL: 1)

Library                    Vulnerability   Severity  Title
github.com/gin-gonic/gin   CVE-2020-28483  HIGH      gin: HTTP response splitting
golang.org/x/crypto        CVE-2024-45337  CRITICAL  crypto/ssh: authorization bypass
golang.org/x/crypto        CVE-2020-29652  HIGH      crypto/ssh: nil pointer dereference
golang.org/x/crypto        CVE-2021-43565  HIGH      empty plaintext packet causes panic
golang.org/x/crypto        CVE-2022-27191  HIGH      crash in golang.org/x/crypto/ssh server
golang.org/x/crypto        CVE-2025-22869  HIGH      DoS in Key Exchange (ssh)
gopkg.in/yaml.v3           CVE-2022-28948  HIGH      crash when deserializing invalid input

exit code 1
```

**FAIL (expected).** 7 HIGH/CRITICAL CVEs in Go binary. Trivy exits 1; image would be blocked from signing. Note: `dgrijalva/jwt-go` CVE-2020-26160 does not appear — not in the OSV advisory database with a fix path for this version, consistent with govulncheck's "No vulnerabilities found" result for that package.

### Gate 8 — image signing (`cosign`)

The `image-sign` job only runs on `push` to `refs/heads/main` (conditional in ci.yml:149). For all other events it is skipped. The job body is a stub:

```yaml
- name: cosign sign image digest
  run: |
    # In a real registry push flow this would be:
    #   cosign sign --yes ghcr.io/.../vault-shim@<digest>
    echo "cosign-sign-was-here" > cosign-attestation.txt
```

**STUB.** No actual image signing occurs in this take-home. The counterpart `Verify image signature` step in `deploy.yml` has **bug W3** (non-fatal `|| echo "warn..."` fallback) — fixed in this repo.

### Gate 9 — policy gate (`kyverno admission dry-run`)

The act `policy-gate` job could not run standalone: it depends on `container-build-scan`, which depends on `unit`, whose artifact upload step fails (ACTIONS_RUNTIME_TOKEN missing), breaking the DAG. The equivalent test was validated manually (see Negative Tests above) and the Makefile logic mirrors the ci.yml job exactly.

```text
# ci.yml policy-gate job negative test (identical logic):
out=$(kubectl apply --dry-run=server -f /tmp/bad-pod.yaml 2>&1)
→ Error from server (Forbidden): ... violates PodSecurity "restricted:latest"
ec=1 → "Policy gate rejected as expected."
```

**PASS (local).** Bad manifest denied. **act limitation:** DAG failure due to ACTIONS_RUNTIME_TOKEN in upstream unit job.

---

## SECURITY.md cross-check

### Row #3 — Default-deny NetworkPolicy

SECURITY.md claims: `deploy/networkpolicy.yaml` enforces default-deny NetworkPolicy.

```text
$ kubectl -n vault-shim get networkpolicy
NAME                       POD-SELECTOR                        AGE
allow-egress-eso           app.kubernetes.io/name=vault-shim   33m
allow-egress-kube-dns      app.kubernetes.io/name=vault-shim   33m
allow-ingress-from-nginx   app.kubernetes.io/name=vault-shim   33m
default-deny               <none>                              33m
```

Negative test confirmed egress to 1.1.1.1 blocked. **MATCH.** Gap: no OTel egress rule exists (referenced as "rule (5)" in deployment.yaml comments but absent from networkpolicy.yaml) — documented as catch B2.

### Row #7 — Image signing (cosign)

SECURITY.md claims deploy.yml `Verify image signature` is a fail-closed control.

Reading `.github/workflows/deploy.yml:43-46`:
```yaml
cosign verify \
  --certificate-identity-regexp "https://github.com/${{ github.repository }}/.*" \
  --certificate-oidc-issuer "https://token.actions.githubusercontent.com" \
  "$IMAGE" || echo "warn: cosign verify failed — continuing for non-prod"
```

**DRIFT.** The `|| echo "warn..."` fallback makes the control non-fatal. An unsigned image deploys freely. SECURITY.md row 7 describes this as fail-closed; it is not. This is catch W3 — fixed in this repo.

### Row #10 — Secret scan (gitleaks)

SECURITY.md claims gitleaks with `.gitleaks.toml` detects secrets on every push with branch history.

Git-mode scan above showed gitleaks misses:
- `vault-shim/config.yaml:8` — `signing_key` (real credential, CRITICAL)
- `vault-shim/config.yaml:12` — `bootstrap_token` (real credential, CRITICAL)

**DRIFT.** `.gitleaks.toml` allowlist exempts `vault-shim/config.yaml` wholesale. Real credentials escape detection. This is catch 1 — fixed in this repo.

---

## Bring-up issues

1. **ExternalSecret/SecretStore API version mismatch** — The starter's `deploy/externalsecret.yaml` uses `external-secrets.io/v1beta1`. The ESO chart installed (current Helm release) exposes only `external-secrets.io/v1`. Caused `kubectl apply -k deploy/` to fail for those two resources. Resolution: applied with v1 API manually; the vault-shim-runtime Secret was created directly as the ESO fake-provider path-format also had a compatibility issue.

2. **No OTel data in LGTM stack** — vault-shim has no OTel Go SDK imports (`go.mod` contains no `go.opentelemetry.io` entries). OTEL_* env vars in deployment.yaml are silently ignored. Loki, Tempo, and Mimir are all empty for vault-shim. promtail's Docker-socket scraper does not reach into the kind cluster for pod-level logs.

3. **PSA blocks `make validate-negative-tests` debug pod** — The Makefile target launches `nicolaka/netshoot` without a restricted securityContext; rejected by `pod-security.kubernetes.io/enforce: restricted` on the vault-shim namespace. Workaround: exec'd into the existing vault-shim pod to validate the NetworkPolicy egress block.

4. **act artifact upload fails for all jobs** — `actions/upload-artifact` requires `ACTIONS_RUNTIME_TOKEN`, unavailable in local act runs. This breaks the dependency DAG for `container-build-scan → image-sign` and `policy-gate`. The actual gate logic (go test, govulncheck, trivy) completed successfully; only upload steps failed.
