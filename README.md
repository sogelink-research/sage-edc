# PSNC EDC MVDS — GitLab CI/CD Deployment Pipeline

A GitLab CI/CD pipeline that deploys the [PSNC EDC MVDS](https://gitlab.pcss.pl/daisd-public/dpi-pipelines/psnc-edc-mvds/psnc-edc-mvds) stack to a Kubernetes cluster.

The pipeline clones the upstream PSNC repository and uses its Ansible playbooks to deploy the full Eclipse Dataspace Connector (EDC) stack, including:

- EDC Connector
- Dashboard
- Keycloak (identity provider — SAGE RCIAM/iShare variant or native PSNC variant)
- Vault (secret store)
- Storage (RustFS / S3-compatible)
- Consumer Backend
- Identity Hub (optional, requires dataspace authority credentials)

> **Note:** This pipeline is designed for plain Kubernetes. The upstream PSNC stack targets OpenShift, so Routes are replaced with cluster-specific ingress resources. See the [Ingress](#ingress) section for details.

---

## Prerequisites

### Cluster requirements

- Kubernetes cluster with a `standard-rwo` storage class (ReadWriteOnce, with `Delete` reclaim policy)
- A namespace pre-created (e.g. `edc-connector`)
- If your cluster enforces PodSecurity (Restricted/Baseline) or ResourceQuota policies, the pipeline automatically patches the upstream templates with the required `securityContext` and resource limits — no manual action needed (see [Template patches](#template-patches-applied-at-runtime))

### Ingress

The upstream PSNC stack targets OpenShift and uses OpenShift **Routes** for ingress. Since this pipeline deploys to plain Kubernetes, Routes are not available and ingress must be set up separately.

The included `gateway.yaml.example` uses a **Geodan-internal** `geodan.nl/v1 Gateway` CRD as an example. The spec format (`routes`, `auth`, `keepContext`) is completely specific to this CRD — **you must create your own `gateway.yaml`** with ingress resources appropriate for your cluster (standard `Ingress`, Istio `VirtualService`, Kubernetes Gateway API `HTTPRoute`, etc.).

`gateway.yaml` is git-ignored so each deployer maintains their own cluster-specific version. The example file documents all services and ports that need to be exposed.

---

## Setup

### 1. Copy files into your GitLab project

Add `.gitlab-ci.yml` and `gateway.yaml.example` to the root of your GitLab repository.

Then create your own `gateway.yaml` from the example (this file is git-ignored and must be created per deployment):

```bash
cp gateway.yaml.example gateway.yaml
# Edit gateway.yaml to match your cluster's ingress mechanism
```

### 2. Set CI/CD variables

Go to **Settings → CI/CD → Variables** in your GitLab project (or group) and add the following.

#### Kubeconfig (File type)zzzz

| Variable | Type | Description |
|----------|------|-------------|
| `KUBECONFIG_FILE` | **File** | Your cluster kubeconfig. Must be set as a **File** type variable, not a plain variable — GitLab writes the content to a temp file and sets the variable to the path. Note: the name `KUBECONFIG` is reserved in some environments; use `KUBECONFIG_FILE` instead. |

#### Deployment target

| Variable | Description | Example |
|----------|-------------|---------|
| `K8S_NAMESPACE` | Kubernetes namespace | `edc-connector` |
| `CONNECTOR_ID` | Unique connector identifier (used in service and resource names) | `my-org` |
| `DOMAIN_BASE` | Base domain for public hostnames | `example.org` |

#### Public hostnames

Hostnames are automatically derived from `CONNECTOR_ID` and `DOMAIN_BASE`:

| Service | Hostname pattern |
|---------|------------------|
| Connector | `${CONNECTOR_ID}.edc.${DOMAIN_BASE}` |
| Dashboard | `${CONNECTOR_ID}.edc-dashboard.${DOMAIN_BASE}` |
| Keycloak | `${CONNECTOR_ID}.edc-keycloak.${DOMAIN_BASE}` |
| Identity Hub | `${CONNECTOR_ID}.edc-identity.${DOMAIN_BASE}` |
| Storage | `${CONNECTOR_ID}.edc-storage.${DOMAIN_BASE}` |
| Consumer Backend | `${CONNECTOR_ID}.edc-consumer.${DOMAIN_BASE}` |
| Vault | `${CONNECTOR_ID}.edc-vault.${DOMAIN_BASE}` |

To override individual hostnames, set the corresponding CI/CD variable (`CONNECTOR_HOST`, `DASHBOARD_HOST`, etc.) — this takes precedence over the derived value.

#### Keycloak flavor

| Variable | Default | Description |
|----------|---------|-------------|
| `KEYCLOAK_FLAVOR` | `sage` | Which Keycloak to deploy: `sage` (RCIAM/iShare) or `psnc` (native PSNC) |

See the [Keycloak](#keycloak) section for details.

#### Feature flags

| Variable | Default | Description |
|----------|---------|-------------|
| `ENABLE_IDENTITY_HUB` | `true` | Deploy Identity Hub (requires dataspace authority credentials below) |
| `ENABLE_STORAGE` | `true` | Deploy RustFS storage |
| `IMAGE_TAG` | `latest` | Image tag to deploy |

#### Dataspace authority credentials

| Variable | Description |
|----------|-------------|
| `ISSUER_DID` | Dataspace authority DID (e.g. `did:web:authority.tsg.example.org`). Also automatically added to `EDC_TRUSTED_ISSUERS` so the connector accepts credentials issued by this authority. |
| `FEDERATED_CATALOG_ADDR` | Federated catalog URL |
| `DATA_SPACE_HUB_ADDR` | Data space hub URL (used only for the `verify:dataspace` DID reachability check; has no effect on trust or catalog) |
| `CATALOG_API_KEY` | Catalog API key (can be empty) |
| `STS_CLIENT_SECRET` | Vault alias name for the STS OAuth client secret. Used as the **key** in Vault, not the secret value — the actual secret is generated by `init:dataspace`. Keep this short and stable (e.g. `sts-client-secret`). Default: `sts-client-secret` |

#### Docker Hub (optional — for private image pull secret)

| Variable | Description |
|----------|-------------|
| `DOCKERHUB_USER` | Docker Hub username |
| `DOCKERHUB_TOKEN` | Docker Hub access token |
| `DOCKERHUB_EMAIL` | Docker Hub email |

#### Secrets

Generate random values with: `openssl rand -base64 32 | tr -d '\n'`

| Variable | Description |
|----------|-------------|
| `CONNECTOR_DB_PASSWORD` | Connector PostgreSQL password |
| `KEYCLOAK_DB_PASSWORD` | Keycloak PostgreSQL password (**`KEYCLOAK_FLAVOR=psnc` only**) |
| `KEYCLOAK_ADMIN_PASSWORD` | Keycloak admin password (**`KEYCLOAK_FLAVOR=psnc` only** — for `KEYCLOAK_FLAVOR=sage` use `SAGE_KC_ADMIN_PASSWORD` instead) |
| `IDENTITY_HUB_DB_PASSWORD` | Identity Hub PostgreSQL password |
| `API_AUTH_KEY` | EDC API authentication key |
| `RUSTFS_ACCESS_KEY` | RustFS / S3 access key |
| `RUSTFS_SECRET_KEY` | RustFS / S3 secret key |
| `IH_API_SUPERUSER_KEY` | Identity Hub superuser key (see format below) |

**`IH_API_SUPERUSER_KEY` format:** `base64(username).base64(secret)`

Generate with:
```bash
IH_USER="super-user"
IH_SECRET="$(openssl rand -base64 32 | tr -d '\r\n')"
printf '%s.%s\n' \
  "$(printf '%s' "$IH_USER" | openssl base64 -A)" \
  "$(printf '%s' "$IH_SECRET" | openssl base64 -A)"
```

---

## Keycloak

The pipeline supports two Keycloak variants, selected via `KEYCLOAK_FLAVOR`:

### `sage` (default) — RCIAM/iShare Keycloak

Deploys a separate Keycloak from `keycloak-sage/k8s/` that is pre-configured for RCIAM/iShare authentication. The upstream PSNC Keycloak is disabled (`enable_identity_provider: false`).

Required CI/CD variables:

| Variable | Description |
|----------|-------------|
| `SATELLITE_ID` | iShare satellite EORI (e.g. `EU.EORI.PL12345678`) |
| `SATELLITE_URL` | iShare satellite URL |
| `SAGE_KC_ADMIN` | Bootstrap admin username |
| `SAGE_KC_ADMIN_PASSWORD` | Bootstrap admin password |
| `ISHARE_CA_PEM` | **File-type** CI variable — iShare CA certificate chain (PEM). Mounted into Keycloak at `/opt/keycloak-keys/sage/ca-file.pem` |

The pipeline automatically repoints all connector config (JWKS URL, dashboard `oauthIssuer`, `REALM_NAME`) from the upstream default realm `Organizations` to `sage`.

After `configure:keycloak` runs, users need to be in the **`federated-catalog`** group in the `sage` realm to access the Catalog Browser in the dashboard. The bootstrap `test` user is added to this group automatically. For federated/RCIAM users, assign the group manually in the Keycloak admin console.

### `psnc` — native PSNC Keycloak

Uses the Keycloak bundled with the upstream PSNC deployment. Requires `KEYCLOAK_DB_PASSWORD` and `KEYCLOAK_ADMIN_PASSWORD`.

---

## Re-running the pipeline

The pipeline is designed to be re-run safely at any time:

- **All deploy stages** use Ansible with `kubernetes.core.k8s`, which calls `kubectl apply` internally — fully idempotent. Existing resources are updated in place; PVCs are never recreated, so database data is preserved.
- **`init:vault`** — safe to re-run. Vault detects if already initialized and skips re-initialization. The Vault unseal key and root token are persisted as a Kubernetes Secret (`vault-pipeline-credentials`) in the cluster after first init, so they survive across pipeline runs.
- **`configure:keycloak`** — safe to re-run. Realm, clients, and users are created only if not already present.
- **`init:dataspace`** and **`verify:dataspace`** — safe to re-run.
- **`cleanup:edc`** — only runs when manually triggered; never part of an automatic re-run.

> **Note:** If you change hostnames between runs, the old gateway/ingress resources with the previous hostname are not automatically removed. Delete them manually if needed.

---

## Pipeline stages

| Stage | Jobs | Description |
|-------|------|-------------|
| `prepare` | `prepare:namespace` | Creates Docker Hub image pull secret (if configured) |
| `deploy-infra` | `deploy:env`, `deploy:secrets`, `deploy:databases`, `deploy:vault`, `deploy:sage-keycloak` | Renders config, creates K8s secrets, deploys databases, Vault, and (if `KEYCLOAK_FLAVOR=sage`) the SAGE Keycloak |
| `deploy-services` | `deploy:services`, `deploy:gateways` | Deploys EDC workloads and ingress/gateway routes |
| `configure` | `init:vault`, `configure:keycloak`, `init:dataspace`, `configure:jsonld-contexts` | Initializes Vault, bootstraps Keycloak, registers with the dataspace (if `ENABLE_IDENTITY_HUB`), pre-loads TSG JSON-LD contexts |
| `verify` | `verify:dataspace`, `verify:resources` | Smoke tests (if `ENABLE_IDENTITY_HUB`) and resource listing |
| `cleanup` | `cleanup:edc` | **Manual** — removes all EDC resources from the namespace |

---

## Template patches applied at runtime

The upstream PSNC templates are patched automatically by the pipeline to comply with stricter cluster security policies and to support the SAGE Keycloak:

| Template | Patch |
|----------|-------|
| All three Postgres StatefulSets | Pod `securityContext` (`fsGroup: 1001`, `runAsUser: 1001`) + container resource limits |
| Vault StatefulSet | Pod `securityContext` (`fsGroup: 100`, `runAsUser: 100`) + container `runAsUser: 100` |
| Storage Deployment | Fixes upstream typo `podSecurityContext` → `securityContext` |
| `deploy-vault.yaml` | Suppresses the OpenShift `Route` task (`when: false`) — ingress is handled by `deploy:gateways` instead |
| `connector-configmap.yaml.j2` | Appends `ISSUER_DID` to `EDC_TRUSTED_ISSUERS` so the connector accepts credentials from the configured dataspace authority |
| `connector-configmap.yaml.j2` | (`KEYCLOAK_FLAVOR=sage`) Repoints all JWKS URLs from `/realms/Organizations/` to `/realms/sage/` |
| `dashboard-configmap.yaml.j2` | (`KEYCLOAK_FLAVOR=sage`) Repoints `oauthIssuer` from `/realms/Organizations` to `/realms/sage` |
| `dotenv.j2` | (`KEYCLOAK_FLAVOR=sage`) Sets `REALM_NAME=sage` |

These patches are applied only to the freshly cloned upstream templates inside the CI runner — your own files are never modified.

## TSG JSON-LD contexts (`configure:jsonld-contexts`)

> **Only needed for TSG integration.** If you are not connecting to a TNO Security Gateway (TSG) connector, this job can be ignored — it has `allow_failure: true` and does not block the pipeline.

EDC's Titanium JSON-LD loader refuses to fetch remote (`https://`) contexts at runtime. When a TSG counter-party sends a DSP message, it includes TSG-specific contexts (`tsg.json`, `health.json`) that EDC cannot resolve, causing the request to fail with HTTP 400 `LOADING_REMOTE_CONTEXT_FAILED`.

This job pre-loads those contexts into the connector pod by:
1. Fetching the JSON-LD files from the public TSG context URL
2. Storing them in a ConfigMap
3. Patching the connector Deployment to mount the ConfigMap
4. Registering each context via `EDC_JSONLD_DOCUMENT_*` env vars
5. Triggering a rollout restart

Override the TSG version via CI/CD variables `TSG_CONTEXTS_VERSION` (default: `v0.19.0`) and `TSG_CONTEXTS_BASE`.

---

The pipeline deploys from:

- **Repo:** `https://gitlab.pcss.pl/daisd-public/dpi-pipelines/psnc-edc-mvds/psnc-edc-mvds.git`
- **Branch:** `develop` (configurable via `EDC_REPO_REF`)

---

## Cleanup

The `cleanup:edc` job is **manual** and will delete all EDC resources (Deployments, StatefulSets, Services, ConfigMaps, Secrets, PVCs, ServiceAccounts, Gateways) from the namespace. PVCs are deleted — data is not preserved.

The gateway CRD name defaults to `gateway.geodan.nl` and can be overridden by setting the `GATEWAY_CRD` CI/CD variable (or the job-level variable in the pipeline UI) if your cluster uses a different CRD.




# Endpoints

## Identity Hub (`sogelink.edc-identity.beta.geodan.nl`)

| Port | Path prefix | Endpoints |
|------|-------------|-----------|
| 7080 | `/api` | `POST /api/bootstrap` — seed superuser (no auth)<br>`GET /api/check/health` — health check |
| 7082 | `/api/identity` | `GET/POST /api/identity/v1alpha/participants` — list/create participant contexts<br>`GET/DELETE /api/identity/v1alpha/participants/{id}` — get/delete participant<br>`PUT /api/identity/v1alpha/participants/{id}/state` — activate/deactivate<br>`POST /api/identity/v1alpha/keypairs` — add key pair<br>`GET /api/identity/v1alpha/keypairs?participantId=` — list key pairs<br>`GET /api/identity/v1alpha/participants/{id}/credentials` — list participant's VCs<br>`GET /api/identity/v1alpha/credentials` — list all VCs |
| 7081 | `/api/credentials` | DCP CredentialService protocol endpoint — used by other connectors to request Verifiable Presentations (not a management API) |
| 7083 | `/` | `GET /{participantId}/did.json` — DID document |
| 7085 | `/api/version` | `GET /api/version` — runtime version |
| 7086 | `/api/sts` | STS token endpoint (used internally by EDC, not called directly) |

---

## Connector (`sogelink.edc.beta.geodan.nl`)

| Port | Path prefix | Endpoints (key ones) |
|------|-------------|----------------------|
| 8081 | `/api/management` | Full management API — `v3/assets`, `v3/policydefinitions`, `v3/contractdefinitions`, `v3/contractnegotiations`, `v3/transferprocesses`, `v3/catalog/request`, `v3/edrs`, `v3/secrets` |
| 8082 | `/api/dsp` | DSP protocol (counterpart-to-counterpart, not called directly) |
| 8083 | `/api/control` | Control plane internal |
| 8084 | `/api/catalog` | `GET /api/catalog/v1alpha/catalog/query` — federated catalog query |
| 8085 | `/api/version` | `GET /api/version` — runtime version |
| 8086 | `/api/catalog-proxy` | `POST /api/catalog-proxy/catalog/request` — catalog proxy |
| 11001 | `/api/public` | Data plane public endpoint (for data transfer) |

All management API calls require header: `x-api-key: <API_AUTH_KEY>`


### Testing
#### Connector

Get API versions:
```bash
curl -X GET https://sogelink.edc.beta.geodan.nl/api/version/v1/version
```

#### Identity hub

Get API versions:
```bash
curl -X GET https://sogelink.edc-identity.beta.geodan.nl/api/version/v1/version
```

Get participants:
```bash
curl -X GET https://sogelink.edc-identity.beta.geodan.nl/api/identity/v1alpha/participants \
  -H "x-api-key: API_AUTH_KEY"
```

Get credentials for a participant:
```bash
curl -X GET https://sogelink.edc-identity.beta.geodan.nl/api/identity/v1alpha/participants/super-user/credentials \
  -H "x-api-key: API_AUTH_KEY"

curl -X GET https://sogelink.edc-identity.beta.geodan.nl/api/identity/v1alpha/participants/did:web:sogelink.edc-identity.beta.geodan.nl:sogelink/credentials \
  -H "x-api-key: API_AUTH_KEY"
```

Add a verifiable credential:
```bash
curl -X POST \
  "https://sogelink.edc-identity.beta.geodan.nl/api/identity/v1alpha/participants/ZGlkOndlYjpzb2dlbGluay5lZGMtaWRlbnRpdHkuYmV0YS5nZW9kYW4ubmw6c29nZWxpbms=/credentials" \
  -H "x-api-key: API_AUTH_KEY" \
  -H "Content-Type: application/json" \
  --data-binary "@credential.json"
```

Delete a verifiable credential:
```bash
curl -X DELETE https://sogelink.edc-identity.beta.geodan.nl/api/identity/v1alpha/participants/super-user/credentials/c02215b1-9d57-4445-bb1f-3b673b74b605 \
  -H "x-api-key: API_AUTH_KEY"
```
