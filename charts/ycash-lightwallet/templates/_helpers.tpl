{{- define "yc.name" -}}{{ default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}{{- end -}}
{{- define "yc.fullname" -}}{{ .Release.Name | trunc 63 | trimSuffix "-" }}{{- end -}}
{{- define "yc.labels" -}}
app.kubernetes.io/name: {{ include "yc.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
helm.sh/chart: {{ .Chart.Name }}-{{ .Chart.Version }}
{{- end -}}
{{- define "yc.image" -}}{{ .repository }}:{{ .tag }}{{- end -}}
{{- define "yc.rpcSecret" -}}{{ default (printf "%s-ycashd-rpc" (include "yc.fullname" .)) .Values.ycashd.rpc.existingSecret }}{{- end -}}
{{- define "yc.rpcHost" -}}{{ include "yc.fullname" . }}-ycashd{{- end -}}
{{- /* D-Q-31: a signer set's maturity (its bond exit delay) is at least 16,128 blocks on mainnet and
testnet and 2 on regtest (consensus nVaultMinSetMaturity; set_create refuses less). The YED module
adopts its attestor set only at exactly BOND_MATURITY (ycash-dd/ycash6 src/yellowback/params.cpp:
16,128; regtest 8), so that is the default and anything else fails the render. */ -}}
{{- define "yc.minSetMaturity" -}}{{ if eq .Values.ycashd.network "regtest" }}2{{ else }}16128{{ end }}{{- end -}}
{{- define "yc.yedBondMaturity" -}}{{ if eq .Values.ycashd.network "regtest" }}8{{ else }}16128{{ end }}{{- end -}}
{{- define "yc.attestorSetMaturity" -}}
{{- $m := int (default (include "yc.yedBondMaturity" .) .Values.regtest.attestorSet.maturity) -}}
{{- if lt $m (int (include "yc.minSetMaturity" .)) -}}
{{- fail (printf "regtest.attestorSet.maturity %d is below the %s minimum %s (D-Q-31)" $m .Values.ycashd.network (include "yc.minSetMaturity" .)) -}}
{{- end -}}
{{- if ne $m (int (include "yc.yedBondMaturity" .)) -}}
{{- fail (printf "regtest.attestorSet.maturity %d: the YED module adopts its attestor set only at BOND_MATURITY = %s on %s" $m (include "yc.yedBondMaturity" .) .Values.ycashd.network) -}}
{{- end -}}
{{- $m -}}
{{- end -}}
