# act-runner-controller

Controller infrastructure for [act_runner](https://gitea.com/gitea/act_runner) scale sets on Kubernetes.

## Overview

This chart installs the shared infrastructure required by `act-runner-scale-set` installations:

- ServiceAccount with appropriate RBAC
- ClusterRole / Role for managing runner pods across namespaces
- Controller Deployment

Install this chart **once per cluster**, then install `act-runner-scale-set` once per runner group.

## Install

```bash
helm install act-runner-controller \
  oci://ghcr.io/00o-sh/act_runner/charts/act-runner-controller \
  --version 0.2.16 \
  -n act-runner-system --create-namespace
```

## Values

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `replicaCount` | int | `1` | Number of controller replicas |
| `image.repository` | string | `ghcr.io/00o-sh/act_runner` | Controller image |
| `image.tag` | string | `""` (appVersion) | Image tag override |
| `image.pullPolicy` | string | `IfNotPresent` | Image pull policy |
| `serviceAccount.create` | bool | `true` | Create a ServiceAccount |
| `serviceAccount.name` | string | `""` | Override ServiceAccount name |
| `serviceAccount.annotations` | object | `{}` | ServiceAccount annotations |
| `rbac.create` | bool | `true` | Create RBAC resources |
| `rbac.watchAllNamespaces` | bool | `true` | ClusterRole (true) or namespace-scoped Role (false) |
| `logLevel` | string | `info` | Log level: `debug`, `info`, `warn`, `error` |
| `logFormat` | string | `text` | Log format: `text`, `json` |
| `resources` | object | `{}` | CPU/memory resource requests and limits |
| `nodeSelector` | object | `{}` | Node selector constraints |
| `tolerations` | list | `[]` | Pod tolerations |
| `affinity` | object | `{}` | Pod affinity rules |
| `priorityClassName` | string | `""` | Pod priority class |
| `podAnnotations` | object | `{}` | Annotations added to pods |
| `podSecurityContext` | object | `{}` | Pod-level security context |
| `securityContext` | object | `{}` | Container-level security context |
| `additionalLabels` | object | `{}` | Extra labels on all resources |
| `additionalAnnotations` | object | `{}` | Extra annotations on all resources |
| `imagePullSecrets` | list | `[]` | Image pull secrets |

## Namespace separation

Best practice is to install the controller in its own namespace (`act-runner-system`) and runner scale sets in a separate namespace (`act-runners`):

```bash
# Controller
helm install act-runner-controller \
  oci://ghcr.io/00o-sh/act_runner/charts/act-runner-controller \
  --version 0.2.16 \
  -n act-runner-system --create-namespace

# Runners
helm install my-runners \
  oci://ghcr.io/00o-sh/act_runner/charts/act-runner-scale-set \
  --version 0.2.16 \
  -n act-runners --create-namespace \
  --set giteaConfigUrl=https://gitea.example.com \
  --set giteaConfigSecret.token=<token>
```

If you only want the controller to watch a single namespace, set:

```yaml
rbac:
  watchAllNamespaces: false
```

## Upgrading

```bash
helm upgrade act-runner-controller \
  oci://ghcr.io/00o-sh/act_runner/charts/act-runner-controller \
  --version <new-version> \
  -n act-runner-system
```
