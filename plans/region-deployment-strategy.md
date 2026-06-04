# Region-Aware Deployment Strategy (v2)

## Overview

Add **region** as a deployment dimension for the **prod** environment only. Two regions: `us-ashburn-1` and `us-chicago-1`. Each ArgoCD instance manages itself independently within its region — there is no multi-cluster hub. Each app (infrastructure or workload) can target one region, both regions, or neither (by omitting the region directory). Default is both regions.

## Key Design Decision: Model A — Independent Deployment Control

Each ArgoCD instance deploys **only** apps intended for its region. Region identity is determined by which bootstrap path an ArgoCD instance follows:

- An ArgoCD instance in `us-ashburn-1` applies `bootstrap/prod/us-ashburn-1/`
- An ArgoCD instance in `us-chicago-1` applies `bootstrap/prod/us-chicago-1/`

The destination server is always `https://kubernetes.default.svc` (self-managing). No multi-cluster destination URLs are needed.

**Dev** has no region awareness — it always uses the flat `bootstrap/dev/` and `appsets/dev/` structure.

---

## 1. Directory Structure

```
bootstrap/
├── dev/                              # unchanged — flat, no region
│   ├── appprojects-app.yaml
│   └── root-app.yaml                 # → appsets/dev/
└── prod/
    ├── us-ashburn-1/                 # NEW — region-specific bootstrap
    │   ├── appprojects-app.yaml      # → appprojects/prod/ (same AppProjects)
    │   └── root-app.yaml             # → appsets/prod/us-ashburn-1/
    └── us-chicago-1/                 # NEW — region-specific bootstrap
        ├── appprojects-app.yaml      # → appprojects/prod/
        └── root-app.yaml             # → appsets/prod/us-chicago-1/

appsets/
├── dev/                              # unchanged — flat, no region
│   ├── infrastructure-appset.yaml    # scans apps/infrastructure/*/overlays/dev
│   └── workload-appset.yaml          # scans apps/workloads/*/overlays/dev
└── prod/
    ├── us-ashburn-1/                 # NEW — region-specific ApplicationSets
    │   ├── infrastructure-appset.yaml  # scans .../overlays/prod/region/us-ashburn-1
    │   └── workload-appset.yaml        # scans .../overlays/prod/region/us-ashburn-1
    └── us-chicago-1/                 # NEW — region-specific ApplicationSets
        ├── infrastructure-appset.yaml  # scans .../overlays/prod/region/us-chicago-1
        └── workload-appset.yaml        # scans .../overlays/prod/region/us-chicago-1

apps/
├── infrastructure/{app}/overlays/
│   ├── dev/                          # unchanged — flat, no region subdir
│   │   └── kustomization.yaml
│   └── prod/
│       ├── kustomization.yaml        # unchanged — shared env config
│       ├── *.yaml                    # unchanged — shared patches
│       └── region/                   # NEW
│           ├── us-ashburn-1/
│           │   └── kustomization.yaml  # resources: - ../..
│           └── us-chicago-1/
│               └── kustomization.yaml  # resources: - ../..
└── workloads/{app}/overlays/
    ├── dev/                          # unchanged — flat
    │   ├── config.json
    │   └── values.yaml
    └── prod/
        ├── values.yaml               # unchanged — shared env values
        └── region/                   # NEW
            ├── us-ashburn-1/
            │   ├── config.json       # chart deployment config (scanned by region appset)
            │   └── values.yaml       # region-specific helm values
            └── us-chicago-1/
                ├── config.json
                └── values.yaml
```

**Principle**: directory presence = deployment target. No region directory = no deployment to that region.

---

## 2. No region.json Files

Unlike the v1 design, **no `region.json` files** are needed. Region identity is implicit in the ApplicationSet path:

- [`appsets/prod/us-ashburn-1/infrastructure-appset.yaml`](appsets/prod/us-ashburn-1/infrastructure-appset.yaml) hardcodes the region path: `apps/infrastructure/*/overlays/prod/region/us-ashburn-1`
- [`appsets/prod/us-chicago-1/infrastructure-appset.yaml`](appsets/prod/us-chicago-1/infrastructure-appset.yaml) hardcodes the region path: `apps/infrastructure/*/overlays/prod/region/us-chicago-1`

The generator is a simple `git.directories` — no matrix generator needed for infrastructure.

---

## 3. ApplicationSet Design

### 3.1 Infrastructure ApplicationSet

**File**: [`appsets/prod/us-ashburn-1/infrastructure-appset.yaml`](appsets/prod/us-ashburn-1/infrastructure-appset.yaml)

Simple `git.directories` generator (no matrix):

```yaml
generators:
  - git:
      repoURL: https://github.com/schmhj/cluster-config.git
      revision: HEAD
      directories:
        - path: apps/infrastructure/*/overlays/prod/region/us-ashburn-1
template:
  metadata:
    name: "{{index .path.segments 2}}-prod-us-ashburn-1"
    labels:
      region: us-ashburn-1
spec:
  destination:
    server: https://kubernetes.default.svc
```

**Path segment mapping**:
| Segment Index | Value |
|---|---|
| `.path.segments[0]` | `apps` |
| `.path.segments[1]` | `infrastructure` |
| `.path.segments[2]` | app name (e.g., `traefik`) |
| `.path.segments[3]` | `overlays` |
| `.path.segments[4]` | `prod` |
| `.path.segments[5]` | `region` |
| `.path.segments[6]` | `us-ashburn-1` |

**Application naming**: `{{index .path.segments 2}}-prod-us-ashburn-1` → e.g., `traefik-prod-us-ashburn-1`

### 3.2 Workload ApplicationSet

**File**: [`appsets/prod/us-ashburn-1/workload-appset.yaml`](appsets/prod/us-ashburn-1/workload-appset.yaml)

Matrix generator (`git.directories` × `git.files`):

```yaml
generators:
  - matrix:
      generators:
        - git:
            directories:
              - path: apps/workloads/*/overlays/prod/region/us-ashburn-1
        - git:
            files:
              - path: "{{.path.path}}/config.json"
```

**Values path** (in `templatePatch`):
```yaml
- $values/apps/workloads/{{index .path.segments 2}}/base/values.yaml
- $values/apps/workloads/{{index .path.segments 2}}/overlays/prod/region/{{index .path.segments 6}}/values.yaml
```

---

## 4. AppProject Changes

**No changes from original.** All 4 AppProject manifests in [`appprojects/{dev,prod}/`](appprojects/dev/infrastructure.yaml) use a single destination:

```yaml
destinations:
  - namespace: "*"
    server: "https://kubernetes.default.svc"
```

No multi-cluster server URLs are needed since each ArgoCD instance manages itself.

---

## 5. Bootstrap Layer

### 5.1 Dev (unchanged)

```
bootstrap/dev/
├── appprojects-app.yaml    → deploys appprojects/dev/
└── root-app.yaml           → deploys appsets/dev/
```

### 5.2 Prod (region-aware)

```
bootstrap/prod/us-ashburn-1/
├── appprojects-app.yaml    → deploys appprojects/prod/ (same AppProjects for both regions)
└── root-app.yaml           → deploys appsets/prod/us-ashburn-1/

bootstrap/prod/us-chicago-1/
├── appprojects-app.yaml    → deploys appprojects/prod/
└── root-app.yaml           → deploys appsets/prod/us-chicago-1/
```

Both region root apps point to the same [`appprojects/prod/`](appprojects/prod/) directory for AppProjects, but different ApplicationSet directories. This means both regions share the same AppProject definitions (which is fine — they both use `kubernetes.default.svc`).

**Bootstrap commands per region**:

```bash
# us-ashburn-1 ArgoCD instance
kubectl apply -f bootstrap/prod/us-ashburn-1/appprojects-app.yaml -n argocd
kubectl apply -f bootstrap/prod/us-ashburn-1/root-app.yaml -n argocd

# us-chicago-1 ArgoCD instance
kubectl apply -f bootstrap/prod/us-chicago-1/appprojects-app.yaml -n argocd
kubectl apply -f bootstrap/prod/us-chicago-1/root-app.yaml -n argocd
```

---

## 6. Scaffolder Updates

**File**: [`scripts/create-app.sh`](scripts/create-app.sh)

### Region Selection (Step 4/5)

Only shown when "prod" is among the selected environments:

```
Step 4/5: Target Regions (prod)
  (1) us-ashburn-1 only
  (2) us-chicago-1 only
  (3) both regions (default)
```

### File Creation Logic

**For infrastructure apps**:
- Always creates `base/values.yaml` and `base/kustomization.yaml`
- Always creates `overlays/{env}/kustomization.yaml`
- Creates `overlays/prod/region/{region}/kustomization.yaml` (resources: `- ../..`) only for prod overlays
- Never creates `region.json` files

**For workload apps**:
- Always creates `base/values.yaml`
- For **dev** overlays: creates `config.json` directly in `overlays/dev/`
- For **prod** overlays: creates `values.yaml` and `config.json` in `overlays/prod/region/{region}/`
- Creates `overlays/{env}/values.yaml` as a shared placeholder

### Key guard condition

```bash
if [[ "$overlay_dir" == */prod && ${#REGIONS[@]} -gt 0 ]]; then
  # scaffold region subdirectories
else
  # scaffold flat (dev) files
fi
```

This ensures region directories are only created under prod overlays, even when both dev and prod are selected.

---

## 7. DevContainer Configuration

### [`config.sh`](.devcontainer/scripts/config.sh)

```bash
export ENVIRONMENT=prod
export REGION=us-ashburn-1
```

### [`post-start.sh`](.devcontainer/scripts/post-start.sh)

Prod bootstrap uses `$REGION` to select the correct bootstrap path:

```bash
if [[ $ENVIRONMENT == "prod" ]]; then
    kubectl apply -f "bootstrap/prod/${REGION:-us-ashburn-1}/appprojects-app.yaml" -n argocd
    kubectl apply -f "bootstrap/prod/${REGION:-us-ashburn-1}/root-app.yaml" -n argocd
else
    kubectl apply -f bootstrap/dev/appprojects-app.yaml -n argocd
    kubectl apply -f bootstrap/dev/root-app.yaml -n argocd
fi
```

---

## 8. Sync Waves (unchanged)

| Wave | Component |
|------|-----------|
| 0 | AppProjects |
| 2 | sealed-secrets, namespaces |
| 3 | infra-secrets, argocd-config |
| 4 | cert-manager, traefik, reflector, grafana-alloy |
| 5 | Workload applications |

Region does not affect sync ordering.

---

## 9. Architecture Diagram

```mermaid
flowchart TD
    subgraph Bootstrap["bootstrap/prod/"]
        B1["us-ashburn-1/<br/>appprojects-app.yaml<br/>root-app.yaml"]
        B2["us-chicago-1/<br/>appprojects-app.yaml<br/>root-app.yaml"]
    end

    subgraph AppProjects["appprojects/prod/"]
        IP["infrastructure.yaml<br/>→ kubernetes.default.svc"]
        WP["workloads.yaml<br/>→ kubernetes.default.svc"]
    end

    subgraph AppSets["appsets/prod/"]
        ASH1["us-ashburn-1/<br/>infrastructure-appset.yaml<br/>workload-appset.yaml"]
        ASH2["us-chicago-1/<br/>infrastructure-appset.yaml<br/>workload-appset.yaml"]
    end

    subgraph Apps["apps/"]
        subgraph Infra["infrastructure/{app}/overlays/prod/"]
            R1["region/us-ashburn-1/<br/>kustomization.yaml"]
            R2["region/us-chicago-1/<br/>kustomization.yaml"]
        end
        subgraph WL["workloads/{app}/overlays/prod/"]
            W1["region/us-ashburn-1/<br/>config.json + values.yaml"]
            W2["region/us-chicago-1/<br/>config.json + values.yaml"]
        end
    end

    B1 --> ASH1
    B2 --> ASH2
    B1 -.-> IP
    B2 -.-> IP
    ASH1 --> Infra
    ASH1 --> WL
    ASH2 --> Infra
    ASH2 --> WL
```

---

## 10. Complete File Change Inventory (v2)

| File | Change |
|------|--------|
| `bootstrap/prod/us-ashburn-1/appprojects-app.yaml` | **NEW** — bootstraps AppProjects for us-ashburn-1 |
| `bootstrap/prod/us-ashburn-1/root-app.yaml` | **NEW** — points to `appsets/prod/us-ashburn-1/` |
| `bootstrap/prod/us-chicago-1/appprojects-app.yaml` | **NEW** — bootstraps AppProjects for us-chicago-1 |
| `bootstrap/prod/us-chicago-1/root-app.yaml` | **NEW** — points to `appsets/prod/us-chicago-1/` |
| `appsets/prod/us-ashburn-1/infrastructure-appset.yaml` | **NEW** — scans `region/us-ashburn-1` dirs |
| `appsets/prod/us-ashburn-1/workload-appset.yaml` | **NEW** — scans `region/us-ashburn-1` dirs |
| `appsets/prod/us-chicago-1/infrastructure-appset.yaml` | **NEW** — scans `region/us-chicago-1` dirs |
| `appsets/prod/us-chicago-1/workload-appset.yaml` | **NEW** — scans `region/us-chicago-1` dirs |
| `appsets/prod/infrastructure-appset.yaml` | **DELETED** — superseded by region-specific versions |
| `appsets/prod/workloads-appset.yaml` | **DELETED** — superseded by region-specific versions |
| `bootstrap/prod/appprojects-app.yaml` | **DELETED** — superseded by region-specific versions |
| `bootstrap/prod/root-app.yaml` | **DELETED** — superseded by region-specific versions |
| `appprojects/dev/infrastructure.yaml` | Unchanged (single `kubernetes.default.svc` destination) |
| `appprojects/dev/workloads.yaml` | Unchanged |
| `appprojects/prod/infrastructure.yaml` | Unchanged |
| `appprojects/prod/workloads.yaml` | Unchanged |
| `apps/infrastructure/*/overlays/prod/region/{us-ashburn-1,us-chicago-1}/` | **NEW** — region kustomization overlays |
| `apps/workloads/*/overlays/prod/region/{us-ashburn-1,us-chicago-1}/` | **NEW** — region-specific config.json + values.yaml |
| `.devcontainer/scripts/config.sh` | **MODIFIED** — added `REGION` variable |
| `.devcontainer/scripts/post-start.sh` | **MODIFIED** — region-aware prod bootstrap |
| `scripts/create-app.sh` | **MODIFIED** — added region selection step, prod-only region scaffolding |

---

## 11. Implementation Notes

- **`ServerSideApply=true`** remains on infrastructure appsets only.
- **Production `selfHeal: false`** preserved on prod root-apps; `selfHeal: true` on prod ApplicationSets.
- **Dev `selfHeal: true`** on both dev root-app and dev ApplicationSets.
- **No region.json files** — region identity is implicit in the ApplicationSet path.
- **No matrix generator for infrastructure** — simple `git.directories` is sufficient since the region path is hardcoded.
- **Workload appsets still use matrix generator** — to read `config.json` for chart metadata.
- **Two-step bootstrap per region**: Apply `appprojects-app.yaml` (wave 0) first, then `root-app.yaml`.
- **All destinations** use `https://kubernetes.default.svc` — each ArgoCD instance manages itself.