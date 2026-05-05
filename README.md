# PSNC EDC MVDS — GitLab CI/CD Deployment Pipeline

A GitLab CI/CD pipeline that deploys the [PSNC EDC MVDS](https://gitlab.pcss.pl/daisd-public/dpi-pipelines/psnc-edc-mvds/psnc-edc-mvds) stack to a Kubernetes cluster (tested on GKE).

The pipeline clones the upstream PSNC repository and uses its Ansible playbooks to deploy the full Eclipse Dataspace Connector (EDC) stack, including:

- EDC Connector
- Dashboard
- Keycloak (identity provider)
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

#### Kubeconfig (File type)

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

#### Feature flags

| Variable | Default | Description |
|----------|---------|-------------|
| `ENABLE_IDENTITY_PROVIDER` | `true` | Deploy Keycloak |
| `ENABLE_IDENTITY_HUB` | `false` | Deploy Identity Hub (requires dataspace authority credentials below) |
| `ENABLE_STORAGE` | `true` | Deploy RustFS storage |
| `IMAGE_TAG` | `latest` | Image tag to deploy |

#### Dataspace authority credentials (required when `ENABLE_IDENTITY_HUB=true`)

Obtain these from your dataspace authority (e.g. PSNC).

| Variable | Description |
|----------|-------------|
| `ISSUER_DID` | Dataspace issuer DID (e.g. `did:web:...`) |
| `FEDERATED_CATALOG_ADDR` | Federated catalog URL |
| `DATA_SPACE_HUB_ADDR` | Data space hub URL |
| `CATALOG_API_KEY` | Catalog API key (can be empty) |
| `DSH_API_KEY` | Data space hub API key (can be empty) |

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
| `KEYCLOAK_DB_PASSWORD` | Keycloak PostgreSQL password |
| `KEYCLOAK_ADMIN_PASSWORD` | Keycloak admin user password |
| `IDENTITY_HUB_DB_PASSWORD` | Identity Hub PostgreSQL password |
| `API_AUTH_KEY` | EDC API authentication key |
| `RUSTFS_ACCESS_KEY` | RustFS / S3 access key |
| `RUSTFS_SECRET_KEY` | RustFS / S3 secret key |
| `STS_CLIENT_SECRET` | STS client secret (optional — has a default fallback) |
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

## Re-running the pipeline

The pipeline is designed to be re-run safely at any time:

- **All deploy stages** use Ansible with `kubernetes.core.k8s`, which calls `kubectl apply` internally — fully idempotent. Existing resources are updated in place; PVCs are never recreated, so database data is preserved.
- **`init:vault`** — safe to re-run. Vault detects if already initialized and skips re-initialization.
- **`configure:keycloak`** — safe to re-run. Realm, clients, and users are created only if not already present.
- **`init:dataspace`** and **`verify:dataspace`** — safe to re-run.
- **`cleanup:edc`** — only runs when manually triggered; never part of an automatic re-run.

> **Note:** If you change hostnames between runs, the old gateway/ingress resources with the previous hostname are not automatically removed. Delete them manually if needed.

---

## Pipeline stages

| Stage | Jobs | Description |
|-------|------|-------------|
| `prepare` | `prepare:namespace` | Creates Docker Hub image pull secret (if configured) |
| `deploy-infra` | `deploy:env`, `deploy:secrets`, `deploy:databases`, `deploy:vault` | Renders config, creates K8s secrets, deploys databases and Vault |
| `deploy-services` | `deploy:services`, `deploy:gateways` | Deploys EDC workloads and ingress/gateway routes |
| `configure` | `init:vault`, `configure:keycloak`, `init:dataspace` | Initializes and unseals Vault, bootstraps Keycloak (if `ENABLE_IDENTITY_PROVIDER`), registers with the dataspace (if `ENABLE_IDENTITY_HUB`) |
| `verify` | `verify:dataspace`, `verify:resources` | Smoke tests (if `ENABLE_IDENTITY_HUB`) and resource listing |
| `cleanup` | `cleanup:edc` | **Manual** — removes all EDC resources from the namespace |

---

## Template patches applied at runtime

The upstream PSNC templates are patched automatically by the pipeline to comply with stricter cluster security policies:

| Template | Patch |
|----------|-------|
| All three Postgres StatefulSets | Pod `securityContext` (`fsGroup: 1001`, `runAsUser: 1001`) + container resource limits |
| Vault StatefulSet | Pod `securityContext` (`fsGroup: 100`, `runAsUser: 100`) + container `runAsUser: 100` |
| Storage Deployment | Fixes upstream typo `podSecurityContext` → `securityContext` |
| `deploy-vault.yaml` | Suppresses the OpenShift `Route` task (`when: false`) — ingress is handled by `deploy:gateways` instead |

These patches are idempotent (skipped if already applied) and are only applied to the cloned upstream templates, never to your own files.

---

## Upstream repository

The pipeline deploys from:

- **Repo:** `https://gitlab.pcss.pl/daisd-public/dpi-pipelines/psnc-edc-mvds/psnc-edc-mvds.git`
- **Branch:** `develop` (configurable via `EDC_REPO_REF`)

---

## Cleanup

The `cleanup:edc` job is **manual** and will delete all EDC resources (Deployments, StatefulSets, Services, ConfigMaps, Secrets, PVCs, ServiceAccounts, Gateways) from the namespace. PVCs are deleted — data is not preserved.
