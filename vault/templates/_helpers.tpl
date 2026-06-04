{{/*
Resolve the fallback secretPath.
If recovery.fallback.secretPath is set explicitly, use it.
Otherwise derive from recovery.selfName: secret/recovery/<selfName>/unseal-keys
If neither is set, fail.
*/}}
{{- define "vrf.fallbackSecretPath" -}}
{{- if .Values.recovery.fallback.secretPath -}}
{{ .Values.recovery.fallback.secretPath }}
{{- else if .Values.recovery.selfName -}}
secret/recovery/{{ .Values.recovery.selfName }}/unseal-keys
{{- else -}}
{{- fail "Set recovery.fallback.secretPath or recovery.selfName to derive the fallback secret path" -}}
{{- end -}}
{{- end -}}

{{/*
Resolve the local secretPath for unseal keys (where this cluster stores them).
Derived from selfName if not set.
*/}}
{{- define "vrf.localSecretPath" -}}
{{- if .Values.recovery.selfName -}}
secret/recovery/{{ .Values.recovery.selfName }}/unseal-keys
{{- else -}}
secret/vault/unseal-keys
{{- end -}}
{{- end -}}
