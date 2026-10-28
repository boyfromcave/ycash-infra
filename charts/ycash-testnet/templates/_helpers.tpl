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
{{- define "yt.roleName" -}}{{ if eq . "verifierDd" }}verifier-dd{{ else }}{{ . }}{{ end }}{{- end -}}
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
