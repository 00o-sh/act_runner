# Forgejo Runner Scale Sets: Achieving GitHub ARC-like Auto-Scaling

## Executive Summary

This document lays out how to replicate GitHub Actions Runner Controller (ARC) / Runner Scale Sets functionality for Forgejo. The goal: a **controller** that watches for pending CI/CD jobs and dynamically creates/destroys **ephemeral runner pods** in Kubernetes, scaling from zero to N and back.

**Strategy**: Start with **Option C (KEDA ScaledJob)** for immediate value with minimal custom code, then evolve to **Option B (Go Kubernetes Operator)** when we need CRD-based management, richer status reporting, and full control over the scaling lifecycle.

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

**ARC's codebase**: ~8,300 LOC (non-test) across ~27 Go files, using controller-runtime v0.22.4. Four controllers (AutoscalingRunnerSet, AutoscalingListener, EphemeralRunnerSet, EphemeralRunner) plus a separate Listener binary.

---

## 2. What Forgejo Provides (The Constraints)

### What exists

| Capability | Status | Details |
|------------|--------|---------|
| Runner protocol | ConnectRPC (gRPC over HTTP) | `Register`, `Declare`, `FetchTask`, `UpdateTask`, `UpdateLog` RPCs via `/api/actions` |
| `--ephemeral` flag | Supported | Runner registers as single-use, executes one job, exits |
| `--once` flag | Supported | Runner executes one job and exits (less strict than ephemeral) |
| Pending jobs API | Available (v11.0+) | `GET /api/v1/admin/runners/jobs?labels={labels}` |
| Registration token API | Available (v1.22+) | `GET /api/v1/repos/{owner}/{repo}/runners/registration-token` |
| Offline registration | Available | `forgejo-cli actions register --secret <secret>` |
| KEDA scaler | Merged in KEDA v2.18.0 | `forgejo-runner` trigger polls pending jobs with label filtering |

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

This means Forgejo scaling will always have slightly higher latency than ARC (polling interval vs near-instant push), but with a 10-15s poll interval this is acceptable for most workloads.

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
| Push-based scaling | Polling every 30s | Medium (acceptable with shorter interval) |
| CRD-driven operator | Bash script | Large (no reconciliation, no status, no events) |
| Per-job pods | Long-lived StatefulSet/Deployment | Large (pods reuse runners, not truly ephemeral) |
| JIT token isolation | Runner gets shared registration token | Medium (token reuse across pod restarts) |
| Scale-from-zero | Supported via minRunners=0 | Small (works, but scale-up latency is 30s + pod startup) |
| Job-label routing | All pending jobs counted globally | Medium (no per-label-set scaling) |
| Failure retry | No retry logic | Medium (failed pods not retried) |

---

## 4. Strategy: Option C (KEDA) now, Option B (Go Operator) later

### Why KEDA first

1. **Immediate per-job ephemeral pods** via ScaledJob (each CI job = one K8s Job pod)
2. **Scale-from-zero is native** (`minReplicaCount: 0`)
3. **Label-based routing built in** (KEDA's `forgejo-runner` trigger accepts `labels` metadata, Forgejo API filters server-side)
4. **No custom controller code needed** - KEDA handles all scaling logic
5. **Retry via K8s Job `backoffLimit`** - no custom failure handling
6. **The pod template is ~80% reusable** from existing charts

### Why eventually Go operator

1. **CRD status reporting** - `kubectl get runnerscalesets` showing current runners, pending jobs, conditions
2. **Kubernetes Events** on scale up/down for debugging
3. **Full lifecycle control** - custom retry logic (5 retries with backoff like ARC), graceful draining
4. **Registration token isolation** - generate per-pod tokens instead of sharing one secret
5. **No KEDA dependency** - one fewer cluster component to manage
6. **ConnectRPC integration** - reuse the existing `internal/pkg/client` for efficient polling via `FetchTask` with `tasksVersion` change detection

### They coexist during migration

KEDA and a Go operator can run side-by-side with zero conflict:
- Different CRDs (`keda.sh/v1alpha1` vs `actions.forgejo.org/v1alpha1`)
- Different target resources (KEDA creates `batch/v1 Jobs`, operator creates `EphemeralRunner` CRs)
- Use different runner labels per scale set to prevent both scaling for the same jobs
- Migrate one scale set at a time: delete KEDA ScaledJob, create RunnerScaleSet CR

---

## 5. Option C: KEDA ScaledJob — Detailed Design

### 5.1 Prerequisites

| Requirement | Version | Notes |
|-------------|---------|-------|
| Forgejo | v11.0+ | For `/runners/jobs?labels=` API endpoints |
| KEDA | v2.18.0+ | For `forgejo-runner` trigger type |
| act_runner image | Current | Must support `--ephemeral` flag |

### 5.2 Architecture

```
                                polls every 10-30s
┌────────────────────┐    GET /api/v1/.../runners/jobs    ┌──────────────┐
│   KEDA Operator     │ ──────────────────────────────→   │   Forgejo     │
│   (ScaledJob        │   ?labels=ubuntu-latest           │   Instance    │
│    controller)      │ ←──────────────────────────────   │              │
└────────┬───────────┘   [{ job1 }, { job2 }, ...]        └──────┬───────┘
         │                                                        │
         │ creates batch/v1 Jobs                                  │
         │ (one per pending CI job)                               │
         ▼                                                        │
┌────────────────────┐                                            │
│  K8s Job Pods       │  register → run 1 job → exit              │
│                     │ ────────────────────────────────────────→  │
│  runner-abc (Job)   │  ConnectRPC: Register, FetchTask,         │
│  runner-def (Job)   │  UpdateTask, UpdateLog                    │
│  runner-ghi (Job)   │                                           │
└────────────────────┘                                            │
         │                                                        │
         │ ttlSecondsAfterFinished: 300                           │
         ▼                                                        │
      (auto-cleaned)                                              │
```

### 5.3 KEDA `forgejo-runner` Trigger Details

The scaler (merged in [KEDA PR #6495](https://github.com/kedacore/keda/pull/6495)) works as follows:

**API endpoints polled** (depending on scope):

| Scope | Endpoint |
|-------|----------|
| Global (admin) | `GET /api/v1/admin/runners/jobs?labels={labels}` |
| Organization | `GET /api/v1/orgs/{org}/actions/runners/jobs?labels={labels}` |
| Repository | `GET /api/v1/repos/{owner}/{repo}/actions/runners/jobs?labels={labels}` |
| User | `GET /api/v1/user/actions/runners/jobs?labels={labels}` |

**Metric**: `len(pendingJobs)` — the number of pending jobs returned by the API.

**Authentication**: Forgejo PAT via `Authorization: token <token>` header. Use `TriggerAuthentication` to reference a K8s Secret.

**Label filtering**: Server-side — Forgejo returns only jobs matching the specified labels.

**Trigger metadata fields**:

| Field | Required | Description |
|-------|----------|-------------|
| `name` | Yes | Runner name identifier |
| `address` | Yes | Forgejo instance URL |
| `labels` | Yes | Comma-separated runner labels (e.g., `"ubuntu-latest"`) |
| `global` | No | `"true"` for admin scope (default) |
| `owner` | No | Username for user/org/repo scope |
| `repo` | No | Repository name (with `owner` for repo scope) |

### 5.4 Why ScaledJob (not ScaledObject)

**ScaledJob is correct for ephemeral CI runners.** ScaledObject would scale a Deployment and could **kill in-progress CI jobs** during scale-in. ScaledJob creates independent K8s Jobs that each run to completion and self-terminate.

| Aspect | ScaledObject (wrong) | ScaledJob (correct) |
|--------|---------------------|---------------------|
| Scale-in | Kills running pods | Jobs finish naturally |
| Pod lifecycle | Long-lived, reused | Ephemeral, one-shot |
| State isolation | Risk of contamination | Fresh pod per job |
| Scaling math | Must count running+pending | Only creates for pending |

### 5.5 Full ScaledJob Manifest

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: forgejo-scaler-token
  namespace: act-runners
type: Opaque
data:
  token: <base64-encoded-forgejo-PAT>
---
apiVersion: v1
kind: Secret
metadata:
  name: runner-registration-token
  namespace: act-runners
type: Opaque
data:
  token: <base64-encoded-runner-registration-token>
---
apiVersion: keda.sh/v1alpha1
kind: TriggerAuthentication
metadata:
  name: forgejo-trigger-auth
  namespace: act-runners
spec:
  secretTargetRef:
  - parameter: token
    name: forgejo-scaler-token
    key: token
---
apiVersion: keda.sh/v1alpha1
kind: ScaledJob
metadata:
  name: ubuntu-runners
  namespace: act-runners
spec:
  # --- Scaling behavior ---
  minReplicaCount: 0              # Scale to zero when idle
  maxReplicaCount: 20             # Max concurrent runner pods
  pollingInterval: 15             # Seconds between Forgejo API polls
  successfulJobsHistoryLimit: 3   # Keep 3 completed Jobs (default 100 is too high)
  failedJobsHistoryLimit: 3       # Keep 3 failed Jobs for debugging
  rollout:
    strategy: gradual             # CRITICAL: don't kill running jobs on manifest update

  # --- Forgejo trigger ---
  triggers:
  - type: forgejo-runner
    metadata:
      name: "ubuntu-runner"
      address: "https://forgejo.example.com"
      labels: "ubuntu-latest"
      global: "true"              # Admin scope (or use owner/repo for narrower scope)
    authenticationRef:
      name: forgejo-trigger-auth

  # --- Job template ---
  jobTargetRef:
    ttlSecondsAfterFinished: 300  # Cleanup 5 min after completion (debug window)
    backoffLimit: 3               # Retry up to 3 times on failure
    template:
      metadata:
        labels:
          app.kubernetes.io/name: forgejo-runner
          app.kubernetes.io/component: runner
      spec:
        restartPolicy: Never
        serviceAccountName: runner-sa
        containers:
        - name: runner
          image: ghcr.io/00o-sh/act_runner:latest
          env:
          - name: GITEA_INSTANCE_URL
            value: "https://forgejo.example.com"
          - name: GITEA_RUNNER_REGISTRATION_TOKEN
            valueFrom:
              secretKeyRef:
                name: runner-registration-token
                key: token
          - name: GITEA_RUNNER_NAME
            valueFrom:
              fieldRef:
                fieldPath: metadata.name    # Unique per Job pod
          - name: GITEA_RUNNER_LABELS
            value: "ubuntu-latest:docker://node:20"
          - name: GITEA_RUNNER_EPHEMERAL
            value: "true"
          resources:
            requests:
              cpu: 500m
              memory: 512Mi
            limits:
              cpu: "2"
              memory: 2Gi
          volumeMounts:
          - name: runner-data
            mountPath: /data
        volumes:
        - name: runner-data
          emptyDir: {}            # No PVC — fresh state per job
```

### 5.6 Two Secrets, Two Purposes

Note the separation of concerns:

| Secret | Used By | Purpose |
|--------|---------|---------|
| `forgejo-scaler-token` | KEDA trigger (TriggerAuthentication) | Forgejo **PAT** to query pending jobs API. Never touches runner pods. |
| `runner-registration-token` | Runner pod env var | Runner **registration token** for `act_runner register`. Only used inside runner pods. |

This is an improvement over the current bash controller where the same API token does both.

### 5.7 DinD Variant

For runners that need Docker (container-based actions):

```yaml
# Add to jobTargetRef.template.spec:
containers:
- name: runner
  image: ghcr.io/00o-sh/act_runner:latest
  env:
  - name: DOCKER_HOST
    value: tcp://localhost:2376
  - name: DOCKER_TLS_VERIFY
    value: "1"
  - name: DOCKER_CERT_PATH
    value: /certs/client
  # ... other env vars same as above
  volumeMounts:
  - name: docker-certs
    mountPath: /certs
    readOnly: true
  - name: runner-data
    mountPath: /data

- name: dind
  image: docker:28-dind
  securityContext:
    privileged: true
  env:
  - name: DOCKER_TLS_CERTDIR
    value: /certs
  volumeMounts:
  - name: docker-certs
    mountPath: /certs

volumes:
- name: docker-certs
  emptyDir: {}
- name: runner-data
  emptyDir: {}
```

### 5.8 Known Gotchas & Mitigations

| Gotcha | Impact | Mitigation |
|--------|--------|------------|
| **Over-provisioning from metric lag** | If runner takes longer to start than `pollingInterval`, KEDA creates duplicate Jobs for same CI job | Tune `pollingInterval` to be longer than pod startup time, or use `accurate` scaling strategy |
| **Default rollout kills running jobs** | Updating ScaledJob manifest terminates all existing Jobs | Always use `rollout.strategy: gradual` |
| **History limits default to 100** | Hundreds of completed Job/Pod objects clutter namespace | Set `successfulJobsHistoryLimit: 3` and `failedJobsHistoryLimit: 3` |
| **No fallback mechanism** | If Forgejo API is unreachable, no new Jobs are created (no fallback value) | ScaledJob limitation — monitor KEDA scaler health, ensure Forgejo uptime |
| **Scope mismatch** | Runner registered at org scope but trigger at admin scope = wrong counts | Match trigger scope to runner registration scope exactly |
| **DinD image pull overhead** | Each ephemeral pod re-pulls Docker images for steps | Use image pull-through registry or pre-warm nodes with common images |
| **Forgejo v11.0+ required** | `/runners/jobs` API only exists in Forgejo v11.0+ | Verify Forgejo version before deploying |
| **`eager` strategy may be buggy** | KEDA issue #6416 reports overlap with `default` strategy | Stick with `default` scaling strategy |
| **Registration token shared** | All runner pods use same token | Acceptable for KEDA phase; Go operator (Option B) will add per-pod tokens |

### 5.9 What Changes vs. Current Charts

| Component | Current | KEDA Approach |
|-----------|---------|---------------|
| **act-runner-controller chart** | Bash controller Deployment | **Eliminated** — KEDA replaces it |
| **act-runner-scale-set chart** | Deployment/StatefulSet | **Replaced** with KEDA ScaledJob |
| `deployment.yaml` template | Scales replicas of long-lived pods | Deleted; replaced by `scaledjob.yaml` |
| `hpa.yaml` template | CPU/memory-based HPA | Deleted; KEDA handles scaling |
| `persistence` values | PVC for runner state | Removed; emptyDir only (ephemeral pods) |
| `replicas` value | Initial replica count | Removed; KEDA determines count from pending jobs |
| `run.sh` script | Checks for existing `.runner` file | Simplified; always registers fresh (no PVC) |
| Pod `restartPolicy` | Always (Deployment) | Never (Job) |
| Runner name | Prefix from release name | Pod name via `metadata.name` fieldRef (unique per Job) |
| RBAC | ClusterRole to patch Deployments/StatefulSets | Minimal; runner pods only need Secret read access |

**~80% of the pod template** (container spec, env vars, volumes, DinD sidecar logic, security context, resources, affinity) is directly reusable. The scaling orchestration is completely replaced.

### 5.10 Helm Chart Structure (KEDA Phase)

```
charts/
├── act-runner-controller/        # KEEP for users not using KEDA (backward compat)
└── act-runner-scale-set/
    ├── Chart.yaml
    ├── values.yaml               # Add keda.enabled toggle
    └── templates/
        ├── _helpers.tpl          # Keep as-is
        ├── deployment.yaml       # Keep: used when keda.enabled=false
        ├── scaledjob.yaml        # NEW: used when keda.enabled=true
        ├── triggerauth.yaml      # NEW: KEDA TriggerAuthentication
        ├── secret.yaml           # Keep (runner registration token)
        ├── configmap.yaml        # Keep (runner config)
        ├── serviceaccount.yaml   # Keep (simplified RBAC)
        └── hpa.yaml              # Keep: used when keda.enabled=false
```

Both modes coexist in the same chart via a `keda.enabled` toggle, so existing users are not disrupted.

---

## 6. Option B: Go Kubernetes Operator — Detailed Design

### 6.1 When to Build It

Move to the Go operator when any of these become true:
- You need `kubectl get runnerscalesets` with live status (pending jobs, current runners, conditions)
- You want Kubernetes Events emitted on scale up/down for debugging
- You want per-pod registration token isolation (security requirement)
- You want custom retry logic beyond K8s Job `backoffLimit` (e.g., 5 retries with exponential backoff)
- You want to drop the KEDA dependency
- You want to use `FetchTask` ConnectRPC with `tasksVersion` change detection instead of REST polling (more efficient)

### 6.2 Architecture (Simplified vs. ARC)

ARC needs 4 CRDs and a separate Listener binary because GitHub uses push-based notifications. Since Forgejo uses polling, our architecture is simpler:

```
ARC (GitHub)                       Our Operator (Forgejo)
────────────────────────          ────────────────────────
AutoscalingRunnerSet CRD    →     RunnerScaleSet CRD
AutoscalingListener CRD     →     NOT NEEDED (no push notifications)
EphemeralRunnerSet CRD      →     NOT NEEDED (controller creates runners directly)
EphemeralRunner CRD         →     EphemeralRunner CRD
Listener binary (separate)  →     Poller goroutine (inside controller)
4 controllers               →     2 controllers
~8,300 LOC                  →     ~2,000-2,500 LOC
```

### 6.3 Custom Resource Definitions

```yaml
# RunnerScaleSet - top-level resource (analogous to ARC's AutoScalingRunnerSet)
apiVersion: actions.forgejo.org/v1alpha1
kind: RunnerScaleSet
metadata:
  name: ubuntu-runners
spec:
  forgejoInstance: https://forgejo.example.com
  authSecretRef:
    name: forgejo-api-token         # PAT for polling pending jobs
  registrationSecretRef:
    name: runner-registration-token  # Registration token for runners
  scope: admin                       # "admin", "org", "repo"
  organization: my-org               # When scope=org
  labels:
    - "ubuntu-latest:docker://node:20"
    - "ubuntu-22.04:docker://ubuntu:22.04"
  minRunners: 0
  maxRunners: 20
  pollInterval: 10s
  scaleDownDelay: 5m
  maxRetries: 5                      # Per-runner failure retries
  template:
    spec:
      restartPolicy: Never
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
  pendingEphemeralRunners: 2
  runningEphemeralRunners: 3
  failedEphemeralRunners: 0
  lastScaleTime: "2026-02-10T12:00:00Z"
  conditions:
  - type: Ready
    status: "True"
    message: "Polling active, 3 runners running"
  - type: ScalingActive
    status: "True"
    message: "5 pending jobs, scaling up"

---
# EphemeralRunner - individual runner lifecycle
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
  phase: Running        # Pending, Registering, Running, Completed, Failed
  podName: ubuntu-runners-abc123-pod
  startedAt: "2026-02-10T12:00:05Z"
  retryCount: 0
  failureMessage: ""
```

### 6.4 Controller Reconciliation Loops

```
RunnerScaleSet Controller:
  Watch: RunnerScaleSet resources
  Reconcile:
    1. Validate Forgejo connectivity (Ping RPC or REST health check)
    2. Ensure secrets exist and are valid
    3. Start/update Poller goroutine for this scale set:
       a. Poll: GET /api/v1/{scope}/runners/jobs?labels={labels}
          (or use FetchTask ConnectRPC with tasksVersion for efficiency)
       b. Count active EphemeralRunner resources for this scale set
       c. Calculate desired = max(minRunners, min(maxRunners, pending))
       d. If desired > current: Create new EphemeralRunner resources
       e. If desired < current (after scaleDownDelay): Delete idle EphemeralRunners
    4. Update RunnerScaleSet status (currentRunners, pendingJobs, conditions)
    5. Emit Kubernetes Events on scale changes

EphemeralRunner Controller:
  Watch: EphemeralRunner resources + owned Pods
  Reconcile:
    1. If no Pod exists and phase=Pending:
       - (Future: generate per-pod registration token via API)
       - Create Pod from RunnerScaleSet template + registration env vars
       - Set phase=Registering
    2. If Pod is Running and phase=Registering:
       - Set phase=Running
    3. If Pod Succeeded:
       - Set phase=Completed
       - Delete EphemeralRunner (with owner reference, Pod auto-deleted)
    4. If Pod Failed and retryCount < maxRetries:
       - Increment retryCount
       - Delete failed Pod
       - Create new Pod (exponential backoff: 5s, 10s, 20s, 40s, 80s)
    5. If Pod Failed and retryCount >= maxRetries:
       - Set phase=Failed
       - Emit warning Event
       - Do not retry (manual intervention needed)
```

### 6.5 Technology Stack

| Component | Choice | Rationale |
|-----------|--------|-----------|
| Scaffolding | Kubebuilder | Industry standard; ARC uses same layout with controller-runtime |
| Operator framework | `sigs.k8s.io/controller-runtime` | Same as ARC; production-proven |
| CRD generation | `controller-gen` | Standard; generates CRD YAML from Go struct tags |
| Forgejo API client | ConnectRPC (reuse `internal/pkg/client`) | Already in this repo; `FetchTask` with `tasksVersion` is efficient |
| Forgejo REST client | Standard `net/http` | For pending jobs API (`/runners/jobs`) |
| Helm charts | Refactor existing | Controller chart deploys Go binary; scale-set chart creates CRs |
| Testing | `envtest` + fake client | Standard k8s controller testing |
| Metrics | `controller-runtime` metrics (Prometheus) | Built into the framework |

### 6.6 Project Structure

```
/
├── cmd/
│   ├── act_runner/                    # Existing runner binary (unchanged)
│   └── controller/
│       └── main.go                    # Operator entrypoint (~80 LOC)
├── api/
│   └── v1alpha1/
│       ├── runnerscaleset_types.go    # RunnerScaleSet CRD (~120 LOC)
│       ├── ephemeralrunner_types.go   # EphemeralRunner CRD (~80 LOC)
│       ├── groupversion_info.go       # API group registration (~35 LOC)
│       └── zz_generated.deepcopy.go   # Auto-generated
├── internal/
│   ├── app/                           # Existing runner code (unchanged)
│   ├── pkg/                           # Existing runner code (unchanged)
│   ├── controller/
│   │   ├── runnerscaleset_controller.go  # Scale set reconciler + poller (~600-800 LOC)
│   │   ├── ephemeralrunner_controller.go # Runner lifecycle (~400-500 LOC)
│   │   └── suite_test.go                 # envtest setup
│   ├── forgejo/
│   │   ├── client.go                  # REST client for /runners/jobs (~150 LOC)
│   │   └── types.go                   # API response types (~50 LOC)
│   └── metrics/
│       └── metrics.go                 # Custom Prometheus metrics (~100 LOC)
├── config/
│   ├── crd/bases/                     # Generated CRD YAML
│   ├── rbac/                          # Controller RBAC
│   └── manager/                       # Controller Deployment
├── charts/
│   ├── act-runner-controller/         # Refactored: deploys Go binary
│   └── act-runner-scale-set/          # Refactored: creates RunnerScaleSet CR
└── Dockerfile                         # Add controller target stage
```

### 6.7 Effort Estimate

| Component | Files | LOC |
|-----------|-------|-----|
| CRD types (hand-written) | 3 | ~235 |
| RunnerScaleSet controller + poller | 2 | 600-800 |
| EphemeralRunner controller | 1 | 400-500 |
| Forgejo REST client | 2 | 200 |
| Resource builder (pod templates) | 1 | 200-300 |
| Metrics | 1 | 100 |
| main.go | 1 | 80 |
| Generated code (deepcopy) | 1 | ~150 |
| **Total (non-test)** | **~12** | **~2,000-2,500** |
| Tests (envtest + unit) | 6-8 | 1,500-2,000 |
| **Total with tests** | **~20** | **~3,500-4,500** |

For comparison: ARC is ~8,300 LOC non-test (~14,300 with tests) — our operator is ~3-4x smaller because we don't need a Listener binary, EphemeralRunnerSet, or AutoscalingListener.

### 6.8 Key Simplification vs. ARC

Since Forgejo uses polling (not push), we avoid ARC's most complex components:

1. **No separate Listener binary** — The Poller runs as a goroutine inside the RunnerScaleSet controller. No HTTPS long-poll session management, no message queue token refresh, no separate pod/deployment/RBAC.

2. **No EphemeralRunnerSet layer** — ARC needs this because the Listener is a separate binary that can only patch a replica count. Our controller creates EphemeralRunners directly.

3. **No AutoscalingListener CRD** — No listener pod to manage.

4. **Simpler API client** — REST calls with `Authorization: token` header vs. GitHub's proprietary Actions Service with session tokens, message queues, and JIT config generation.

---

## 7. Migration Roadmap

### Phase 1: KEDA ScaledJob (Option C) — Now

**Goal**: Ephemeral per-job pods with scale-from-zero using minimal custom code.

| Step | Task | Details |
|------|------|---------|
| 1.1 | Install KEDA v2.18+ | `helm install keda kedacore/keda -n keda-system` |
| 1.2 | Add `keda.enabled` toggle to scale-set chart | Conditional: ScaledJob when true, Deployment when false |
| 1.3 | Create `scaledjob.yaml` template | Embed existing pod template in ScaledJob spec |
| 1.4 | Create `triggerauth.yaml` template | KEDA TriggerAuthentication referencing Forgejo PAT secret |
| 1.5 | Add `kedaScalerToken` to values.yaml | Separate from runner registration token |
| 1.6 | Simplify `run.sh` for ephemeral mode | Always register fresh (no PVC check needed) |
| 1.7 | Test scale-from-zero | Push code → job queued → KEDA creates Job → runner executes → pod deleted |
| 1.8 | Test label routing | Multiple ScaledJobs with different labels, verify correct routing |
| 1.9 | Document KEDA setup | Prerequisites, values, examples |

**Outcome**: Functional ephemeral runner scaling with ~75% ARC parity.

### Phase 2: Go Operator (Option B) — Later

**Goal**: Full Kubernetes-native control with CRDs, status, events, and no KEDA dependency.

| Step | Task | Details |
|------|------|---------|
| 2.1 | Scaffold with kubebuilder | `kubebuilder init --domain forgejo.org` |
| 2.2 | Define CRD types | `RunnerScaleSet` and `EphemeralRunner` Go structs |
| 2.3 | Implement RunnerScaleSet controller | Polling loop + scaling decisions |
| 2.4 | Implement EphemeralRunner controller | Pod lifecycle + retry logic |
| 2.5 | Add Forgejo REST client | Reuse patterns from `internal/pkg/client` |
| 2.6 | Add Prometheus metrics | Pending jobs, active runners, scale events |
| 2.7 | Add Dockerfile target | New multi-stage build for controller binary |
| 2.8 | Refactor Helm charts | Controller chart deploys Go binary; scale-set creates CRs |
| 2.9 | Write envtest tests | Controller reconciliation, pod lifecycle, failure retry |
| 2.10 | Run alongside KEDA | Migrate scale sets one at a time using different labels |
| 2.11 | Remove KEDA dependency | Once all scale sets use RunnerScaleSet CRs |

**Outcome**: ~95% ARC parity with full Kubernetes-native experience.

### Phase 3: Advanced Features — Future

| Step | Task | Depends On |
|------|------|-----------|
| 3.1 | Per-pod registration tokens | Forgejo API for generating tokens programmatically |
| 3.2 | ConnectRPC-based polling | Use `FetchTask` with `tasksVersion` instead of REST |
| 3.3 | Webhook-driven scaling | Forgejo adding `workflow_job.queued` webhook event |
| 3.4 | Multi-cluster federation | Shared job queue with cluster-aware scheduling |
| 3.5 | Warm pool (min idle runners) | Keep N registered-but-idle runners for instant pickup |

---

## 8. Forgejo Server-Side Improvements (Upstream Proposals)

To close remaining gaps with ARC, these Forgejo changes would help:

| Feature | Priority | Effort | Impact | Needed For |
|---------|----------|--------|--------|-----------|
| `workflow_job.queued` webhook event | High | Medium | Eliminates polling entirely | Phase 3.3 |
| JIT runner registration tokens | Medium | High | Per-pod token isolation | Phase 3.1 |
| Job listing with `runs-on` in response | High | Low | Better label routing without extra API calls | Phase 1 (nice-to-have) |
| Long-poll endpoint for job availability | Medium | Medium | Near-instant scaling (replaces polling) | Phase 3.3 alternative |
| Runner assignment API | Low | High | Precise job-to-runner routing | Phase 3 |

---

## 9. Summary

| Phase | Approach | Effort | ARC Parity | Key Wins |
|-------|----------|--------|------------|----------|
| **Now** | KEDA ScaledJob (Option C) | Minimal | ~75% | Per-job pods, scale-from-zero, label routing, no custom controller |
| **Later** | Go Operator (Option B) | ~2,000-2,500 LOC | ~95% | CRD status, Events, custom retry, no KEDA dependency |
| **Future** | Advanced features | Depends on Forgejo | ~100% | Push-based scaling, JIT tokens, multi-cluster |

The KEDA phase validates the ephemeral-pod model with real workloads. The Go operator phase replaces KEDA with a purpose-built controller when you need deeper control. The migration is seamless because both use the same pod templates and runner images — only the scaling orchestration changes.
