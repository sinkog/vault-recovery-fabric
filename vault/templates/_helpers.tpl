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
Derived from selfName if set.

NOTE: the postStart auto-unseal hook in vault.server.postStart uses the LEGACY path
(secret/vault/unseal-keys) because values.yaml shell blocks cannot use Helm helpers.
In mesh mode (selfName set), bootstrap.storeUnsealKeys should be false and
postStart will log a warning — the recovery Job handles unsealing instead.
In lab mode (selfName empty, storeUnsealKeys=true), the legacy path is used by both
the bootstrap job and postStart, so auto-unseal works correctly.
*/}}
{{- define "vrf.localSecretPath" -}}
{{- if .Values.recovery.selfName -}}
secret/recovery/{{ .Values.recovery.selfName }}/unseal-keys
{{- else -}}
secret/vault/unseal-keys
{{- end -}}
{{- end -}}
