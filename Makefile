# ycash-infra: build images from the workspace trees, run the chart on kind, promote to EKS.
WORKSPACE   ?= $(abspath ..)
# The source trees (AGENTS.md rule 5): the workspace's main repo dirs (README layout, repos.yaml).
# Point them anywhere else (a worktree) on the command line.
YCASH6      ?= $(WORKSPACE)/ycash6
YCASH_DD    ?= $(WORKSPACE)/ycash-dd
LWD         ?= $(WORKSPACE)/lightwalletd-dd
# The node line the images are built from, as a branch: each tree must have it checked out or be on a
# branch that contains it (`make line` checks). LINE is a shorthand for the branch names only:
# LINE=vault -> upgrade/vault, LINE=quantum -> upgrade/quantum-vaults.
LINE        ?=
ifeq ($(LINE),quantum)
BRANCH      ?= upgrade/quantum-vaults
else ifeq ($(LINE),vault)
BRANCH      ?= upgrade/vault
else ifneq ($(LINE),)
$(error LINE=$(LINE): quantum or vault, or set BRANCH)
endif
BRANCH      ?= upgrade/vault
# The rpcversion the trees must speak (ycashd YELLOWBACK_RPC_VERSION = lightwalletd-dd KnownRPCVersion);
# empty = they only have to agree. Deploy with --set ycashd.rpcVersion=<it> (the chart's default is 8).
RPC_VERSION ?=
# the node image's Dockerfile (contrib/docker/ycashd/, K0a); it COPYs its entrypoint from the build context
YCASHD_DOCKERFILE ?= $(YCASH6)/contrib/docker/ycashd/Dockerfile
YCASHD_LEGACY_DOCKERFILE ?= $(YCASH_DD)/contrib/docker/ycashd/Dockerfile
# the wallet tree: yew/ (the web shell is on its upgrade/vault since yew#14); YEW=… for a worktree
YEW         ?= $(WORKSPACE)/yew
CLUSTER     ?= ycash
NAMESPACE   ?= ycash
RELEASE     ?= ycash
CHART       := charts/ycash-lightwallet
TESTNET_CHART := charts/ycash-testnet
REGISTRY    ?= ycash
YCASHD_REV  := $(shell git -C $(YCASH6) rev-parse --short HEAD 2>/dev/null || echo dev)
LWD_REV     := $(shell git -C $(LWD) rev-parse --short HEAD 2>/dev/null || echo dev)
YINDEX_REV  := $(shell git rev-parse --short HEAD 2>/dev/null || echo dev)
PLATFORM    ?= $(shell uname -m | sed 's/x86_64/linux\/amd64/;s/arm64/linux\/arm64/;s/aarch64/linux\/arm64/')
CONTEXT     ?= kind-$(CLUSTER)
JOBS        ?= $(shell sysctl -n hw.logicalcpu 2>/dev/null || nproc)
DOMAIN      ?= lite.example.org
# kind-up / kind-reset-chain / demo: how long each Deployment and StatefulSet of the release may take
# to roll out before the target fails (scripts/kind-check-release.sh)
ROLLOUT_TIMEOUT ?= 10m

.PHONY: help line image-check docker-noauth kind-reset-chain images image-ycashd image-ycashd-legacy proto-sync image-lightwalletd image-yindex image-web image-faucet kind-create kind-load kind-up kind-down kind-cert demo kind-smoke kind-load-test eks-up eks-push eks-deploy eks-smoke eks-down eks-validate seeds-validate lint lint-testnet template kind-parity kind-personas-up kind-personas-down kind-personas-status prefix-test prefix-verify prefix-local mainnet-prefix-local zcash-params-test

help: ## list targets
	@grep -E '^[a-zA-Z_-]+:.*## ' $(MAKEFILE_LIST) | awk -F':.*## ' '{printf "  %-18s %s\n", $$1, $$2}'

images: image-ycashd image-lightwalletd image-yindex image-web image-faucet ## build every image from the workspace trees

# Image stamps (scripts/image-stamp.sh): each image-* target labels the image with a sha256 over these
# files; kind-load refuses a :local image whose label differs from them as they are now (a chart change
# can need a rebuilt image). The node and lightwalletd files are hashed in their own trees, never edited.
STAMP_LABEL         := org.ycash.infra.stamp
STAMP_ycashd        = $(YCASHD_DOCKERFILE) $(dir $(YCASHD_DOCKERFILE))entrypoint.sh
STAMP_ycashd_legacy = $(YCASHD_LEGACY_DOCKERFILE) $(dir $(YCASHD_LEGACY_DOCKERFILE))entrypoint.sh
STAMP_lightwalletd  = $(LWD)/Dockerfile $(LWD)/docker/entrypoint.sh
STAMP_yindex        = images/yindex/Dockerfile
STAMP_web           = images/web/Dockerfile images/web/nginx.conf
STAMP_faucet        = images/faucet/Dockerfile images/faucet/faucet.py images/faucet/fetch-params.py images/faucet/index.html images/faucet/app.js
# ALLOW_STALE_IMAGES=1 (every image) or =ycashd,lightwalletd (by name): kind-load warns about a stale
# image instead of failing (e.g. a node image built before stamps from an unchanged Dockerfile)
ALLOW_STALE_IMAGES ?=

line: ## check the source trees: on BRANCH (or a branch containing it), one rpcversion across ycashd and lightwalletd-dd (RPC_VERSION= to require one)
	@set -e; vs=""; for t in $(YCASH6) $(YCASH_DD) $(LWD); do \
	  b=$$(git -C $$t rev-parse --abbrev-ref HEAD 2>/dev/null) || { echo "  $$t: not a git tree"; exit 1; }; \
	  if [ -f $$t/src/rpc/yellowback.cpp ]; then v=$$(sed -n 's/.*YELLOWBACK_RPC_VERSION = \([0-9]*\);.*/\1/p' $$t/src/rpc/yellowback.cpp | head -1); \
	  else v=$$(sed -n 's/^const KnownRPCVersion = \([0-9]*\).*/\1/p' $$t/common/yellowback.go | head -1); fi; \
	  printf '  %-16s %-26s %-10s rpcversion %s\n' "$$(basename $$t)" "$$b" "$$(git -C $$t rev-parse --short HEAD)" "$${v:-?}"; \
	  git -C $$t rev-parse -q --verify "$(BRANCH)^{commit}" >/dev/null || { echo "  $$t has no branch $(BRANCH)"; exit 1; }; \
	  git -C $$t merge-base --is-ancestor "$(BRANCH)" HEAD || { echo "  $$t: HEAD ($$b) does not contain $(BRANCH)"; exit 1; }; \
	  vs="$$vs $${v:-?}"; \
	done; \
	set -- $$vs; for v in "$$@"; do [ "$$v" = "$$1" ] || { echo "  rpcversion differs between the trees:$$vs"; exit 1; }; done; \
	if [ -n "$(RPC_VERSION)" ] && [ "$$1" != "$(RPC_VERSION)" ]; then echo "  the trees speak rpcversion $$1, RPC_VERSION=$(RPC_VERSION)"; exit 1; fi; \
	echo "  line $(BRANCH): rpcversion $$1 (deploy with --set ycashd.rpcVersion=$$1)"

image-ycashd: line ## ycashd from YCASH6 (BRANCH) and its contrib/docker/ycashd/Dockerfile (first build: 1-2 h; depends cached in a buildx mount)
	@test -f $(YCASHD_DOCKERFILE) || { echo "$(YCASHD_DOCKERFILE) missing: contrib/docker/ycashd (K0a) is not in $(YCASH6) yet"; exit 1; }
	s=$$(scripts/image-stamp.sh hash $(STAMP_ycashd)) && docker build --platform $(PLATFORM) -f $(YCASHD_DOCKERFILE) --build-arg JOBS=$(JOBS) --label $(STAMP_LABEL)=$$s -t $(REGISTRY)/ycashd:$(YCASHD_REV) -t $(REGISTRY)/ycashd:local $(YCASH6)

image-ycashd-legacy: line ## the v4.5.0 tree YCASH_DD (BRANCH), same Dockerfile shape, tagged ycashd-legacy
	@test -f $(YCASHD_LEGACY_DOCKERFILE) || { echo "$(YCASHD_LEGACY_DOCKERFILE) missing: contrib/docker/ycashd (K0a) is not in $(YCASH_DD) yet"; exit 1; }
	s=$$(scripts/image-stamp.sh hash $(STAMP_ycashd_legacy)) && docker build --platform $(PLATFORM) -f $(YCASHD_LEGACY_DOCKERFILE) --build-arg JOBS=$(JOBS) --label $(STAMP_LABEL)=$$s -t $(REGISTRY)/ycashd-legacy:local $(YCASH_DD)

proto-sync: ## refresh yindex/walletrpc from lightwalletd-dd (generated code, never edited here)
	cp $(LWD)/walletrpc/{service.pb.go,service_grpc.pb.go,compact_formats.pb.go,service.proto,compact_formats.proto} yindex/walletrpc/

image-lightwalletd: line ## lightwalletd-dd from LWD (BRANCH), its own Dockerfile; it speaks exactly the node's rpcversion
	s=$$(scripts/image-stamp.sh hash $(STAMP_lightwalletd)) && docker build --platform $(PLATFORM) --build-arg LWD_VERSION=$(LWD_REV) --label $(STAMP_LABEL)=$$s -t $(REGISTRY)/lightwalletd:$(LWD_REV) -t $(REGISTRY)/lightwalletd:local $(LWD)

image-yindex: ## the address index
	s=$$(scripts/image-stamp.sh hash $(STAMP_yindex)) && docker build --platform $(PLATFORM) -f images/yindex/Dockerfile --label $(STAMP_LABEL)=$$s -t $(REGISTRY)/yindex:$(YINDEX_REV) -t $(REGISTRY)/yindex:local .

image-web: ## the yew/web static bundle behind nginx (needs yew/web built: scripts/build-core-wasm.sh + `npm run build` there; YEW=… for a worktree)
	@test -d $(YEW)/web/dist || { echo "yew/web/dist missing: build the web wallet first (cd $(YEW)/web && scripts/build-core-wasm.sh && npm run build)"; exit 1; }
	s=$$(scripts/image-stamp.sh hash $(STAMP_web)) && docker buildx build --load --platform $(PLATFORM) --build-context dist=$(YEW)/web/dist --label $(STAMP_LABEL)=$$s -t $(REGISTRY)/web:$(WEB_REV) -t $(REGISTRY)/web:local images/web

image-faucet: ## the regtest faucet (images/faucet: python:3.12-alpine + the standard library)
	s=$$(scripts/image-stamp.sh hash $(STAMP_faucet)) && docker build --platform $(PLATFORM) --label $(STAMP_LABEL)=$$s -t $(REGISTRY)/faucet:$(YINDEX_REV) -t $(REGISTRY)/faucet:local images/faucet

kind-create: ## the kind cluster from kind/kind.yaml
	kind get clusters | grep -qx $(CLUSTER) || kind create cluster --name $(CLUSTER) --config kind/kind.yaml

image-check: ## each :local image's stamp label against its Dockerfile (and copied files) in the tree now
	@export ALLOW_STALE_IMAGES="$(ALLOW_STALE_IMAGES)"; bad=0; \
	scripts/image-stamp.sh check $(REGISTRY)/ycashd:local image-ycashd $(STAMP_ycashd) || bad=1; \
	scripts/image-stamp.sh check $(REGISTRY)/lightwalletd:local image-lightwalletd $(STAMP_lightwalletd) || bad=1; \
	scripts/image-stamp.sh check $(REGISTRY)/yindex:local image-yindex $(STAMP_yindex) || bad=1; \
	scripts/image-stamp.sh check $(REGISTRY)/web:local image-web $(STAMP_web) || bad=1; \
	scripts/image-stamp.sh check $(REGISTRY)/faucet:local image-faucet $(STAMP_faucet) || bad=1; \
	[ $$bad = 0 ] || { echo "rebuild the image(s) above, or ALLOW_STALE_IMAGES=1 (all) / =ycashd,web (by name) to go on; pods already on a reloaded tag need kubectl rollout restart"; exit 1; }

kind-load: image-check ## push the local images into the cluster (refuses stale ones: image-check, ALLOW_STALE_IMAGES=1)
	kind load docker-image --name $(CLUSTER) $(REGISTRY)/ycashd:local $(REGISTRY)/lightwalletd:local $(REGISTRY)/yindex:local
	-kind load docker-image --name $(CLUSTER) $(REGISTRY)/web:local
	-kind load docker-image --name $(CLUSTER) $(REGISTRY)/faucet:local

kind-up: kind-create kind-load ## cluster + gateway + cert-manager + the chart (values-kind.yaml); fails unless every workload rolls out (ROLLOUT_TIMEOUT=10m each) and no pod is failing
	ROLLOUT_TIMEOUT=$(ROLLOUT_TIMEOUT) scripts/kind-up.sh $(CLUSTER) $(NAMESPACE) $(RELEASE)

kind-cert: ## a browser-trusted certificate for https://localhost from mkcert's local CA as the gateway's TLS Secret (mkcert -install touches the system trust store)
	scripts/kind-cert.sh $(CLUSTER) $(NAMESPACE) $(RELEASE)

demo: ## idempotent: cluster, images, the mkcert certificate, kube-prometheus-stack, the chart; prints the wallet, faucet and Grafana URLs (docs/try-it.md)
	ROLLOUT_TIMEOUT=$(ROLLOUT_TIMEOUT) MONITORING=$${MONITORING:-1} scripts/demo.sh $(CLUSTER) $(NAMESPACE) $(RELEASE) "$(YEW)"

kind-reset-chain: ## wipe the regtest chain (node + Postgres volumes, attestor set, Jobs) and redeploy
	ROLLOUT_TIMEOUT=$(ROLLOUT_TIMEOUT) scripts/kind-reset-chain.sh $(CLUSTER) $(NAMESPACE) $(RELEASE)

kind-down: ## delete the cluster
	kind delete cluster --name $(CLUSTER)

kind-smoke: ## GetLightdInfo, GetYellowbackInfo, GetVaultInfo, GetChainInfo, ListSets through the gateway
	CONTEXT=$(CONTEXT) NAMESPACE=$(NAMESPACE) RELEASE=$(RELEASE) LWD_DIR=$(LWD) scripts/smoke.sh https://localhost:443

# ---- the Yellowback personas (plan K0c): host-run, the devnet's own agents against the kind node
PYTHON      ?= $(WORKSPACE)/.venv/bin/python
PERSONAS    := WORKSPACE=$(WORKSPACE) YCASH6=$(YCASH6) NAMESPACE=$(NAMESPACE) RELEASE=$(RELEASE) CONTEXT=$(CONTEXT) $(PYTHON) scripts/kind-personas.py

kind-personas-up: ## arm YED for real: the node as the quoting pool, 3 registered attestors, attest/quote agents, the price walk (PRICE=50)
	$(PERSONAS) up --price $(or $(PRICE),50)

kind-personas-down: ## stop the agents (the chain stays ARMED; minting halts once the attestations go stale)
	$(PERSONAS) down

kind-personas-status: ## the agents, attest status, the price, a mint estimate
	$(PERSONAS) status

kind-parity: ## yindex vs lightwalletd's node-proxied answers for every address the chain touched (plan K3)
	scripts/parity.sh localhost:443

kind-load-test: ## ghz: the node RPC ceiling per method (plan K1)
	load/run.sh localhost:443

# ---- EKS (docs/eks-runbook.md). TF_DIR is the example root around infra/eks/module and holds the
# terraform state (local); terraform output feeds the rest. A private root calls the module instead.
TF_DIR      ?= infra/eks
EKS_MODULE  := infra/eks/module
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
	ADDR="$(ADDR)" CONTEXT=$(EKS_CONTEXT) NAMESPACE=$(NAMESPACE) RELEASE=$(RELEASE) LWD_DIR=$(LWD) scripts/smoke.sh https://$(EKS_DOMAIN):443

eks-down: ## helm uninstall (releases the NLB and the record) then terraform destroy (RDS and the secrets go too)
	-helm uninstall $(RELEASE) --kube-context $(EKS_CONTEXT) -n $(NAMESPACE) --wait
	$(TF) destroy

eks-validate: ## offline: terraform fmt/validate (example root and module), the module's test (mocked providers), helm template (values-eks.yaml) through kubeconform with the CRD schemas
	terraform -chdir=$(TF_DIR) fmt -check -recursive
	terraform -chdir=$(TF_DIR) init -backend=false -input=false >/dev/null
	terraform -chdir=$(TF_DIR) validate
	terraform -chdir=$(EKS_MODULE) init -backend=false -input=false >/dev/null
	terraform -chdir=$(EKS_MODULE) test
	helm lint $(EKS_MODULE)/charts/cluster-config --set hostedZoneId=Z0
	helm lint $(CHART) -f $(CHART)/values-eks.yaml $(EKS_LINT_SET)
	helm template $(RELEASE) $(CHART) -n $(NAMESPACE) -f $(CHART)/values-eks.yaml $(EKS_LINT_SET) | kubeconform -strict -summary $(KUBECONFORM_SCHEMAS)
	# the catalog's external-secrets.io/v1 ClusterSecretStore schema does not compile in kubeconform 0.8 (ExternalSecret v1 does): skipped
	helm template cc $(EKS_MODULE)/charts/cluster-config --set hostedZoneId=Z0 | kubeconform -strict -summary -skip ClusterSecretStore $(KUBECONFORM_SCHEMAS)

SEEDS_DIRS := infra/testnet-seeds/ips infra/testnet-seeds/nodes
seeds-validate: ## offline: terraform fmt/validate for infra/testnet-seeds (ips, nodes), the nodes test (mocked AWS), shellcheck and the offline seedctl test; no credentials, no plan
	terraform fmt -check -recursive infra/testnet-seeds
	set -e; for d in $(SEEDS_DIRS); do terraform -chdir=$$d init -backend=false -input=false >/dev/null; terraform -chdir=$$d validate; done
	terraform -chdir=infra/testnet-seeds/nodes test
	shellcheck infra/testnet-seeds/nodes/files/*.sh infra/testnet-seeds/nodes/files/seedctl infra/testnet-seeds/nodes/tests/*.sh
	infra/testnet-seeds/nodes/tests/seedctl.sh

EKS_LINT_SET := --set gateway.host=lite.example.org \
  --set images.ycashd.repository=0.dkr.ecr.us-east-1.amazonaws.com/ycash/ycashd --set images.ycashd.tag=rev \
  --set images.lightwalletd.repository=0.dkr.ecr.us-east-1.amazonaws.com/ycash/lightwalletd --set images.lightwalletd.tag=rev \
  --set images.yindex.repository=0.dkr.ecr.us-east-1.amazonaws.com/ycash/yindex --set images.yindex.tag=rev \
  --set images.web.repository=0.dkr.ecr.us-east-1.amazonaws.com/ycash/web --set images.web.tag=rev
# CRD schemas (Gateway API, Envoy Gateway, cert-manager, External Secrets, Prometheus Operator) from datree's catalog
KUBECONFORM_SCHEMAS := -schema-location default -schema-location 'https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json'

docker-noauth: ## print an `export DOCKER_CONFIG=...` that bypasses Docker Desktop's hanging keychain helper
	@d=$${TMPDIR:-/tmp}/docker-noauth; mkdir -p $$d; python3 -c "import json,sys; c=json.load(open('$(HOME)/.docker/config.json')); c.pop('credsStore',None); c['auths']={}; json.dump(c,open('$$d/config.json','w'))"; \
	for x in cli-plugins contexts buildx; do [ -e $(HOME)/.docker/$$x ] && ln -sfn $(HOME)/.docker/$$x $$d/$$x; done; echo "export DOCKER_CONFIG=$$d"

lint: lint-testnet ## helm lint + image pins + kubeconform + go vet
	helm lint $(CHART) -f $(CHART)/values-kind.yaml
	scripts/lint-images.sh
	helm lint $(CHART) -f $(CHART)/values-eks.yaml $(EKS_LINT_SET)
	helm template $(RELEASE) $(CHART) -f $(CHART)/values-kind.yaml | kubeconform -strict -summary $(KUBECONFORM_SCHEMAS)
	cd yindex && go vet ./...

# The testnet value sets leave the release digests to the deploy; lint renders them with a placeholder.
PLACEHOLDER_DIGEST := sha256:0000000000000000000000000000000000000000000000000000000000000000
TESTNET_LITE_SET := $(foreach c,ycashd lightwalletd yindex web,--set images.$(c).digest=$(PLACEHOLDER_DIGEST))
TESTNET_EKS_SET  := --set images.ycashd.digest=$(PLACEHOLDER_DIGEST) --set images.ycashdLegacy.digest=$(PLACEHOLDER_DIGEST)
# the three testnets: values-<network>.yaml in both charts, one release (and one namespace) each
TESTNET_NETWORKS := yb-fast yb-slow legacy

lint-testnet: ## the testnet renders (render-only until N1): charts/ycash-testnet kind + EKS, the lightwallet chart's values-testnet.yaml, each per network (yb-fast, yb-slow, legacy); helm lint + kubeconform
	helm lint $(TESTNET_CHART) -f $(TESTNET_CHART)/values-kind.yaml
	helm lint $(TESTNET_CHART) -f $(TESTNET_CHART)/values-eks.yaml $(TESTNET_EKS_SET)
	helm lint $(CHART) -f $(CHART)/values-eks.yaml -f $(CHART)/values-testnet.yaml $(TESTNET_LITE_SET)
	helm template $(RELEASE) $(TESTNET_CHART) -f $(TESTNET_CHART)/values-kind.yaml | kubeconform -strict -summary $(KUBECONFORM_SCHEMAS)
	helm template $(RELEASE) $(TESTNET_CHART) -f $(TESTNET_CHART)/values-eks.yaml $(TESTNET_EKS_SET) | kubeconform -strict -summary $(KUBECONFORM_SCHEMAS)
	helm template $(RELEASE) $(CHART) -f $(CHART)/values-eks.yaml -f $(CHART)/values-testnet.yaml $(TESTNET_LITE_SET) | kubeconform -strict -summary $(KUBECONFORM_SCHEMAS)
	# the three testnets (plan Revision 3): each chart once per network, over kind and EKS values
	set -e; for n in $(TESTNET_NETWORKS); do echo "== $$n"; \
	  helm lint $(TESTNET_CHART) -f $(TESTNET_CHART)/values-eks.yaml -f $(TESTNET_CHART)/values-$$n.yaml $(TESTNET_EKS_SET) >/dev/null; \
	  helm lint $(CHART) -f $(CHART)/values-eks.yaml -f $(CHART)/values-testnet.yaml -f $(CHART)/values-$$n.yaml $(TESTNET_LITE_SET) >/dev/null; \
	  helm template $$n $(TESTNET_CHART) -f $(TESTNET_CHART)/values-kind.yaml -f $(TESTNET_CHART)/values-$$n.yaml | kubeconform -strict -summary $(KUBECONFORM_SCHEMAS); \
	  helm template $$n $(TESTNET_CHART) -f $(TESTNET_CHART)/values-eks.yaml -f $(TESTNET_CHART)/values-$$n.yaml $(TESTNET_EKS_SET) | kubeconform -strict -summary $(KUBECONFORM_SCHEMAS); \
	  helm template lite $(CHART) -f $(CHART)/values-eks.yaml -f $(CHART)/values-testnet.yaml -f $(CHART)/values-$$n.yaml $(TESTNET_LITE_SET) | kubeconform -strict -summary $(KUBECONFORM_SCHEMAS); \
	done

template: ## render the kind values to stdout
	helm template $(RELEASE) $(CHART) -n $(NAMESPACE) -f $(CHART)/values-kind.yaml

# --- Zcash-testnet prefix (bundles/prefix, FORMAT.md) ---
PREFIX_LAST ?= 4799
PREFIX_DIR  ?= prefix-work/out

prefix-test: ## the prefix harvest's offline unit tests (Python stdlib, real Zcash testnet vectors)
	python3 -I -m unittest discover -s bundles/prefix/tests -v

prefix-verify: ## re-verify a finished prefix directory offline, either network (PREFIX_DIR=prefix-work/out)
	python3 -I bundles/prefix/harvest.py verify $(PREFIX_DIR)

prefix-local: ## harvest the prefix on this machine with Docker (PREFIX_LAST=4799 smoke; 510247 full)
	bundles/prefix/run-local.sh $(PREFIX_LAST)

MAINNET_SPLIT ?= auto
mainnet-prefix-local: ## harvest Ycash mainnet 0..H_S on this machine with Docker (MAINNET_SPLIT=auto or a height; the EC2 path)
	bundles/prefix/run-local-mainnet.sh $(MAINNET_SPLIT)

# --- Zcash parameter mirror (bundles/zcash-params) ---
zcash-params-test: ## the parameter mirror's offline tests: SHA256SUMS vs the chart copy and ycash-dd's fetch-params.sh (YCASH_DD), the chart's init script
	YCASH_DD=$(YCASH_DD) python3 -I -m unittest discover -s bundles/zcash-params/tests -v
