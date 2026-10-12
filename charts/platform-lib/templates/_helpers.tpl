{{/* Name of the service: values.name, else the release name. */}}
{{- define "platform.name" -}}
{{- default .Release.Name .Values.name | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/* Recommended Kubernetes labels, used on every object. */}}
{{- define "platform.labels" -}}
app.kubernetes.io/name: {{ include "platform.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/version: {{ .Values.image.tag | quote }}
app.kubernetes.io/part-of: {{ .Values.partOf | default "platform" }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version }}
{{- with .Values.team }}
team: {{ . }}
{{- end }}
{{- end -}}

{{/* Selector labels: a subset that never changes (selectors are immutable). */}}
{{- define "platform.selectorLabels" -}}
app.kubernetes.io/name: {{ include "platform.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}

{{/* Image reference. A tag is required: "latest" would make rollbacks meaningless. */}}
{{- define "platform.image" -}}
{{- $tag := required "image.tag is required (an immutable version or git SHA)" .Values.image.tag -}}
{{- if eq $tag "latest" -}}
{{- fail "image.tag must not be \"latest\": use an immutable version or git SHA" -}}
{{- end -}}
{{- if .Values.image.digest -}}
{{ .Values.image.repository }}@{{ .Values.image.digest }}
{{- else -}}
{{ .Values.image.repository }}:{{ $tag }}
{{- end -}}
{{- end -}}
