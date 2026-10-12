{{- define "platform.deployment" -}}
apiVersion: apps/v1
kind: Deployment
metadata:
  name: {{ include "platform.name" . }}
  labels:
    {{- include "platform.labels" . | nindent 4 }}
spec:
  {{- if not .Values.autoscaling.enabled }}
  replicas: {{ .Values.replicas }}
  {{- end }}
  revisionHistoryLimit: 5
  minReadySeconds: {{ .Values.minReadySeconds }}
  progressDeadlineSeconds: 600
  strategy:
    type: RollingUpdate
    rollingUpdate:
      # Never drop below the desired count during a rollout; add capacity first.
      maxUnavailable: 0
      maxSurge: {{ .Values.rollout.maxSurge | quote }}
  selector:
    matchLabels:
      {{- include "platform.selectorLabels" . | nindent 6 }}
  template:
    metadata:
      labels:
        {{- include "platform.labels" . | nindent 8 }}
      annotations:
        # A config change changes this hash, which rolls the pods.
        checksum/config: {{ toJson .Values.env | sha256sum }}
    spec:
      serviceAccountName: {{ include "platform.name" . }}
      automountServiceAccountToken: {{ .Values.serviceAccount.automountToken }}
      terminationGracePeriodSeconds: {{ .Values.terminationGracePeriodSeconds }}
      securityContext:
        runAsNonRoot: true
        seccompProfile:
          type: RuntimeDefault
      {{- with .Values.priorityClassName }}
      priorityClassName: {{ . }}
      {{- end }}
      topologySpreadConstraints:
        # Spread across zones first (an AZ outage takes at most a third), then across nodes.
        - maxSkew: 1
          topologyKey: topology.kubernetes.io/zone
          whenUnsatisfiable: ScheduleAnyway
          labelSelector:
            matchLabels:
              {{- include "platform.selectorLabels" . | nindent 14 }}
        - maxSkew: 1
          topologyKey: kubernetes.io/hostname
          whenUnsatisfiable: ScheduleAnyway
          labelSelector:
            matchLabels:
              {{- include "platform.selectorLabels" . | nindent 14 }}
      {{- with .Values.nodeSelector }}
      nodeSelector:
        {{- toYaml . | nindent 8 }}
      {{- end }}
      {{- with .Values.tolerations }}
      tolerations:
        {{- toYaml . | nindent 8 }}
      {{- end }}
      containers:
        - name: app
          image: {{ include "platform.image" . }}
          imagePullPolicy: IfNotPresent
          ports:
            - name: http
              containerPort: {{ .Values.containerPort }}
          env:
            - name: SERVICE_NAME
              value: {{ include "platform.name" . | quote }}
            - name: VERSION
              value: {{ .Values.image.tag | quote }}
            {{- range $k, $v := .Values.env }}
            - name: {{ $k }}
              value: {{ $v | quote }}
            {{- end }}
          {{- with .Values.envFromSecrets }}
          envFrom:
            {{- range . }}
            - secretRef:
                name: {{ . }}
            {{- end }}
          {{- end }}
          resources:
            {{- required "resources are required: requests drive scheduling and autoscaling" .Values.resources | toYaml | nindent 12 }}
          startupProbe:
            httpGet: { path: {{ .Values.probes.livenessPath }}, port: http }
            periodSeconds: 2
            failureThreshold: {{ .Values.probes.startupFailureThreshold }}
          livenessProbe:
            # Liveness checks only the process. Never a dependency: a database blip must not
            # restart every pod at once.
            httpGet: { path: {{ .Values.probes.livenessPath }}, port: http }
            periodSeconds: 10
            failureThreshold: 3
          readinessProbe:
            httpGet: { path: {{ .Values.probes.readinessPath }}, port: http }
            periodSeconds: 5
            failureThreshold: 2
          lifecycle:
            preStop:
              # Keep serving while the pod is removed from Service endpoints and LB targets.
              sleep:
                seconds: {{ .Values.preStopSleepSeconds }}
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            capabilities:
              drop: ["ALL"]
          volumeMounts:
            - name: tmp
              mountPath: /tmp
      volumes:
        - name: tmp
          emptyDir:
            sizeLimit: 64Mi
{{- end -}}
