# Forgejo Runner Scale Sets: Achieving GitHub ARC-like Auto-Scaling

## Executive Summary

This document lays out how to replicate GitHub Actions Runner Controller (ARC) / Runner Scale Sets functionality for Forgejo. The goal: a **controller** that watches for pending CI/CD jobs and dynamically creates/destroys **ephemeral runner pods** in Kubernetes, scaling from zero to N and back.

This repo already contains a working foundation (bash-based controller + Helm charts). This plan identifies the gaps relative to GitHub ARC and proposes concrete improvements.

---

## 1. What GitHub ARC Provides (The Target)

GitHub ARC consists of:

| Component | Role |
|-----------|------|
| **Controller Manager** | Kubernetes operator (Go binary) running reconciliation loops for 4 CRDs |
| **AutoScalingRunnerSet** CRD | Top-level resource defining a runner pool (name, GitHub scope, min/max, pod template) |
| **Listener Pod** | Long-lived pod that maintains an HTTPS long-poll session with GitHub's Actions Service; receives push notifications when jobs are queued |
| **EphemeralRunnerSet** CRD | ReplicaSet-like resource; Listener patches its `replicas` field to trigger scaling |
| **EphemeralRunner** CRD | Represents a single runner; controller requests JIT (Just-in-Time) tokens, creates pods, monitors lifecycle |
| **Runner Pods** | Ephemeral pods that register with JIT token, execute exactly one job, then get deleted |

**Key ARC properties:**
- **Push-based scaling**: GitHub pushes `JobAvailable` messages to the Listener via a message session (HTTPS long-poll with ~50s hold). No polling of a REST API.
- **Scale-from-zero**: Listener pod is always running (cheap), runner pods scale 0-N.
- **JIT registration**: Runner pods get single-use tokens. The GitHub PAT never touches runner pods.
- **Per-job pods**: Each job gets a fresh pod. No state contamination.
- **CRD-driven**: Full Kubernetes-native operator with reconciliation loops.

---

## 2. What Forgejo Provides (The Constraints)

### What exists

| Capability | Status | Details |
|------------|--------|---------|
| Runner protocol | ConnectRPC (gRPC over HTTP) | `Register`, `Declare`, `FetchTask`, `UpdateTask`, `UpdateLog` RPCs via `/api/actions` |
| `--ephemeral` flag | Supported | Runner registers as single-use, executes one job, exits |
| `--once` flag | Supported | Runner executes one job and exits (less strict than ephemeral) |
| Pending jobs API | Available (v11.0+) | `GET /api/v1/admin/actions/jobs?status=waiting` |
| Registration token API | Available (v1.22+) | `GET /api/v1/repos/{owner}/{repo}/runners/registration-token` |
| Offline registration | Available | `forgejo-cli actions register --secret <secret>` |
| KEDA scaler | Merged upstream | `forgejo-runner` trigger in KEDA polls pending jobs |

### What does NOT exist

| Missing Feature | Impact |
|-----------------|--------|
| **Job-queued webhook/event** | No push notification when a job is queued. Must poll. |
| **Message session / long-poll API** | No equivalent to GitHub's `GetMessage()` long-poll endpoint |
| **JIT runner tokens** | No API to generate single-use registration tokens programmatically for a specific job |
| **Job-to-runner assignment API** | No way to pre-assign a specific job to a specific runner |
| **Native Kubernetes operator** | No official CRD-based operator |

### The fundamental difference

GitHub ARC uses a **push model**: GitHub tells the controller "a job is waiting" via a persistent message session. Forgejo requires a **poll model**: the controller must periodically ask "are there pending jobs?"

This means Forgejo scaling will always have slightly higher latency than ARC (polling interval vs near-instant push), but with a 5-10s poll interval this is acceptable for most workloads.

---

## 3. Current State of This Repo

This repo already implements a two-chart architecture:

### `act-runner-controller` (Helm chart)
- **Implementation**: Bash script (`scripts/controller.sh`) running in Alpine container
- **Polling**: Queries `GET /api/v1/admin/actions/jobs?status=waiting` every 30s
- **Discovery**: Finds runner workloads by label `app.kubernetes.io/managed-by=act-runner-controller`
- **Scaling**: Patches `Deployment/scale` or `StatefulSet/scale` subresource
- **Scale-down**: Graceful, 1 replica per cycle after configurable idle cooldown (300s default)
- **Bounds**: Reads `act-runner/min-runners` and `act-runner/max-runners` annotations

### `act-runner-scale-set` (Helm chart)
- **Workload**: StatefulSet (with PVC) or Deployment (emptyDir)
- **Registration**: Automatic via `run.sh` with environment variables
- **Container modes**: Basic (host socket), DinD sidecar, DinD-rootless
- **Ephemeral support**: `GITEA_RUNNER_EPHEMERAL=true` environment variable

### Gaps vs. GitHub ARC

| ARC Feature | Current Status | Gap |
|-------------|---------------|-----|
| Push-based scaling | Polling every 30s | Medium (acceptable, could reduce interval) |
| CRD-driven operator | Bash script | Large (no reconciliation, no status, no events) |
| Per-job pods | Long-lived StatefulSet/Deployment | Large (pods reuse runners, not truly ephemeral) |
| JIT token isolation | Runner gets registration token | Medium (token reuse across pod restarts) |
| Listener component | Controller polls API | Medium (functionally equivalent but less efficient) |
| Scale-from-zero | Supported via minRunners=0 | Small (works, but scale-up latency is 30s + pod startup) |
| Job-label routing | All pending jobs counted globally | Medium (no per-label-set scaling) |
| Failure retry | No retry logic | Medium (failed pods not retried) |

---

## 4. Architecture Plan

### Option A: Enhanced Bash Controller (Incremental)

Improve the existing bash-based controller to close the most impactful gaps.

**Pros**: Minimal development effort, builds on working foundation.
**Cons**: Bash has limits for complex state management, no CRDs, harder to test.

### Option B: Go Kubernetes Operator (Full Rewrite)

Build a proper Kubernetes operator in Go with CRDs, mimicking ARC's architecture.

**Pros**: Full ARC parity, Kubernetes-native, testable, extensible.
**Cons**: Significant development effort, requires operator-sdk or controller-runtime expertise.

### Option C: KEDA + Ephemeral Jobs (External Tooling)

Use KEDA's `ScaledJob` with the `forgejo-runner` trigger. KEDA handles all scaling logic.

**Pros**: Minimal custom code, mature scaling framework, community-maintained.
**Cons**: External dependency (KEDA), less control over scaling logic, KEDA ScaledJob has its own quirks.

### Recommendation: Option A first, then Option B

Start with **Option A** to get immediate value from the existing foundation, then evolve toward **Option B** as complexity requirements grow. Option C is a good alternative if you want to minimize custom code.

---

## 5. Detailed Design: Option A (Enhanced Controller)

### 5.1 Per-Label-Set Scaling

**Problem**: The current controller counts all pending jobs globally and scales all runner workloads equally. A `gpu-runner` scale set shouldn't scale up because `ubuntu-latest` jobs are pending.

**Solution**: Match pending jobs to runner scale sets by label.

```
For each runner scale set:
  1. Read its labels from annotation: act-runner/labels
  2. Query pending jobs: GET /api/v1/admin/actions/jobs?status=waiting
  3. Filter: count only jobs whose `runs-on` matches the scale set's labels
  4. Scale the workload based on matched pending count
```

**API limitation**: The Forgejo API may not expose `runs-on` in the job list response. If not, two fallbacks:
- Query individual job details to get the `runs-on` field
- Track active runners per scale set and distribute pending jobs proportionally

### 5.2 True Ephemeral Pods (Job-Based Scaling)

**Problem**: Current approach scales a Deployment/StatefulSet. Pods are long-lived and reuse runners. Not truly one-pod-per-job.

**Solution**: Switch from scaling a Deployment to creating individual Kubernetes Jobs.

```yaml
apiVersion: batch/v1
kind: Job
metadata:
  name: runner-<job-id>-<random>
  labels:
    app.kubernetes.io/managed-by: act-runner-controller
    act-runner/scale-set: my-runners
spec:
  ttlSecondsAfterFinished: 60
  backoffLimit: 3
  template:
    spec:
      restartPolicy: Never
      containers:
      - name: runner
        image: ghcr.io/00o-sh/act_runner:latest
        env:
        - name: GITEA_INSTANCE_URL
          value: "https://forgejo.example.com"
        - name: GITEA_RUNNER_REGISTRATION_TOKEN
          valueFrom:
            secretKeyRef: ...
        - name: GITEA_RUNNER_EPHEMERAL
          value: "true"
```

**Benefits**:
- Each job gets a fresh pod (true ephemeral)
- Kubernetes handles retry logic via `backoffLimit`
- `ttlSecondsAfterFinished` auto-cleans completed pods
- Pod count = active job count (natural scaling)

**Controller logic changes**:
```
each cycle:
  pending = count_pending_jobs()
  active_runners = count_running_job_pods(label=act-runner/scale-set)
  needed = pending - active_runners  # may be negative (scale down is automatic)

  if needed > 0:
    for i in range(min(needed, max_runners - active_runners)):
      create_kubernetes_job()

  # Scale-down is automatic: ephemeral runners finish and Jobs complete
  # ttlSecondsAfterFinished handles cleanup
```

### 5.3 Faster Polling / Hybrid Polling

**Problem**: 30s polling interval means up to 30s latency before scaling starts.

**Solutions** (choose one or combine):

1. **Reduce poll interval to 5-10s**: Simple, slightly more API load
2. **Adaptive polling**: Poll every 5s when pending > 0, every 30s when idle
3. **ConnectRPC long-poll**: Instead of the REST API, use the runner's `FetchTask` RPC with a longer timeout. The `tasksVersion` mechanism already provides change detection - if version hasn't changed, no new tasks exist. This is more efficient than REST polling.
4. **Forgejo webhook (future)**: If Forgejo adds a `workflow_job.queued` webhook event, the controller could expose an HTTP endpoint to receive push notifications.

**Recommended**: Adaptive polling (option 2) as immediate improvement.

```bash
if [ "$PENDING_JOBS" -gt 0 ]; then
  NEXT_INTERVAL=5
else
  NEXT_INTERVAL=$RECONCILE_INTERVAL  # 30s default
fi
```

### 5.4 Registration Token Isolation

**Problem**: All runner pods in a scale set share the same registration token. If a pod is compromised, the token can register rogue runners.

**Solution**: Generate per-pod registration tokens.

```
For each new runner pod:
  1. Controller calls: GET /api/v1/admin/runners/registration-token
  2. Create a per-pod Secret with the token
  3. Mount it in the pod
  4. Runner uses it to register (ephemeral, single-use)
  5. Delete the Secret after pod completes
```

This mimics ARC's JIT token model, though not as granular (ARC's JIT tokens are scoped to a single runner registration, not a reusable registration token).

### 5.5 Health and Observability

**Additions to the controller**:
- Expose Prometheus metrics endpoint (pending jobs, active runners, scale events)
- Emit Kubernetes Events on scale-up/scale-down
- Log structured JSON for easier parsing
- Add readiness probe (not just liveness)

---

## 6. Detailed Design: Option B (Go Operator)

For when complexity outgrows bash. This is the ARC-equivalent architecture.

### 6.1 Custom Resource Definitions

```yaml
# RunnerScaleSet - top-level resource (analogous to ARC's AutoScalingRunnerSet)
apiVersion: actions.forgejo.org/v1alpha1
kind: RunnerScaleSet
metadata:
  name: ubuntu-runners
spec:
  forgejoInstance: https://forgejo.example.com
  authSecretRef:
    name: forgejo-api-token
  scope: organization  # or "repository", "global"
  organization: my-org
  labels:
    - "ubuntu-latest:docker://node:20"
    - "ubuntu-22.04:docker://ubuntu:22.04"
  minRunners: 0
  maxRunners: 20
  pollInterval: 10s
  scaleDownDelay: 5m
  template:
    spec:
      containers:
      - name: runner
        image: ghcr.io/00o-sh/act_runner:latest
        resources:
          requests:
            cpu: 500m
            memory: 512Mi
status:
  currentRunners: 3
  pendingJobs: 5
  lastScaleTime: "2026-02-10T12:00:00Z"
  conditions:
  - type: Ready
    status: "True"

---
# EphemeralRunner - individual runner lifecycle (analogous to ARC's EphemeralRunner)
apiVersion: actions.forgejo.org/v1alpha1
kind: EphemeralRunner
metadata:
  name: ubuntu-runners-abc123
  ownerReferences:
  - apiVersion: actions.forgejo.org/v1alpha1
    kind: RunnerScaleSet
    name: ubuntu-runners
spec:
  scaleSetRef: ubuntu-runners
status:
  phase: Running  # Pending, Registering, Running, Completed, Failed
  podName: ubuntu-runners-abc123-pod
  startedAt: "2026-02-10T12:00:05Z"
  retryCount: 0
```

### 6.2 Controller Reconciliation Loops

```
RunnerScaleSet Controller:
  Watch: RunnerScaleSet resources
  Reconcile:
    1. Validate Forgejo connectivity (Ping RPC)
    2. Ensure registration token Secret exists
    3. Start/update Poller goroutine for this scale set
    4. Update status with current runner count and pending jobs

Poller (per RunnerScaleSet):
  Loop:
    1. GET /api/v1/admin/actions/jobs?status=waiting
    2. Filter jobs matching this scale set's labels
    3. Count active EphemeralRunner resources for this scale set
    4. Calculate desired = max(minRunners, min(maxRunners, pending))
    5. If desired > current: Create new EphemeralRunner resources
    6. If desired < current (after cooldown): Delete idle EphemeralRunner resources
    7. Update RunnerScaleSet status

EphemeralRunner Controller:
  Watch: EphemeralRunner resources + owned Pods
  Reconcile:
    1. If no Pod exists: Generate registration token, create Pod
    2. If Pod is Running: Monitor for completion
    3. If Pod Succeeded: Mark EphemeralRunner as Completed, delete
    4. If Pod Failed: Increment retryCount, recreate if < maxRetries (5)
    5. If Pod Failed maxRetries times: Mark as Failed, alert
```

### 6.3 Technology Stack

| Component | Choice | Rationale |
|-----------|--------|-----------|
| Operator framework | controller-runtime (kubebuilder) | Industry standard, same as ARC |
| CRD generation | controller-gen | Standard code generation |
| Forgejo client | ConnectRPC (reuse `internal/pkg/client`) | Already implemented in this repo |
| Helm charts | Refactor existing | Preserve backward compatibility |
| Testing | envtest + fake client | Standard k8s testing patterns |

### 6.4 Project Structure

```
/
├── cmd/
│   └── controller/
│       └── main.go                    # Controller entrypoint
├── api/
│   └── v1alpha1/
│       ├── runnerscaleset_types.go    # CRD type definitions
│       ├── ephemeralrunner_types.go
│       ├── groupversion_info.go
│       └── zz_generated.deepcopy.go
├── internal/
│   ├── controller/
│   │   ├── runnerscaleset_controller.go
│   │   ├── ephemeralrunner_controller.go
│   │   └── poller.go                  # Job polling logic
│   ├── forgejo/
│   │   ├── client.go                  # Forgejo API client
│   │   └── jobs.go                    # Job listing/filtering
│   └── metrics/
│       └── metrics.go                 # Prometheus metrics
├── config/
│   ├── crd/                           # Generated CRD manifests
│   ├── rbac/                          # RBAC manifests
│   └── manager/                       # Controller manager manifests
├── charts/
│   ├── act-runner-controller/         # Refactored Helm chart
│   └── act-runner-scale-set/          # Refactored Helm chart
└── Dockerfile                         # Multi-stage with controller target
```

---

## 7. Detailed Design: Option C (KEDA-Based)

Offload all scaling logic to KEDA.

### 7.1 Architecture

```
┌──────────────┐    polls    ┌──────────────┐
│    KEDA       │ ────────→  │   Forgejo     │
│  (operator)   │            │   REST API    │
└──────┬───────┘            └──────────────┘
       │ creates/deletes
       ▼
┌──────────────┐
│  K8s Jobs     │  ← one Job per CI job
│  (runners)    │
└──────────────┘
```

### 7.2 KEDA ScaledJob Manifest

```yaml
apiVersion: keda.sh/v1alpha1
kind: ScaledJob
metadata:
  name: forgejo-runner
spec:
  jobTargetRef:
    parallelism: 1
    completions: 1
    backoffLimit: 3
    ttlSecondsAfterFinished: 60
    template:
      spec:
        restartPolicy: Never
        containers:
        - name: runner
          image: ghcr.io/00o-sh/act_runner:latest
          env:
          - name: GITEA_INSTANCE_URL
            value: "https://forgejo.example.com"
          - name: GITEA_RUNNER_REGISTRATION_TOKEN
            valueFrom:
              secretKeyRef:
                name: runner-token
                key: token
          - name: GITEA_RUNNER_EPHEMERAL
            value: "true"
  pollingInterval: 10
  minReplicaCount: 0
  maxReplicaCount: 20
  triggers:
  - type: forgejo-runner
    metadata:
      forgejoUrl: "https://forgejo.example.com"
      token: "<api-token>"
      labels: "ubuntu-latest"
```

### 7.3 Pros/Cons

| Aspect | Assessment |
|--------|-----------|
| Development effort | Minimal (KEDA does the scaling) |
| Scale-from-zero | Native KEDA feature |
| Per-job pods | ScaledJob creates one Job per trigger |
| Label routing | Supported via `labels` metadata |
| Dependency | Requires KEDA installed in cluster |
| Customization | Limited to KEDA's scaling algorithm |
| Observability | KEDA provides some metrics, less control |

---

## 8. Comparison Matrix

| Feature | Option A (Bash++) | Option B (Go Operator) | Option C (KEDA) |
|---------|-------------------|----------------------|-----------------|
| Development effort | Low | High | Minimal |
| Per-job ephemeral pods | Yes (K8s Jobs) | Yes (EphemeralRunner CRD) | Yes (ScaledJob) |
| Scale-from-zero | Yes | Yes | Yes |
| Label-based routing | Possible | Full support | Via trigger metadata |
| CRD status/events | No | Full support | KEDA provides some |
| Failure retry | K8s Job backoffLimit | Custom (up to 5) | K8s Job backoffLimit |
| Token isolation | Possible | Full support | Manual |
| Prometheus metrics | Add-on | Native | Via KEDA |
| Pod template flexibility | Helm values | CRD spec.template | ScaledJob template |
| External dependencies | None | controller-runtime | KEDA operator |
| Maintenance burden | Low | High | Low (KEDA maintained externally) |
| Testing | Manual/script | envtest + unit tests | Manual |

---

## 9. Implementation Roadmap

### Phase 1: Enhanced Bash Controller (Option A) — Immediate

1. **Switch to Kubernetes Jobs for ephemeral runners**
   - Controller creates `batch/v1 Job` resources instead of scaling Deployments
   - Each Job runs one ephemeral runner pod
   - `ttlSecondsAfterFinished: 60` for auto-cleanup
   - `backoffLimit: 3` for retry on failure

2. **Add per-label-set job matching**
   - Read `act-runner/labels` annotation from scale set
   - Filter pending jobs by matching `runs-on` labels
   - Scale each set independently

3. **Implement adaptive polling**
   - 5s interval when pending jobs > 0
   - 30s interval when idle
   - Configurable via environment variable

4. **Add structured logging and metrics**
   - JSON log output
   - Kubernetes Events on scale actions
   - Optional Prometheus metrics via a sidecar or embedded endpoint

### Phase 2: Go Operator (Option B) — Medium Term

5. **Scaffold Go operator with kubebuilder**
   - Define `RunnerScaleSet` and `EphemeralRunner` CRDs
   - Implement basic reconciliation loops
   - Reuse existing ConnectRPC client from `internal/pkg/client`

6. **Implement Poller component**
   - Per-RunnerScaleSet polling goroutine
   - Job filtering by label
   - Desired replica calculation

7. **Implement EphemeralRunner lifecycle**
   - Pod creation with registration token
   - Completion monitoring
   - Failure retry (up to 5 attempts)
   - Cleanup on completion

8. **Update Helm charts**
   - Controller chart deploys Go binary instead of bash script
   - Scale set chart creates RunnerScaleSet CRD instead of Deployment/StatefulSet
   - Backward compatibility via chart version

### Phase 3: Advanced Features — Long Term

9. **ConnectRPC-based polling** (if Forgejo adds server-push support)
   - Use `FetchTask` RPC with long timeout instead of REST API polling
   - Or implement a custom long-poll endpoint in Forgejo

10. **JIT token generation**
    - Requires Forgejo server-side changes
    - API to generate single-use, scoped registration tokens
    - Controller generates token per EphemeralRunner, never passes main token to pods

11. **Multi-cluster support**
    - Controller federation across clusters
    - Shared job queue with cluster-aware scheduling

12. **Webhook-driven scaling** (if Forgejo adds `workflow_job.queued` event)
    - Controller exposes webhook endpoint
    - Forgejo pushes job events
    - Eliminates polling entirely

---

## 10. Quick Start: Achieving ARC-Equivalent Today

With the current repo, you can get 80% of ARC's functionality:

```bash
# 1. Install the controller (watches for pending jobs)
helm install controller charts/act-runner-controller \
  --namespace act-system --create-namespace \
  --set forgejo.url=https://forgejo.example.com \
  --set forgejo.apiToken=$FORGEJO_ADMIN_TOKEN \
  --set reconcileInterval=10 \
  --set scaleDownDelay=120

# 2. Install a runner scale set (ephemeral runners)
helm install ubuntu-runners charts/act-runner-scale-set \
  --namespace act-runners --create-namespace \
  --set giteaConfigUrl=https://forgejo.example.com \
  --set giteaConfigSecret.token=$RUNNER_REG_TOKEN \
  --set runnerLabels="ubuntu-latest:docker://node:20" \
  --set ephemeral=true \
  --set minRunners=0 \
  --set maxRunners=20 \
  --set replicas=0

# 3. Push code → workflow triggers → controller detects pending job →
#    scales up runner → runner executes job → runner exits →
#    controller scales back down
```

**What you get**:
- Scale from 0 to N runners based on demand
- Runners exit after each job (ephemeral mode)
- Automatic scale-down after cooldown period
- Multiple scale sets with different labels/configurations

**What you don't get (yet)**:
- True per-job pod isolation (pods are recycled within the StatefulSet)
- Per-label job routing (all pending jobs counted globally)
- Push-based notifications (polling only)
- CRD-based management with status tracking

---

## 11. Forgejo Server-Side Improvements (Upstream Proposals)

To achieve full ARC parity, these Forgejo server-side features would help:

| Feature | Priority | Effort | Impact |
|---------|----------|--------|--------|
| `workflow_job.queued` webhook event | High | Medium | Enables push-based scaling, eliminates polling |
| JIT runner registration tokens | Medium | High | Per-pod token isolation, no shared secrets in runner pods |
| Job listing with `runs-on` in response | High | Low | Enables per-label scaling without extra API calls |
| Long-poll endpoint for job availability | Medium | Medium | Reduces polling overhead, near-instant scale-up |
| Runner assignment API (assign job X to runner Y) | Low | High | Precise job-to-runner routing |

These could be proposed as Forgejo enhancement issues on Codeberg.

---

## 12. Summary

| Approach | When to Use | Effort | ARC Parity |
|----------|-------------|--------|------------|
| **Current repo as-is** | Quick start, small teams | Zero | ~60% |
| **Option A: Enhanced Bash** | Production use, moderate scale | Low | ~80% |
| **Option B: Go Operator** | Large scale, enterprise needs | High | ~95% |
| **Option C: KEDA** | Minimal custom code, KEDA already in cluster | Minimal | ~75% |

The path from here to full ARC-equivalent functionality is incremental. The existing controller + scale set charts provide a solid foundation. The main architectural decision is whether to invest in a Go operator (Option B) or stay with the pragmatic bash + KEDA approach.
