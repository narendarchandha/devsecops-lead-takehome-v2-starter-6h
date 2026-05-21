# INCIDENT_TABLETOP.md

Three scenarios. The first is fleshed in detail (as a template). The other two are stubs — you flesh ONE of them in detail at this tier. The third can stay as the stub you ship.

---

## Scenario (a) — Secret in logs `<YOU FLESH IN DETAIL>`

**Trigger.** Routine Loki query during weekly secret-rotation audit reveals lines containing what look like full secret values, written by vault-shim.

```
2026-05-21T03:14:22Z vault-shim INFO request_id=req-abc123 trace_id=4f2... msg="stored secret key=db-password value=hunter2-actual-prod-value"
```

The pipeline missed this — `semgrep`'s baseline ruleset has no rule for "log + sensitive-field pattern". Run-time discovery via `logcli`.

### Detection signal

**Proactive (alert-based):**
A Loki alert rule in `observability/alerts/alerts.yaml` should exist for this pattern:

```yaml
- alert: SecretValueInLogs
  expr: |
    sum(count_over_time({app="vault-shim"} |= "value=" [5m])) > 0
  for: 0m
  labels:
    severity: critical
  annotations:
    summary: "vault-shim is logging secret values"
    description: "Log lines matching 'value=' detected in vault-shim — possible credential leak to Loki."
    runbook_url: "RUNBOOK.md#scenario-a-secret-in-logs"
```

**Reactive (logcli query run during weekly review):**
```bash
# Find all log lines containing "value=" from vault-shim in the last 24 hours
logcli query '{app="vault-shim"} |= "value=" | json' \
  --limit 50 \
  --since 24h \
  --addr http://localhost:3100

# Broader: any secret-resembling field (key, token, password, secret)
logcli query '{app="vault-shim"} |~ "value=|password=|token=|secret=" | json' \
  --limit 100 \
  --since 168h \
  --addr http://localhost:3100
```

**Expected output that triggers the incident:**
```
2026-05-21T03:14:22Z {app="vault-shim", pod="vault-shim-7544bb89f9-425kj"}
  request_id=req-abc123 key=db-password value=hunter2-actual-prod-value
2026-05-21T03:14:55Z {app="vault-shim", pod="vault-shim-7544bb89f9-922wr"}
  request_id=req-def456 key=signing-key value=8f3b2a4c1d6e9f0a7b8c5d2e3f4a1b6c
```

Seeing `value=` in structured log fields is the P1 signal. Escalate immediately.

### First-5-min containment

**Goal:** stop new exposure, preserve evidence, don't destroy what you haven't analyzed yet.

```bash
# 1. Snapshot the affected log window to a local file before any rotation
logcli query '{app="vault-shim"} |= "value=" | json' \
  --since 720h --limit 10000 \
  --addr http://localhost:3100 \
  --output jsonl > /tmp/incident-$(date +%Y%m%d%H%M%S)-vault-shim-leaked-logs.jsonl

# 2. Identify which secret keys were logged
jq -r '.key' /tmp/incident-*.jsonl | sort -u
# Expected output: db-password, signing-key, bootstrap-token, ...

# 3. Scale deployment to zero — stops new secret values entering logs
#    (do NOT delete pods yet — preserve any in-flight request context)
kubectl -n vault-shim scale deployment/vault-shim --replicas=0

# 4. Notify incident commander and secret owner within 5 minutes of discovery
#    (PagerDuty / Slack #incidents with: "P1: vault-shim logging secret values to Loki since <timestamp>")

# 5. Revoke and rotate bootstrap_token immediately via ESO
#    (or directly via kubectl if ESO rotation is broken — see catch B5)
kubectl -n vault-shim create secret generic vault-shim-runtime \
  --from-literal=signing_key="$(openssl rand -hex 32)" \
  --from-literal=bootstrap_token="vshim_$(openssl rand -hex 16)" \
  --dry-run=client -o yaml | kubectl apply -f -
```

At this point: exposure is stopped (replicas=0), evidence is preserved (snapshot), primary credentials are rotated. Do NOT re-enable traffic until the fix is deployed.

### 30-min investigation

**Who had read access to Loki during the exposure window?**
```bash
# Check Grafana access logs for queries against vault-shim streams
logcli query '{compose_service="grafana"} |= "vault-shim" | json' \
  --since 720h --limit 500 --addr http://localhost:3100

# Check if Loki data was forwarded to any external archive (check promtail config)
grep -r "forward\|external\|remote_write\|s3\|gcs" observability/promtail/
```

**How far back does the exposure go?**
```bash
# Loki has 30-day retention — find earliest log line with "value="
logcli query '{app="vault-shim"} |= "value=" | json' \
  --since 720h --limit 1 \
  --addr http://localhost:3100 \
  --output jsonl | jq -r '.timestamp'

# Cross-reference with git log to find when the log line was first introduced
git log --all --oneline --diff-filter=A -- vault-shim/main.go | head -5
git show <commit>:vault-shim/main.go | grep 'value=%q'
```

**Which specific secrets were logged and when?**
```bash
jq -r '{key: .key, pod: .labels.pod, time: .timestamp}' \
  /tmp/incident-*.jsonl | sort -k3 | head -50
```

**Are there downstream systems where the secret has been mirrored?**
- Check if Loki remote_write is configured to ship to a centralized archive (S3, Elasticsearch)
- Check Grafana alerting — did any alert forward the log line payload to a webhook (PagerDuty, Slack)?
- Check any log aggregation pipelines (Datadog, Splunk agents) that might scrape Docker/node logs
- If CI ran during the window: check GitHub Actions logs — vault-shim logs in integration test runs would also contain the values

```bash
# If using GitHub Actions: check recent workflow runs for log exfiltration
gh run list --workflow ci.yml --limit 20 --json databaseId,status,createdAt
# Review each run's logs for test steps that exercise POST /v1/secrets
```

### 4-hour remediation

```bash
# 1. Apply the code fix (removes value=%q from both log.Printf calls)
#    This commit is already in this repo: fix(vault-shim): stop logging secret values
git log --oneline | grep "stop logging secret values"

# 2. Rebuild the image with the fix
docker build -t vault-shim:$(git rev-parse --short HEAD) ./vault-shim
kind load docker-image vault-shim:$(git rev-parse --short HEAD) --name vault-shim

# 3. Update deployment image tag and redeploy
kubectl -n vault-shim set image deployment/vault-shim \
  vault-shim=vault-shim:$(git rev-parse --short HEAD)

# 4. Scale back up
kubectl -n vault-shim scale deployment/vault-shim --replicas=2
kubectl -n vault-shim wait --for=condition=available --timeout=120s deployment/vault-shim

# 5. Verify new logs do NOT contain "value="
logcli query '{app="vault-shim"} |= "value=" | json' \
  --since 5m --limit 20 --addr http://localhost:3100
# Expected: zero results

# 6. Force ESO to re-sync rotated secrets
kubectl -n vault-shim annotate externalsecret vault-shim-runtime \
  force-sync=$(date +%s) --overwrite

# 7. Redact historical Loki data containing the leaked values
#    Loki does not support in-place redaction — options:
#    a. If Loki chunks are on object storage: delete affected chunks covering the exposure window
#    b. If retention allows: let 30-day TTL expire (document the window in the post-incident note)
#    c. Contact Loki vendor/ops for chunk-level deletion of matching streams

# 8. Notify all downstream teams that had Loki read access during the window
#    Include: which keys were leaked, exposure window, confirmation of rotation

# 9. Run gitleaks to confirm no other secret-in-file issues
docker run --rm -v "$(pwd):/repo" -w /repo zricethezav/gitleaks:v8.18.4 detect \
  --config /repo/.gitleaks.toml --source /repo --verbose
```

**Smoke test post-remediation:**
```bash
BOOTSTRAP=$(kubectl -n vault-shim get secret vault-shim-runtime -o jsonpath='{.data.bootstrap_token}' | base64 -d)
curl -s -X POST http://vault-shim.localtest.me/v1/secrets \
  -H "Authorization: Bearer $BOOTSTRAP" \
  -H "Content-Type: application/json" \
  -d '{"key":"canary","value":"canary-value-post-incident"}'
# {"key":"canary"}   — note: value NOT returned in logs

kubectl -n vault-shim logs -l app.kubernetes.io/name=vault-shim --since=1m | grep canary
# Expected: stored secret key="canary"   — no value field
```

### 1-week post-incident review

**Post-mortem structure** (blameless):

- **Trigger:** Routine weekly Loki review discovered `value=` in vault-shim log lines.
- **Impact:** All secret values written to or read from vault-shim for up to 30 days (Loki retention) were exposed to any user with Loki read access. Keys affected: [list from jq output]. Total events: [count].
- **Root cause:** `log.Printf("stored secret key=%q value=%q", ...)` in `main.go:103,116` — logging secret values is the application-level failure. The pipeline had no gate to catch this pattern.
- **Contributing factors:** (1) No custom semgrep rule for `log + sensitive-field`. (2) No runtime alert on `|= "value="` in Loki. (3) Code review did not flag the log line as a security concern.
- **What changed in the system:** Removed `value=%q` from both log calls. Rotated `signing_key` and `bootstrap_token`.
- **Action items:**
  1. **[Owner: Security, Due: +3d]** Add `.semgrep/rules.yml` rule `log-sensitive-field` that flags any `log.Printf`/`slog.*` call with a field named `value`, `password`, `secret`, `token`. Wire as a blocking semgrep rule.
  2. **[Owner: Platform, Due: +3d]** Add Loki alert `SecretValueInLogs` (rule above) to `observability/alerts/alerts.yaml`. Test by manually triggering a log line and confirming the alert fires.
  3. **[Owner: DevSecOps, Due: +7d]** Add `log-sensitive-field` check to the Go code review checklist in `MENTORSHIP_GUIDE.md`.
  4. **[Owner: Security, Due: +14d]** Audit all other services for the same `log.Printf + value=` pattern. Run `grep -rn 'log.Printf.*value=' --include="*.go" .` across all repos.
  5. **[Owner: Platform, Due: +14d]** Evaluate log stream encryption at rest and column-level redaction in the Loki pipeline for fields matching known secret patterns.

**Custom semgrep rule added (action item 1):**
```yaml
# .semgrep/rules.yml (addition)
- id: log-sensitive-field
  patterns:
    - pattern: log.$FUNC(..., $FMT, ..., $VAL, ...)
    - metavariable-regex:
        metavariable: $FMT
        regex: '.*(value|password|secret|token|key)=%'
  message: "Do not log sensitive field values — log the key name only."
  languages: [go]
  severity: ERROR
```

---

## Scenario (b) — Container compromise: anomalous outbound from the pod `<STUB>`

**Trigger.** GuardDuty (or Falco at stretch tier) fires "PenTest:Runtime/MaliciousFile" inside `vault-shim` namespace. Pod's egress shows TCP connections to `185.220.101.*` (a Tor exit node range).

### Detection signal

`<stub — Falco rule + GuardDuty finding shape>`

### First-5-min containment

`<stub — kubectl delete pod (forces recreation; loses in-memory store) OR network-isolate via emergency NetworkPolicy>`

### 30-min investigation

`<stub — pod's process tree, recent kubectl exec, image diff against signed digest>`

### 4-hour remediation

`<stub — rotate every secret the pod could have read, regenerate signing keys, redeploy from known-good signed image>`

### 1-week post-incident review

`<stub — defence-in-depth gaps; runtime detection coverage; image-scanning gate tightening>`

---

## Scenario (c) — Leaked OIDC credential: CloudTrail shows assumption from a non-`main` branch `<STUB>`

**Trigger.** CloudTrail event for `AssumeRoleWithWebIdentity` on the `github-deploy` role; `sub` claim shows `repo:org/repo:ref:refs/heads/feature/xyz`. The repo's branch protection requires reviews on `main`, but `feature/xyz` has no such protection. Anyone who could push to `feature/xyz` could trigger a workflow that assumes deploy permissions.

### Detection signal

`<stub — CloudTrail event + which Athena / Glue query exposes it>`

### First-5-min containment

`<stub — disable the role, revoke active sessions>`

### 30-min investigation

`<stub — what did that branch's workflow do? Did it apply Terraform? Did it push images? What did it touch?>`

### 4-hour remediation

`<stub — rotate any secrets it could have written, tighten the trust policy `sub` claim to branch-pinned exactly, audit recent runs>`

### 1-week post-incident review

`<stub — supply-chain control: branch protection on `main` is necessary but not sufficient when OIDC trust is over-broad>`
