{{- define "mosaicod.labels" -}}
app.kubernetes.io/name: {{ .Chart.Name }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{- define "mosaicod.config" -}}
{{- $config := fromToml .Values.config }}
{{- with $config.Error }}
{{- fail (printf "config is not valid TOML: %s" .) }}
{{- end }}
{{- range list "database.url" "store.endpoint" "store.bucket" }}
{{- $key := splitList "." . }}
{{- $_ := required (printf "config: set %s" .) (dig (first $key) (last $key) "" $config) }}
{{- end }}
{{- toJson $config }}
{{- end }}

{{- define "mosaicod.podSpec" -}}
automountServiceAccountToken: false
enableServiceLinks: false
securityContext:
  runAsNonRoot: true
  runAsUser: 65532
  runAsGroup: 65532
  seccompProfile:
    type: RuntimeDefault
volumes:
  - name: config
    configMap:
      name: {{ .Release.Name }}
  - name: secrets
    secret:
      secretName: {{ required "set existingSecret to a Secret with the keys db-password and store-secret-key" .Values.existingSecret }}
  - name: tmp
    emptyDir: {}
{{ pick .Values "nodeSelector" "tolerations" "affinity" | toYaml }}
{{- end }}

{{- define "mosaicod.container" -}}
image: {{ .Values.image.repository }}:{{ .Values.image.tag }}{{ with .Values.image.digest }}@{{ . }}{{ end }}
env:
  - name: MOSAICOD_DB_PASSWORD_FILE
    value: /run/secrets/mosaicod/db-password
  - name: MOSAICOD_STORE_SECRET_KEY_FILE
    value: /run/secrets/mosaicod/store-secret-key
volumeMounts:
  - name: config
    mountPath: /etc/mosaicod
  - name: secrets
    mountPath: /run/secrets/mosaicod
  - name: tmp
    mountPath: /tmp
securityContext:
  allowPrivilegeEscalation: false
  readOnlyRootFilesystem: true
  capabilities:
    drop:
      - ALL
{{- end }}
