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

## Top five operating-discipline lessons (in your voice) `<YOU FILL>`

This is the section a junior reads and thinks "OK, that person has done this for real". It's also the section that's hardest to generate convincingly. Write five lessons that you've actually internalized through doing this work.

Each lesson:
- A one-sentence statement of the lesson.
- A short story (1 paragraph) of when you learned it. Real beats hypothetical.
- The check you do today to honour it.

### Lesson 1

`<YOUR LESSON>`

### Lesson 2

`<YOUR LESSON>`

### Lesson 3

`<YOUR LESSON>`

### Lesson 4

`<YOUR LESSON>`

### Lesson 5

`<YOUR LESSON>`

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
