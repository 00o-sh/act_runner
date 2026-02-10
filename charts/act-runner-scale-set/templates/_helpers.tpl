{{/*
Expand the name of the chart.
*/}}
{{- define "act-runner-scale-set.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create a default fully qualified app name.
*/}}
{{- define "act-runner-scale-set.fullname" -}}
{{- if .Values.fullnameOverride }}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- $name := default .Chart.Name .Values.nameOverride }}
{{- if contains $name .Release.Name }}
{{- .Release.Name | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}
{{- end }}

{{/*
Create chart name and version as used by the chart label.
*/}}
{{- define "act-runner-scale-set.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels
*/}}
{{- define "act-runner-scale-set.labels" -}}
helm.sh/chart: {{ include "act-runner-scale-set.chart" . }}
{{ include "act-runner-scale-set.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- with .Values.additionalLabels }}
{{ toYaml . }}
{{- end }}
{{- end }}

{{/*
Selector labels
*/}}
{{- define "act-runner-scale-set.selectorLabels" -}}
app.kubernetes.io/name: {{ include "act-runner-scale-set.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/component: runner
{{- end }}

{{/*
Create the name of the service account to use
*/}}
{{- define "act-runner-scale-set.serviceAccountName" -}}
{{- if .Values.serviceAccount.create }}
{{- default (include "act-runner-scale-set.fullname" .) .Values.serviceAccount.name }}
{{- else }}
{{- default "default" .Values.serviceAccount.name }}
{{- end }}
{{- end }}

{{/*
Runner image reference - selects the correct tag variant based on containerMode
*/}}
{{- define "act-runner-scale-set.image" -}}
{{- $containerType := .Values.containerMode.type | default "" -}}
{{- if .Values.image.tag }}
{{- printf "%s:%s" .Values.image.repository .Values.image.tag }}
{{- else }}
{{- $tag := .Chart.AppVersion }}
{{- if eq $containerType "dind" }}
{{- printf "%s:%s-dind" .Values.image.repository $tag }}
{{- else if eq $containerType "dind-rootless" }}
{{- printf "%s:%s-dind-rootless" .Values.image.repository $tag }}
{{- else }}
{{- printf "%s:%s" .Values.image.repository $tag }}
{{- end }}
{{- end }}
{{- end }}

{{/*
Runner scale set name (used as runner name prefix)
*/}}
{{- define "act-runner-scale-set.runnerScaleSetName" -}}
{{- default .Release.Name .Values.runnerScaleSetName | trunc 45 | trimSuffix "-" }}
{{- end }}

{{/*
Determine if we should create a Secret for the registration token.
True when giteaConfigSecret is a map with a .token value and no .name override.
*/}}
{{- define "act-runner-scale-set.createSecret" -}}
{{- if kindIs "map" .Values.giteaConfigSecret }}
  {{- if and (index .Values.giteaConfigSecret "token") (not (index .Values.giteaConfigSecret "name")) }}
    {{- true }}
  {{- end }}
{{- end }}
{{- end }}

{{/*
Secret name for Gitea registration token.
Supports giteaConfigSecret as:
  - a string: used directly as the Secret name
  - a map with .name: used as the Secret name
  - a map with .token (no .name): generates a name from the release
*/}}
{{- define "act-runner-scale-set.secretName" -}}
{{- if kindIs "string" .Values.giteaConfigSecret }}
{{- .Values.giteaConfigSecret }}
{{- else if and (kindIs "map" .Values.giteaConfigSecret) (index .Values.giteaConfigSecret "name") }}
{{- index .Values.giteaConfigSecret "name" }}
{{- else }}
{{- printf "%s-gitea-secret" (include "act-runner-scale-set.fullname" .) | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}

{{/*
Config map name for runner config
*/}}
{{- define "act-runner-scale-set.configMapName" -}}
{{- printf "%s-config" (include "act-runner-scale-set.fullname" .) | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Whether to use a KEDA ScaledJob instead of Deployment/StatefulSet + ScaledObject.
True when KEDA is enabled and the runner is ephemeral (one job per pod).
*/}}
{{- define "act-runner-scale-set.useScaledJob" -}}
{{- if and .Values.keda.enabled .Values.ephemeral -}}
{{- true -}}
{{- end -}}
{{- end }}

{{/*
Shared pod template for both Deployment/StatefulSet and ScaledJob.
Outputs a complete PodTemplateSpec (metadata + spec) that callers
embed at the appropriate indentation level.
*/}}
{{- define "act-runner-scale-set.runnerPodTemplate" -}}
{{- $fullname := include "act-runner-scale-set.fullname" . -}}
{{- $secretName := include "act-runner-scale-set.secretName" . -}}
{{- $runnerName := include "act-runner-scale-set.runnerScaleSetName" . -}}
{{- $containerType := .Values.containerMode.type | default "" -}}
{{- $isScaledJob := include "act-runner-scale-set.useScaledJob" . -}}
metadata:
  labels:
    {{- include "act-runner-scale-set.selectorLabels" . | nindent 4 }}
  {{- if or .Values.runnerConfig .Values.podAnnotations }}
  annotations:
    {{- if .Values.runnerConfig }}
    checksum/config: {{ .Values.runnerConfig | sha256sum }}
    {{- end }}
    {{- with .Values.podAnnotations }}
    {{- toYaml . | nindent 4 }}
    {{- end }}
  {{- end }}
spec:
  {{- with .Values.imagePullSecrets }}
  imagePullSecrets:
    {{- toYaml . | nindent 4 }}
  {{- end }}
  serviceAccountName: {{ include "act-runner-scale-set.serviceAccountName" . }}
  {{- with .Values.priorityClassName }}
  priorityClassName: {{ . }}
  {{- end }}
  {{- with .Values.podSecurityContext }}
  securityContext:
    {{- toYaml . | nindent 4 }}
  {{- end }}
  {{- if $isScaledJob }}
  restartPolicy: Never
  {{- else }}
  restartPolicy: Always
  {{- end }}
  volumes:
    {{- if or $isScaledJob (not .Values.persistence.enabled) }}
    - name: runner-data
      emptyDir: {}
    {{- end }}
    {{- if .Values.runnerConfig }}
    - name: runner-config
      configMap:
        name: {{ include "act-runner-scale-set.configMapName" . }}
    {{- end }}
    {{- if eq $containerType "dind" }}
    - name: docker-certs
      emptyDir: {}
    {{- end }}
    {{- if and (not $containerType) .Values.hostDockerSocket.enabled }}
    - name: docker-socket
      hostPath:
        path: {{ .Values.hostDockerSocket.path }}
        type: Socket
    {{- end }}
    {{- if and .Values.giteaServerTLS .Values.giteaServerTLS.certificateFrom .Values.giteaServerTLS.certificateFrom.configMapRef .Values.giteaServerTLS.certificateFrom.configMapRef.name }}
    - name: tls-ca
      configMap:
        name: {{ .Values.giteaServerTLS.certificateFrom.configMapRef.name }}
    {{- end }}
    {{- with .Values.extraVolumes }}
    {{- toYaml . | nindent 4 }}
    {{- end }}

  containers:
    - name: runner
      image: {{ include "act-runner-scale-set.image" . }}
      imagePullPolicy: {{ .Values.image.pullPolicy }}
      {{- if eq $containerType "dind" }}
      command: ["sh", "-c", "until nc -z localhost 2376; do echo 'waiting for docker daemon...'; sleep 2; done && /sbin/tini -- run.sh"]
      {{- else if ne $containerType "dind-rootless" }}
      command: ["sh", "-c", "/sbin/tini -- run.sh"]
      {{- end }}
      env:
        - name: GITEA_INSTANCE_URL
          value: {{ .Values.giteaConfigUrl | quote }}
        - name: GITEA_RUNNER_REGISTRATION_TOKEN
          valueFrom:
            secretKeyRef:
              name: {{ $secretName }}
              key: token
        - name: GITEA_RUNNER_NAME
          value: {{ $runnerName | quote }}
        {{- if .Values.runnerLabels }}
        - name: GITEA_RUNNER_LABELS
          value: {{ .Values.runnerLabels | quote }}
        {{- end }}
        {{- if .Values.ephemeral }}
        - name: GITEA_RUNNER_EPHEMERAL
          value: "true"
        {{- end }}
        {{- if eq $containerType "dind" }}
        - name: DOCKER_HOST
          value: tcp://localhost:2376
        - name: DOCKER_CERT_PATH
          value: /certs/client
        - name: DOCKER_TLS_VERIFY
          value: "1"
        {{- end }}
        {{- if .Values.proxy.http }}
        - name: HTTP_PROXY
          value: {{ .Values.proxy.http | quote }}
        - name: http_proxy
          value: {{ .Values.proxy.http | quote }}
        {{- end }}
        {{- if .Values.proxy.https }}
        - name: HTTPS_PROXY
          value: {{ .Values.proxy.https | quote }}
        - name: https_proxy
          value: {{ .Values.proxy.https | quote }}
        {{- end }}
        {{- if .Values.proxy.noProxy }}
        - name: NO_PROXY
          value: {{ .Values.proxy.noProxy | quote }}
        - name: no_proxy
          value: {{ .Values.proxy.noProxy | quote }}
        {{- end }}
        {{- with .Values.extraEnv }}
        {{- toYaml . | nindent 8 }}
        {{- end }}
      {{- if eq $containerType "dind-rootless" }}
      securityContext:
        seccompProfile:
          type: Unconfined
        {{- with .Values.securityContext }}
        {{- toYaml . | nindent 8 }}
        {{- end }}
      {{- else }}
      {{- with .Values.securityContext }}
      securityContext:
        {{- toYaml . | nindent 8 }}
      {{- end }}
      {{- end }}
      {{- with .Values.resources }}
      resources:
        {{- toYaml . | nindent 8 }}
      {{- end }}
      volumeMounts:
        - name: runner-data
          mountPath: /data
        {{- if .Values.runnerConfig }}
        - name: runner-config
          mountPath: /etc/act_runner
          readOnly: true
        {{- end }}
        {{- if eq $containerType "dind" }}
        - name: docker-certs
          mountPath: /certs
        {{- end }}
        {{- if and (not $containerType) .Values.hostDockerSocket.enabled }}
        - name: docker-socket
          mountPath: /var/run/docker.sock
          readOnly: true
        {{- end }}
        {{- if and .Values.giteaServerTLS .Values.giteaServerTLS.certificateFrom .Values.giteaServerTLS.certificateFrom.configMapRef .Values.giteaServerTLS.certificateFrom.configMapRef.name }}
        - name: tls-ca
          mountPath: /etc/ssl/certs/gitea-ca.crt
          subPath: {{ .Values.giteaServerTLS.certificateFrom.configMapRef.key | default "ca.crt" }}
          readOnly: true
        {{- end }}
        {{- with .Values.extraVolumeMounts }}
        {{- toYaml . | nindent 8 }}
        {{- end }}

    {{- if eq $containerType "dind" }}
    - name: dind
      image: {{ .Values.containerMode.dindImage }}
      env:
        - name: DOCKER_TLS_CERTDIR
          value: /certs
      securityContext:
        privileged: true
      volumeMounts:
        - name: docker-certs
          mountPath: /certs
        - name: runner-data
          mountPath: /data
    {{- end }}

  {{- with .Values.nodeSelector }}
  nodeSelector:
    {{- toYaml . | nindent 4 }}
  {{- end }}
  {{- with .Values.affinity }}
  affinity:
    {{- toYaml . | nindent 4 }}
  {{- end }}
  {{- with .Values.tolerations }}
  tolerations:
    {{- toYaml . | nindent 4 }}
  {{- end }}
{{- end }}
