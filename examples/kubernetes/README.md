## Kubernetes Deployments for `act_runner`

This directory contains examples for deploying `act_runner` on Kubernetes, ranging from simple manifests to full GitOps workflows.

### Raw Manifests (Docker in Docker)

> **Note:** Docker in Docker (dind) requires elevated privileges on Kubernetes. The current way to achieve this is to set the pod `SecurityContext` to `privileged`. Keep in mind that this is a potential security issue that has the potential for a malicious application to break out of the container context.

- [`dind-docker.yaml`](dind-docker.yaml)
  How to create a Deployment and Persistent Volume for Kubernetes to act as a runner. The Docker credentials are re-generated each time the pod connects and does not need to be persisted.

- [`rootless-docker.yaml`](rootless-docker.yaml)
  How to create a rootless Deployment and Persistent Volume for Kubernetes to act as a runner. The Docker credentials are re-generated each time the pod connects and does not need to be persisted.

### Flux CD / GitOps

- [`flux-cd/`](flux-cd/)
  A complete Flux CD deployment example using OCI-based HelmReleases for both the `act-runner-controller` (KEDA TriggerAuthentication) and `act-runner-scale-set` (runner pods with autoscaling). Includes templates for managing secrets via External Secrets Operator. See the [Flux CD README](flux-cd/README.md) for setup instructions.

### Helm Charts

For Helm-based deployments (with or without Flux), see the chart documentation:

- [`act-runner-controller`](../../charts/act-runner-controller/) — KEDA TriggerAuthentication and API token management
- [`act-runner-scale-set`](../../charts/act-runner-scale-set/) — Runner pods with static replicas, HPA, or KEDA autoscaling
