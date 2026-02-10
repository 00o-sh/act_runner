# act-runner-scale-set

A configurable [act_runner](https://gitea.com/gitea/act_runner) scale set for Forgejo/Gitea Actions on Kubernetes.

## Overview

Each installation of this chart creates one runner scale set — a group of runner pods that register with your Forgejo/Gitea instance and pick up workflow jobs. Multiple installations can coexist in the same namespace with different labels, capacity, or container modes.

**Prerequisites:**
- Install [`act-runner-controller`](../act-runner-controller/) first (provides KEDA TriggerAuthentication)
- [KEDA](https://keda.sh) must be installed for job-aware autoscaling

## Install

### Basic (static replicas)

```bash
helm install my-runners \
  oci://ghcr.io/00o-sh/act_runner/charts/act-runner-scale-set \
  --version 0.2.22 \
  -n act-runners --create-namespace \
  --set giteaConfigUrl=https://forgejo.example.com \
  --set giteaConfigSecret.token=<registration-token>
```

### With KEDA job-aware autoscaling (recommended)

```bash
# First: install the controller chart for TriggerAuthentication
helm install act-runner-controller \
  oci://ghcr.io/00o-sh/act_runner/charts/act-runner-controller \
  --version 0.2.22 \
  -n act-runners --create-namespace \
  --set forgejo.url=https://forgejo.example.com \
  --set forgejo.apiToken=<api-token>

# Then: install the scale set with KEDA enabled
helm install my-runners \
  oci://ghcr.io/00o-sh/act_runner/charts/act-runner-scale-set \
  --version 0.2.22 \
  -n act-runners \
  --set giteaConfigUrl=https://forgejo.example.com \
  --set giteaConfigSecret.token=<registration-token> \
  --set keda.enabled=true \
  --set "keda.metricsUrl=https://forgejo.example.com/api/v1/admin/runners/jobs?status=waiting&limit=1" \
  --set keda.triggerAuthenticationRef=act-runner-controller-trigger-auth
```

### With KEDA ephemeral runners (ScaledJob)

For ephemeral runners (one job per pod), KEDA creates a Kubernetes **ScaledJob** instead of scaling a Deployment. Each pending Forgejo workflow job spawns a fresh runner pod that registers, runs the job, and exits cleanly.

```bash
helm install my-runners \
  oci://ghcr.io/00o-sh/act_runner/charts/act-runner-scale-set \
  --version 0.2.22 \
  -n act-runners \
  --set giteaConfigUrl=https://forgejo.example.com \
  --set giteaConfigSecret.token=<registration-token> \
  --set ephemeral=true \
  --set keda.enabled=true \
  --set "keda.metricsUrl=https://forgejo.example.com/api/v1/admin/runners/jobs?status=waiting&limit=1" \
  --set keda.triggerAuthenticationRef=act-runner-controller-trigger-auth
```

### KEDA scaling modes

| Mode | Condition | Behavior |
|------|-----------|----------|
| **ScaledObject** | `keda.enabled=true`, `ephemeral=false` | Scales Deployment/StatefulSet replicas between `minRunners` and `maxRunners`. Runners are long-lived and process multiple jobs. Scales down after `cooldownPeriod`. |
| **ScaledJob** | `keda.enabled=true`, `ephemeral=true` | Creates one Kubernetes Job per pending workflow job. Each runner pod registers, runs one job, and exits. No Deployment is created. Jobs are cleaned up after `ttlSecondsAfterFinished`. |

## Container modes

| Mode | `containerMode.type` | Description |
|------|---------------------|-------------|
| **Basic** | `""` (default) | Runner only. Mount host Docker socket or run without Docker. |
| **DinD** | `"dind"` | Runner + Docker-in-Docker sidecar. Requires `privileged: true`. |
| **DinD Rootless** | `"dind-rootless"` | Rootless Docker-in-Docker embedded in the runner image. |

### DinD example

```bash
helm install dind-runners \
  oci://ghcr.io/00o-sh/act_runner/charts/act-runner-scale-set \
  --version 0.2.22 \
  -n act-runners \
  --set giteaConfigUrl=https://forgejo.example.com \
  --set giteaConfigSecret.token=<token> \
  --set containerMode.type=dind
```

### Host Docker socket example

```bash
helm install socket-runners \
  oci://ghcr.io/00o-sh/act_runner/charts/act-runner-scale-set \
  --version 0.2.22 \
  -n act-runners \
  --set giteaConfigUrl=https://forgejo.example.com \
  --set giteaConfigSecret.token=<token> \
  --set hostDockerSocket.enabled=true
```

## Values

### Required

| Key | Type | Description |
|-----|------|-------------|
| `giteaConfigUrl` | string | Forgejo/Gitea instance URL (e.g. `https://forgejo.example.com`) |
| `giteaConfigSecret.token` | string | Registration token from admin panel |

Or reference a pre-existing Secret:

| Key | Type | Description |
|-----|------|-------------|
| `giteaConfigSecret.name` | string | Name of existing Secret (must contain key `token`) |

### Runner

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `runnerScaleSetName` | string | Release name | Runner name prefix / `runs-on` label |
| `runnerLabels` | string | `""` | Comma-separated runner labels (e.g. `ubuntu-latest:docker://node:20`) |
| `replicas` | int | `1` | Number of runner replicas (ignored when KEDA or HPA is enabled) |
| `ephemeral` | bool | `false` | Runner exits after one job |
| `runnerConfig` | string | `""` | Inline runner config YAML (see `act_runner generate-config`) |

### Image

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `image.repository` | string | `ghcr.io/00o-sh/act_runner` | Runner image |
| `image.tag` | string | `""` (appVersion + mode suffix) | Image tag override |
| `image.pullPolicy` | string | `IfNotPresent` | Pull policy |
| `imagePullSecrets` | list | `[]` | Image pull secrets |

### Container mode

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `containerMode.type` | string | `""` | `"dind"`, `"dind-rootless"`, or `""` |
| `containerMode.dindImage` | string | `docker:28-dind` | DinD sidecar image |
| `containerMode.dindRootlessImage` | string | `docker:28-dind-rootless` | Rootless DinD image |
| `hostDockerSocket.enabled` | bool | `false` | Mount host Docker socket (basic mode only) |
| `hostDockerSocket.path` | string | `/var/run/docker.sock` | Host socket path |

### KEDA autoscaling (job-aware)

KEDA-based autoscaling scales runners based on the number of pending Forgejo/Gitea workflow jobs. This requires [KEDA](https://keda.sh) to be installed and the `act-runner-controller` chart to provide a `TriggerAuthentication`.

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `keda.enabled` | bool | `false` | Enable KEDA for job-aware scaling (ScaledObject or ScaledJob) |
| `keda.triggerAuthenticationRef` | string | `""` | Name of TriggerAuthentication (from controller chart) |
| `keda.metricsUrl` | string | `""` | Full URL to jobs API endpoint (see examples below) |
| `keda.valueLocation` | string | `"total_count"` | JSON path in API response holding pending job count |
| `keda.pollingInterval` | int | `30` | Seconds between KEDA polling cycles |
| `keda.cooldownPeriod` | int | `300` | Seconds of idle before scaling to minRunners (ScaledObject only) |
| `keda.unsafeSsl` | bool | `false` | Skip TLS verification (not for production) |
| `keda.scaledJob.ttlSecondsAfterFinished` | int | `300` | Cleanup delay for completed Jobs (ScaledJob only) |
| `keda.scaledJob.successfulJobsHistoryLimit` | int | `5` | Successful Jobs to retain (ScaledJob only) |
| `keda.scaledJob.failedJobsHistoryLimit` | int | `5` | Failed Jobs to retain (ScaledJob only) |
| `keda.scaledJob.scalingStrategy` | string | `""` | KEDA scaling strategy: `default`, `accurate`, or `custom` (ScaledJob only) |
| `minRunners` | int | `1` | Minimum runner replicas (ScaledObject) or Jobs (ScaledJob) |
| `maxRunners` | int | `10` | Maximum runner replicas (ScaledObject) or Jobs (ScaledJob) |

**`keda.metricsUrl` examples:**

| Platform | Scope | URL |
|----------|-------|-----|
| Forgejo | admin | `https://forgejo.example.com/api/v1/admin/runners/jobs?status=waiting&limit=1` |
| Gitea | admin | `https://gitea.example.com/api/v1/admin/actions/jobs?status=waiting&limit=1` |
| Both | org | `https://forgejo.example.com/api/v1/orgs/my-org/actions/jobs?status=waiting&limit=1` |

### HPA autoscaling (CPU/memory-based)

Use this as a fallback when KEDA is not available. Not recommended for job-aware scaling.

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `autoscaling.enabled` | bool | `false` | Enable HPA (CPU/memory-based) |
| `autoscaling.minReplicas` | int | `1` | Minimum replicas (HPA) |
| `autoscaling.maxReplicas` | int | `10` | Maximum replicas (HPA) |
| `autoscaling.targetCPUUtilizationPercentage` | int | `80` | CPU target for scaling (HPA) |

### Storage

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `persistence.enabled` | bool | `true` | Use PVC (StatefulSet) vs emptyDir (Deployment) |
| `persistence.storageClass` | string | `""` | Storage class |
| `persistence.accessMode` | string | `ReadWriteOnce` | PVC access mode |
| `persistence.size` | string | `1Gi` | PVC size |

### Pod scheduling

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `resources` | object | `{}` | CPU/memory requests and limits |
| `nodeSelector` | object | `{}` | Node selector constraints |
| `tolerations` | list | `[]` | Pod tolerations |
| `affinity` | object | `{}` | Pod affinity rules |
| `priorityClassName` | string | `""` | Pod priority class |

### Network / TLS

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `proxy.http` | string | `""` | HTTP proxy |
| `proxy.https` | string | `""` | HTTPS proxy |
| `proxy.noProxy` | string | `""` | No-proxy list |
| `giteaServerTLS.certificateFrom.configMapRef.name` | string | `""` | ConfigMap with CA cert |
| `giteaServerTLS.certificateFrom.configMapRef.key` | string | `ca.crt` | Key in the ConfigMap |

### Extensibility

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `extraEnv` | list | `[]` | Extra environment variables |
| `extraVolumeMounts` | list | `[]` | Extra volume mounts |
| `extraVolumes` | list | `[]` | Extra volumes |
| `serviceAccount.create` | bool | `true` | Create ServiceAccount |
| `serviceAccount.name` | string | `""` | ServiceAccount name override |
| `serviceAccount.annotations` | object | `{}` | ServiceAccount annotations |
| `podAnnotations` | object | `{}` | Pod annotations |
| `podSecurityContext` | object | `{}` | Pod security context |
| `securityContext` | object | `{}` | Container security context |
| `additionalLabels` | object | `{}` | Extra labels on all resources |
| `additionalAnnotations` | object | `{}` | Extra annotations on all resources |

## Custom runner config

Pass a full runner config inline:

```yaml
runnerConfig: |
  log:
    level: info
  runner:
    capacity: 1
    timeout: 3h
  container:
    network: ""
    privileged: false
```

Or generate the default and customize:

```bash
act_runner generate-config > config.yaml
# edit config.yaml
helm install my-runners ... --set-file runnerConfig=config.yaml
```

## Using a pre-existing secret

If you manage secrets externally (e.g. via Sealed Secrets or External Secrets):

```bash
kubectl create secret generic my-runner-token \
  -n act-runners \
  --from-literal=token=<registration-token>

helm install my-runners \
  oci://ghcr.io/00o-sh/act_runner/charts/act-runner-scale-set \
  --version 0.2.22 \
  -n act-runners \
  --set giteaConfigUrl=https://forgejo.example.com \
  --set giteaConfigSecret.name=my-runner-token
```

## Upgrading

```bash
helm upgrade my-runners \
  oci://ghcr.io/00o-sh/act_runner/charts/act-runner-scale-set \
  --version <new-version> \
  -n act-runners
```

## Uninstalling

```bash
helm uninstall my-runners -n act-runners
```

Runner pods will be terminated and de-registered from Forgejo/Gitea on shutdown.
