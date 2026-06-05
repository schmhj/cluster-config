# AGENTS.md

This file provides guidance to agents when working with code in this repository.

## Stack

- **GitOps**: ArgoCD with Kustomize + Helm
- **Environments**: `dev` (flat) and `prod` (tenant-aware: `tenant-a`, `tenant-b`)
- **Local dev**: k3d clusters created via [`devcontainer`](.devcontainer/devcontainer.json)
- **Secrets**: Bitnami Sealed Secrets + Emberstack Reflector for cross-namespace mirroring

## Architecture — 3-Layer ArgoCD Pattern

```
appprojects/{env}/      AppProject CRs (infrastructure.yaml, workloads.yaml)
                        — created by the wave-0 bootstrap Application, no
                          tenant split in prod (both tenants share the same
                          AppProjects pointing at kubernetes.default.svc)

bootstrap/{env}/        Layer 1 — Root Application
  └─ dev/
      └─ appprojects-app.yaml  (sync-wave: 0, deploys appprojects/dev/)
      └─ root-app.yaml         (sync-wave: implicit 0, points to appsets/dev/)
  └─ prod/{tenant-a,tenant-b}/
      └─ appprojects-app.yaml  (sync-wave: 0, deploys appprojects/prod/)
      └─ root-app.yaml         (sync-wave: 0, selfHeal: false,
                                points to appsets/prod/<tenant>/)

appsets/{env}/          Layer 2 — ApplicationSets
  ├─ dev/
  │   ├─ infrastructure-appset.yaml   (git directory generator)
  │   └─ workload-appset.yaml         (matrix: directory + config.json)
  └─ prod/{tenant-a,tenant-b}/
      ├─ infrastructure-appset.yaml   (git directory generator,
      │                                scans prod-tenant/<tenant>/)
      └─ workload-appset.yaml         (matrix: directory + config.json,
                                       scans prod/tenant/<tenant>/)

apps/{infrastructure,workloads}/   Layer 3 — Generated Apps
  ├─ .../overlays/dev/               (flat; no tenant subdir)
  └─ .../overlays/prod-tenant/{tenant-a,tenant-b}/  (infra)
     .../overlays/prod/tenant/{tenant-a,tenant-b}/  (workloads)
```

**Application naming convention** (derived from `.path.segments`):
- Dev: `{{index .path.segments 2}}-dev` → e.g. `traefik-dev`
- Prod tenant: `{{index .path.segments 2}}-prod-{tenant}` → e.g. `traefik-prod-tenant-a`

**Path-segment caveat**: infra prod paths use `prod-tenant/<tenant>/` (segment index 6 = tenant), workload prod paths use `prod/tenant/<tenant>/` (segment index 6 = tenant). The naming template `{{index .path.segments 2}}` works for both, but the path-segment-indexing in `valueFiles` differs — see "Non-Obvious Patterns" below.

## Non-Obvious Patterns

- **Workload apps use a matrix generator**: The workload appset reads [`config.json`](apps/workloads/sample-app/overlays/dev/config.json) from each overlay directory to determine chart source, repo, version, and whether it's a Git or Helm repo (`isGitRepo` flag).
- **Multi-source Helm values**: Workload appsets use a [`$values` ref](appsets/dev/workload-appset.yaml:67) pointing back to this repo, so values.yaml files are served from the same repo even when the chart comes from a different repo.
- **Infra apps use `ServerSideApply=true`** ([example](appsets/dev/infrastructure-appset.yaml:40)); workload appsets do NOT. This is intentional.
- **AppProject CRs carry `sync-wave: "2"`** ([example](appprojects/dev/infrastructure.yaml:7)), while the bootstrap Application that creates them uses `sync-wave: "0"` ([example](bootstrap/dev/appprojects-app.yaml:7)). The bootstrap App itself is wave 0, the AppProject resources it deploys are wave 2.
- **`selfHeal: false` on prod tenant root-apps** ([example](bootstrap/prod/tenant-a/root-app.yaml:20), [tenant-b](bootstrap/prod/tenant-b/root-app.yaml)) — dev uses `selfHeal: true` on both the root-app and the ApplicationSets.
- **Prod infra appsets pin to a feature branch** during rollout ([`feature/deployment-strategy`](appsets/prod/tenant-a/infrastructure-appset.yaml:12)) rather than `HEAD`; dev infra appsets track `HEAD`.
- **Infra vs workload prod path inconsistency**: infra uses `apps/infrastructure/*/overlays/prod-tenant/<tenant>/` (single `prod-tenant` segment) but the workload appset scans `apps/workloads/*/overlays/prod/tenant/<tenant>/` (nested `prod/tenant/`). This is **as-implemented**, not what the original plan document described — see [`plans/tenant-deployment-strategy.md`](plans/tenant-deployment-strategy.md) for the design doc.
- **Directory presence = deployment target**: omitting `prod-tenant/<tenant>/` (infra) or `prod/tenant/<tenant>/` (workloads) means the app is not deployed to that tenant.
- **Namespace manifests are centralized** in [`apps/infrastructure/namespaces/base/`](apps/infrastructure/namespaces/base/) and auto-registered by the scaffolder script.

## Commands (Shell-based, no package.json)

| Purpose | Command |
|---------|---------|
| Scaffold new app | [`bash scripts/create-app.sh`](scripts/create-app.sh) (interactive, 5 steps incl. tenant selection for prod) |
| Create sealed secrets | [`bash scripts/create-secrets.sh <env>`](scripts/create-secrets.sh) — `<env>` is `dev` or `prod`; requires `~/.secrets/sealed-secrets.pub` |
| Bootstrap dev | `kubectl apply -f bootstrap/dev/appprojects-app.yaml -n argocd` then `kubectl apply -f bootstrap/dev/root-app.yaml -n argocd` |
| Bootstrap prod `tenant-a` | `kubectl apply -f bootstrap/prod/tenant-a/appprojects-app.yaml -n argocd` then `kubectl apply -f bootstrap/prod/tenant-a/root-app.yaml -n argocd` |
| Bootstrap prod `tenant-b` | `kubectl apply -f bootstrap/prod/tenant-b/appprojects-app.yaml -n argocd` then `kubectl apply -f bootstrap/prod/tenant-b/root-app.yaml -n argocd` |
| Pick devcontainer env/tenant | Edit [`ENVIRONMENT` and `TENANT`](.devcontainer/scripts/config.sh) |

## Code Style

- All Kubernetes manifests use `apiVersion: kustomize.config.k8s.io/v1beta1` for Kustomization files
- Infrastructure apps use Helm charts via `helmCharts:` in kustomization; workloads use ArgoCD multi-source
- Every kustomization gets `argocd.argoproj.io/sync-wave` annotation
- All ArgoCD Application/AppProject resources live in `namespace: argocd`
- Secrets are encrypted (SealedSecret), never stored in plaintext
- Use `set -euo pipefail` in all shell scripts ([example](scripts/create-app.sh:2))

## Sync Waves

| Wave | Component | Notes |
|------|-----------|-------|
| 0 | `appprojects-app` Application (bootstrap) | Creates the wave-2 AppProject CRs |
| 2 | sealed-secrets, namespaces, AppProject CRs | AppProjects must exist before the appset-generated apps reference them |
| 3 | infra-secrets, argocd-config | Depends on sealed-secrets |
| 4 | cert-manager, traefik, reflector, grafana-alloy | Set via appset template: `{{ if eq (index .path.segments 2) "sealed-secrets" }}2{{ else if eq (index .path.segments 2) "infra-secrets" }}3{{ else }}4{{ end }}` |
| 5 | Workload applications | Hard-coded in the workload appset template |

Tenant does not affect sync ordering — both prod tenants share the same wave plan.
