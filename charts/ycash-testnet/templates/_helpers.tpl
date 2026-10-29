{{- define "yt.name" -}}{{ default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}{{- end -}}
{{- define "yt.fullname" -}}{{ .Release.Name | trunc 63 | trimSuffix "-" }}{{- end -}}
{{- define "yt.labels" -}}
app.kubernetes.io/name: {{ include "yt.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
helm.sh/chart: {{ .Chart.Name }}-{{ .Chart.Version }}
{{- end -}}
{{- /* The testnet only (plan §6.1: a mainnet value set for this chart is refused at render). */ -}}
{{- define "yt.network" -}}
{{- if ne .Values.network "testnet" -}}
{{- fail (printf "network %q: charts/ycash-testnet renders the testnet only" .Values.network) -}}
{{- end -}}
testnet
{{- end -}}
{{- /* The testnet profile: empty (a build from before the profiles) or one of the three (T-14). */ -}}
{{- define "yt.profile" -}}
{{- $p := .Values.testnetProfile | default "" -}}
{{- if and $p (not (has $p (list "fast" "slow" "legacy"))) -}}
{{- fail (printf "testnetProfile %q: fast, slow or legacy (or empty for a build from before the profiles)" $p) -}}
{{- end -}}
{{- $p -}}
{{- end -}}
{{- /* repository[:tag][@digest], as charts/ycash-lightwallet's yc.image, but a reference with neither
a tag nor a digest fails the render here (values-eks.yaml leaves both to the deploy). */ -}}
{{- define "yt.image" -}}
{{- $i := .image -}}
{{- if not $i.repository -}}{{- fail (printf "images.%s.repository is empty" .key) -}}{{- end -}}
{{- if not (or $i.tag $i.digest) -}}{{- fail (printf "images.%s: set a tag or a digest (release images by digest, plan §6.1)" .key) -}}{{- end -}}
{{ $i.repository }}{{ with $i.tag }}:{{ . }}{{ end }}{{ with $i.digest }}@{{ . }}{{ end }}
{{- end -}}
{{- define "yt.rpcSecret" -}}{{ default (printf "%s-rpc" (include "yt.fullname" .)) .Values.rpc.existingSecret }}{{- end -}}
{{- /* role names as they appear in object names and the component label */ -}}
{{- define "yt.roleName" -}}{{ if eq . "verifierDd" }}verifier-dd{{ else if eq . "faucetNode" }}faucet-node{{ else }}{{ . }}{{ end }}{{- end -}}
{{- /* The node roles templates/node.yaml and services.yaml render, as JSON [[key, values], ...]: seed,
verifierDd and, with the faucet, its wallet node (faucet.node plus enabled and wallet). */ -}}
{{- define "yt.roles" -}}
{{- $roles := list (list "seed" .Values.seed) (list "verifierDd" .Values.verifierDd) -}}
{{- if .Values.faucet.enabled -}}
{{- $roles = append $roles (list "faucetNode" (merge (dict "enabled" true "wallet" true) .Values.faucet.node)) -}}
{{- end -}}
{{- toJson $roles -}}
{{- end -}}
{{- /* The network's name, as its datadir (testnet plan Revision 3): testnet-yb-fast, testnet-yb-slow,
testnet-legacy; "testnet" for a build from before the profiles. */ -}}
{{- define "yt.networkName" -}}
{{- $p := include "yt.profile" . -}}
{{- if eq $p "fast" }}testnet-yb-fast{{ else if eq $p "slow" }}testnet-yb-slow{{ else if eq $p "legacy" }}testnet-legacy{{ else }}testnet{{ end -}}
{{- end -}}
{{- /* T-9: a role that holds a key renders only with testnetKeys.allowed (values.yaml). */ -}}
{{- define "yt.keys" -}}
{{- if not .root.Values.testnetKeys.allowed -}}
{{- fail (printf "%s holds a key: charts/ycash-testnet holds testnet keys only under the owner's T-9 amendment of AGENTS.md rule 4 (plan §6.1); set testnetKeys.allowed=true once it is in force" .what) -}}
{{- end -}}
{{- end -}}
{{- /* The Python services' pods (faucet, probe, status): non-root above uid 10,000, RuntimeDefault seccomp. */ -}}
{{- define "yt.serviceSecurity" -}}
{{- $uid := .Values.serviceUid -}}
securityContext: { runAsUser: {{ $uid }}, runAsGroup: {{ $uid }}, runAsNonRoot: true, fsGroup: {{ $uid }}, seccompProfile: { type: RuntimeDefault } }
{{- end -}}
{{- /* The in-cluster RPC URL of a role's ready nodes (its -rpc Service). */ -}}
{{- define "yt.rpcUrl" -}}
http://{{ include "yt.fullname" .root }}-{{ .role }}-rpc:{{ .root.Values.rpc.port }}/
{{- end -}}
{{- /* the in-cluster peer list for a role: every seed pod's stable DNS name (headless Service) */ -}}
{{- define "yt.seedPeers" -}}
{{- $root := . -}}
{{- $fn := include "yt.fullname" $root -}}
{{- $out := list -}}
{{- if and $root.Values.peers.inCluster $root.Values.seed.enabled -}}
{{- range $i := until (int $root.Values.seed.replicas) -}}
{{- $out = append $out (printf "%s-seed-%d.%s-seed-headless.%s.svc.cluster.local:%d" $fn $i $fn $root.Release.Namespace (int $root.Values.p2p.port)) -}}
{{- end -}}
{{- end -}}
{{- join " " $out -}}
{{- end -}}
{{- /* Hardening, as charts/ycash-lightwallet's yc.containerSecurity / yc.podSecurity (Checkov
CKV_K8S_20/22/28/30/37): every container's securityContext from values.yaml containerSecurityContext;
what a container writes is an emptyDir or PVC mount in templates/node.yaml. */ -}}
{{- define "yt.containerSecurity" -}}
securityContext: {{- toYaml .Values.containerSecurityContext | nindent 2 }}
{{- end -}}
{{- /* The pod-level half: non-root with the image's own UID (both node images bake it: ycash6 and
ycash-dd contrib/docker/ycashd/Dockerfile useradd --uid 2001), RuntimeDefault seccomp. */ -}}
{{- define "yt.podSecurity" -}}
{{- $uid := .Values.podUid -}}
securityContext: { runAsUser: {{ $uid }}, runAsGroup: {{ $uid }}, runAsNonRoot: true, fsGroup: {{ $uid }}, seccompProfile: { type: RuntimeDefault } }
{{- end -}}

{{- /* The snapshotter containers' common environment (templates/snapshotter.yaml): the node image's
entrypoint settings for this network and files/snapshot.sh's. */ -}}
{{- define "yt.snapEnv" -}}
- { name: WORK, value: /work }
- { name: NETDIR, value: {{ .net | quote }} }
- { name: PROFILE, value: {{ .profile | quote }} }
- { name: STATE, value: /var/lib/ycash }
- { name: YCASHD_NETWORK, value: testnet }
- { name: YCASHD_TESTNET_PROFILE, value: {{ .profile | quote }} }
- { name: YCASHD_RPC_PORT, value: {{ .root.Values.rpc.port | quote }} }
- { name: YCASHD_EXTRA_ARGS, value: "-dnsseed=0" }
- { name: YCASHD_CONF_EXTRA, value: {{ join "\n" .conf | quote }} }
- { name: FLAVOUR, value: {{ .sn.flavour | quote }} }
- { name: STATEMENT_FIELDS, value: {{ join " " .sn.statementFields | quote }} }
- name: YCASHD_RPC_USER
  valueFrom: { secretKeyRef: { name: {{ include "yt.rpcSecret" .root }}, key: rpcuser } }
- name: YCASHD_RPC_PASSWORD
  valueFrom: { secretKeyRef: { name: {{ include "yt.rpcSecret" .root }}, key: rpcpassword } }
{{- end -}}
