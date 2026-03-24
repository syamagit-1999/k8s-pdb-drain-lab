# Phase 2 Alternative: Drain Without Changing PDBs

This approach resolves node drain blockage without editing or deleting PodDisruptionBudgets.

Reference:
- [phase-1-reproduce-pdb-drain-issue.md](phase-1-reproduce-pdb-drain-issue.md)

## Why This Works

PDBs are not the only constraint. In this 2-node lab, workloads are pinned to nodes with `drain-target=true`. If only the worker has that label, replacement pods cannot schedule during drain.

Instead of relaxing PDBs, this approach temporarily adds schedulable capacity by allowing placement on control-plane.

Additionally, singleton Deployments (`replicas: 1`) are automatically scaled to `2` before drain and restored to `1` after the upgrade flow resumes.

## Guardrails

- PDB specs remain untouched throughout this flow.
- No PDB delete/recreate operations are used.
- Temporary control-plane changes are reverted at the end.

## Manual Steps

## 1. Confirm Current State

```bash
kubectl get nodes
kubectl -n pdb-lab get pdb
kubectl -n pdb-lab get pods -o wide
```

## 2. Temporarily Add Scheduling Capacity (Lab-Only)

```bash
kubectl label node pdb-lab-control-plane drain-target=true --overwrite
kubectl taint nodes pdb-lab-control-plane node-role.kubernetes.io/control-plane:NoSchedule-
```

## 3. Cordon and Drain Worker

```bash
kubectl cordon pdb-lab-worker
kubectl drain pdb-lab-worker --ignore-daemonsets --delete-emptydir-data --grace-period=30 --timeout=20m
```

## 4. Run Upgrade Action (If Required)

Run your node upgrade step (platform specific).

## 5. Bring Worker Back

```bash
kubectl uncordon pdb-lab-worker
```

## 6. Revert Temporary Control-Plane Changes

```bash
kubectl taint nodes pdb-lab-control-plane node-role.kubernetes.io/control-plane:NoSchedule --overwrite
kubectl label node pdb-lab-control-plane drain-target-
```

## 7. Post-Checks

```bash
kubectl get nodes
kubectl -n pdb-lab get pdb
kubectl -n pdb-lab get pods -o wide
```

Expected:
- Nodes return to Ready state
- PDB values are unchanged from pre-maintenance
- Workloads are healthy

## Automation Script (WSL)

Use:

```bash
chmod +x scripts/phase2-no-pdb-change-drain.sh
./scripts/phase2-no-pdb-change-drain.sh
```

Pause is enabled by default in this script.

Optional pause for manual upgrade action:

```bash
./scripts/phase2-no-pdb-change-drain.sh --wait-for-upgrade-step
```

To skip the pause:

```bash
./scripts/phase2-no-pdb-change-drain.sh --no-wait
```

To disable singleton auto-scaling:

```bash
./scripts/phase2-no-pdb-change-drain.sh --disable-auto-scale-singletons
```

If running in a non-interactive shell, resume by creating the marker file:

```bash
touch .tmp/upgrade.resume
```

Note: the script now removes any stale marker file before waiting, so pause cannot be skipped by an old file.

You can customize the marker path:

```bash
./scripts/phase2-no-pdb-change-drain.sh --wait-for-upgrade-step --resume-file .tmp/my-resume.flag
```
