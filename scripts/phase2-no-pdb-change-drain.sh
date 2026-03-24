#!/usr/bin/env bash
set -euo pipefail

NAMESPACE="pdb-lab"
WORKER_NODE="pdb-lab-worker"
CONTROL_PLANE_NODE="pdb-lab-control-plane"
DRAIN_TIMEOUT="20m"
WAIT_FOR_UPGRADE_STEP="true"
APPLY_LAB_FIX="true"
RESUME_FILE=".tmp/upgrade.resume"
AUTO_SCALE_SINGLETONS="true"

usage() {
  cat <<'EOF'
Drain worker node without modifying or deleting PDBs.

Usage:
  ./scripts/phase2-no-pdb-change-drain.sh [options]

Options:
  --namespace <name>             Namespace for workload checks (default: pdb-lab)
  --worker-node <name>           Worker node to drain (default: pdb-lab-worker)
  --control-plane-node <name>    Control-plane node (default: pdb-lab-control-plane)
  --timeout <duration>           Drain timeout (default: 20m)
  --wait-for-upgrade-step        Pause after drain for manual upgrade action (default: pause enabled)
  --no-wait                      Skip pause and continue immediately after drain
  --resume-file <path>           Resume marker file for non-interactive pause (default: .tmp/upgrade.resume)
  --disable-auto-scale-singletons  Do not scale Deployments with replicas=1
  --disable-lab-fix              Do not touch control-plane label/taint
  -h, --help                     Show help

Notes:
- This script does not patch, delete, or recreate any PDB.
- In the 2-node kind lab, lab-fix is enabled by default so replacement pods can schedule.
EOF
}

log() {
  echo "[no-pdb-change] $*"
}

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Missing required command: $1" >&2
    exit 1
  fi
}

require_cmd kubectl

while [[ $# -gt 0 ]]; do
  case "$1" in
    --namespace)
      NAMESPACE="$2"
      shift 2
      ;;
    --worker-node)
      WORKER_NODE="$2"
      shift 2
      ;;
    --control-plane-node)
      CONTROL_PLANE_NODE="$2"
      shift 2
      ;;
    --timeout)
      DRAIN_TIMEOUT="$2"
      shift 2
      ;;
    --wait-for-upgrade-step)
      WAIT_FOR_UPGRADE_STEP="true"
      shift
      ;;
    --no-wait)
      WAIT_FOR_UPGRADE_STEP="false"
      shift
      ;;
    --resume-file)
      RESUME_FILE="$2"
      shift 2
      ;;
    --disable-auto-scale-singletons)
      AUTO_SCALE_SINGLETONS="false"
      shift
      ;;
    --disable-lab-fix)
      APPLY_LAB_FIX="false"
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage
      exit 1
      ;;
  esac
done

if ! kubectl version >/dev/null 2>&1; then
  echo "kubectl cannot reach a cluster. Check kube context first." >&2
  exit 1
fi

kubectl get node "$WORKER_NODE" >/dev/null
if [[ "$APPLY_LAB_FIX" == "true" ]]; then
  kubectl get node "$CONTROL_PLANE_NODE" >/dev/null
fi

LAB_FIX_APPLIED="false"
SINGLETONS_SCALED="false"
declare -a SINGLETON_DEPLOYS=()

scale_up_singletons() {
  if [[ "$AUTO_SCALE_SINGLETONS" != "true" ]]; then
    log "Skipping singleton deployment scaling"
    return
  fi

  mapfile -t SINGLETON_DEPLOYS < <(kubectl -n "$NAMESPACE" get deploy -o jsonpath='{range .items[*]}{.metadata.name}{"="}{.spec.replicas}{"\n"}{end}' | awk -F= '$2==1 {print $1}')

  if [[ ${#SINGLETON_DEPLOYS[@]} -eq 0 ]]; then
    log "No singleton deployments found (replicas=1)"
    return
  fi

  log "Scaling singleton deployments to 2 replicas: ${SINGLETON_DEPLOYS[*]}"
  for d in "${SINGLETON_DEPLOYS[@]}"; do
    kubectl -n "$NAMESPACE" scale deploy "$d" --replicas=2 >/dev/null
  done
  SINGLETONS_SCALED="true"
}

restore_singletons() {
  if [[ "$SINGLETONS_SCALED" != "true" ]]; then
    return
  fi

  log "Restoring singleton deployments to 1 replica"
  for d in "${SINGLETON_DEPLOYS[@]}"; do
    kubectl -n "$NAMESPACE" scale deploy "$d" --replicas=1 >/dev/null 2>&1 || true
  done
  SINGLETONS_SCALED="false"
}

revert_lab_fix() {
  if [[ "$APPLY_LAB_FIX" == "true" && "$LAB_FIX_APPLIED" == "true" ]]; then
    log "Reverting temporary control-plane changes"
    kubectl taint nodes "$CONTROL_PLANE_NODE" node-role.kubernetes.io/control-plane:NoSchedule --overwrite >/dev/null 2>&1 || true
    kubectl label node "$CONTROL_PLANE_NODE" drain-target- >/dev/null 2>&1 || true
    LAB_FIX_APPLIED="false"
  fi
}

cleanup() {
  local exit_code="$1"
  restore_singletons
  revert_lab_fix
  if [[ "$exit_code" -eq 0 ]]; then
    log "Completed successfully"
  else
    log "Failed; temporary lab changes were rolled back where possible"
  fi
}

wait_for_upgrade_step() {
  if [[ -t 0 ]]; then
    echo
    read -r -p "Run your upgrade action now, then press Enter to continue... " _
    return
  fi

  mkdir -p "$(dirname "$RESUME_FILE")"
  rm -f "$RESUME_FILE"
  log "Non-interactive session detected; waiting for resume marker: $RESUME_FILE"
  log "Create it from another shell to continue: touch $RESUME_FILE"
  while [[ ! -f "$RESUME_FILE" ]]; do
    sleep 2
  done
  rm -f "$RESUME_FILE"
}

trap 'cleanup $?' EXIT

log "Snapshot before drain"
kubectl get nodes
kubectl -n "$NAMESPACE" get pdb

scale_up_singletons

if [[ "$APPLY_LAB_FIX" == "true" ]]; then
  log "Applying temporary lab scheduling capacity on control-plane"
  kubectl label node "$CONTROL_PLANE_NODE" drain-target=true --overwrite >/dev/null
  kubectl taint nodes "$CONTROL_PLANE_NODE" node-role.kubernetes.io/control-plane:NoSchedule- >/dev/null 2>&1 || true
  LAB_FIX_APPLIED="true"
fi

log "Cordoning worker"
kubectl cordon "$WORKER_NODE" >/dev/null 2>&1 || true

log "Draining worker"
kubectl drain "$WORKER_NODE" --ignore-daemonsets --delete-emptydir-data --grace-period=30 --timeout="$DRAIN_TIMEOUT"

if [[ "$WAIT_FOR_UPGRADE_STEP" == "true" ]]; then
  wait_for_upgrade_step
else
  log "Skipping upgrade pause (use --wait-for-upgrade-step to pause)"
fi

log "Uncordoning worker"
kubectl uncordon "$WORKER_NODE" >/dev/null

restore_singletons

revert_lab_fix

log "Post-checks"
kubectl get nodes
kubectl -n "$NAMESPACE" get pdb
kubectl -n "$NAMESPACE" get pods -o wide
