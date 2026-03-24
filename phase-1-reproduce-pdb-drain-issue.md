# Phase 1: Reproduce PDB Blocking Node Drain

This document is Phase 1 of the task and focuses only on reproducing a common Kubernetes node-upgrade issue where `kubectl drain` is blocked by PodDisruptionBudgets (PDBs).

## Scenario Covered

- Kind cluster with 2 nodes
- 3 Deployments (3 replicas each)
- 2 StatefulSets (3 replicas each)
- PDB for all 5 workloads (`minAvailable: 2`)

## Prerequisites

- `kind` installed
- `kubectl` installed
- Docker running
- Current directory is repo root

## Manifests Used

- `manifests/kind-2nodes.yaml`
- `manifests/kustomization.yaml`
- `manifests/deployments.yaml`
- `manifests/statefulsets.yaml`
- `manifests/pdb.yaml`

## Workload Details

For details about what these sample Deployments and StatefulSets represent, see `workload-types.md`.

## 1. Create the Cluster

```bash
kind create cluster --name pdb-lab --config manifests/kind-2nodes.yaml
```

Verify nodes:

```bash
kubectl get nodes
```

Expected: two nodes (`pdb-lab-control-plane` and `pdb-lab-worker`).

## 2. Force Workloads onto Worker Node

Label worker node:

```bash
kubectl label node pdb-lab-worker drain-target=true
```

The workload manifests use `nodeSelector: drain-target=true`, so all workload pods schedule on `pdb-lab-worker`.

## 3. Deploy Workloads and PDBs

```bash
kubectl apply -k manifests
```

Wait for rollout:

```bash
kubectl -n pdb-lab rollout status deploy/deploy-a
kubectl -n pdb-lab rollout status deploy/deploy-b
kubectl -n pdb-lab rollout status deploy/deploy-c
kubectl -n pdb-lab rollout status sts/sts-a
kubectl -n pdb-lab rollout status sts/sts-b
```

Verify workload placement and PDBs:

```bash
kubectl -n pdb-lab get pods -o wide
kubectl -n pdb-lab get pdb
```

Expected:
- All pods run on `pdb-lab-worker`
- 5 PDBs present, each with `minAvailable: 2`

## 4. Reproduce the Drain Obstruction

### Scenario A: Direct Drain Test

Drain the worker node:

```bash
kubectl drain pdb-lab-worker --ignore-daemonsets --delete-emptydir-data --grace-period=30 --timeout=120s
```

Expected behavior:
- Drain starts eviction attempts
- Evictions are blocked/retried due to PDB constraints
- Command times out or reports inability to evict some pods due to disruption budget

You should see messages similar to:

```text
Cannot evict pod as it would violate the pod's disruption budget
```

### Scenario B: During Kubernetes Version Upgrade (Pre-Upgrade Drain)

In real upgrades, draining a node is a required pre-step before replacing/updating it. This scenario reproduces the same obstruction in that context.

Check current node versions:

```bash
kubectl get nodes
```

Mark the worker unschedulable as part of upgrade prep:

```bash
kubectl cordon pdb-lab-worker
```

Run the same pre-upgrade drain step:

```bash
kubectl drain pdb-lab-worker --ignore-daemonsets --delete-emptydir-data --grace-period=30 --timeout=120s
```

Expected behavior during upgrade prep:
- Drain fails or times out because PDB rules prevent additional pod evictions
- Node upgrade cannot safely continue until disruption constraints are handled

You should still see errors similar to:

```text
Cannot evict pod as it would violate the pod's disruption budget
```

Quick verification that upgrade is blocked at drain stage:

```bash
kubectl get nodes
kubectl -n pdb-lab get pods -o wide
```

Expected:
- `pdb-lab-worker` shows `SchedulingDisabled`
- Some workload pods remain on `pdb-lab-worker` because eviction was blocked

## 5. Inspect Why Drain Is Blocked

Check PDB disruption allowance:

```bash
kubectl -n pdb-lab get pdb
kubectl -n pdb-lab describe pdb pdb-deploy-a
kubectl -n pdb-lab describe pdb pdb-sts-a
```

Look at fields like:
- `Min available`
- `Allowed disruptions`
- `Current healthy`

When `Allowed disruptions` reaches 0 for matching workloads, further evictions are blocked.

## 6. Cleanup

```bash
kind delete cluster --name pdb-lab
```

## Next Phase

For resolution steps after reproducing the issue, continue with [phase-2-resolve-pdb-drain.md](phase-2-resolve-pdb-drain.md).
