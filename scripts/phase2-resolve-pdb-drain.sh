#!/usr/bin/env bash
set -euo pipefail

NAMESPACE="pdb-lab"
WORKER_NODE="pdb-lab-worker"
CONTROL_PLANE_NODE="pdb-lab-control-plane"
RELAX_TO="1"
DRAIN_TIMEOUT="10m"
ENABLE_LAB_FIX="true"
WAIT_FOR_UPGRADE_STEP="false"
RESUME_FILE=".tmp/upgrade.resume"

usage() {
  cat <<'EOF'
Automate Phase 2 PDB drain resolution flow.

Usage:
  ./scripts/phase2-resolve-pdb-drain.sh [options]

Options:
  --namespace <name>             Namespace containing PDBs (default: pdb-lab)
  --worker-node <name>           Node to drain (default: pdb-lab-worker)
  --control-plane-node <name>    Control-plane node name (default: pdb-lab-control-plane)
  --relax-to <value>             Temporary minAvailable value (default: 1)
  --timeout <duration>           Drain timeout (default: 10m)
  --disable-lab-fix              Do not modify control-plane taint/label
  --wait-for-upgrade-step        Pause after drain for manual upgrade action (default: no pause)
  --resume-file <path>           Resume marker file for non-interactive pause (default: .tmp/upgrade.resume)
  -h, --help                     Show this help

Notes:
- Designed for WSL/bash execution.
- Restores original PDB minAvailable values even if drain fails.
- In this 2-node kind lab, lab-fix is enabled by default so replacement pods can schedule.
EOF
}

log() {
  echo "[phase2] $*"
}

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Missing required command: $1" >&2
    exit 1
  fi
}

is_integer() {
  [[ "$1" =~ ^[0-9]+$ ]]
}

patch_min_available() {
  local pdb_name="$1"
  local value="$2"
  local patch

  if is_integer "$value"; then
    patch="{\"spec\":{\"minAvailable\":${value}}}"
  else
    patch="{\"spec\":{\"minAvailable\":\"${value}\"}}"
  fi

  kubectl -n "$NAMESPACE" patch pdb "$pdb_name" --type=merge -p "$patch" >/dev/null
}

require_cmd kubectl

if [[ $# -gt 0 ]]; then
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
      --relax-to)
        RELAX_TO="$2"
        shift 2
        ;;
      --timeout)
        DRAIN_TIMEOUT="$2"
        shift 2
        ;;
      --disable-lab-fix)
        ENABLE_LAB_FIX="false"
        shift
        ;;
      --wait-for-upgrade-step)
        WAIT_FOR_UPGRADE_STEP="true"
        shift
        ;;
      --resume-file)
        RESUME_FILE="$2"
        shift 2
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
fi

if ! kubectl version >/dev/null 2>&1; then
  echo "kubectl cannot reach a cluster. Check kube context first." >&2
  exit 1
fi

if ! kubectl -n "$NAMESPACE" get pdb >/dev/null 2>&1; then
  echo "No PDBs found in namespace '$NAMESPACE'." >&2
  exit 1
fi

if ! kubectl get node "$WORKER_NODE" >/dev/null 2>&1; then
  echo "Worker node '$WORKER_NODE' not found." >&2
  exit 1
fi

if [[ "$ENABLE_LAB_FIX" == "true" ]] && ! kubectl get node "$CONTROL_PLANE_NODE" >/dev/null 2>&1; then
  echo "Control-plane node '$CONTROL_PLANE_NODE' not found." >&2
  exit 1
fi

declare -a PDB_NAMES=()
declare -A ORIGINAL_MIN=()
LAB_FIX_APPLIED="false"

mapfile -t PDB_NAMES < <(kubectl -n "$NAMESPACE" get pdb -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}')

if [[ ${#PDB_NAMES[@]} -eq 0 ]]; then
  echo "No PDB objects found in namespace '$NAMESPACE'." >&2
  exit 1
fi

for pdb in "${PDB_NAMES[@]}"; do
  min_val="$(kubectl -n "$NAMESPACE" get pdb "$pdb" -o jsonpath='{.spec.minAvailable}')"
  if [[ -z "$min_val" ]]; then
    echo "PDB '$pdb' uses maxUnavailable; this script expects minAvailable." >&2
    exit 1
  fi
  ORIGINAL_MIN["$pdb"]="$min_val"
done

mkdir -p .tmp
backup_file=".tmp/pdb-min-$(date +%Y%m%d-%H%M%S).txt"
for pdb in "${PDB_NAMES[@]}"; do
  echo "${pdb}=${ORIGINAL_MIN[$pdb]}" >> "$backup_file"
done
log "Saved original minAvailable snapshot to $backup_file"

cleanup() {
  local exit_code="$1"

  log "Restoring original PDB minAvailable values"
  for pdb in "${PDB_NAMES[@]}"; do
    patch_min_available "$pdb" "${ORIGINAL_MIN[$pdb]}" || true
  done

  if [[ "$ENABLE_LAB_FIX" == "true" && "$LAB_FIX_APPLIED" == "true" ]]; then
    log "Reverting temporary control-plane scheduling changes"
    kubectl taint nodes "$CONTROL_PLANE_NODE" node-role.kubernetes.io/control-plane:NoSchedule --overwrite >/dev/null 2>&1 || true
    kubectl label node "$CONTROL_PLANE_NODE" drain-target- >/dev/null 2>&1 || true
  fi

  if [[ "$exit_code" -eq 0 ]]; then
    log "Phase 2 flow completed and protections restored"
  else
    log "Script exited with errors; rollback steps were attempted"
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

log "Current node status"
kubectl get nodes

log "Relaxing PDBs to minAvailable=$RELAX_TO"
for pdb in "${PDB_NAMES[@]}"; do
  patch_min_available "$pdb" "$RELAX_TO"
done
kubectl -n "$NAMESPACE" get pdb

if [[ "$ENABLE_LAB_FIX" == "true" ]]; then
  log "Applying lab-only capacity fix on control-plane"
  kubectl label node "$CONTROL_PLANE_NODE" drain-target=true --overwrite >/dev/null
  kubectl taint nodes "$CONTROL_PLANE_NODE" node-role.kubernetes.io/control-plane:NoSchedule- >/dev/null 2>&1 || true
  LAB_FIX_APPLIED="true"
fi

log "Cordoning worker node"
kubectl cordon "$WORKER_NODE" >/dev/null 2>&1 || true

log "Draining worker node"
kubectl drain "$WORKER_NODE" --ignore-daemonsets --delete-emptydir-data --grace-period=30 --timeout="$DRAIN_TIMEOUT"

if [[ "$WAIT_FOR_UPGRADE_STEP" == "true" ]]; then
  wait_for_upgrade_step
else
  log "Skipping upgrade pause (use --wait-for-upgrade-step to pause)"
fi

log "Uncordoning worker node"
kubectl uncordon "$WORKER_NODE" >/dev/null

log "Post-checks"
kubectl get nodes
kubectl -n "$NAMESPACE" get pdb
kubectl -n "$NAMESPACE" get pods -o wide
