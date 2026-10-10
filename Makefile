# ycash-infra: build images from the workspace trees, run the chart on kind, promote to EKS.
WORKSPACE   ?= $(abspath ../..)
YCASH6      ?= $(WORKSPACE)/ycash6
YCASH_DD    ?= $(WORKSPACE)/ycash-dd
LWD         ?= $(WORKSPACE)/lightwalletd-dd
# the wallet tree: the workspace's wt/yew-web worktree when it exists (the web shell's branch), else yew/
YEW         ?= $(if $(wildcard $(WORKSPACE)/wt/yew-web/web),$(WORKSPACE)/wt/yew-web,$(WORKSPACE)/yew)
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

.PHONY: help docker-noauth kind-reset-chain images image-ycashd image-ycashd-legacy proto-sync image-lightwalletd image-yindex image-web image-faucet kind-create kind-load kind-up kind-down kind-cert demo kind-smoke kind-load-test eks-up eks-push eks-deploy eks-smoke eks-down eks-validate lint template kind-parity

help: ## list targets
	@grep -E '^[a-zA-Z_-]+:.*## ' $(MAKEFILE_LIST) | awk -F':.*## ' '{printf "  %-18s %s\n", $$1, $$2}'

images: image-ycashd image-lightwalletd image-yindex image-web image-faucet ## build every image from the workspace trees

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

image-web: ## the yew/web static bundle behind nginx (needs yew/web built: scripts/build-core-wasm.sh + `npm run build` there; YEW=… for a worktree)
	@test -d $(YEW)/web/dist || { echo "yew/web/dist missing: build the web wallet first (cd $(YEW)/web && scripts/build-core-wasm.sh && npm run build)"; exit 1; }
	docker buildx build --load --platform $(PLATFORM) --build-context dist=$(YEW)/web/dist -t $(REGISTRY)/web:$(WEB_REV) -t $(REGISTRY)/web:local images/web

image-faucet: ## the regtest faucet (images/faucet: python:3.12-alpine + the standard library)
	docker build --platform $(PLATFORM) -t $(REGISTRY)/faucet:$(YINDEX_REV) -t $(REGISTRY)/faucet:local images/faucet

kind-create: ## the kind cluster from kind/kind.yaml
	kind get clusters | grep -qx $(CLUSTER) || kind create cluster --name $(CLUSTER) --config kind/kind.yaml

kind-load: ## push the local images into the cluster
	kind load docker-image --name $(CLUSTER) $(REGISTRY)/ycashd:local $(REGISTRY)/lightwalletd:local $(REGISTRY)/yindex:local
	-kind load docker-image --name $(CLUSTER) $(REGISTRY)/web:local
	-kind load docker-image --name $(CLUSTER) $(REGISTRY)/faucet:local

kind-up: kind-create kind-load ## cluster + gateway + cert-manager + the chart (values-kind.yaml)
	scripts/kind-up.sh $(CLUSTER) $(NAMESPACE) $(RELEASE)

kind-cert: ## a browser-trusted certificate for https://localhost from mkcert's local CA as the gateway's TLS Secret (mkcert -install touches the system trust store)
	scripts/kind-cert.sh $(CLUSTER) $(NAMESPACE) $(RELEASE)

demo: ## idempotent: cluster, images, the mkcert certificate, kube-prometheus-stack, the chart; prints the wallet, faucet and Grafana URLs (docs/try-it.md)
	MONITORING=$${MONITORING:-1} scripts/demo.sh $(CLUSTER) $(NAMESPACE) $(RELEASE) "$(YEW)"

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

# ---- EKS (docs/eks-runbook.md). TF_DIR holds the terraform state; terraform output feeds the rest.
TF_DIR      ?= infra/eks
TF          ?= terraform -chdir=$(TF_DIR)
EKS_CONTEXT ?= $(shell $(TF) output -raw cluster_name 2>/dev/null)
ECR         ?= $(shell $(TF) output -raw ecr_registry 2>/dev/null)
EKS_DOMAIN  ?= $(shell $(TF) output -raw domain 2>/dev/null || echo $(DOMAIN))
WEB_REV     ?= $(shell git -C $(YEW) rev-parse --short HEAD 2>/dev/null || echo dev)

eks-up: ## terraform apply (VPC, EKS, IRSA, ECR, RDS, secrets, add-ons) and write the kubeconfig context; needs infra/eks/terraform.tfvars
	$(TF) init
	$(TF) apply
	$$($(TF) output -raw kubeconfig_command)

eks-push: ## tag the four local images with their revs and push them to ECR (make images first)
	scripts/eks-push.sh "$(ECR)" "$(REGISTRY)" ycashd:$(YCASHD_REV) lightwalletd:$(LWD_REV) yindex:$(YINDEX_REV) web:$(WEB_REV)

eks-deploy: ## helm upgrade --install with values-eks.yaml: ECR images at their revs, the host from terraform (or DOMAIN=)
	helm upgrade --install $(RELEASE) $(CHART) --kube-context $(EKS_CONTEXT) -n $(NAMESPACE) --create-namespace \
	  -f $(CHART)/values-eks.yaml --set gateway.host=$(EKS_DOMAIN) \
	  --set images.ycashd.repository=$(ECR)/ycash/ycashd --set images.ycashd.tag=$(YCASHD_REV) \
	  --set images.lightwalletd.repository=$(ECR)/ycash/lightwalletd --set images.lightwalletd.tag=$(LWD_REV) \
	  --set images.yindex.repository=$(ECR)/ycash/yindex --set images.yindex.tag=$(YINDEX_REV) \
	  --set images.web.repository=$(ECR)/ycash/web --set images.web.tag=$(WEB_REV) \
	  --wait --timeout 20m

eks-smoke: ## the smoke test against the public host (TLS from Let's Encrypt; ADDR= a funded t-address)
	ADDR="$(ADDR)" scripts/smoke.sh https://$(EKS_DOMAIN):443

eks-down: ## helm uninstall (releases the NLB and the record) then terraform destroy (RDS and the secrets go too)
	-helm uninstall $(RELEASE) --kube-context $(EKS_CONTEXT) -n $(NAMESPACE) --wait
	$(TF) destroy

eks-validate: ## offline: terraform fmt/validate + helm template (values-eks.yaml) through kubeconform with the CRD schemas
	terraform -chdir=$(TF_DIR) fmt -check -recursive
	terraform -chdir=$(TF_DIR) init -backend=false -input=false >/dev/null
	terraform -chdir=$(TF_DIR) validate
	helm lint $(TF_DIR)/charts/cluster-config --set hostedZoneId=Z0
	helm lint $(CHART) -f $(CHART)/values-eks.yaml $(EKS_LINT_SET)
	helm template $(RELEASE) $(CHART) -n $(NAMESPACE) -f $(CHART)/values-eks.yaml $(EKS_LINT_SET) | kubeconform -strict -summary $(KUBECONFORM_SCHEMAS)
	# the catalog's external-secrets.io/v1 ClusterSecretStore schema does not compile in kubeconform 0.8 (ExternalSecret v1 does): skipped
	helm template cc $(TF_DIR)/charts/cluster-config --set hostedZoneId=Z0 | kubeconform -strict -summary -skip ClusterSecretStore $(KUBECONFORM_SCHEMAS)

EKS_LINT_SET := --set gateway.host=lite.example.org \
  --set images.ycashd.repository=0.dkr.ecr.us-east-1.amazonaws.com/ycash/ycashd \
  --set images.lightwalletd.repository=0.dkr.ecr.us-east-1.amazonaws.com/ycash/lightwalletd --set images.lightwalletd.tag=rev \
  --set images.yindex.repository=0.dkr.ecr.us-east-1.amazonaws.com/ycash/yindex --set images.yindex.tag=rev \
  --set images.web.repository=0.dkr.ecr.us-east-1.amazonaws.com/ycash/web --set images.web.tag=rev
# CRD schemas (Gateway API, Envoy Gateway, cert-manager, External Secrets, Prometheus Operator) from datree's catalog
KUBECONFORM_SCHEMAS := -schema-location default -schema-location 'https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json'

docker-noauth: ## print an `export DOCKER_CONFIG=...` that bypasses Docker Desktop's hanging keychain helper
	@d=$${TMPDIR:-/tmp}/docker-noauth; mkdir -p $$d; python3 -c "import json,sys; c=json.load(open('$(HOME)/.docker/config.json')); c.pop('credsStore',None); c['auths']={}; json.dump(c,open('$$d/config.json','w'))"; \
	for x in cli-plugins contexts buildx; do [ -e $(HOME)/.docker/$$x ] && ln -sfn $(HOME)/.docker/$$x $$d/$$x; done; echo "export DOCKER_CONFIG=$$d"

lint: ## helm lint + kubeconform + go vet
	helm lint $(CHART) -f $(CHART)/values-kind.yaml
	helm lint $(CHART) -f $(CHART)/values-eks.yaml $(EKS_LINT_SET)
	helm template $(RELEASE) $(CHART) -f $(CHART)/values-kind.yaml | kubeconform -strict -summary $(KUBECONFORM_SCHEMAS)
	cd yindex && go vet ./...

template: ## render the kind values to stdout
	helm template $(RELEASE) $(CHART) -n $(NAMESPACE) -f $(CHART)/values-kind.yaml
