# SAGE Keycloak

This directory contains the **RCIAM / iShare "SAGE" Keycloak**, which **replaces
the Keycloak that ships with the upstream `psnc-edc-mvds` repository** in the
deployment pipeline ([../.gitlab-ci.yml](../.gitlab-ci.yml)).

---

## Why a different Keycloak?

The default `psnc-edc-mvds` Keycloak is a plain OIDC identity provider. The SAGE
Keycloak (`registry.egi.eu/sage.greendealdata.eu/rciam-ishare-keycloak`) is built
from the **eosc-kc Keycloak** fork and adds two capabilities the plain image does
not have — both required to participate in the **SAGE dataspace within the EU
Green Deal Data Space**:

1. **iShare trust-framework support.** The container renders an `ishare.json`
   from a `satellite-id` (an EORI such as `EU.EORI.PL12345678`), a `satellite-url`
   and an `ishare-ca-file`. iShare is a dataspace trust framework in which
   participants are identified by EORI numbers and eIDAS-style certificates, and a
   **satellite** acts as the trust anchor / participant registry. Baking this into
   the IdP lets the connector be *trusted* within an iShare-compliant dataspace
   (certificate-based, machine-to-machine) — something vanilla Keycloak OIDC
   cannot do on its own.

2. **RCIAM / AARC entitlements + group management.** The image ships the
   [keycloak-group-management (AGM)](https://github.com/rciam/keycloak-group-management)
   plugin. The [`init.sh`](init.sh) step configures a `member-user-attribute`
   (`localEntitlements` under a `urn:...` namespace), implementing the **AARC
   entitlement model** used across EGI/EOSC research infrastructures for
   federated, community-managed group membership.

In short: the switch is a **trust and interoperability** decision (iShare
satellite + AARC entitlements), not a change of authentication UX. The default
PSNC Keycloak has no iShare or AARC entitlement machinery.

---

## Choosing which Keycloak (`KEYCLOAK_FLAVOR`)

Both Keycloaks are supported and selected with the `KEYCLOAK_FLAVOR` CI/CD
variable:

| `KEYCLOAK_FLAVOR` | Keycloak used | Realm | How it is deployed |
| --- | --- | --- | --- |
| `sage` (default) | RCIAM/iShare SAGE Keycloak (this folder) | `sage` | `deploy:sage-keycloak` job; upstream Keycloak disabled (`enable_identity_provider: false`) |
| `psnc` | Native Keycloak bundled with psnc-edc-mvds | `Organizations` | Upstream Ansible playbooks (`enable_identity_provider: true`) |

The rest of the pipeline adapts automatically: the realm-repoint patches, the
bootstrap admin credentials, the realm the `configure:keycloak` job waits for and
bootstraps, and the SAGE-only entitlements job are all gated on `KEYCLOAK_FLAVOR`.
Either way the Keycloak Service is named `edc-connector-keycloak`, so
[../gateway.yaml](../gateway.yaml) and the connector/dashboard wiring are
identical for both flavors.

---

## What gets deployed

The pipeline (with `KEYCLOAK_FLAVOR=sage`) disables the upstream Keycloak
(`enable_identity_provider: false`) and deploys this stack instead:

| Resource | Kind | Notes |
| --- | --- | --- |
| `edc-connector-keycloak` | Deployment + Service | SAGE Keycloak, port `8080`. **Named as a drop-in** for the upstream service, so [../gateway.yaml](../gateway.yaml) and the EDC connector/dashboard wiring are unchanged. |
| `edc-connector-sage-keycloak-db` | Deployment + Service | Custom `rciam-ishare-postgres` snapshot (db `postgres2`). |
| `sage-keycloak-realm` | ConfigMap | Realm import ([realms/sage-realm.json](realms/sage-realm.json)) mounted at `/opt/keycloak/data/import`. |
| `sage-keycloak-ca` | Secret | iShare CA chain (from `ISHARE_CA_PEM`) mounted at `/opt/keycloak-keys/sage/ca-file.pem`. |
| `sage-keycloak-init` | ConfigMap | [init.sh](init.sh) for the entitlements job. |
| `edc-connector-sage-entitlements` | Job | Runs `init.sh` once to configure the AGM member-user-attribute for realm `sage`. |

All resources are labelled `app=edc-connector`, so the pipeline's `cleanup:edc`
job removes them.

Kubernetes manifests live in [k8s/](k8s/) and are the translation of
[docker-compose.yml](docker-compose.yml) (kept for local development).

---

## How it integrates with the EDC

The SAGE realm is named **`sage`** (the upstream connector/dashboard assume
`Organizations`). The pipeline patches the *cloned* upstream templates at build
time to repoint them:

- `connector-configmap.yaml.j2` — token-validation URLs → `/realms/sage/.../certs`
- `dashboard-configmap.yaml.j2` — OIDC issuer → `/realms/sage`
- `env/dotenv.j2` — `REALM_NAME=sage`

The imported `sage` realm ships only Keycloak's default clients, so the EDC
clients it needs (`data-space-users`, `federated-catalog`, `connector`), their
roles, groups, default group, test user and the `audience-resolve` mapper are
created **idempotently** by the upstream `make configure-keycloak` bootstrap
(run with `REALM_NAME=sage`). The bootstrap does **not** overwrite the imported
realm — it only ensures `sslRequired=none` on the existing realm and adds the
clients. This keeps our EDC configuration decoupled from the (externally owned)
`sage-realm.json`, so it survives future realm refreshes.

---

## Pipeline flow

1. **`deploy:sage-keycloak`** (stage `deploy-infra`, `KEYCLOAK_FLAVOR=sage` only)
   — creates the realm/init ConfigMaps and the CA Secret, then applies the
   Postgres and Keycloak manifests.
2. **`configure:keycloak`** (stage `configure`) — waits for the Keycloak rollout
   and for `/realms/<realm>/.well-known/openid-configuration` to return `200`
   (`sage` or `Organizations` depending on the flavor), runs
   `make configure-keycloak` (creates the EDC clients in the selected realm), and
   for the `sage` flavor also runs the entitlements Job.
3. **`cleanup:edc`** (stage `cleanup`, manual) — removes all SAGE resources.

---

## CI/CD variables

| Variable | Default | Purpose |
| --- | --- | --- |
| `KEYCLOAK_FLAVOR` | `sage` | Which Keycloak to use: `sage` or `psnc`. |
| `SATELLITE_ID` | `EU.EORI.PL12345678` | iShare satellite id (written to `ishare.json`). |
| `SATELLITE_URL` | `https://pr-middleware.62.3.175.232.nip.io/v2.0.1` | iShare satellite URL. |
| `ISHARE_CA_PEM` | — (**required** for `sage`, File-type) | iShare CA certificate chain (PEM). Mounted as `ca-file.pem`. |
| `SAGE_KC_ADMIN` | `tempadmin` | SAGE bootstrap admin username. |
| `SAGE_KC_ADMIN_PASSWORD` | `tempadmin` | SAGE bootstrap admin password. |

> For `KEYCLOAK_FLAVOR=psnc` the native Keycloak uses admin `admin` with
> `KEYCLOAK_ADMIN_PASSWORD`, and the `SATELLITE_*` / `ISHARE_CA_PEM` variables are
> ignored.

> The satellite values **will change** in future but are correct for the MVP.

---

## Operational notes & caveats

- **Ephemeral database.** Like the docker-compose setup, the Postgres deployment
  has no PersistentVolumeClaim — the pre-seeded snapshot is used as-is and the
  database is recreated on every restart. Keycloak re-imports the `sage` realm on
  each start (`--import-realm`). Add a PVC if persistence is required.
- **Postgres security context.** The manifest assumes the snapshot is based on
  the official `postgres` image (uid/gid `999`). If the EGI snapshot uses a
  different uid, adjust `runAsUser`/`fsGroup` in
  [k8s/sage-postgres.yaml](k8s/sage-postgres.yaml).
- **Dev mode.** Keycloak runs with `start-dev` (matching upstream compose). For a
  hardened production setup, switch to `start` with an optimized build and a
  persistent database.
- **Realm ownership.** `sage-realm.json` is provided by the SAGE team and may be
  re-sent; EDC clients are applied on top by the bootstrap and are not stored in
  that file.
