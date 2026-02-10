#!/usr/bin/env bash
set -euo pipefail

#
# act-runner-controller — job-aware autoscaler for act_runner scale sets
#
# Discovers runner Deployments/StatefulSets by label, polls the Forgejo/Gitea
# REST API for pending jobs, and scales replicas up or down accordingly.
#

### ---------------------------------------------------------------------------
### Kubernetes API helpers (uses in-cluster service account)
### ---------------------------------------------------------------------------

KUBE_TOKEN_FILE="/var/run/secrets/kubernetes.io/serviceaccount/token"
KUBE_CA="/var/run/secrets/kubernetes.io/serviceaccount/ca.crt"
KUBE_NS_FILE="/var/run/secrets/kubernetes.io/serviceaccount/namespace"
KUBE_API="https://kubernetes.default.svc"

kube_token() { cat "$KUBE_TOKEN_FILE"; }

kube() {
  local method="$1" path="$2"; shift 2
  curl -sS --max-time 10 --cacert "$KUBE_CA" \
    -X "$method" \
    -H "Authorization: Bearer $(kube_token)" \
    -H "Content-Type: application/json" \
    "$KUBE_API$path" "$@"
}

### ---------------------------------------------------------------------------
### Forgejo / Gitea REST API helpers
### ---------------------------------------------------------------------------

forgejo() {
  local path="$1"; shift
  curl -sS --max-time 15 \
    -H "Authorization: token ${FORGEJO_API_TOKEN}" \
    -H "Accept: application/json" \
    "${FORGEJO_URL}/api/v1${path}" "$@"
}

# Returns the number of jobs in "waiting" status.
# Tries admin endpoint first; falls back to org-level if FORGEJO_ORG is set.
get_pending_jobs() {
  local jobs=""

  if [ "${FORGEJO_SCOPE:-admin}" = "org" ] && [ -n "${FORGEJO_ORG:-}" ]; then
    jobs=$(forgejo "/orgs/${FORGEJO_ORG}/actions/jobs?status=waiting&limit=50" 2>/dev/null || echo "")
  else
    jobs=$(forgejo "/admin/actions/jobs?status=waiting&limit=50" 2>/dev/null || echo "")
  fi

  # The response may be an object with a "jobs" key or a raw array
  if [ -z "$jobs" ]; then
    echo "0"
    return
  fi

  local count
  count=$(echo "$jobs" | jq '
    if type == "object" and has("jobs") then .jobs
    elif type == "array" then .
    else []
    end | length
  ' 2>/dev/null || echo "0")

  echo "$count"
}

# Returns the number of active (busy) runners.
get_active_runners() {
  local runners=""

  if [ "${FORGEJO_SCOPE:-admin}" = "org" ] && [ -n "${FORGEJO_ORG:-}" ]; then
    runners=$(forgejo "/orgs/${FORGEJO_ORG}/actions/runners" 2>/dev/null || echo "")
  else
    runners=$(forgejo "/admin/actions/runners" 2>/dev/null || echo "")
  fi

  if [ -z "$runners" ]; then
    echo "0"
    return
  fi

  local count
  count=$(echo "$runners" | jq '
    if type == "object" and has("runners") then .runners
    elif type == "array" then .
    else []
    end | [.[] | select(.busy == true)] | length
  ' 2>/dev/null || echo "0")

  echo "$count"
}

### ---------------------------------------------------------------------------
### Scale runner workloads
### ---------------------------------------------------------------------------

LABEL_SELECTOR="app.kubernetes.io/managed-by=act-runner-controller"
LAST_SCALE_DOWN=0

list_workloads() {
  local all_ns="${WATCH_ALL_NAMESPACES:-true}"
  local deps stats

  if [ "$all_ns" = "true" ]; then
    deps=$(kube GET "/apis/apps/v1/deployments?labelSelector=${LABEL_SELECTOR}")
    stats=$(kube GET "/apis/apps/v1/statefulsets?labelSelector=${LABEL_SELECTOR}")
  else
    local ns
    ns=$(cat "$KUBE_NS_FILE")
    deps=$(kube GET "/apis/apps/v1/namespaces/${ns}/deployments?labelSelector=${LABEL_SELECTOR}")
    stats=$(kube GET "/apis/apps/v1/namespaces/${ns}/statefulsets?labelSelector=${LABEL_SELECTOR}")
  fi

  # Merge items from both lists
  echo "$deps" "$stats" | jq -s '.[0].items + .[1].items'
}

scale_workload() {
  local kind="$1" ns="$2" name="$3" replicas="$4"
  local resource
  if [ "$kind" = "StatefulSet" ]; then
    resource="statefulsets"
  else
    resource="deployments"
  fi

  kube PATCH "/apis/apps/v1/namespaces/${ns}/${resource}/${name}/scale" \
    -d "{\"spec\":{\"replicas\":${replicas}}}" \
    -H "Content-Type: application/merge-patch+json" > /dev/null
}

reconcile() {
  local workloads
  workloads=$(list_workloads 2>/dev/null || echo "[]")

  local count
  count=$(echo "$workloads" | jq 'length' 2>/dev/null || echo "0")

  if [ "$count" -eq 0 ]; then
    log "No runner workloads found (label: ${LABEL_SELECTOR})"
    return 0
  fi

  # Get global pending job count from Forgejo
  local pending
  pending=$(get_pending_jobs)
  local active_runners
  active_runners=$(get_active_runners)

  log "Forgejo status: pending_jobs=${pending} active_runners=${active_runners}"

  local now
  now=$(date +%s)
  local scale_down_delay="${SCALE_DOWN_DELAY:-300}"

  for i in $(seq 0 $((count - 1))); do
    local item
    item=$(echo "$workloads" | jq ".[$i]")

    local name ns kind current_replicas
    name=$(echo "$item" | jq -r '.metadata.name')
    ns=$(echo "$item" | jq -r '.metadata.namespace')
    kind=$(echo "$item" | jq -r '.kind')
    current_replicas=$(echo "$item" | jq -r '.spec.replicas // 1')

    # Read scaling bounds from annotations (set by scale-set chart)
    local min_runners max_runners
    min_runners=$(echo "$item" | jq -r '.metadata.annotations["act-runner/min-runners"] // "1"')
    max_runners=$(echo "$item" | jq -r '.metadata.annotations["act-runner/max-runners"] // "10"')

    # Scaling logic:
    #   desired = max(min_runners, min(max_runners, current + pending))
    #
    # If there are pending jobs, scale up immediately.
    # If all runners are idle (pending=0), scale down after cooldown.
    local desired="$current_replicas"

    if [ "$pending" -gt 0 ]; then
      # Scale up: add runners for pending jobs
      desired=$((current_replicas + pending))
      LAST_SCALE_DOWN=0  # reset cooldown
    elif [ "$current_replicas" -gt "$min_runners" ]; then
      # No pending jobs — consider scaling down after cooldown
      if [ "$LAST_SCALE_DOWN" -eq 0 ]; then
        LAST_SCALE_DOWN="$now"
        log "${ns}/${name}: idle, cooldown started (${scale_down_delay}s)"
      fi

      local elapsed=$(( now - LAST_SCALE_DOWN ))
      if [ "$elapsed" -ge "$scale_down_delay" ]; then
        # Scale down by 1 per cycle (graceful)
        desired=$((current_replicas - 1))
        LAST_SCALE_DOWN="$now"  # reset for next scale-down step
      fi
    fi

    # Clamp to bounds
    [ "$desired" -lt "$min_runners" ] && desired="$min_runners"
    [ "$desired" -gt "$max_runners" ] && desired="$max_runners"

    if [ "$desired" -ne "$current_replicas" ]; then
      log "Scaling ${ns}/${name} (${kind}) from ${current_replicas} to ${desired}"
      scale_workload "$kind" "$ns" "$name" "$desired"
    else
      log "${ns}/${name}: ${current_replicas}/${max_runners} replicas (pending=${pending})"
    fi
  done
}

### ---------------------------------------------------------------------------
### Liveness probe support — touch a file each cycle
### ---------------------------------------------------------------------------

touch_liveness() {
  touch /tmp/controller-alive
}

### ---------------------------------------------------------------------------
### Main loop
### ---------------------------------------------------------------------------

log() { echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] $*"; }

validate_config() {
  local ok=true
  if [ -z "${FORGEJO_URL:-}" ]; then
    log "ERROR: FORGEJO_URL is required"
    ok=false
  fi
  if [ -z "${FORGEJO_API_TOKEN:-}" ]; then
    log "ERROR: FORGEJO_API_TOKEN is required"
    ok=false
  fi
  if [ "$ok" = "false" ]; then
    exit 1
  fi
}

main() {
  validate_config

  local interval="${RECONCILE_INTERVAL:-30}"

  log "act-runner-controller starting"
  log "  Forgejo URL:        ${FORGEJO_URL}"
  log "  Scope:              ${FORGEJO_SCOPE:-admin}"
  log "  Reconcile interval: ${interval}s"
  log "  Scale-down delay:   ${SCALE_DOWN_DELAY:-300}s"
  log "  Watch all NS:       ${WATCH_ALL_NAMESPACES:-true}"

  while true; do
    touch_liveness
    reconcile || log "WARNING: reconciliation cycle failed"
    sleep "$interval"
  done
}

main "$@"
