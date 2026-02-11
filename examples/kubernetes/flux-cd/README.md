## Flux CD / GitOps Deployment

This example shows how to deploy `act_runner` on Kubernetes using [Flux CD](https://fluxcd.io/) and a GitOps workflow. Instead of running `helm install` commands manually, all configuration lives as declarative YAML in your Git repository and Flux reconciles it automatically.

This approach is based on a [production reference implementation](https://github.com/00o-sh/special-winner/tree/main/kubernetes/apps/forgejo-runner-system).

### Architecture

```
Git Repository
  └── kubernetes/apps/forgejo-runner-system/
        ├── namespace.yaml
        ├── kustomization.yaml
        ├── controller-secret.yaml          ─┐
        ├── controller-ocirepository.yaml    ├── KEDA TriggerAuth + API token
        ├── controller-helmrelease.yaml      ─┘
        ├── runner-secret.yaml               ─┐
        ├── runner-ocirepository.yaml        ├── Runner scale set + KEDA autoscaling
        └── runner-helmrelease.yaml          ─┘

Flux CD reconciles these manifests → Helm charts are pulled from OCI → Runners register with Forgejo
```

### Prerequisites

- A Kubernetes cluster with [Flux CD](https://fluxcd.io/flux/installation/) bootstrapped
- [KEDA](https://keda.sh) installed in the cluster (for job-aware autoscaling)
- A Forgejo/Gitea instance with Actions enabled
- A Forgejo API token (site admin) for KEDA scaling
- A runner registration token from the Forgejo admin panel

### How it works

1. **OCIRepository** resources tell Flux where to find the Helm charts in the OCI registry (`ghcr.io/00o-sh/act_runner/charts/`)
2. **HelmRelease** resources declare the Helm values — Flux installs and upgrades the charts automatically
3. **Secrets** hold the API token (for KEDA) and the runner registration token — these can be plain Secrets or managed via [External Secrets Operator](https://external-secrets.io/)
4. **Kustomization** ties everything together and sets the target namespace

### Files

| File | Description |
|------|-------------|
| [`namespace.yaml`](namespace.yaml) | Creates the `forgejo-runner-system` namespace |
| [`kustomization.yaml`](kustomization.yaml) | Kustomize entrypoint that bundles all resources |
| [`controller-secret.yaml`](controller-secret.yaml) | Forgejo API token Secret (or ExternalSecret template) |
| [`controller-ocirepository.yaml`](controller-ocirepository.yaml) | OCI source for the `act-runner-controller` Helm chart |
| [`controller-helmrelease.yaml`](controller-helmrelease.yaml) | HelmRelease for the controller (KEDA TriggerAuthentication) |
| [`runner-secret.yaml`](runner-secret.yaml) | Runner registration token Secret (or ExternalSecret template) |
| [`runner-ocirepository.yaml`](runner-ocirepository.yaml) | OCI source for the `act-runner-scale-set` Helm chart |
| [`runner-helmrelease.yaml`](runner-helmrelease.yaml) | HelmRelease for the runner scale set with KEDA + DinD |
| [`flux-kustomization.yaml`](flux-kustomization.yaml) | Optional Flux Kustomization CR for full GitOps reconciliation |

### Quick start

**Step 1:** Copy these files into your GitOps repository:

```bash
cp -r examples/kubernetes/flux-cd/ /path/to/your-gitops-repo/kubernetes/apps/forgejo-runner-system/
```

**Step 2:** Update the placeholder values:

- In `controller-helmrelease.yaml`: set `forgejo.url` to your Forgejo instance URL
- In `controller-secret.yaml`: set your base64-encoded API token (or configure ExternalSecret)
- In `runner-helmrelease.yaml`: set `giteaConfigUrl`, `keda.metricsUrl`, and `persistence.storageClass`
- In `runner-secret.yaml`: set your base64-encoded registration token (or configure ExternalSecret)

**Step 3:** Apply directly or let Flux reconcile from Git:

```bash
# Option A: Apply with kubectl (one-time)
kubectl apply -k examples/kubernetes/flux-cd/

# Option B: Commit to Git and let Flux reconcile (recommended)
# Adjust flux-kustomization.yaml to point to your repo path, then:
kubectl apply -f examples/kubernetes/flux-cd/flux-kustomization.yaml
```

**Step 4:** Verify the deployment:

```bash
# Check Flux reconciliation
flux get kustomizations -n flux-system
flux get helmreleases -n forgejo-runner-system

# Check runner pods
kubectl get pods -n forgejo-runner-system

# Check KEDA scaling
kubectl get scaledjob -n forgejo-runner-system
```

### Using External Secrets

For production deployments, avoid storing tokens in plain Kubernetes Secrets. The `controller-secret.yaml` and `runner-secret.yaml` files include commented-out `ExternalSecret` templates for use with the [External Secrets Operator](https://external-secrets.io/).

To use them:
1. Install External Secrets Operator in your cluster
2. Configure a `ClusterSecretStore` (e.g. for HashiCorp Vault, AWS Secrets Manager, 1Password, etc.)
3. Uncomment the `ExternalSecret` blocks and remove the plain `Secret` blocks
4. Update the `secretStoreRef.name` and `dataFrom[].extract.key` to match your secret store

### Customization

**Static replicas (no KEDA):** Remove the `keda` block from `runner-helmrelease.yaml` and set `replicas` instead:

```yaml
values:
  replicas: 3
  ephemeral: false
```

**Multiple runner groups:** Duplicate the runner files (`runner-*.yaml`) with different names and labels to create separate runner pools:

```yaml
# runner-arm64-helmrelease.yaml
metadata:
  name: forgejo-runner-arm64
spec:
  values:
    runnerLabels: "arm64:docker://node:20"
    nodeSelector:
      kubernetes.io/arch: arm64
```

**Rootless DinD:** Change `containerMode.type` in `runner-helmrelease.yaml`:

```yaml
containerMode:
  type: dind-rootless
```

### Upgrading chart versions

Update the `spec.ref.tag` in both OCIRepository files:

```yaml
# controller-ocirepository.yaml and runner-ocirepository.yaml
spec:
  ref:
    tag: 0.2.25   # new version
```

Commit and push — Flux will reconcile the new chart versions automatically.
