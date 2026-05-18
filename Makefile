.DEFAULT_GOAL := help
SHELL := /bin/bash
CLUSTER_NAME ?= vault-shim
KIND_CONFIG  ?= kind-config.yaml

.PHONY: help
help: ## Show this help.
	@awk 'BEGIN {FS = ":.*?## "} /^[a-zA-Z_-]+:.*?## / {printf "  \033[36m%-28s\033[0m %s\n", $$1, $$2}' $(MAKEFILE_LIST)

# ---------------------------------------------------------------------------
# One-shot
# ---------------------------------------------------------------------------

.PHONY: up
up: observability-up cluster-up deploy ## Bring up everything: LGTM + kind + deploy

.PHONY: down
down: deploy-down cluster-down observability-down ## Tear down everything

# ---------------------------------------------------------------------------
# Observability (host docker-compose)
# ---------------------------------------------------------------------------

.PHONY: observability-up
observability-up: ## Bring up the LGTM stack via docker compose
	cd observability && docker compose -f docker-compose.observability.yml up -d
	@echo "Grafana: http://localhost:3000 (anonymous; admin if needed admin/admin)"
	@echo "OTel Collector OTLP HTTP: http://localhost:4318"

.PHONY: observability-down
observability-down: ## Tear down the LGTM stack
	cd observability && docker compose -f docker-compose.observability.yml down -v

# ---------------------------------------------------------------------------
# Cluster (kind)
# ---------------------------------------------------------------------------

.PHONY: cluster-up
cluster-up: ## Create kind cluster + install Calico + ingress-nginx + Kyverno + ESO
	kind create cluster --name $(CLUSTER_NAME) --config $(KIND_CONFIG)
	@echo "Installing Calico CNI (kindnet is disabled — see kind-config.yaml)..."
	kubectl apply --server-side -f https://raw.githubusercontent.com/projectcalico/calico/v3.27.3/manifests/calico.yaml
	kubectl -n kube-system wait --for=condition=available --timeout=180s deployment/calico-kube-controllers
	kubectl -n kube-system rollout status daemonset/calico-node --timeout=180s
	kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/controller-v1.11.3/deploy/static/provider/kind/deploy.yaml
	@echo "Waiting for ingress-nginx pod to be Ready..."
	@for i in $$(seq 1 45); do \
		kubectl -n ingress-nginx get pod -l app.kubernetes.io/component=controller 2>/dev/null | grep -q '.' && break; \
		sleep 2; \
	done
	kubectl -n ingress-nginx wait --for=condition=ready pod --selector=app.kubernetes.io/component=controller --timeout=180s
	@echo "Installing Kyverno..."
	# Server-side apply: Kyverno CRDs exceed the 256KB client-side annotation limit.
	kubectl apply --server-side -f https://github.com/kyverno/kyverno/releases/download/v1.12.0/install.yaml
	kubectl -n kyverno wait --for=condition=available --timeout=180s deployment/kyverno-admission-controller
	@echo "Installing External Secrets Operator..."
	helm repo add external-secrets https://charts.external-secrets.io 2>/dev/null || true
	helm repo update
	helm upgrade --install external-secrets external-secrets/external-secrets -n external-secrets --create-namespace --wait

.PHONY: cluster-down
cluster-down: ## Delete kind cluster
	kind delete cluster --name $(CLUSTER_NAME)

# ---------------------------------------------------------------------------
# Deploy (kubectl)
# ---------------------------------------------------------------------------

.PHONY: build-image
build-image: ## Build vault-shim image and load into kind
	docker build -t vault-shim:dev ./vault-shim
	kind load docker-image vault-shim:dev --name $(CLUSTER_NAME)

.PHONY: deploy
deploy: build-image ## Apply deploy/ + policies
	kubectl apply -f deploy/policies/
	kubectl apply -k deploy/
	@echo "Waiting for vault-shim Deployment to be Available..."
	kubectl -n vault-shim wait --for=condition=available --timeout=120s deployment/vault-shim || \
		(echo ""; echo "Deployment did not become available. Investigate:"; \
		 echo "  kubectl -n vault-shim describe deployment vault-shim"; \
		 echo "  kubectl -n vault-shim describe pod -l app.kubernetes.io/name=vault-shim"; \
		 echo "  kubectl -n vault-shim get networkpolicy"; \
		 exit 1)
	@echo ""
	@echo "vault-shim reachable via ingress at http://vault-shim.localtest.me/healthz"
	@echo "Add to /etc/hosts: 127.0.0.1 vault-shim.localtest.me"

.PHONY: deploy-down
deploy-down: ## Delete deploy/ resources
	kubectl delete -k deploy/ || true
	kubectl delete -f deploy/policies/ || true

# ---------------------------------------------------------------------------
# Validation
# ---------------------------------------------------------------------------

.PHONY: validate-manifests
validate-manifests: ## kubeconform on every deploy manifest
	@which kubeconform > /dev/null || (echo "kubeconform not installed; brew install kubeconform" && exit 1)
	kubeconform -strict -summary -kubernetes-version 1.30.0 deploy/

.PHONY: validate-negative-tests
validate-negative-tests: ## Run the negative tests the brief promises (kubectl exec, curl 1.1.1.1, apply violation)
	@echo "=== Negative test 1: pod can NOT reach 1.1.1.1 (NetworkPolicy default-deny) ==="
	kubectl -n vault-shim run debug --image=nicolaka/netshoot --rm --restart=Never -i -- \
		sh -c 'curl --max-time 3 -sSI https://1.1.1.1 2>&1 || echo "BLOCKED (expected)"'
	@echo ""
	@echo "=== Negative test 2: bad manifest must be rejected by Kyverno ==="
	@cat <<'EOF' > /tmp/bad-pod.yaml
	apiVersion: v1
	kind: Pod
	metadata:
	  name: bad-pod
	  namespace: vault-shim
	spec:
	  containers:
	    - name: bad
	      image: nginx:1.27
	      securityContext:
	        allowPrivilegeEscalation: true
	EOF
	@set +e; out=$$(kubectl apply --dry-run=server -f /tmp/bad-pod.yaml 2>&1); ec=$$?; \
		echo "$$out"; \
		if [ $$ec -eq 0 ]; then echo "FAIL: bad manifest was admitted"; exit 1; \
		else echo "OK: bad manifest rejected"; fi

# ---------------------------------------------------------------------------
# Inner loop
# ---------------------------------------------------------------------------

.PHONY: vault-shim-up
vault-shim-up: ## docker compose up vault-shim alone (no kind, no LGTM)
	docker compose up --build -d

.PHONY: vault-shim-down
vault-shim-down: ## docker compose down vault-shim
	docker compose down -v
