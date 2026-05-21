# MENTORSHIP_GUIDE.md — for a junior DevSecOps hire joining the team

Most sections of this guide ship complete. The "Top five operating-discipline lessons" section is the stub for you to fill — that's the section that's hardest to fake and the section that means the most when a junior reads it on day 1.

---

## Day 1–7 onboarding path

| Day | Goal | Specifics |
| --- | --- | --- |
| 1 | Local stack up + first request | Pair with on-call. `make up`, hit `/healthz`, see your first trace in Grafana, see your first log line in Loki. Read `RUNBOOK.md` end to end. |
| 2 | CI pipeline tour | Open the latest CI run on `main`. Walk through each of the 9 gates with on-call. What does each one catch? What artefacts does each leave? Where does a 6-month-old audit start when they need evidence for build SHA `XYZ`? Read `.security/EVIDENCE.md`. |
| 3 | Reading the deploy manifests | Read every file in `deploy/`. Map each one to the corresponding `SECURITY.md` row. Re-derive the topology diagram from the manifests without looking at `RUNBOOK.md` — does what you draw match? |
| 4 | First small ticket | Pick a "fix tflint warning" or "tighten one Kyverno rule" or "add one Loki dashboard row" ticket. Open a PR. Get a real review from on-call. **No tickets larger than 100 LoC in week 1.** |
| 5 | Shadow on-call | Half-day shadowing the rotating on-call. Watch the alert flow. Read the post-mortem for the most recent P1 incident. Ask "why didn't we catch this earlier?" |
| 6 | Read `INCIDENT_TABLETOP.md` | Walk one scenario as if live with on-call. Then write your own draft of one of the stub scenarios (b or c). Don't ship — just exercise the muscle. |
| 7 | AI agent boundaries session | Pair with the team lead on `JUDGEMENT.md` Section 1 of recent take-homes (anonymized). Where did agents help? Where did agents hurt? How does this team use agents day-to-day? |

---

## Top five operating-discipline lessons (in your voice)

### Lesson 1 — Validate the failure path of every gate, not just the pass path.

**Statement:** A gate that can't fail is not a gate — it's a comfort blanket.

**The story:** Early in my career I inherited a SAST pipeline that had been "passing" for months. One day I noticed the scan artefact was always the same size regardless of what code changed. The scanner was running, producing output, and the CI step was green. What nobody had checked was whether a finding would actually block the build. The step used `|| true` to handle scanner exit codes "safely." The gate was fully wired and completely useless. I've seen the same pattern on govulncheck, dependency-check, and even custom audit scripts — all passing, all silent. Now I validate gates by deliberately triggering their failure path: inject a known-bad dep, commit a fake secret, apply a violating manifest. If the gate doesn't fire, the gate is broken, full stop.

**The check today:** Before closing any ticket that adds or modifies a CI gate, run a negative test: introduce the violation the gate is supposed to catch, confirm the build fails, revert. Document the negative test result in the PR description.

---

### Lesson 2 — `set +e` in a CI gate step is almost always a security defect, not a convenience.

**Statement:** If you need to suppress errors in a security check, what you actually need is a better check — not error suppression.

**The story:** I've seen `set +e` appear in CI scripts dozens of times, almost always with a comment that says "we'll handle this properly later." Later never comes. The `set +e` pattern in the govulncheck step in this repo is a textbook example: the comment says "fail on HIGH-severity findings"; the code exits 0 unconditionally. The dangerous part is not the bug itself — it's that the developer who wrote it and the reviewers who approved it all read the comment and assumed the intent was implemented. I now read security-related CI scripts the same way I read IAM policies: the declared intent is irrelevant; only the effective behavior matters. What does `$?` actually hold at exit? Is there a `|| true` anywhere in the chain?

**The check today:** When reviewing any CI step that runs a security tool, I grep for `set +e`, `|| true`, `|| echo`, `; true`, and `exit 0` — any pattern that could swallow a non-zero exit. If I find one, I block the PR until the step is fixed or the suppression is explicitly justified with a comment explaining what other gate compensates.

---

### Lesson 3 — Fail-closed controls must actually fail closed — test by triggering the failure.

**Statement:** "Fail-closed" is a claim, not a property — it becomes true only after you've observed the failure.

**The story:** The cosign verify step in this repo had `|| echo "warn: cosign verify failed — continuing for non-prod"` appended to it. SECURITY.md row 7 described this as a fail-closed control. The SECURITY.md was not wrong by accident — someone wrote it believing the step would fail closed, because that was the intent. The disconnect between the written security posture and the actual code is the most dangerous gap in a security program, because it means your controls matrix is fiction. I learned this the hard way when a "mandatory code signing check" in a deploy pipeline turned out to have a `--force` flag available to any developer. Nobody used it maliciously; it just meant the control existed only on paper. Now when I review a security control, I ask: "what does an attacker need to do to make this step succeed when it should fail?" If the answer is "add `|| true`" or "pass `--skip-verify`" or "set an env var," the control is not fail-closed.

**The check today:** For every fail-closed control in a SECURITY.md or controls matrix, I trace from the control description to the actual enforcement file. I look for fallbacks, overrides, environment-variable bypasses, and conditional `if:` blocks. I add a one-line comment to the enforcement file explaining why the fallback is absent.

---

### Lesson 4 — Logs are a secret store you didn't intend to build.

**Statement:** Every field you log is a field an attacker (or an overprivileged colleague) can read — treat log fields with the same access control mindset you apply to the data store.

**The story:** The `value=%q` log line in vault-shim is a perfect example of how this happens in practice: the developer who wrote it was debugging, wanted to confirm the store was working, and left the field in. It's not malicious — it's the "log everything while developing, prune before prod" habit that nobody remembers to honour at ship time. The blast radius is significant: Loki has 30-day retention, is readable by every developer with dashboard access, and may be forwarded to a centralized log archive that has its own retention policy. A single `log.Printf("value=%q")` in one endpoint turns your secret store into a 30-day plaintext leak. I've seen this pattern with database query results, API response bodies, and JWT payloads — all logged for "debugging convenience" and all readable after the fact.

**The check today:** In code review, I scan every new or changed `log.Printf`/`slog.Info`/`logger.With` call for field names that resemble sensitive data: `value`, `password`, `token`, `secret`, `key`, `credential`. I also have a custom semgrep rule that flags this pattern at CI time. The rule is not perfect — it will miss a field named `v` — but it catches the obvious cases and creates a forcing function for reviewers to think about what they're logging.

---

### Lesson 5 — Read allowlists as carefully as rulesets — exclusions are where the risk hides.

**Statement:** A broad allowlist is a security control that runs backwards: it reduces the attack surface of your detection, not of your system.

**The story:** The gitleaks allowlist in this repo exempted `vault-shim/config.yaml` entirely. The comment said "test fixtures" — which is a legitimate reason to exempt a file. The problem is that config.yaml also contained the real production credentials (`signing_key`, `bootstrap_token`). The exclusion was added at some point during development when the scanner was generating noise, and nobody went back to narrow it. The result: gitleaks ran on every commit, produced output, and the two highest-severity findings in the repo were invisible to it. I've seen the same pattern in WAF rules ("allowlist this IP range because it's our load balancer" — then the IP range is too broad), in IAM policies ("allow s3:* on arn:aws:s3:::dev-*" — then a prod bucket gets named `dev-backups-prod`), and in Semgrep rulesets ("ignore this path" — then the path pattern matches more files than intended). Allowlists and exclusions deserve a separate review pass, because they often accumulate silently over time and nobody challenges them.

**The check today:** When reviewing any security tool configuration that contains an allowlist, exclusion list, or suppression rule, I read each entry and ask: (1) Is this still valid? (2) Is it as narrow as it can be? (3) Does it exclude things it shouldn't? I add an expiry comment to any time-bound exclusion (`# expires 2026-06-01: false positive in test fixture, remove after test refactor`) so it doesn't silently persist forever.

---

## Code review — how we run it

| Surface | What we look for | Time-to-review SLA |
| --- | --- | --- |
| **Terraform** | IAM least-privilege; secrets not in diff; module reuse; named test list; drift implications. | 24 hr business |
| **Kubernetes manifests** | PSS Restricted; NetworkPolicy egress completeness; no `kind: Secret`; image by digest. | 24 hr business |
| **CI/CD workflow YAML** | Pinned SHAs; least-privilege `permissions:`; OIDC vs static keys; per-gate fail thresholds; artefact retention. | 24 hr business |
| **vault-shim Go code** | Tests for new behaviour; structured log fields; never log secret values; rate-limit on writes. | 24 hr business |

### Review approach

- **Diff sweep first** — read the whole diff before commenting on the first line. Avoid drive-by nits.
- **Ask "why" before "no"** — half the time the answer surfaces a real constraint.
- **One non-blocking suggestion per file** — don't drown the author.
- **Block on rubric-line violations** — IAM wildcards, secrets in diff, missing tests for security-relevant code.

---

## How to use AI agents on infra code

| Where they help | Where they hurt | How we keep them honest |
| --- | --- | --- |
| Boilerplate Terraform (provider blocks, common modules) | IAM trust policies — agents default to `*` | Manual diff against a known-good template |
| Kubernetes manifest skeletons | NetworkPolicy egress completeness — agents miss indirect dependencies | Run the negative tests every time |
| Generating tabletop scenario drafts | Logging "what is the safe thing to print" — agents over-log | Custom semgrep rule for `log + sensitive-field` |
| Refactoring tests | Choosing fail-thresholds on CI gates | Threshold drift over time is the failure mode — review quarterly |

### Three rules for the agent

1. **Never let an agent change a trust policy without a `JUDGEMENT.md`-style human review.** The cost of getting an IAM trust wrong is unbounded.
2. **Never accept an agent's "make CI green" commit.** Always ask: did it tighten the assertion, or weaken the assertion? Weakening is the common mode.
3. **Agent output goes in the PR description.** "Here's what I tried, here's what the agent suggested, here's what I changed and why."

---

## On-call expectations

| Item | Expectation |
| --- | --- |
| **Ack-time SLA** | 5 min for P0, 30 min for P1 during business hours; 30 min for P0, 1 hr for P1 off-hours. |
| **Page-during-meeting** | Step out. The team agrees that nobody will hold a grudge for skipping a meeting to handle a page. |
| **Quiet hours** | 23:00–07:00 SGT. P0 only. If you're paged at 03:00 for a P1, that's a tuning problem — write it up Monday. |
| **Post-incident note shape** | Trigger, impact, timeline, root cause, contributing factors, what changed in the system, action items with owners + dates. **Always blameless.** |
| **Handover** | End-of-rotation walk-through with the incoming on-call: open alarms, open follow-ups, anything weird in the last week's telemetry. |
