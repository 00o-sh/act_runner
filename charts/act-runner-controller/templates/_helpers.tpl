{{/*
Expand the name of the chart.
*/}}
{{- define "act-runner-controller.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create a default fully qualified app name.
*/}}
{{- define "act-runner-controller.fullname" -}}
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
{{- define "act-runner-controller.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels
*/}}
{{- define "act-runner-controller.labels" -}}
helm.sh/chart: {{ include "act-runner-controller.chart" . }}
{{ include "act-runner-controller.selectorLabels" . }}
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
{{- define "act-runner-controller.selectorLabels" -}}
app.kubernetes.io/name: {{ include "act-runner-controller.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/component: controller
{{- end }}

{{/*
Create the name of the service account to use
*/}}
{{- define "act-runner-controller.serviceAccountName" -}}
{{- if .Values.serviceAccount.create }}
{{- default (include "act-runner-controller.fullname" .) .Values.serviceAccount.name }}
{{- else }}
{{- default "default" .Values.serviceAccount.name }}
{{- end }}
{{- end }}

{{/*
Controller image reference — uses the -controller tagged variant
*/}}
{{- define "act-runner-controller.image" -}}
{{- if .Values.image.tag }}
{{- printf "%s:%s" .Values.image.repository .Values.image.tag }}
{{- else }}
{{- printf "%s:%s-controller" .Values.image.repository .Chart.AppVersion }}
{{- end }}
{{- end }}

{{/*
Name of the Secret holding the Forgejo API token
*/}}
{{- define "act-runner-controller.apiTokenSecretName" -}}
{{- if .Values.forgejo.apiTokenSecret.name }}
{{- .Values.forgejo.apiTokenSecret.name }}
{{- else }}
{{- printf "%s-forgejo-api" (include "act-runner-controller.fullname" .) | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}

{{/*
Whether the chart should create the API token Secret
*/}}
{{- define "act-runner-controller.createApiTokenSecret" -}}
{{- if and .Values.forgejo.apiToken (not .Values.forgejo.apiTokenSecret.name) }}
{{- true }}
{{- end }}
{{- end }}
