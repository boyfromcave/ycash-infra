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
