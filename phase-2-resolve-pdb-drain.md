# Phase 2: Resolve PDB Blocking During Node Drain

This document starts after Phase 1, where drain failure has already been reproduced.

Reference: [phase-1-reproduce-pdb-drain-issue.md](phase-1-reproduce-pdb-drain-issue.md)

Alternative approach without changing or deleting PDBs:
- [phase-2-no-pdb-change-approach.md](phase-2-no-pdb-change-approach.md)

## Goal

Complete node drain for upgrade/maintenance without permanently weakening disruption protection.

## Automation Script (WSL)

You can run the full Phase 2 flow end-to-end using:

```bash
chmod +x scripts/phase2-resolve-pdb-drain.sh
./scripts/phase2-resolve-pdb-drain.sh
```

By default, the script does not pause for upgrade commands.
Use `--wait-for-upgrade-step` if you want an interactive pause between drain and uncordon.

Useful options:

```bash
./scripts/phase2-resolve-pdb-drain.sh --wait-for-upgrade-step
./scripts/phase2-resolve-pdb-drain.sh --wait-for-upgrade-step --resume-file .tmp/my-resume.flag
./scripts/phase2-resolve-pdb-drain.sh --disable-lab-fix
./scripts/phase2-resolve-pdb-drain.sh --namespace pdb-lab --worker-node pdb-lab-worker --control-plane-node pdb-lab-control-plane
```

When running in a non-interactive shell, use `touch .tmp/upgrade.resume` (or your custom `--resume-file`) to continue after the pause point.

The script auto-removes stale marker files before waiting.

What the script does:
- Captures original PDB `minAvailable` values
- Temporarily relaxes them
- Applies lab-only control-plane scheduling fix (unless disabled)
- Drains and uncordons worker node
- Restores original PDB settings and temporary node changes automatically

## Resolution Strategy

1. Back up current PDB definitions
2. Temporarily relax PDB constraints (`minAvailable: 2` -> `minAvailable: 1`)
3. Drain the worker node
4. Perform upgrade action (if any)
5. Uncordon worker node
6. Restore original PDBs

## 1. Confirm Current Blocked State

```bash
kubectl get nodes
kubectl -n pdb-lab get pdb
kubectl -n pdb-lab get pods -o wide
```

Expected:
- `pdb-lab-worker` is often `SchedulingDisabled` if cordoned
- Some pods remain on `pdb-lab-worker`
- PDBs show disruption limits preventing further eviction

## 2. Back Up Existing PDBs

```bash
kubectl -n pdb-lab get pdb -o yaml > pdb-backup.yaml
```

## 3. Temporarily Relax PDBs

Patch all 5 PDBs from `minAvailable: 2` to `minAvailable: 1`:

```bash
kubectl -n pdb-lab patch pdb pdb-deploy-a --type=merge -p '{"spec":{"minAvailable":1}}'
kubectl -n pdb-lab patch pdb pdb-deploy-b --type=merge -p '{"spec":{"minAvailable":1}}'
kubectl -n pdb-lab patch pdb pdb-deploy-c --type=merge -p '{"spec":{"minAvailable":1}}'
kubectl -n pdb-lab patch pdb pdb-sts-a --type=merge -p '{"spec":{"minAvailable":1}}'
kubectl -n pdb-lab patch pdb pdb-sts-b --type=merge -p '{"spec":{"minAvailable":1}}'
```

Verify:

```bash
kubectl -n pdb-lab get pdb
```

## 3a. Lab-Specific Capacity Fix (2-Node Kind)

In this lab, workload pods are pinned by `nodeSelector: drain-target=true` and only the worker is labeled. During drain, replacement pods cannot schedule unless another eligible node exists.

Temporarily allow scheduling on control-plane for this lab:

```bash
kubectl label node pdb-lab-control-plane drain-target=true
kubectl taint nodes pdb-lab-control-plane node-role.kubernetes.io/control-plane:NoSchedule-
```

After maintenance, revert these temporary changes:

```bash
kubectl taint nodes pdb-lab-control-plane node-role.kubernetes.io/control-plane:NoSchedule --overwrite
kubectl label node pdb-lab-control-plane drain-target-
```

## 4. Drain Node Again

```bash
kubectl drain pdb-lab-worker --ignore-daemonsets --delete-emptydir-data --grace-period=30 --timeout=10m
```

Expected:
- Evictions proceed
- Drain completes

## 5. Run Upgrade Step (Contextual)

At this point, run your node upgrade action (platform-specific).

Examples:
- Managed clusters: trigger node pool upgrade
- Self-managed: replace/recreate node with target Kubernetes version

## 6. Bring Node Back

```bash
kubectl uncordon pdb-lab-worker
kubectl get nodes
```

## 7. Restore Original PDB Definitions

```bash
kubectl apply -f pdb-backup.yaml
kubectl -n pdb-lab get pdb
```

Expected:
- All PDBs return to `minAvailable: 2`

## 8. Post-Checks

```bash
kubectl -n pdb-lab get pods -o wide
kubectl -n pdb-lab get deploy,sts
```

Confirm:
- Workloads are healthy
- Desired replicas are available
- PDB protection is restored

## Important Notes

- Keep the relaxed PDB window as short as possible.
- Do not leave production PDBs permanently lowered.
- Avoid `kubectl drain --disable-eviction` unless break-glass emergency is explicitly approved.

## Optional Fast Rollback

If something goes wrong during drain/upgrade:

```bash
kubectl apply -f pdb-backup.yaml
kubectl uncordon pdb-lab-worker
```
