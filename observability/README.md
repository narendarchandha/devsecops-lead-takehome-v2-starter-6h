# `observability/` — pre-wired Grafana LGTM stack

This folder is **fully wired and working**. `make observability-up` brings up Loki + Tempo + Mimir + Grafana + Promtail + OTel Collector via docker-compose, with Grafana datasources and dashboard folder provisioned automatically.

**Do not rewrite the configs in this folder without a defended reason in `JUDGEMENT.md`.** Your hours go into wiring your service into this stack, not rebuilding it.

---

## ⚠️ The contract field name — read this twice

The Grafana Loki datasource (`grafana/provisioning/datasources/datasources.yaml`) has a **derived field** configured exactly like this:

```yaml
derivedFields:
  - datasourceUid: tempo
    matcherRegex: '"trace_id"\s*:\s*"([a-f0-9]+)"'
    name: trace_id
    url: '$${__value.raw}'
```

That regex looks for the JSON key `"trace_id"` (snake_case) followed by a hex string value. When it matches, Grafana renders a clickable link in the log line that opens the corresponding trace in Tempo.

**Your service MUST emit the trace_id under the exact JSON key `trace_id`.** Not `traceId`. Not `trace-id`. Not `traceID`. The contract is the literal string `trace_id`.

If you emit under a different key, logs↔traces correlation silently fails the rubric line. This is exactly the kind of agent-generated drift (the OTel SDK defaults to `traceId` in some languages) that should land in `JUDGEMENT.md` Section 2 as a catch.

---

## ⚠️ The cross-boundary path — read this

The LGTM stack runs on **the host** (via `make observability-up` docker-compose), NOT inside the kind cluster. This is deliberate — keeping LGTM out of kind speeds up cluster bring-up, keeps memory usage manageable, and makes the inner-loop `docker-compose up` flow on `service/<lang>/` work without a second observability stack.

The trade-off: your kind-deployed pod has to reach an out-of-cluster Collector. The starter's `deploy/deployment.yaml` does this by setting `OTEL_EXPORTER_OTLP_ENDPOINT=http://host.docker.internal:4318`. This works because:

- On **macOS / Windows Docker Desktop**: kind pods can resolve `host.docker.internal` to the host loopback IP. We tested this — it returns HTTP 200 from the docker-compose Loki without any extra setup.
- On **Linux Docker** (Docker Engine, not Desktop): `host.docker.internal` does NOT resolve from pods by default. Three workarounds:
  1. Add `extraMounts` to your `kind-config.yaml` mounting `/etc/hosts`.
  2. Look up the docker bridge gateway IP (`docker network inspect kind | jq '.[0].IPAM.Config'`) and substitute it directly into the env var.
  3. Ship an in-cluster OTel Collector that forwards to the host backends (more work, more correct).

Pick one, defend in `JUDGEMENT.md`. If you're on macOS/Windows you can ignore this and the default works.

Your `deploy/networkpolicy.yaml` egress rule needs to allow this — the default-deny blocks it. See the TODO in that file for the `ipBlock` pattern.

## What's in the stack

| Component | Container | Port (host) | Purpose |
| --------- | --------- | ----------- | ------- |
| Grafana | `grafana/grafana:11.3.0` | 3000 | UI for logs, traces, metrics. Login: `admin` / `admin` |
| Loki | `grafana/loki:3.2.1` | 3100 | Log storage. Receives from Promtail |
| Tempo | `grafana/tempo:2.6.1` | 3200 | Trace storage. Receives OTLP from the OTel Collector |
| Mimir | `grafana/mimir:2.14.1` | 9009 | Metrics storage (Prometheus-compatible). Receives via remote_write from the OTel Collector |
| Promtail | `grafana/promtail:3.2.1` | — | Tails Docker container logs and ships to Loki |
| OTel Collector | `otel/opentelemetry-collector-contrib:0.112.0` | 4317 (gRPC) / 4318 (HTTP) | Receives OTLP from your service, fans out: traces → Tempo, metrics → Mimir, logs → (optional, defaults to Loki) |

## Data flow

```
                  ┌─────────────────────────┐
                  │   your service (app)    │
                  │  (FastAPI / Express)    │
                  └────────────┬────────────┘
                               │
              ┌────────────────┼────────────────┐
              │                │                │
       JSON logs           OTLP traces      Prometheus
       to stdout           (via OTel SDK)    /metrics
              │                │                │
              ▼                ▼                ▼
        ┌──────────┐    ┌──────────────┐   ┌──────────┐
        │ Promtail │    │ OTel         │   │ OTel     │
        │ (tails   │    │ Collector    │   │ Collector│
        │  docker  │    │ (otlp/http)  │   │ (prom    │
        │  logs)   │    │              │   │ scrape)  │
        └────┬─────┘    └──────┬───────┘   └────┬─────┘
             │                 │                │
             ▼                 ▼                ▼
        ┌────────┐         ┌───────┐       ┌─────────┐
        │ Loki   │         │ Tempo │       │ Mimir   │
        └───┬────┘         └───┬───┘       └────┬────┘
            │                  │                │
            └──────────────────┼────────────────┘
                               ▼
                      ┌──────────────────┐
                      │     Grafana      │
                      │  (datasources    │
                      │   provisioned)   │
                      └──────────────────┘
```

## What you write

You add **one** RED dashboard JSON to `observability/grafana/dashboards/red.json` (the path is `grafana/dashboards/red.json` from inside `observability/`). It's auto-loaded by Grafana via the dashboards provisioning (already wired in `grafana/provisioning/dashboards/dashboards.yaml`, which points at `/etc/grafana/dashboards`. That container path is bind-mounted to `./grafana/dashboards` in `docker-compose.observability.yml`).

To create the dashboard:

1. Open Grafana → Dashboards → New → Add visualization.
2. Pick the Mimir datasource.
3. Add three panels — rate of requests, rate of errors, request duration histogram.
4. Export the dashboard as JSON (Settings gear → JSON Model → copy).
5. Save the JSON to `observability/grafana/dashboards/red.json`.
6. Grafana picks it up within ~30s (the provisioning `updateIntervalSeconds: 30`). To force a refresh, restart: `docker compose -f docker-compose.observability.yml restart grafana`.

The dashboard must render real data after `make load`. Don't ship an empty one — the panels need queries that work.

## Sanity checks

After `make observability-up`:

```bash
# All four backends reachable
curl -sf http://localhost:3000/api/health         # Grafana — "ok"
curl -sf http://localhost:3100/ready              # Loki — "ready"
curl -sf http://localhost:3200/ready              # Tempo — "ready"
curl -sf http://localhost:9009/ready              # Mimir — "ready"

# Datasources show up in Grafana
open http://localhost:3000/connections/datasources
# Should see: Loki, Tempo, Mimir — all green

# OTel Collector accepting OTLP
curl -sf http://localhost:4318/v1/traces -X POST \
  -H 'content-type: application/json' \
  -d '{"resourceSpans":[]}'                       # Should return 200 + {"partialSuccess":{}}
```

If any of these fail, check `docker compose -f docker-compose.observability.yml logs <container>`.

## What's intentionally NOT in this stack

- **Persistent storage.** Loki, Tempo, Mimir all run in `filesystem` mode with no persistent volumes. Take down the stack with `make observability-down -v` and your trace history is gone. Fine for the take-home.
- **Authn/authz.** Grafana is `admin / admin`. The other backends have no auth. Fine for local; obvious production gap.
- **Multi-tenancy.** Single tenant everywhere. Fine for one service.
- **A second dashboard.** Out of scope at the 12h tier — call out as a known gap in `RUNBOOK.md`.
- **Alerts.** Out of scope at the 12h tier — stretch tier if you want to add one.
- **Cilium for NetworkPolicy visibility.** Optional swap; defend in `JUDGEMENT.md` if you do it.
