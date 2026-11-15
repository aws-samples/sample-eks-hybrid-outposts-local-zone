{{/*
Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
SPDX-License-Identifier: Apache-2.0
*/}}

{{- define "eastwest.selectorLabels" -}}
istio: eastwestgateway
app: istio-eastwestgateway
{{- end }}

{{- define "eastwest.labels" -}}
{{ include "eastwest.selectorLabels" . }}
topology.istio.io/network: {{ required "network is required" .Values.network | quote }}
app.kubernetes.io/name: istio-eastwestgateway
app.kubernetes.io/managed-by: {{ .Release.Service }}
helm.sh/chart: {{ .Chart.Name }}-{{ .Chart.Version }}
{{- end }}
