# ycash-infra: build images from the workspace trees, run the chart on kind, promote to EKS.
WORKSPACE   ?= $(abspath ../..)
YCASH6      ?= $(WORKSPACE)/ycash6
YCASH_DD    ?= $(WORKSPACE)/ycash-dd
LWD         ?= $(WORKSPACE)/lightwalletd-dd
YEW         ?= $(WORKSPACE)/yew
CLUSTER     ?= ycash
NAMESPACE   ?= ycash
RELEASE     ?= ycash
CHART       := charts/ycash-lightwallet
REGISTRY    ?= ycash
YCASHD_REV  := $(shell git -C $(YCASH6) rev-parse --short HEAD 2>/dev/null || echo dev)
LWD_REV     := $(shell git -C $(LWD) rev-parse --short HEAD 2>/dev/null || echo dev)
YINDEX_REV  := $(shell git rev-parse --short HEAD 2>/dev/null || echo dev)
PLATFORM    ?= $(shell uname -m | sed 's/x86_64/linux\/amd64/;s/arm64/linux\/arm64/;s/aarch64/linux\/arm64/')
CONTEXT     ?= kind-$(CLUSTER)
JOBS        ?= $(shell sysctl -n hw.logicalcpu 2>/dev/null || nproc)
DOMAIN      ?= lite.example.org

.PHONY: help docker-noauth kind-reset-chain images image-ycashd image-ycashd-legacy proto-sync image-lightwalletd image-yindex image-web kind-create kind-load kind-up kind-down kind-smoke kind-parity kind-load-test eks-deploy lint template

help: ## list targets
	@grep -E '^[a-zA-Z_-]+:.*## ' $(MAKEFILE_LIST) | awk -F':.*## ' '{printf "  %-18s %s\n", $$1, $$2}'

images: image-ycashd image-lightwalletd image-yindex image-web ## build every image from the workspace trees

image-ycashd: ## ycashd from ../../ycash6's own contrib/docker/ycashd/Dockerfile (first build: 1-2 h; depends cached in a buildx mount)
	docker build --platform $(PLATFORM) -f $(YCASH6)/contrib/docker/ycashd/Dockerfile --build-arg JOBS=$(JOBS) -t $(REGISTRY)/ycashd:$(YCASHD_REV) -t $(REGISTRY)/ycashd:local $(YCASH6)

image-ycashd-legacy: ## the v4.5.0 line (../../ycash-dd), same Dockerfile shape, tagged ycashd-legacy
	docker build --platform $(PLATFORM) -f $(YCASH_DD)/contrib/docker/ycashd/Dockerfile --build-arg JOBS=$(JOBS) -t $(REGISTRY)/ycashd-legacy:local $(YCASH_DD)

proto-sync: ## refresh yindex/walletrpc from lightwalletd-dd (generated code, never edited here)
	cp $(LWD)/walletrpc/{service.pb.go,service_grpc.pb.go,compact_formats.pb.go,service.proto,compact_formats.proto} yindex/walletrpc/

image-lightwalletd: ## lightwalletd-dd from its own Dockerfile
	docker build --platform $(PLATFORM) --build-arg LWD_VERSION=$(LWD_REV) -t $(REGISTRY)/lightwalletd:$(LWD_REV) -t $(REGISTRY)/lightwalletd:local $(LWD)

image-yindex: ## the address index
	docker build --platform $(PLATFORM) -f images/yindex/Dockerfile -t $(REGISTRY)/yindex:$(YINDEX_REV) -t $(REGISTRY)/yindex:local .

image-web: ## the yew/web static bundle behind nginx (needs yew/web built: `npm run build` there)
	@test -d $(YEW)/web/dist || { echo "yew/web/dist missing: build the web wallet first (cd $(YEW)/web && npm run build)"; exit 1; }
	docker build --platform $(PLATFORM) -f images/web/Dockerfile -t $(REGISTRY)/web:local $(YEW)/web

kind-create: ## the kind cluster from kind/kind.yaml
	kind get clusters | grep -qx $(CLUSTER) || kind create cluster --name $(CLUSTER) --config kind/kind.yaml

kind-load: ## push the local images into the cluster
	kind load docker-image --name $(CLUSTER) $(REGISTRY)/ycashd:local $(REGISTRY)/lightwalletd:local $(REGISTRY)/yindex:local
	-kind load docker-image --name $(CLUSTER) $(REGISTRY)/web:local

kind-up: kind-create kind-load ## cluster + gateway + cert-manager + the chart (values-kind.yaml)
	scripts/kind-up.sh $(CLUSTER) $(NAMESPACE) $(RELEASE)

kind-reset-chain: ## wipe the regtest chain (node + Postgres volumes, attestor set, Jobs) and redeploy
	scripts/kind-reset-chain.sh $(CLUSTER) $(NAMESPACE) $(RELEASE)

kind-down: ## delete the cluster
	kind delete cluster --name $(CLUSTER)

kind-smoke: ## GetLightdInfo, GetYellowbackInfo, GetVaultInfo, GetChainInfo, ListSets through the gateway
	scripts/smoke.sh https://localhost:443

kind-parity: ## yindex vs lightwalletd's node-proxied answers for every address the chain touched (plan K3)
	scripts/parity.sh localhost:443

kind-load-test: ## ghz: the node RPC ceiling per method (plan K1)
	load/run.sh localhost:443

eks-deploy: ## helm upgrade --install with values-eks.yaml on CONTEXT (DOMAIN=...)
	helm upgrade --install $(RELEASE) $(CHART) --kube-context $(CONTEXT) -n $(NAMESPACE) --create-namespace \
	  -f $(CHART)/values-eks.yaml --set gateway.host=$(DOMAIN)

docker-noauth: ## print an `export DOCKER_CONFIG=...` that bypasses Docker Desktop's hanging keychain helper
	@d=$${TMPDIR:-/tmp}/docker-noauth; mkdir -p $$d; python3 -c "import json,sys; c=json.load(open('$(HOME)/.docker/config.json')); c.pop('credsStore',None); c['auths']={}; json.dump(c,open('$$d/config.json','w'))"; \
	for x in cli-plugins contexts buildx; do [ -e $(HOME)/.docker/$$x ] && ln -sfn $(HOME)/.docker/$$x $$d/$$x; done; echo "export DOCKER_CONFIG=$$d"

lint: ## helm lint + kubeconform + go vet
	helm lint $(CHART) -f $(CHART)/values-kind.yaml
	helm lint $(CHART) -f $(CHART)/values-eks.yaml
	helm template $(RELEASE) $(CHART) -f $(CHART)/values-kind.yaml | kubeconform -strict -ignore-missing-schemas -summary
	cd yindex && go vet ./...

template: ## render the kind values to stdout
	helm template $(RELEASE) $(CHART) -n $(NAMESPACE) -f $(CHART)/values-kind.yaml
