# act runner

Act runner is a runner for Gitea based on [Gitea fork](https://gitea.com/gitea/act) of [act](https://github.com/nektos/act).

> **Note:** This is a GitHub mirror/fork of [gitea.com/gitea/act_runner](https://gitea.com/gitea/act_runner).
> Upstream changes are synced automatically via the [sync-from-gitea](.github/workflows/sync-from-gitea.yml) workflow.

## Installation

### Prerequisites

Docker Engine Community version is required for docker mode. To install Docker CE, follow the official [install instructions](https://docs.docker.com/engine/install/).

### Download pre-built binary

Visit the [Releases](../../releases) page and download the right version for your platform.

### Build from source

```bash
make build
```

### Build a docker image

```bash
make docker
```

## Quickstart

Actions are disabled by default, so you need to add the following to the configuration file of your Gitea instance to enable it:

```ini
[actions]
ENABLED=true
```

### Register

```bash
./act_runner register
```

And you will be asked to input:

1. Gitea instance URL, like `http://192.168.8.8:3000/`. You should use your gitea instance ROOT_URL as the instance argument
 and you should not use `localhost` or `127.0.0.1` as instance IP;
2. Runner token, you can get it from `http://192.168.8.8:3000/admin/actions/runners`;
3. Runner name, you can just leave it blank;
4. Runner labels, you can just leave it blank.

The process looks like:

```text
INFO Registering runner, arch=amd64, os=darwin, version=0.1.5.
WARN Runner in user-mode.
INFO Enter the Gitea instance URL (for example, https://gitea.com/):
http://192.168.8.8:3000/
INFO Enter the runner token:
fe884e8027dc292970d4e0303fe82b14xxxxxxxx
INFO Enter the runner name (if set empty, use hostname: Test.local):

INFO Enter the runner labels, leave blank to use the default labels (comma-separated, for example, ubuntu-latest:docker://docker.gitea.com/runner-images:ubuntu-latest):

INFO Registering runner, name=Test.local, instance=http://192.168.8.8:3000/, labels=[ubuntu-latest:docker://docker.gitea.com/runner-images:ubuntu-latest ubuntu-22.04:docker://docker.gitea.com/runner-images:ubuntu-22.04 ubuntu-20.04:docker://docker.gitea.com/runner-images:ubuntu-20.04].
DEBU Successfully pinged the Gitea instance server
INFO Runner registered successfully.
```

You can also register with command line arguments.

```bash
./act_runner register --instance http://192.168.8.8:3000 --token <my_runner_token> --no-interactive
```

If the registry succeed, it will run immediately. Next time, you could run the runner directly.

### Run

```bash
./act_runner daemon
```

### Run with docker

```bash
docker run \
  -e GITEA_INSTANCE_URL=https://your_gitea.com \
  -e GITEA_RUNNER_REGISTRATION_TOKEN=<your_token> \
  -v /var/run/docker.sock:/var/run/docker.sock \
  --name my_runner \
  ghcr.io/00o-sh/act_runner:latest
```

### Configuration

You can also configure the runner with a configuration file.
The configuration file is a YAML file, you can generate a sample configuration file with `./act_runner generate-config`.

```bash
./act_runner generate-config > config.yaml
```

You can specify the configuration file path with `-c`/`--config` argument.

```bash
./act_runner -c config.yaml register # register with config file
./act_runner -c config.yaml daemon # run with config file
```

You can read the latest version of the configuration file online at [config.example.yaml](internal/pkg/config/config.example.yaml).

### Example Deployments

Check out the [examples](examples) directory for sample deployment types.

## Helm Charts

This repository includes Helm charts modeled after the [GitHub Actions Runner Controller (ARC)](https://docs.github.com/en/actions/hosting-your-own-runners/managing-self-hosted-runners-with-actions-runner-controller) pattern, with **job-aware autoscaling powered by [KEDA](https://keda.sh)**:

| Chart | Description | OCI Reference |
|-------|-------------|---------------|
| [act-runner-controller](charts/act-runner-controller/) | KEDA TriggerAuthentication + Forgejo API Secret | `oci://ghcr.io/00o-sh/act_runner/charts/act-runner-controller` |
| [act-runner-scale-set](charts/act-runner-scale-set/) | Runner pods + optional KEDA ScaledObject | `oci://ghcr.io/00o-sh/act_runner/charts/act-runner-scale-set` |

### Prerequisites

- **KEDA** installed in your cluster (for job-aware autoscaling): `helm install keda kedacore/keda -n keda --create-namespace`
- A **Forgejo/Gitea API token** with admin or org-level access to list action jobs

### Quick install (with KEDA autoscaling)

```bash
# 1. Install KEDA (if not already installed)
helm repo add kedacore https://kedacore.github.io/charts
helm install keda kedacore/keda -n keda --create-namespace

# 2. Install the controller chart (creates TriggerAuthentication + Secret)
helm install act-runner-controller \
  oci://ghcr.io/00o-sh/act_runner/charts/act-runner-controller \
  --version 0.2.20 \
  -n act-runners --create-namespace \
  --set forgejo.url=https://forgejo.example.com \
  --set forgejo.apiToken=<your-api-token>

# 3. Install a runner scale set with KEDA scaling enabled
helm install my-runners \
  oci://ghcr.io/00o-sh/act_runner/charts/act-runner-scale-set \
  --version 0.2.20 \
  -n act-runners \
  --set giteaConfigUrl=https://forgejo.example.com \
  --set giteaConfigSecret.token=<registration-token> \
  --set keda.enabled=true \
  --set keda.forgejoApiUrl=https://forgejo.example.com \
  --set keda.triggerAuthenticationRef=act-runner-controller-trigger-auth
```

This creates runners that automatically scale from `minRunners` (default: 1) to `maxRunners` (default: 10) based on the number of pending workflow jobs in Forgejo.

### Quick install (static replicas, no KEDA)

```bash
helm install my-runners \
  oci://ghcr.io/00o-sh/act_runner/charts/act-runner-scale-set \
  --version 0.2.20 \
  -n act-runners --create-namespace \
  --set giteaConfigUrl=https://forgejo.example.com \
  --set giteaConfigSecret.token=<registration-token> \
  --set replicas=3
```

### Container modes

The scale-set chart supports three container modes:

```bash
# Docker-in-Docker (privileged sidecar)
helm install dind-runners \
  oci://ghcr.io/00o-sh/act_runner/charts/act-runner-scale-set \
  --version 0.2.20 \
  -n act-runners \
  --set giteaConfigUrl=https://forgejo.example.com \
  --set giteaConfigSecret.token=<token> \
  --set containerMode.type=dind

# Docker-in-Docker rootless
helm install rootless-runners \
  oci://ghcr.io/00o-sh/act_runner/charts/act-runner-scale-set \
  --version 0.2.20 \
  -n act-runners \
  --set giteaConfigUrl=https://forgejo.example.com \
  --set giteaConfigSecret.token=<token> \
  --set containerMode.type=dind-rootless

# Host Docker socket
helm install socket-runners \
  oci://ghcr.io/00o-sh/act_runner/charts/act-runner-scale-set \
  --version 0.2.20 \
  -n act-runners \
  --set giteaConfigUrl=https://forgejo.example.com \
  --set giteaConfigSecret.token=<token> \
  --set hostDockerSocket.enabled=true
```

See each chart's [README](charts/) for full values documentation.
