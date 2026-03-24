# Kubernetes PDB Drain Lab

Reproducible lab for a common Kubernetes upgrade problem: node drain blocked by PodDisruptionBudgets (PDBs).

This repository helps you:
- Reproduce PDB-blocked drain behavior on a 2-node kind cluster.
- Understand why drain can still fail even after relaxing PDBs.
- Resolve safely with two operational approaches.

## Lab Topology

- 2-node kind cluster (`control-plane` + `worker`)
- 3 Deployments (`replicas: 3` each)
- 2 StatefulSets (`replicas: 3` each)
- 5 PDBs (`minAvailable: 2` each)

## Repository Structure

- [manifests/kind-2nodes.yaml](manifests/kind-2nodes.yaml): kind cluster config
- [manifests/kustomization.yaml](manifests/kustomization.yaml): apply all manifests
- [manifests/deployments.yaml](manifests/deployments.yaml): sample Deployments
- [manifests/statefulsets.yaml](manifests/statefulsets.yaml): sample StatefulSets
- [manifests/pdb.yaml](manifests/pdb.yaml): PDB definitions
- [phase-1-reproduce-pdb-drain-issue.md](phase-1-reproduce-pdb-drain-issue.md): Phase 1 reproduction
- [phase-2-resolve-pdb-drain.md](phase-2-resolve-pdb-drain.md): Phase 2 (PDB relaxation approach)
- [phase-2-no-pdb-change-approach.md](phase-2-no-pdb-change-approach.md): Phase 2 alternative (no PDB changes)
- [workload-types.md](workload-types.md): workload explanation
- [scripts/phase2-resolve-pdb-drain.sh](scripts/phase2-resolve-pdb-drain.sh): automate PDB-relaxation flow
- [scripts/phase2-no-pdb-change-drain.sh](scripts/phase2-no-pdb-change-drain.sh): automate no-PDB-change flow

## Prerequisites

- Docker running
- `kind` installed
- `kubectl` installed
- WSL/bash available (for script execution)

## Quick Start

1. Create the cluster:

```bash
kind create cluster --name pdb-lab --config manifests/kind-2nodes.yaml
```

2. Label worker for workload placement:

```bash
kubectl label node pdb-lab-worker drain-target=true
```

3. Deploy workloads and PDBs:

```bash
kubectl apply -k manifests
```

4. Verify:

```bash
kubectl get nodes
kubectl -n pdb-lab get pods -o wide
kubectl -n pdb-lab get pdb
```

## Phase Flow

### Phase 1: Reproduce the Problem

Follow [phase-1-reproduce-pdb-drain-issue.md](phase-1-reproduce-pdb-drain-issue.md).

Expected symptom:

```text
Cannot evict pod as it would violate the pod's disruption budget
```

### Phase 2: Resolve the Problem

Choose one approach:

1. PDB relaxation approach:
- Guide: [phase-2-resolve-pdb-drain.md](phase-2-resolve-pdb-drain.md)
- Script: [scripts/phase2-resolve-pdb-drain.sh](scripts/phase2-resolve-pdb-drain.sh)

2. No-PDB-change approach (recommended for this lab):
- Guide: [phase-2-no-pdb-change-approach.md](phase-2-no-pdb-change-approach.md)
- Script: [scripts/phase2-no-pdb-change-drain.sh](scripts/phase2-no-pdb-change-drain.sh)

## Script Usage

Run from WSL/bash at repo root.

### PDB relaxation script

```bash
chmod +x scripts/phase2-resolve-pdb-drain.sh
./scripts/phase2-resolve-pdb-drain.sh
```

Optional pause:

```bash
./scripts/phase2-resolve-pdb-drain.sh --wait-for-upgrade-step
```

### No-PDB-change script

```bash
chmod +x scripts/phase2-no-pdb-change-drain.sh
./scripts/phase2-no-pdb-change-drain.sh
```

Notes:
- Pause is enabled by default in this script.
- To skip pause, use `--no-wait`.
- In non-interactive shells, resume by creating marker file:

```bash
touch .tmp/upgrade.resume
```

- Deployments with `replicas: 1` are auto-scaled to `2` before drain and restored after upgrade resume (disable via `--disable-auto-scale-singletons`).

## Why Drain Can Stall

Drain is constrained by both:
- PDB disruption rules
- Scheduler capacity/placement constraints (taints, node selectors, affinity, free capacity)

In this lab, workloads are pinned to `drain-target=true`. If only worker has that label, replacements cannot schedule while draining worker unless temporary capacity is enabled.

## Safety Notes

- This is a learning lab, not production-ready automation.
- Avoid `kubectl drain --disable-eviction` except break-glass emergencies.
- Keep any temporary policy/scheduling relaxations as short as possible.
- Always verify workloads are healthy after maintenance.

## Cleanup

```bash
kind delete cluster --name pdb-lab
```

## Contributing

Issues and PRs are welcome. If you add scenarios, include:
- reproduction steps
- expected output
- rollback/cleanup steps

## License

This project is licensed under the MIT License. See [LICENSE](LICENSE).
