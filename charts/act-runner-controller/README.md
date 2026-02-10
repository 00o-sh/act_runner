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

2. **Forgejo/Gitea API token** with permission to list action jobs:
   - **Admin scope**: requires a site-admin API token (reads `/api/v1/admin/actions/jobs`)
   - **Org scope**: requires an org-level API token (reads `/api/v1/orgs/{org}/actions/jobs`)

## How it works

```
                                    +-----------------+
                                    |   Forgejo/Gitea |
                                    |   REST API      |
                                    +--------+--------+
                                             |
                                    GET /api/v1/admin/actions/jobs?status=waiting
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
  --version 0.2.19 \
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
  --version 0.2.19 \
  -n act-runner-system --create-namespace \
  --set forgejo.url=https://forgejo.example.com \
  --set forgejo.apiTokenSecret.name=forgejo-api-token
```

Then install runner scale sets with KEDA enabled:

```bash
helm install my-runners \
  oci://ghcr.io/00o-sh/act_runner/charts/act-runner-scale-set \
  --version 0.2.19 \
  -n act-runner-system \
  --set giteaConfigUrl=https://forgejo.example.com \
  --set giteaConfigSecret.token=<registration-token> \
  --set keda.enabled=true \
  --set keda.forgejoApiUrl=https://forgejo.example.com \
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

The API token needs permission to **list action jobs**:

| Scope | Required Permission | API Endpoint |
|-------|-------------------|--------------|
| `admin` | Site administrator | `GET /api/v1/admin/actions/jobs?status=waiting` |
| `org` | Organization owner/admin | `GET /api/v1/orgs/{org}/actions/jobs?status=waiting` |

To create an admin API token in Forgejo:
1. Go to **Site Administration** > **User Accounts** > select your admin user
2. Go to **Applications** > **Generate New Token**
3. Grant at least `read:admin` scope

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
  --version 0.2.19 \
  -n act-runners --create-namespace \
  --set forgejo.url=https://forgejo.example.com \
  --set forgejo.apiToken=<token>

# Runners (same namespace for TriggerAuthentication access)
helm install my-runners \
  oci://ghcr.io/00o-sh/act_runner/charts/act-runner-scale-set \
  --version 0.2.19 \
  -n act-runners \
  --set giteaConfigUrl=https://forgejo.example.com \
  --set giteaConfigSecret.token=<registration-token> \
  --set keda.enabled=true \
  --set keda.forgejoApiUrl=https://forgejo.example.com \
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
   curl -H "Authorization: token <your-token>" \
     https://forgejo.example.com/api/v1/admin/actions/jobs?status=waiting&limit=1
   ```
   Expected response includes `"total_count": <number>`.

### TriggerAuthentication not found

Ensure the controller chart and scale-set chart are in the **same namespace**, and that the `keda.triggerAuthenticationRef` value matches the TriggerAuthentication name.
