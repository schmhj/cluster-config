# Documentation/Ask Rules (Non-Obvious Only)

- **This repo has no code to compile or tests to run** — it's purely Kubernetes manifests and ArgoCD configuration. All "commands" are `kubectl apply` or shell scripts.
- **Infrastructure apps** (under `apps/infrastructure/`) are deployed via Kustomize + Helm with a git directory generator in the ApplicationSet. Each subdirectory automatically becomes a generated ArgoCD Application.
- **Workload apps** (under `apps/workloads/`) require a [`config.json`](apps/workloads/sample-app/overlays/dev/config.json) in each overlay that specifies the Helm chart source. Without this file, the matrix generator produces no applications.
- **New apps are scaffolded** with [`scripts/create-app.sh`](scripts/create-app.sh) — an interactive wizard. Never create app directories manually.
- **Secrets must be encrypted** as SealedSecret resources before committing. Use [`scripts/create-secrets.sh`](scripts/create-secrets.sh). Plain Kubernetes Secrets in the repo will be rejected.
- **The `microservice-template`** under [`apps/workloads/microservice-template/`](apps/workloads/microservice-template/) is a reference implementation for OCI-chart workloads with image pull secrets and Grafana Alloy/OTel collector configuration.