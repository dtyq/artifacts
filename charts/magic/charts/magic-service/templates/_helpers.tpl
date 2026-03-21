{{/*
Selector labels for the main Deployment and Service.
Uses component: web to explicitly exclude daemon pods from Service routing.
*/}}
{{- define "magic-service.selectorLabels" -}}
{{- include "common.labels.matchLabels" . }}
app.kubernetes.io/component: web
{{- end }}

{{/*
Selector labels for the daemon Deployment.
Uses component: daemon to isolate daemon pods from the Service.
*/}}
{{- define "magic-service.daemonSelectorLabels" -}}
{{- include "common.labels.matchLabels" . }}
app.kubernetes.io/component: daemon
{{- end }}
