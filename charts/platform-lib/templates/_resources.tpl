{{- define "platform.serviceaccount" -}}
apiVersion: v1
kind: ServiceAccount
metadata:
  name: {{ include "platform.name" . }}
  labels:
    {{- include "platform.labels" . | nindent 4 }}
# AWS permissions come from an EKS Pod Identity association for this ServiceAccount
# (created in Terraform), so there's no role ARN annotation here.
automountServiceAccountToken: {{ .Values.serviceAccount.automountToken }}
{{- end -}}

{{- define "platform.service" -}}
apiVersion: v1
kind: Service
metadata:
  name: {{ include "platform.name" . }}
  labels:
    {{- include "platform.labels" . | nindent 4 }}
spec:
  selector:
    {{- include "platform.selectorLabels" . | nindent 4 }}
  ports:
    - name: http
      port: 80
      targetPort: http
  {{- if .Values.service.preferSameZone }}
  # Prefer endpoints in the caller's zone: lower latency and no cross-AZ data charges.
  trafficDistribution: PreferClose
  {{- end }}
{{- end -}}

{{- define "platform.hpa" -}}
{{- if .Values.autoscaling.enabled }}
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: {{ include "platform.name" . }}
  labels:
    {{- include "platform.labels" . | nindent 4 }}
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: {{ include "platform.name" . }}
  minReplicas: {{ .Values.autoscaling.minReplicas }}
  maxReplicas: {{ .Values.autoscaling.maxReplicas }}
  metrics:
    - type: Resource
      resource:
        name: cpu
        target:
          type: Utilization
          averageUtilization: {{ .Values.autoscaling.targetCPUUtilization }}
  behavior:
    scaleDown:
      stabilizationWindowSeconds: 300
      policies:
        - type: Pods
          value: 1
          periodSeconds: 60
{{- end }}
{{- end -}}

{{- define "platform.pdb" -}}
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: {{ include "platform.name" . }}
  labels:
    {{- include "platform.labels" . | nindent 4 }}
spec:
  # maxUnavailable (not minAvailable) so a drain can always make progress: a PDB that allows
  # zero disruptions blocks node upgrades forever.
  maxUnavailable: 1
  selector:
    matchLabels:
      {{- include "platform.selectorLabels" . | nindent 6 }}
{{- end -}}

{{- define "platform.networkpolicy" -}}
{{- if .Values.networkPolicy.enabled }}
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: {{ include "platform.name" . }}
  labels:
    {{- include "platform.labels" . | nindent 4 }}
spec:
  podSelector:
    matchLabels:
      {{- include "platform.selectorLabels" . | nindent 6 }}
  policyTypes: ["Ingress"]
  ingress:
    # From the ingress controller / gateway namespace.
    - from:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: {{ .Values.networkPolicy.ingressNamespace }}
      ports:
        - port: http
    # From the monitoring namespace (Prometheus scrapes /metrics).
    - from:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: {{ .Values.networkPolicy.monitoringNamespace }}
      ports:
        - port: http
    {{- range .Values.networkPolicy.allowFromApps }}
    # From another service that calls this one.
    - from:
        - podSelector:
            matchLabels:
              app.kubernetes.io/name: {{ . }}
      ports:
        - port: http
    {{- end }}
{{- end }}
{{- end -}}

{{- define "platform.servicemonitor" -}}
{{- if .Values.monitoring.serviceMonitor }}
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: {{ include "platform.name" . }}
  labels:
    {{- include "platform.labels" . | nindent 4 }}
spec:
  selector:
    matchLabels:
      {{- include "platform.selectorLabels" . | nindent 6 }}
  endpoints:
    - port: http
      path: /metrics
      interval: 30s
{{- end }}
{{- end -}}

{{- define "platform.ingress" -}}
{{- if .Values.ingress.enabled }}
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: {{ include "platform.name" . }}
  labels:
    {{- include "platform.labels" . | nindent 4 }}
  {{- with .Values.ingress.annotations }}
  annotations:
    {{- toYaml . | nindent 4 }}
  {{- end }}
spec:
  ingressClassName: {{ .Values.ingress.className }}
  rules:
    - host: {{ required "ingress.host is required when ingress is enabled" .Values.ingress.host }}
      http:
        paths:
          - path: {{ .Values.ingress.path }}
            pathType: Prefix
            backend:
              service:
                name: {{ include "platform.name" . }}
                port:
                  name: http
{{- end }}
{{- end -}}

{{/* Everything a typical service needs, in one include. */}}
{{- define "platform.all" -}}
{{ include "platform.serviceaccount" . }}
---
{{ include "platform.deployment" . }}
---
{{ include "platform.service" . }}
---
{{ include "platform.pdb" . }}
{{- with (include "platform.hpa" . | trim) }}
---
{{ . }}
{{- end }}
{{- with (include "platform.networkpolicy" . | trim) }}
---
{{ . }}
{{- end }}
{{- with (include "platform.servicemonitor" . | trim) }}
---
{{ . }}
{{- end }}
{{- with (include "platform.ingress" . | trim) }}
---
{{ . }}
{{- end }}
{{- end -}}
