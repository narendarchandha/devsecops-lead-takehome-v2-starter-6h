FROM golang:1.21

WORKDIR /app

COPY . .

RUN go mod download
RUN go build -o /app/vault-shim .

EXPOSE 8080

ENTRYPOINT ["/app/vault-shim", "--config", "/app/config.yaml"]
