# Code Rules (Non-Obvious Only)

- **Infrastructure apps** use `helmCharts:` in their [`kustomization.yaml`](apps/infrastructure/sealed-secrets/base/kustomization.yaml:5) with `valuesFile: values.yaml`. The ArgoCD ApplicationSet picks up the kustomize directory directly.
- **Workload apps** do NOT use kustomize `helmCharts:`. Instead, the workload ApplicationSet ([example](appsets/dev/workload-appset.yaml:50)) builds multi-source ArgoCD Applications using `templatePatch` — it reads [`config.json`](apps/workloads/sample-app/overlays/dev/config.json) for chart source and `isGitRepo` to toggle between `chart:` and `path:`.
- When adding a new infrastructure app with a new namespace, the scaffolder auto-registers it in [`apps/infrastructure/namespaces/base/kustomization.yaml`](apps/infrastructure/namespaces/base/kustomization.yaml:5). If adding one manually, you MUST add it there.
- `ServerSideApply=true` is required in the infrastructure ApplicationSet's `syncOptions` ([line 40](appsets/dev/infrastructure-appset.yaml:40)) — some infra charts (especially sealed-secrets CRDs) will fail without it.
- Workload app names are derived from `{{index .path.segments 2}}` — the third segment of the directory path. Renaming an app directory renames the ArgoCD Application.
- Shell scripts must use `set -euo pipefail` ([example](scripts/create-app.sh:2)).