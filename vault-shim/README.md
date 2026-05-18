# vault-shim

A small HTTP service that mimics the operator-facing surface of an internal secrets vault. Used as a take-home fixture.

This repo contains the service only. It is not a production component.

## Surface

| Method | Path | Auth | Description |
| --- | --- | --- | --- |
| `POST` | `/v1/secrets` | Bearer | Store a secret. Body: `{"key": "...", "value": "..."}`. Returns `201` with `{"key": "..."}`. |
| `GET` | `/v1/secrets/{key}` | Bearer | Retrieve a secret by key. Returns `200` with `{"key": "...", "value": "..."}` or `404`. |
| `GET` | `/healthz` | none | Liveness probe. Returns `200` with `{"status": "ok"}`. |
| `GET` | `/readyz` | none | Readiness probe. Returns `200` with `{"status": "ready"}`. |

The bearer token can be either a JWT signed with the configured `signing_key` (HMAC), or the raw `bootstrap_token` from the config file.

Storage is in-memory. The service does not persist across restarts. There is no database dependency.

## Build

```bash
go mod download
go build -o vault-shim .
```

## Run

```bash
./vault-shim --config ./config.yaml
```

Or with the env var:

```bash
VAULT_SHIM_CONFIG=./config.yaml ./vault-shim
```

The service listens on the address in `config.yaml` (`:8080` by default).

## Configuration

`config.yaml` keys:

| Key | Purpose |
| --- | --- |
| `addr` | Address to bind. Defaults to `:8080`. |
| `log_level` | Log verbosity hint. Currently informational only. |
| `signing_key` | HMAC key used to verify bearer JWTs. |
| `bootstrap_token` | Raw bearer token accepted as an alternative to a signed JWT. |

## Quick smoke test

```bash
# in one terminal
./vault-shim --config ./config.yaml

# in another
TOKEN="vshim_b9d4c8e1a2f7345698abcdef01234567"
curl -s http://localhost:8080/healthz
curl -s -X POST http://localhost:8080/v1/secrets \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"key":"db/password","value":"hunter2"}'
curl -s http://localhost:8080/v1/secrets/db/password \
  -H "Authorization: Bearer $TOKEN"
```

## Container

A single-stage `Dockerfile` is included for convenience:

```bash
docker build -t vault-shim:dev .
docker run --rm -p 8080:8080 vault-shim:dev
```

## Layout

```
.
├── README.md
├── go.mod
├── main.go
├── config.yaml
└── Dockerfile
```

## Not provided

This repo intentionally does not include tests, CI workflows, Kubernetes manifests, observability instrumentation, or a deployment pipeline. Those are part of the take-home you are working on around this service.
