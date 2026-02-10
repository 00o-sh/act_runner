# act-runner-controller

KEDA-based autoscaler configuration for [act_runner](https://gitea.com/gitea/act_runner) scale sets on Kubernetes. Works with **Forgejo** and **Gitea**.

## Overview

This chart provides the **KEDA TriggerAuthentication** and **Secret** needed for job-aware autoscaling of runner pods. It does not deploy any pods itself — [KEDA](https://keda.sh) handles all scaling logic.

This chart installs:

- **Secret** — stores the Forgejo/Gitea API token (or references a pre-existing one)
- **TriggerAuthentication** — a KEDA resource that references the Secret, allowing ScaledObjects to authenticate against the Forgejo API

Install this chart **once per cluster** (or once per namespace if you prefer isolation), then install `act-runner-scale-set` with `keda.enabled=true` once per runner group.

## Prerequisites

1. **KEDA** must be installed in your cluster. See [KEDA deployment docs](https://keda.sh/docs/latest/deploy/).

   ```bash
   # Example: install KEDA via Helm
   helm repo add kedacore https://kedacore.github.io/charts
   helm repo update
   helm install keda kedacore/keda -n keda --create-namespace
   ```

2. **Forgejo/Gitea API token** with permission to list runner jobs:
   - **Forgejo admin**: requires a site-admin API token (reads `/api/v1/admin/runners/jobs`)
   - **Gitea admin**: requires a site-admin API token (reads `/api/v1/admin/actions/jobs`)
   - **Org scope**: requires an org-level API token (reads `/api/v1/orgs/{org}/actions/jobs`)

## How it works

```
                                    +-----------------+
                                    |   Forgejo/Gitea |
                                    |   REST API      |
                                    +--------+--------+
                                             |
                                    GET /api/v1/admin/runners/jobs?status=waiting
                                             |
                                    +--------v--------+
                                    |   KEDA Operator  |
                                    |   (metrics-api   |
                                    |    trigger)      |
                                    +--------+--------+
                                             |
                              Scales based on total_count of pending jobs
                                             |
                          +------------------v-------------------+
                          |  Runner Deployment / StatefulSet     |
                          |  (act-runner-scale-set chart)        |
                          |  Replicas: minRunners..maxRunners    |
                          +--------------------------------------+
```

1. The **act-runner-controller** chart creates a `TriggerAuthentication` that holds a reference to the Forgejo API token Secret.
2. The **act-runner-scale-set** chart (with `keda.enabled=true`) creates either a `ScaledObject` or `ScaledJob`, both using KEDA's [`metrics-api` trigger](https://keda.sh/docs/latest/scalers/metrics-api/) to query the Forgejo REST API for pending jobs.
3. KEDA reads the `total_count` field from the JSON response.
4. **ScaledObject** (persistent runners, `ephemeral=false`): scales the Deployment/StatefulSet between `minRunners` and `maxRunners`. Scales down after `cooldownPeriod`.
5. **ScaledJob** (ephemeral runners, `ephemeral=true`): creates one Kubernetes Job per pending workflow job. Each Job runs a single runner that registers, processes one job, and exits cleanly.

## Install

```bash
helm install act-runner-controller \
  oci://ghcr.io/00o-sh/act_runner/charts/act-runner-controller \
  --version 0.2.23 \
  -n act-runner-system --create-namespace \
  --set forgejo.url=https://forgejo.example.com \
  --set forgejo.apiToken=<your-api-token>
```

Or reference a pre-existing Secret:

```bash
# Create the secret manually (or via Sealed Secrets / External Secrets)
kubectl create secret generic forgejo-api-token \
  --from-literal=token=<your-api-token> \
  -n act-runner-system

helm install act-runner-controller \
  oci://ghcr.io/00o-sh/act_runner/charts/act-runner-controller \
  --version 0.2.23 \
  -n act-runner-system --create-namespace \
  --set forgejo.url=https://forgejo.example.com \
  --set forgejo.apiTokenSecret.name=forgejo-api-token
```

Then install runner scale sets with KEDA enabled:

```bash
helm install my-runners \
  oci://ghcr.io/00o-sh/act_runner/charts/act-runner-scale-set \
  --version 0.2.23 \
  -n act-runner-system \
  --set giteaConfigUrl=https://forgejo.example.com \
  --set giteaConfigSecret.token=<registration-token> \
  --set keda.enabled=true \
  --set keda.metricsUrl=https://forgejo.example.com/api/v1/admin/runners/jobs?status=waiting&limit=1 \
  --set keda.triggerAuthenticationRef=act-runner-controller-trigger-auth
```

## Values

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `forgejo.url` | string | `""` | **(required)** Forgejo/Gitea instance URL |
| `forgejo.apiToken` | string | `""` | API token — chart creates a Secret if set |
| `forgejo.apiTokenSecret.name` | string | `""` | Pre-existing Secret name (skips Secret creation) |
| `forgejo.apiTokenSecret.key` | string | `"token"` | Key inside the Secret holding the API token |
| `forgejo.scope` | string | `"admin"` | API scope: `admin` or `org` |
| `forgejo.org` | string | `""` | Organization name (when scope=org) |
| `triggerAuthentication.create` | bool | `true` | Create a KEDA TriggerAuthentication resource |
| `triggerAuthentication.name` | string | `""` | Override TriggerAuthentication name |
| `nameOverride` | string | `""` | Override chart name |
| `fullnameOverride` | string | `""` | Override full release name |
| `additionalLabels` | object | `{}` | Extra labels on all resources |
| `additionalAnnotations` | object | `{}` | Extra annotations on all resources |

## API token permissions

The API token needs permission to **list runner jobs**:

| Platform | Scope | Required Permission | API Endpoint |
|----------|-------|-------------------|--------------|
| Forgejo | `admin` | Site administrator | `GET /api/v1/admin/runners/jobs?status=waiting` |
| Gitea | `admin` | Site administrator | `GET /api/v1/admin/actions/jobs?status=waiting` |
| Both | `org` | Organization owner/admin | `GET /api/v1/orgs/{org}/actions/jobs?status=waiting` |

**Important:** The token must belong to a **site administrator** user account. The `read:admin` scope alone is not sufficient — the user itself must have admin privileges in Forgejo/Gitea.

### Creating the API token

**Option 1: Web UI**

1. Log in to Forgejo/Gitea as a **site administrator**
2. Go to **Settings** > **Applications** > **Manage Access Tokens**
3. Enter a name (e.g. `keda-scaler`)
4. Click **Select permissions** and check **`read:admin`**
5. Click **Generate Token** — copy the token (shown only once)

**Option 2: Server CLI** (recommended for automation)

```bash
# Create a dedicated service account (if it doesn't exist)
forgejo admin user create \
  --username arc-runner-svc \
  --password <strong-password> \
  --email arc-runner-svc@noreply.localhost \
  --admin

# Generate a scoped token
forgejo admin user generate-access-token \
  --username arc-runner-svc \
  --token-name keda-scaler \
  --scopes "read:admin" \
  --raw
```

For Gitea, replace `forgejo` with `gitea` in the commands above.

The `--raw` flag outputs only the token value, useful for piping into secrets:

```bash
TOKEN=$(forgejo admin user generate-access-token \
  --username arc-runner-svc \
  --token-name keda-scaler \
  --scopes "read:admin" \
  --raw)

kubectl create secret generic forgejo-api-token \
  --from-literal=token="$TOKEN" \
  -n act-runners
```

**Option 3: REST API** (bootstrap via basic auth)

```bash
curl -X POST "https://forgejo.example.com/api/v1/users/arc-runner-svc/tokens" \
  -H "Content-Type: application/json" \
  -u "arc-runner-svc:<password>" \
  -d '{"name":"keda-scaler","scopes":["read:admin"]}'
```

> **Note:** The `/users/:username/tokens` endpoint only accepts basic auth (username:password), not token auth — by design, since you need credentials to bootstrap a token.

### Available token scopes

| Scope | Description |
|-------|-------------|
| `read:admin` | Read-only access to admin endpoints (minimum for KEDA) |
| `write:admin` | Full admin access (implies read) |
| `read:organization` | Read org endpoints (for org-scoped scaling) |
| `all` | Full access to everything (not recommended) |

For org-scoped scaling (`forgejo.scope: org`), use `read:organization` instead of `read:admin`, and the user must be an organization owner/admin rather than a site admin.

## Architecture: why KEDA?

Previous versions of this chart deployed a custom bash-based controller pod. The KEDA approach is superior because:

- **No custom controller image** — eliminates a maintenance burden and potential security surface
- **Battle-tested scaling logic** — KEDA is a CNCF graduated project used in production by thousands of organizations
- **Rich ecosystem** — supports 60+ event sources, advanced scaling behaviors, and Prometheus metrics out of the box
- **Declarative** — scaling configuration is pure Kubernetes YAML, no imperative scripts
- **Observable** — KEDA exposes metrics to Prometheus and integrates with standard Kubernetes monitoring

## Namespace separation

Best practice is to install the controller config and runner scale sets in the same namespace (since TriggerAuthentication is namespace-scoped in KEDA):

```bash
# Controller config (TriggerAuthentication + Secret)
helm install act-runner-controller \
  oci://ghcr.io/00o-sh/act_runner/charts/act-runner-controller \
  --version 0.2.23 \
  -n act-runners --create-namespace \
  --set forgejo.url=https://forgejo.example.com \
  --set forgejo.apiToken=<token>

# Runners (same namespace for TriggerAuthentication access)
helm install my-runners \
  oci://ghcr.io/00o-sh/act_runner/charts/act-runner-scale-set \
  --version 0.2.23 \
  -n act-runners \
  --set giteaConfigUrl=https://forgejo.example.com \
  --set giteaConfigSecret.token=<registration-token> \
  --set keda.enabled=true \
  --set keda.metricsUrl=https://forgejo.example.com/api/v1/admin/runners/jobs?status=waiting&limit=1 \
  --set keda.triggerAuthenticationRef=act-runner-controller-trigger-auth
```

> **Note:** KEDA's `TriggerAuthentication` is namespace-scoped. If you need cross-namespace access, use `ClusterTriggerAuthentication` instead (not currently generated by this chart — contributions welcome).

## Upgrading

```bash
helm upgrade act-runner-controller \
  oci://ghcr.io/00o-sh/act_runner/charts/act-runner-controller \
  --version <new-version> \
  -n act-runners
```

## Troubleshooting

### KEDA not scaling

1. Verify KEDA is running:
   ```bash
   kubectl get pods -n keda
   ```

2. Check the ScaledObject status:
   ```bash
   kubectl get scaledobject -n act-runners
   kubectl describe scaledobject <name> -n act-runners
   ```

3. Check KEDA operator logs:
   ```bash
   kubectl logs -n keda -l app=keda-operator -f
   ```

4. Test the Forgejo API manually:
   ```bash
   # Forgejo
   curl -H "Authorization: token <your-token>" \
     https://forgejo.example.com/api/v1/admin/runners/jobs?status=waiting&limit=1

   # Gitea
   curl -H "Authorization: token <your-token>" \
     https://gitea.example.com/api/v1/admin/actions/jobs?status=waiting&limit=1
   ```
   Expected response includes `"total_count": <number>`.

### TriggerAuthentication not found

Ensure the controller chart and scale-set chart are in the **same namespace**, and that the `keda.triggerAuthenticationRef` value matches the TriggerAuthentication name.
