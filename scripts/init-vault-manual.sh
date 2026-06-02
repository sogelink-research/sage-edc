NS="research-services"
VAULT_ADDR="https://sogelink-ih.edc-vault.YOUR_DOMAIN"  # or port-forward locally

# 1. Check status
curl -s "$VAULT_ADDR/v1/sys/seal-status" | jq .

# 2. Initialize (only if .initialized == false)
curl -s -X PUT "$VAULT_ADDR/v1/sys/init" \
  -H "Content-Type: application/json" \
  -d '{"secret_shares":1,"secret_threshold":1}' | jq .
# → Save root_token and keys_base64[0] from the response

# 3. Unseal (only if sealed)
curl -s -X PUT "$VAULT_ADDR/v1/sys/unseal" \
  -H "Content-Type: application/json" \
  -d '{"key":"<UNSEAL_KEY_FROM_STEP_2>"}'

# 4. Enable KV v2 secrets engine
curl -s -X POST "$VAULT_ADDR/v1/sys/mounts/secret" \
  -H "X-Vault-Token: <ROOT_TOKEN>" \
  -H "Content-Type: application/json" \
  -d '{"type":"kv","options":{"version":"2"}}'

# 5. Write EDC policy
curl -s -X PUT "$VAULT_ADDR/v1/sys/policies/acl/edc-runtime" \
  -H "X-Vault-Token: <ROOT_TOKEN>" \
  -H "Content-Type: application/json" \
  -d '{"policy":"path \"secret/data/*\" { capabilities = [\"create\",\"read\",\"update\",\"delete\",\"list\"] }\npath \"secret/metadata/*\" { capabilities = [\"create\",\"read\",\"update\",\"delete\",\"list\"] }\npath \"transit/keys/*\" { capabilities = [\"read\",\"list\"] }\npath \"transit/sign/*\" { capabilities = [\"update\"] }\npath \"transit/verify/*\" { capabilities = [\"update\"] }\npath \"transit/keys/issuer-*\" { capabilities = [\"create\",\"update\",\"read\",\"list\"] }\npath \"secret/data/public-keys/*\" { capabilities = [\"create\",\"read\",\"update\",\"list\"] }\npath \"secret/metadata/public-keys/*\" { capabilities = [\"read\",\"list\",\"delete\"] }\npath \"secret/data/vc-metadata/*\" { capabilities = [\"create\",\"read\",\"update\",\"list\"] }"}'

# 6. Create service token
curl -s -X POST "$VAULT_ADDR/v1/auth/token/create" \
  -H "X-Vault-Token: <ROOT_TOKEN>" \
  -H "Content-Type: application/json" \
  -d '{"policies":["edc-runtime"],"no_parent":true}' | jq .
# → Save .auth.client_token as SERVICE_TOKEN

# 7. Patch K8s secrets with the service token
kubectl -n "$NS" patch secret connector-secret --type merge \
  -p "{\"stringData\":{\"EDC_VAULT_HASHICORP_TOKEN\":\"<SERVICE_TOKEN>\"}}"
kubectl -n "$NS" patch secret identity-hub-secret --type merge \
  -p "{\"stringData\":{\"EDC_VAULT_HASHICORP_TOKEN\":\"<SERVICE_TOKEN>\"}}"

# 8. Restart workloads to pick up the new token
kubectl -n "$NS" rollout restart deploy/edc-connector-connector
kubectl -n "$NS" rollout restart deploy/edc-connector-identity-hub

# 9. Persist credentials so the next pipeline run can restore them
kubectl -n "$NS" create secret generic vault-pipeline-credentials \
  --from-literal=VAULT_UNSEAL_KEY="<UNSEAL_KEY>" \
  --from-literal=VAULT_ROOT_TOKEN="<ROOT_TOKEN>" \
  --from-literal=VAULT_SERVICE_TOKEN="<SERVICE_TOKEN>" \
  --dry-run=client -o yaml | kubectl apply -f -