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
  backoffLimit: 0
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
        image: python:3.12-alpine
        env:
        - name: VAULT_ADDR
          value: "${VAULT_ADDR}"
        - name: UNSEAL_KEY
          value: "${EXISTING_UNSEAL_KEY}"
        - name: ROOT_TOKEN
          value: "${EXISTING_ROOT_TOKEN}"
        command: ["python3", "-u", "-c"]
        args:
        - |
          import urllib.request, urllib.error, json, os, sys, time

          vault_addr = os.environ['VAULT_ADDR']
          unseal_key = os.environ.get('UNSEAL_KEY', '')
          root_token = os.environ.get('ROOT_TOKEN', '')

          def req(method, path, data=None, token=None):
              url = vault_addr + path
              headers = {'Content-Type': 'application/json'}
              if token:
                  headers['X-Vault-Token'] = token
              body = json.dumps(data).encode() if data is not None else None
              r = urllib.request.Request(url, data=body, headers=headers, method=method)
              try:
                  with urllib.request.urlopen(r) as resp:
                      return json.loads(resp.read())
              except urllib.error.HTTPError as e:
                  return json.loads(e.read())

          print('Waiting for Vault...', file=sys.stderr, flush=True)
          for _ in range(30):
              try:
                  req('GET', '/v1/sys/seal-status')
                  break
              except Exception:
                  time.sleep(2)

          status = req('GET', '/v1/sys/seal-status')
          initialized = status.get('initialized', False)
          sealed = status.get('sealed', True)

          if not initialized:
              print('Initializing Vault...', file=sys.stderr, flush=True)
              init = req('PUT', '/v1/sys/init', {'secret_shares': 1, 'secret_threshold': 1})
              unseal_key = init['keys_base64'][0]
              root_token = init['root_token']
              sealed = True
              print('Vault initialized.', file=sys.stderr, flush=True)

          if sealed:
              print('Unsealing Vault...', file=sys.stderr, flush=True)
              req('PUT', '/v1/sys/unseal', {'key': unseal_key})
              print('Vault unsealed.', file=sys.stderr, flush=True)

          mounts = req('GET', '/v1/sys/mounts', token=root_token)
          if 'secret/' not in mounts:
              req('POST', '/v1/sys/mounts/secret', {'type': 'kv', 'options': {'version': '2'}}, token=root_token)
              print('KV v2 enabled.', file=sys.stderr, flush=True)

          policy = (
              'path "secret/data/*" { capabilities = ["create","read","update","delete","list"] }\n'
              'path "secret/metadata/*" { capabilities = ["create","read","update","delete","list"] }\n'
              'path "transit/keys/*" { capabilities = ["read","list"] }\n'
              'path "transit/sign/*" { capabilities = ["update"] }\n'
              'path "transit/verify/*" { capabilities = ["update"] }\n'
              'path "transit/keys/issuer-*" { capabilities = ["create","update","read","list"] }\n'
              'path "secret/data/public-keys/*" { capabilities = ["create","read","update","list"] }\n'
              'path "secret/metadata/public-keys/*" { capabilities = ["read","list","delete"] }\n'
              'path "secret/data/vc-metadata/*" { capabilities = ["create","read","update","list"] }'
          )
          req('PUT', '/v1/sys/policies/acl/edc-runtime', {'policy': policy}, token=root_token)
          print('Policy written.', file=sys.stderr, flush=True)

          token_resp = req('POST', '/v1/auth/token/create',
              {'policies': ['edc-runtime'], 'no_parent': True}, token=root_token)
          service_token = token_resp['auth']['client_token']
          print('Service token created.', file=sys.stderr, flush=True)

          print(f'VAULT_UNSEAL_KEY={unseal_key}')
          print(f'VAULT_ROOT_TOKEN={root_token}')
          print(f'VAULT_SERVICE_TOKEN={service_token}')
        securityContext:
          allowPrivilegeEscalation: false
          capabilities:
            drop: ["ALL"]
        resources:
          requests: { cpu: "50m",  memory: "128Mi" }
          limits:   { cpu: "200m", memory: "256Mi" }
JOBEOF

# ---------------------------------------------------------------------------
# Wait for completion and capture credentials from Job logs.
# ---------------------------------------------------------------------------
echo "Waiting for vault-init job to complete..."
if ! kubectl -n "$NS" wait --for=condition=Complete "job/${JOB_NAME}" --timeout=300s; then
	echo "Job did not complete — last pod logs:" >&2
	kubectl -n "$NS" logs "job/${JOB_NAME}" >&2 || true
	kubectl -n "$NS" describe job "$JOB_NAME" >&2 || true
	kubectl -n "$NS" delete job "$JOB_NAME" --ignore-not-found >/dev/null 2>&1
	exit 1
fi

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
