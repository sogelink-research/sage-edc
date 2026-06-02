#!/usr/bin/env bash
# init-vault-manual.sh — Manual fallback for the init:vault pipeline job.
#
# Run this when the pipeline's init:vault job fails (e.g. due to cluster
# policy restrictions). Vault must already be initialized and unsealed.
# UNSEAL_KEY and ROOT_TOKEN are read from the vault-pipeline-credentials
# K8s secret that was persisted by a previous successful run.
#
# Usage:
#   bash scripts/init-vault-manual.sh
set -euo pipefail

NS="research-services"
VAULT_ADDR="https://sogelink.edc-vault.beta.geodan.nl"

# ---------------------------------------------------------------------------
# Load credentials from the persisted K8s secret
# ---------------------------------------------------------------------------
echo "Reading credentials from vault-pipeline-credentials..."
UNSEAL_KEY=$(kubectl -n "$NS" get secret vault-pipeline-credentials \
	-o jsonpath='{.data.VAULT_UNSEAL_KEY}' | base64 -d)
ROOT_TOKEN=$(kubectl -n "$NS" get secret vault-pipeline-credentials \
	-o jsonpath='{.data.VAULT_ROOT_TOKEN}' | base64 -d)

if [ -z "$UNSEAL_KEY" ] || [ -z "$ROOT_TOKEN" ]; then
	echo "ERROR: vault-pipeline-credentials secret is missing or incomplete."
	echo "If Vault was never initialized, run steps 2-3 manually first and re-run."
	exit 1
fi

# ---------------------------------------------------------------------------
# 1. Check status
# ---------------------------------------------------------------------------
echo "=== 1. Vault status ==="
STATUS=$(curl -sf "$VAULT_ADDR/v1/sys/seal-status")
echo "$STATUS" | jq .
INITIALIZED=$(echo "$STATUS" | jq -r '.initialized')
SEALED=$(echo "$STATUS" | jq -r '.sealed')

# ---------------------------------------------------------------------------
# 2+3. Initialize and/or unseal if needed
# ---------------------------------------------------------------------------
if [ "$INITIALIZED" != "true" ]; then
	echo "=== 2. Initializing Vault ==="
	INIT=$(curl -sf -X PUT "$VAULT_ADDR/v1/sys/init" \
		-H "Content-Type: application/json" \
		-d '{"secret_shares":1,"secret_threshold":1}')
	UNSEAL_KEY=$(echo "$INIT" | jq -r '.keys_base64[0]')
	ROOT_TOKEN=$(echo "$INIT" | jq -r '.root_token')
	echo "$INIT" | jq .
	SEALED="true"
fi

if [ "$SEALED" = "true" ]; then
	echo "=== 3. Unsealing Vault ==="
	curl -sf -X PUT "$VAULT_ADDR/v1/sys/unseal" \
		-H "Content-Type: application/json" \
		-d "{\"key\":\"${UNSEAL_KEY}\"}" | jq .
fi

# ---------------------------------------------------------------------------
# 4. Enable KV v2 (idempotent — ignores 400 if already mounted)
# ---------------------------------------------------------------------------
echo "=== 4. Enabling KV v2 secrets engine ==="
curl -s -X POST "$VAULT_ADDR/v1/sys/mounts/secret" \
	-H "X-Vault-Token: $ROOT_TOKEN" \
	-H "Content-Type: application/json" \
	-d '{"type":"kv","options":{"version":"2"}}' | jq . || true

# ---------------------------------------------------------------------------
# 5. Write EDC policy
# ---------------------------------------------------------------------------
echo "=== 5. Writing edc-runtime policy ==="
curl -sf -X PUT "$VAULT_ADDR/v1/sys/policies/acl/edc-runtime" \
	-H "X-Vault-Token: $ROOT_TOKEN" \
	-H "Content-Type: application/json" \
	-d '{"policy":"path \"secret/data/*\" { capabilities = [\"create\",\"read\",\"update\",\"delete\",\"list\"] }\npath \"secret/metadata/*\" { capabilities = [\"create\",\"read\",\"update\",\"delete\",\"list\"] }\npath \"transit/keys/*\" { capabilities = [\"read\",\"list\"] }\npath \"transit/sign/*\" { capabilities = [\"update\"] }\npath \"transit/verify/*\" { capabilities = [\"update\"] }\npath \"transit/keys/issuer-*\" { capabilities = [\"create\",\"update\",\"read\",\"list\"] }\npath \"secret/data/public-keys/*\" { capabilities = [\"create\",\"read\",\"update\",\"list\"] }\npath \"secret/metadata/public-keys/*\" { capabilities = [\"read\",\"list\",\"delete\"] }\npath \"secret/data/vc-metadata/*\" { capabilities = [\"create\",\"read\",\"update\",\"list\"] }"}' | jq .

# ---------------------------------------------------------------------------
# 6. Create a fresh service token
# ---------------------------------------------------------------------------
echo "=== 6. Creating service token ==="
TOKEN_RESP=$(curl -sf -X POST "$VAULT_ADDR/v1/auth/token/create" \
	-H "X-Vault-Token: $ROOT_TOKEN" \
	-H "Content-Type: application/json" \
	-d '{"policies":["edc-runtime"],"no_parent":true}')
SERVICE_TOKEN=$(echo "$TOKEN_RESP" | jq -r '.auth.client_token')
echo "Service token created."

# ---------------------------------------------------------------------------
# 7. Patch K8s secrets with the new service token
# ---------------------------------------------------------------------------
echo "=== 7. Patching K8s secrets ==="
PATCH="{\"stringData\":{\"EDC_VAULT_HASHICORP_TOKEN\":\"${SERVICE_TOKEN}\"}}"
kubectl -n "$NS" patch secret connector-secret     --type merge -p "$PATCH"
kubectl -n "$NS" patch secret identity-hub-secret  --type merge -p "$PATCH"

# ---------------------------------------------------------------------------
# 8. Restart workloads to pick up the new token
# ---------------------------------------------------------------------------
echo "=== 8. Restarting workloads ==="
kubectl -n "$NS" rollout restart deploy/edc-connector-connector
kubectl -n "$NS" rollout restart deploy/edc-connector-identity-hub

# ---------------------------------------------------------------------------
# 9. Persist credentials for future pipeline runs
# ---------------------------------------------------------------------------
echo "=== 9. Persisting credentials ==="
kubectl -n "$NS" create secret generic vault-pipeline-credentials \
	--from-literal=VAULT_UNSEAL_KEY="$UNSEAL_KEY" \
	--from-literal=VAULT_ROOT_TOKEN="$ROOT_TOKEN" \
	--from-literal=VAULT_SERVICE_TOKEN="$SERVICE_TOKEN" \
	--dry-run=client -o yaml | kubectl apply -f -

echo "Done. Vault init/unseal complete."