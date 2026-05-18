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

`<TO COMPLETE — write the exact logcli query you'd run, the alert (if any) you'd want, and how this would surface in a normal weekly review>`

### First-5-min containment

`<TO COMPLETE — what do you do first? Rotate? Snapshot logs? Block the API? Be specific with commands.>`

### 30-min investigation

`<TO COMPLETE — who accessed those log lines? How far back does this go? Are there downstream systems (e.g., centralized log archive) where the secret has been mirrored?>`

### 4-hour remediation

`<TO COMPLETE — patch vault-shim, force key rotation, redact log archives, deploy fix. Specific Makefile / kubectl commands.>`

### 1-week post-incident review

`<TO COMPLETE — what does the post-mortem say? What custom semgrep rule do you add? What gate config change prevents this class of issue?>`

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
