# act-runner-controller

Job-aware autoscaler for [act_runner](https://gitea.com/gitea/act_runner) scale sets on Kubernetes. Works with **Forgejo** and **Gitea**.

## Overview

The controller polls the Forgejo/Gitea REST API for pending jobs and automatically scales runner Deployments/StatefulSets created by the `act-runner-scale-set` chart.

This chart installs:

- **Controller Deployment** — a lightweight pod (alpine + curl + jq) running a reconciliation loop
- **ServiceAccount** with RBAC to list/scale Deployments and StatefulSets across namespaces
- **Secret** for the Forgejo API token (or reference a pre-existing one)

Install this chart **once per cluster**, then install `act-runner-scale-set` once per runner group.

## How it works

1. The controller discovers runner workloads by label: `app.kubernetes.io/managed-by: act-runner-controller`
2. Every `reconcileInterval` seconds (default: 30), it queries the Forgejo REST API for pending jobs
3. If jobs are waiting, it scales up runner replicas (up to the `act-runner/max-runners` annotation)
4. If runners are idle for `scaleDownDelay` seconds (default: 300), it scales down (to `act-runner/min-runners`)

## Install

```bash
helm install act-runner-controller \
  oci://ghcr.io/00o-sh/act_runner/charts/act-runner-controller \
  --version 0.2.18 \
  -n act-runner-system --create-namespace \
  --set forgejo.url=https://forgejo.example.com \
  --set forgejo.apiToken=<your-api-token>
```

Or reference a pre-existing Secret:

```bash
kubectl create secret generic forgejo-api-token \
  --from-literal=token=<your-api-token> \
  -n act-runner-system

helm install act-runner-controller \
  oci://ghcr.io/00o-sh/act_runner/charts/act-runner-controller \
  --version 0.2.18 \
  -n act-runner-system --create-namespace \
  --set forgejo.url=https://forgejo.example.com \
  --set forgejo.apiTokenSecret.name=forgejo-api-token
```

## Values

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `forgejo.url` | string | `""` | **(required)** Forgejo/Gitea instance URL |
| `forgejo.apiToken` | string | `""` | API token (chart creates Secret) |
| `forgejo.apiTokenSecret.name` | string | `""` | Pre-existing Secret name |
| `forgejo.apiTokenSecret.key` | string | `"token"` | Key in the Secret |
| `forgejo.scope` | string | `"admin"` | API scope: `admin` or `org` |
| `forgejo.org` | string | `""` | Organization name (when scope=org) |
| `reconcileInterval` | int | `30` | Seconds between reconciliation cycles |
| `scaleDownDelay` | int | `300` | Seconds of idle time before scaling down |
| `replicaCount` | int | `1` | Number of controller replicas |
| `image.repository` | string | `ghcr.io/00o-sh/act_runner` | Controller image |
| `image.tag` | string | `""` (appVersion-controller) | Image tag override |
| `image.pullPolicy` | string | `IfNotPresent` | Image pull policy |
| `serviceAccount.create` | bool | `true` | Create a ServiceAccount |
| `serviceAccount.name` | string | `""` | Override ServiceAccount name |
| `rbac.create` | bool | `true` | Create RBAC resources |
| `rbac.watchAllNamespaces` | bool | `true` | ClusterRole (true) or namespace-scoped Role (false) |
| `resources` | object | `{}` | CPU/memory requests and limits |
| `nodeSelector` | object | `{}` | Node selector constraints |
| `tolerations` | list | `[]` | Pod tolerations |
| `affinity` | object | `{}` | Pod affinity rules |

## API token permissions

The API token needs permission to list runners and jobs:

- **Admin scope** (`forgejo.scope: admin`): Requires a Forgejo admin API token. Uses `/api/v1/admin/actions/runners` and `/api/v1/admin/actions/jobs`.
- **Org scope** (`forgejo.scope: org`): Requires an org-level API token. Uses `/api/v1/orgs/{org}/actions/runners` and `/api/v1/orgs/{org}/actions/jobs`. Set `forgejo.org` to your organization name.

## Namespace separation

Best practice is to install the controller in its own namespace and runner scale sets in a separate namespace:

```bash
# Controller
helm install act-runner-controller \
  oci://ghcr.io/00o-sh/act_runner/charts/act-runner-controller \
  --version 0.2.18 \
  -n act-runner-system --create-namespace \
  --set forgejo.url=https://forgejo.example.com \
  --set forgejo.apiToken=<token>

# Runners
helm install my-runners \
  oci://ghcr.io/00o-sh/act_runner/charts/act-runner-scale-set \
  --version 0.2.18 \
  -n act-runners --create-namespace \
  --set giteaConfigUrl=https://forgejo.example.com \
  --set giteaConfigSecret.token=<registration-token>
```

## Upgrading

```bash
helm upgrade act-runner-controller \
  oci://ghcr.io/00o-sh/act_runner/charts/act-runner-controller \
  --version <new-version> \
  -n act-runner-system
```
