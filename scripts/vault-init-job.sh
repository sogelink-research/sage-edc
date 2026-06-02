#!/usr/bin/env bash
# vault-init-job.sh — Initialize and unseal Vault via an in-cluster Kubernetes Job.
#
# Background: kubectl exec is blocked by the GKE/Rancher L7 proxy (returns
# "400 Bad Request" on connection upgrades). This script works around that by
# submitting a batch Job that runs inside the cluster and reaches Vault over
# its ClusterIP service with plain HTTP — no connection upgrade required.
# Credentials are printed to the Job's stdout and retrieved with kubectl logs.
#
# Required environment variables (all present in GitLab CI):
#   K8S_NAMESPACE   — target namespace
#   CONNECTOR_ID    — connector instance identifier (used to derive the Vault service name)
#   CI_PIPELINE_ID  — used to give the Job a unique name (falls back to "manual")
#
# Working directory: must be the kubernetes deployment instruction dir so that
# ./secrets/vault.secrets is at the expected relative path.
set -euo pipefail

NS="${K8S_NAMESPACE}"
VAULT_SVC="edc-connector-vault-${CONNECTOR_ID}-ih"
VAULT_ADDR="http://${VAULT_SVC}:8200"
JOB_NAME="vault-init-${CI_PIPELINE_ID:-manual}"
SECRETS_FILE="./secrets/vault.secrets"

# ---------------------------------------------------------------------------
# Load existing credentials so we can unseal a Vault that was already
# initialized but is sealed again after a pod restart.
# ---------------------------------------------------------------------------
EXISTING_UNSEAL_KEY=""
EXISTING_ROOT_TOKEN=""
if [ -f "$SECRETS_FILE" ]; then
	EXISTING_UNSEAL_KEY="$(grep '^VAULT_UNSEAL_KEY=' "$SECRETS_FILE" | cut -d= -f2- || true)"
	EXISTING_ROOT_TOKEN="$(grep '^VAULT_ROOT_TOKEN=' "$SECRETS_FILE" | cut -d= -f2- || true)"
fi

# ---------------------------------------------------------------------------
# Clean up any leftover Job from a previous run, then submit a fresh one.
# ---------------------------------------------------------------------------
kubectl -n "$NS" delete job "$JOB_NAME" --ignore-not-found >/dev/null 2>&1

kubectl apply -n "$NS" -f - <<JOBEOF
apiVersion: batch/v1
kind: Job
metadata:
  name: ${JOB_NAME}
spec:
  backoffLimit: 2
  ttlSecondsAfterFinished: 600
  template:
    spec:
      restartPolicy: Never
      securityContext:
        runAsNonRoot: true
        runAsUser: 65534
        seccompProfile:
          type: RuntimeDefault
      containers:
      - name: vault-init
        image: alpine:3.20
        command: ["/bin/sh", "-c"]
        args:
        - |
          set -e
          apk add --no-cache curl jq >/dev/null 2>&1
          VAULT_ADDR="${VAULT_ADDR}"
          UNSEAL_KEY="${EXISTING_UNSEAL_KEY}"
          ROOT_TOKEN="${EXISTING_ROOT_TOKEN}"

          echo "Waiting for Vault at \${VAULT_ADDR}..." >&2
          for i in \$(seq 1 30); do
            curl -sf -o /dev/null "\${VAULT_ADDR}/v1/sys/seal-status" && break
            sleep 2
          done

          STATUS=\$(curl -sf "\${VAULT_ADDR}/v1/sys/seal-status")
          INITIALIZED=\$(echo "\$STATUS" | jq -r '.initialized')
          SEALED=\$(echo "\$STATUS"      | jq -r '.sealed')

          if [ "\$INITIALIZED" != "true" ]; then
            echo "Initializing Vault..." >&2
            INIT=\$(curl -sf -X PUT "\${VAULT_ADDR}/v1/sys/init" \
              -H "Content-Type: application/json" \
              -d '{"secret_shares":1,"secret_threshold":1}')
            UNSEAL_KEY=\$(echo "\$INIT" | jq -r '.keys_base64[0]')
            ROOT_TOKEN=\$(echo "\$INIT" | jq -r '.root_token')
            if [ -z "\$UNSEAL_KEY" ] || [ "\$UNSEAL_KEY" = "null" ]; then
              echo "ERROR: init failed: \$INIT" >&2; exit 1
            fi
            SEALED="true"
            echo "Vault initialized." >&2
          fi

          if [ "\$SEALED" = "true" ]; then
            echo "Unsealing Vault..." >&2
            curl -sf -X PUT "\${VAULT_ADDR}/v1/sys/unseal" \
              -H "Content-Type: application/json" \
              -d "{\"key\":\"\${UNSEAL_KEY}\"}" >/dev/null
            echo "Vault unsealed." >&2
          fi

          MOUNTS=\$(curl -sf -H "X-Vault-Token: \${ROOT_TOKEN}" "\${VAULT_ADDR}/v1/sys/mounts")
          if ! echo "\$MOUNTS" | jq -e '."secret/"' >/dev/null 2>&1; then
            curl -sf -X POST "\${VAULT_ADDR}/v1/sys/mounts/secret" \
              -H "X-Vault-Token: \${ROOT_TOKEN}" \
              -H "Content-Type: application/json" \
              -d '{"type":"kv","options":{"version":"2"}}' >/dev/null
            echo "KV v2 enabled at secret/." >&2
          fi

          POLICY='path "secret/data/*" { capabilities = ["create","read","update","delete","list"] } path "secret/metadata/*" { capabilities = ["create","read","update","delete","list"] } path "transit/keys/*" { capabilities = ["read","list"] } path "transit/sign/*" { capabilities = ["update"] } path "transit/verify/*" { capabilities = ["update"] } path "transit/keys/issuer-*" { capabilities = ["create","update","read","list"] } path "secret/data/public-keys/*" { capabilities = ["create","read","update","list"] } path "secret/metadata/public-keys/*" { capabilities = ["read","list","delete"] } path "secret/data/vc-metadata/*" { capabilities = ["create","read","update","list"] }'
          curl -sf -X PUT "\${VAULT_ADDR}/v1/sys/policies/acl/edc-runtime" \
            -H "X-Vault-Token: \${ROOT_TOKEN}" \
            -H "Content-Type: application/json" \
            -d "{\"policy\":\"\${POLICY}\"}" >/dev/null
          echo "Policy edc-runtime written." >&2

          TOKEN_RESP=\$(curl -sf -X POST "\${VAULT_ADDR}/v1/auth/token/create" \
            -H "X-Vault-Token: \${ROOT_TOKEN}" \
            -H "Content-Type: application/json" \
            -d '{"policies":["edc-runtime"],"no_parent":true}')
          SERVICE_TOKEN=\$(echo "\$TOKEN_RESP" | jq -r '.auth.client_token')
          if [ -z "\$SERVICE_TOKEN" ] || [ "\$SERVICE_TOKEN" = "null" ]; then
            echo "ERROR: token create failed: \$TOKEN_RESP" >&2; exit 1
          fi
          echo "Service token created." >&2

          printf 'VAULT_UNSEAL_KEY=%s\n'    "\$UNSEAL_KEY"
          printf 'VAULT_ROOT_TOKEN=%s\n'     "\$ROOT_TOKEN"
          printf 'VAULT_SERVICE_TOKEN=%s\n'  "\$SERVICE_TOKEN"
        securityContext:
          allowPrivilegeEscalation: false
          capabilities:
            drop: ["ALL"]
        resources:
          requests: { cpu: "50m",  memory: "64Mi" }
          limits:   { cpu: "200m", memory: "128Mi" }
JOBEOF

# ---------------------------------------------------------------------------
# Wait for completion and capture credentials from Job logs.
# ---------------------------------------------------------------------------
echo "Waiting for vault-init job to complete..."
kubectl -n "$NS" wait --for=condition=Complete "job/${JOB_NAME}" --timeout=300s

JOB_OUTPUT="$(kubectl -n "$NS" logs "job/${JOB_NAME}")"
mkdir -p "$(dirname "$SECRETS_FILE")"
echo "$JOB_OUTPUT" | grep -E '^VAULT_(UNSEAL_KEY|ROOT_TOKEN|SERVICE_TOKEN)=' > "$SECRETS_FILE"

SERVICE_TOKEN="$(grep '^VAULT_SERVICE_TOKEN=' "$SECRETS_FILE" | cut -d= -f2-)"
PATCH="{\"stringData\":{\"EDC_VAULT_HASHICORP_TOKEN\":\"${SERVICE_TOKEN}\"}}"

# ---------------------------------------------------------------------------
# Propagate the service token to the connector and identity-hub K8s secrets.
# ---------------------------------------------------------------------------
if kubectl -n "$NS" get secret connector-secret >/dev/null 2>&1; then
	kubectl -n "$NS" patch secret connector-secret --type merge -p "$PATCH" >/dev/null
	echo "Patched connector-secret"
fi
if kubectl -n "$NS" get secret identity-hub-secret >/dev/null 2>&1; then
	kubectl -n "$NS" patch secret identity-hub-secret --type merge -p "$PATCH" >/dev/null
	echo "Patched identity-hub-secret"
fi

kubectl -n "$NS" rollout restart deploy/edc-connector-connector    2>/dev/null || true
kubectl -n "$NS" rollout restart deploy/edc-connector-identity-hub 2>/dev/null || true

kubectl -n "$NS" delete job "$JOB_NAME" --ignore-not-found >/dev/null 2>&1
echo "Vault init/unseal complete."
