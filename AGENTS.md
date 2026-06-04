# AGENTS.md

This file provides guidance to agents when working with code in this repository.

## Stack

- **GitOps**: ArgoCD with Kustomize + Helm
- **Environments**: `dev` and `prod` — fully parallel directory structures
- **Local dev**: k3d clusters created via [`devcontainer`](.devcontainer/devcontainer.json)
- **Secrets**: Bitnami Sealed Secrets + Emberstack Reflector for cross-namespace mirroring

## Architecture — 3-Layer ArgoCD Pattern

```
bootstrap/{env}/          Layer 1 — Root Application
  └─ appprojects-app.yaml  (sync-wave: 0, creates AppProjects first)
  └─ root-app.yaml         (points to appsets/{env}/)
appsets/{env}/            Layer 2 — ApplicationSets
  ├─ infrastructure-appset.yaml   (git directory generator)
  └─ workload-appset.yaml         (matrix: directory + config.json files)
apps/{infrastructure,workloads}/  Layer 3 — Generated Apps
```

**Critical naming convention**: Application names are derived from the directory segment: `{{index .path.segments 2}}-{env}` — so `apps/infrastructure/traefik/overlays/dev` becomes `traefik-dev`.

## Non-Obvious Patterns

- **Workload apps use a matrix generator**: The workload appset reads [`config.json`](apps/workloads/sample-app/overlays/dev/config.json) from each overlay directory to determine chart source, repo, version, and whether it's a Git or Helm repo (`isGitRepo` flag).
- **Multi-source Helm values**: Workload appsets use a [`$values` ref](appsets/dev/workload-appset.yaml:65) pointing back to this repo, so values.yaml files are served from the same repo even when the chart comes from a different repo.
- **Infra apps use `ServerSideApply=true`** ([example](appsets/dev/infrastructure-appset.yaml:40)); workload appsets do NOT. This is intentional.
- **`selfHeal: false` on prod root-app** ([`bootstrap/prod/root-app.yaml`](bootstrap/prod/root-app.yaml:19)) — dev uses `selfHeal: true`.
- **Namespace manifests are centralized** in [`apps/infrastructure/namespaces/base/`](apps/infrastructure/namespaces/base/) and auto-registered by the scaffolder script.

## Commands (Shell-based, no package.json)

| Purpose | Command |
|---------|---------|
| Scaffold new app | [`bash scripts/create-app.sh`](scripts/create-app.sh) (interactive) |
| Create sealed secrets | [`bash scripts/create-secrets.sh dev`](scripts/create-secrets.sh) (requires `~/.secrets/sealed-secrets.pub`) |
| Bootstrap dev | `kubectl apply -f bootstrap/dev/appprojects-app.yaml -n argocd` then `kubectl apply -f bootstrap/dev/root-app.yaml -n argocd` |
| Bootstrap prod | Same pattern under `bootstrap/prod/` |

## Code Style

- All Kubernetes manifests use `apiVersion: kustomize.config.k8s.io/v1beta1` for Kustomization files
- Infrastructure apps use Helm charts via `helmCharts:` in kustomization; workloads use ArgoCD multi-source
- Every kustomization gets `argocd.argoproj.io/sync-wave` annotation
- All ArgoCD Application/AppProject resources live in `namespace: argocd`
- Secrets are encrypted (SealedSecret), never stored in plaintext
- Use `set -euo pipefail` in all shell scripts ([example](scripts/create-app.sh:2))

## Sync Waves

| Wave | Component |
|------|-----------|
| 0 | AppProjects |
| 2 | sealed-secrets, namespaces |
| 3 | infra-secrets, argocd-config |
| 4 | cert-manager, traefik, reflector, grafana-alloy |
| 5 | Workload applications |