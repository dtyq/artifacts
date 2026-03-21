{{/*
Returns HTTP or HTTPS protocol based on global TLS configuration.
Usage: {{ include "utils.httpProtocol" . }}
*/}}
{{- define "utils.httpProtocol" -}}
{{- if and .Values.global .Values.global.ingress .Values.global.ingress.tls .Values.global.ingress.tls.enabled -}}
https
{{- else -}}
http
{{- end -}}
{{- end -}}

{{/*
Returns WS or WSS protocol based on global TLS configuration.
Usage: {{ include "utils.wsProtocol" . }}
*/}}
{{- define "utils.wsProtocol" -}}
{{- if and .Values.global .Values.global.ingress .Values.global.ingress.tls .Values.global.ingress.tls.enabled -}}
wss
{{- else -}}
ws
{{- end -}}
{{- end -}}

{{/*
Returns the host for a given service.
Priority: global.services.<service>.domain > global.services.<service>.subdomain+domainSuffix > default+domainSuffix
Usage: {{ include "utils.serviceHost" (dict "service" "magic-service" "default" "magic-service" "context" $) }}
*/}}
{{- define "utils.serviceHost" -}}
{{- $global := .context.Values.global | default dict -}}
{{- $services := $global.services | default dict -}}
{{- $cfg := index $services .service | default dict -}}
{{- if $cfg.domain -}}
{{- $cfg.domain -}}
{{- else -}}
{{- $subdomain := $cfg.subdomain | default (.default | default .service) -}}
{{- $domainSuffix := $global.domainSuffix | default "example.local" -}}
{{- printf "%s.%s" $subdomain $domainSuffix -}}
{{- end -}}
{{- end -}}

{{/*
Returns the full HTTP URL for a service.
Usage: {{ include "utils.serviceHttpUrl" (dict "service" "magic-service" "default" "magic-service" "context" $) }}
*/}}
{{- define "utils.serviceHttpUrl" -}}
{{- $protocol := include "utils.httpProtocol" .context -}}
{{- $host := include "utils.serviceHost" . -}}
{{- printf "%s://%s" $protocol $host -}}
{{- end -}}

{{/*
Returns the full WebSocket URL for a service.
Usage: {{ include "utils.serviceWsUrl" (dict "service" "magic-service" "default" "magic-service" "context" $) }}
*/}}
{{- define "utils.serviceWsUrl" -}}
{{- $protocol := include "utils.wsProtocol" .context -}}
{{- $host := include "utils.serviceHost" . -}}
{{- printf "%s://%s" $protocol $host -}}
{{- end -}}

{{/*
Returns hostname from an URL string (without port).
Usage: {{ include "utils.urlHost" (dict "url" "http://magic-service.magic.svc:9501/v1") }}
*/}}
{{- define "utils.urlHost" -}}
{{- $url := .url | default "" -}}
{{- if eq $url "" -}}
{{- "" -}}
{{- else -}}
{{- $parsed := urlParse $url -}}
{{- $fallbackHostPort := $url | trimPrefix "http://" | trimPrefix "https://" -}}
{{- $fallbackHostPort = regexReplaceAll "/.*$" $fallbackHostPort "" -}}
{{- $hostPort := (index $parsed "host") | default $fallbackHostPort -}}
{{- regexReplaceAll ":[0-9]+$" $hostPort "" -}}
{{- end -}}
{{- end -}}
