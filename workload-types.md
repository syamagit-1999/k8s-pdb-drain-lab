# Workload Types Used in This Lab

This lab uses simple `nginx` sample applications to reproduce PDB behavior during node drain.

## Deployments

Defined in `manifests/deployments.yaml`:

- `deploy-a`
- `deploy-b`
- `deploy-c`

Characteristics:
- Controller type: `Deployment` (stateless workload)
- Replica count: `3` for each deployment
- Container image: `nginx:1.27`
- Placement: scheduled to worker with `nodeSelector: drain-target=true`

Why used:
- Represents common stateless app services in Kubernetes
- Helps validate how PDB affects Deployment pod evictions during maintenance

## StatefulSets

Defined in `manifests/statefulsets.yaml`:

- `sts-a`
- `sts-b`

Characteristics:
- Controller type: `StatefulSet` (stable pod identity and ordered behavior)
- Replica count: `3` for each StatefulSet
- Container image: `nginx:1.27`
- Includes one headless `Service` per StatefulSet
- Placement: scheduled to worker with `nodeSelector: drain-target=true`

Important note:
- These StatefulSets do not define `volumeClaimTemplates`, so they model StatefulSet controller behavior without persistent storage claims.

Why used:
- Represents workloads where stable identity/order matters
- Helps validate how PDB affects StatefulSet pod evictions during maintenance

## PodDisruptionBudgets

Defined in `manifests/pdb.yaml`.

For each of the 5 workloads:
- PDB exists with `minAvailable: 2`
- Selector matches the workload label (`app: <workload-name>`)

Effect during drain:
- Eviction is allowed only when at least 2 pods stay available for each workload
- This can block `kubectl drain` when too many pods for a workload must move at once
