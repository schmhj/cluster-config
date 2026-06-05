# GitOps Cluster Configuration

A comprehensive GitOps configuration repository for managing Kubernetes clusters with ArgoCD, featuring a multi-layered application architecture, tenant-aware prod deployments, sealed secrets management, and automated deployment of infrastructure and workload services.

## Table of Contents

- [Project Summary](#project-summary)
- [Project Structure](#project-structure)
- [ArgoCD 3-Layer Application Architecture](#argocd-3-layer-application-architecture)
- [Tenant Deployment (prod)](#tenant-deployment-prod)
- [Infrastructure Applications](#infrastructure-applications)
- [Sealed Secrets & Reflector](#sealed-secrets--reflector)
- [Workload Applications](#workload-applications)
- [Development Environment (devContainer)](#development-environment-devcontainer)

## Project Summary

This repository implements a production-ready GitOps workflow using ArgoCD and Kubernetes. It manages infrastructure components and business applications across multiple environments using a structured, declarative approach:

- **`dev`** — a single flat environment (no tenants)
- **`prod`** — a tenant-aware environment split across two tenants: `tenant-a` and `tenant-b`

The setup includes:

- **Multi-environment deployment** — Separate configurations for dev and prod environments
- **Tenant-aware prod** — Each prod tenant has its own bootstrap, ApplicationSet, and per-app tenant overlays
- **Sealed secrets management** — Secure credential storage using bitnami-labs sealed-secrets
- **Automated secret reflection** — Dynamic secret replication using Reflector
- **Helm-based workloads** — Microservices deployed via Helm charts with environment-specific values
- **GitOps automation** — Continuous reconciliation of desired vs actual cluster state

## Project Structure

```
cluster-config/
├── appprojects/                    # AppProject CRs (Layer 1.5)
│   ├── dev/
│   │   ├── infrastructure.yaml    # AppProject for dev infra apps
│   │   └── workloads.yaml         # AppProject for dev workload apps
│   └── prod/
│       ├── infrastructure.yaml    # Shared across both prod tenants
│       └── workloads.yaml         # Shared across both prod tenants
│
├── bootstrap/                      # Root application bootstrapping
│   ├── dev/
│   │   ├── appprojects-app.yaml   # Wave 0 — creates appprojects/dev/
│   │   └── root-app.yaml          # Wave 0 — points to appsets/dev/
│   └── prod/
│       ├── tenant-a/
│       │   ├── appprojects-app.yaml  # Wave 0 — creates appprojects/prod/
│       │   └── root-app.yaml         # selfHeal: false, points to appsets/prod/tenant-a/
│       └── tenant-b/
│           ├── appprojects-app.yaml  # Wave 0 — creates appprojects/prod/
│           └── root-app.yaml         # selfHeal: false, points to appsets/prod/tenant-b/
│
├── appsets/                        # ApplicationSet definitions (Layer 2)
│   ├── dev/
│   │   ├── infrastructure-appset.yaml
│   │   └── workload-appset.yaml
│   └── prod/
│       ├── tenant-a/
│       │   ├── infrastructure-appset.yaml   # scans prod-tenant/tenant-a
│       │   └── workload-appset.yaml         # matrix, scans prod/tenant/tenant-a
│       └── tenant-b/
│           ├── infrastructure-appset.yaml
│           └── workload-appset.yaml
│
├── apps/                           # Actual applications (Layer 3)
│   ├── infrastructure/             # Infrastructure components
│   │   ├── sealed-secrets/         # Sealed secrets controller
│   │   ├── infra-secrets/          # Application secrets
│   │   ├── reflector/              # Secret reflection operator
│   │   ├── argocd-config/          # ArgoCD configuration
│   │   ├── cert-manager/           # Certificate management
│   │   ├── traefik/                # Ingress controller
│   │   ├── namespaces/             # Namespace definitions
│   │   └── grafana-alloy/          # Observability stack
│   │
│   └── workloads/                  # Business applications
│       ├── sample-app/             # Example application
│       └── microservice-template/  # Template for new microservices
│
├── .devcontainer/                  # Development container setup
│   ├── devcontainer.json
│   ├── scripts/
│   │   ├── config.sh               # ENVIRONMENT + TENANT switches
│   │   ├── post-create.sh          # K3d cluster + ArgoCD install
│   │   └── post-start.sh           # Tenant-aware bootstrap
│   └── manifests/                  # K3d cluster configuration
│
├── docs/                           # Topic-specific documentation
│   ├── sealed-secrets.md
│   ├── github-app-setup.md
│   ├── docker-registry-setup.md
│   └── traefik.md
│
├── plans/                          # Design documents
│   └── tenant-deployment-strategy.md
│
└── scripts/                        # Shell-based tooling
    ├── create-app.sh               # 5-step interactive scaffolder
    └── create-secrets.sh           # Encrypted secret generation
```

Each `apps/infrastructure/{app}/` and `apps/workloads/{app}/` directory contains a `base/` plus environment overlays:

```
apps/{infrastructure,workloads}/{app}/
├── base/                              # Shared Helm values + kustomization
└── overlays/
    ├── dev/                           # Dev overlay (flat, no tenant)
    ├── prod/                          # Shared prod env config (workloads)
    ├── prod-tenant/                   # Infra prod tenant overlays (flat)
    │   ├── tenant-a/                  # → resources: ../../prod
    │   └── tenant-b/                  # → resources: ../../prod
    └── prod/tenant/                   # Workload prod tenant overlays (nested)
        ├── tenant-a/                  # config.json + values.yaml (planned)
        └── tenant-b/                  # config.json + values.yaml (planned)
```

> **Note** — The infra path uses a single `prod-tenant/` segment, while the workload path nests under `prod/tenant/`. This is **as-implemented** in the appsets. See [plans/tenant-deployment-strategy.md](plans/tenant-deployment-strategy.md) for the design discussion. No workload apps have a prod overlay yet.

## ArgoCD 3-Layer Application Architecture

This repository follows a hierarchical pattern in ArgoCD for managing deployments, with an additional AppProject layer that gets created first:

### Architecture Diagram

```
┌─────────────────────────────────────────────────────────────────────────┐
│                         ARGOCD NAMESPACE                                 │
└─────────────────────────────────────────────────────────────────────────┘

Layer 1.5: AppProject CRs (created by wave-0 bootstrap)
┌──────────────────────────────────────────────────────────────────────────┐
│  appprojects/{env}/                                                       │
│  ├─ infrastructure.yaml  (AppProject: infrastructure-{env})              │
│  └─ workloads.yaml       (AppProject: workload-{env})                    │
│  Both prod tenants share the same appprojects/prod/ directory.            │
└──────────────────────────────────────────────────────────────────────────┘
                                      ▲
                                      │ created by
                                      │
Layer 1: Root Application (Bootstrapping)
┌──────────────────────────────────────────────────────────────────────────┐
│  dev:  bootstrap/dev/{appprojects-app,root-app}.yaml                    │
│       └─ root-app → appsets/dev/   (selfHeal: true)                      │
│  prod: bootstrap/prod/{tenant-a,tenant-b}/{appprojects-app,              │
│        root-app}.yaml                                                    │
│       └─ root-app → appsets/prod/<tenant>/  (selfHeal: false)            │
└──────────────────────────────────────────────────────────────────────────┘
                                      │
                                      ▼
Layer 2: ApplicationSets (Generators)
┌──────────────────────────────────────────────────────────────────────────┐
│  dev/                          │  prod/<tenant>/                          │
│  ├─ infrastructure-appset      │  ├─ infrastructure-appset                │
│  │  (git.directories)          │  │  (git.directories)                    │
│  │  scans overlays/dev         │  │  scans overlays/prod-tenant/<tenant>  │
│  └─ workload-appset            │  └─ workload-appset                      │
│     (matrix: dir + config.json)│     (matrix: dir + config.json)          │
│     scans overlays/dev         │     scans overlays/prod/tenant/<tenant>  │
└──────────────────────────────────────────────────────────────────────────┘
                                      │
                                      ▼
Layer 3: Individual Applications (Deployed Resources)
┌──────────────────────────────────────────────────────────────────────────┐
│  Infrastructure Namespace (argocd)         │  Workload Namespace         │
│  ├─ sealed-secrets controller              │  ├─ sample-app             │
│  ├─ reflector controller                   │  ├─ microservice-template  │
│  ├─ cert-manager                           │  └─ [other microservices]  │
│  ├─ traefik ingress controller             │                             │
│  ├─ argocd-config                          │                             │
│  └─ application secrets                    │                             │
│  Application names:                        │                             │
│  ├─ dev:    {app-name}-dev                 │                             │
│  └─ prod:   {app-name}-prod-{tenant}       │                             │
└──────────────────────────────────────────────────────────────────────────┘
```

### How It Works

1. **Bootstrap `appprojects-app`** (wave 0) — deploys AppProject CRs from `appprojects/{env}/` so the rest of the appset can reference them. The bootstrap `appprojects-app` is **per-tenant** in prod, but both tenants deploy the same `appprojects/prod/` directory.
2. **Bootstrap `root-app`** (wave 0) — points to `appsets/{env}/` (dev) or `appsets/prod/<tenant>/` (prod). Self-heal is `true` in dev and `false` in prod tenants.
3. **Layer 2 - ApplicationSets** — Two ApplicationSets generate individual Applications dynamically:
   - **Infrastructure ApplicationSet**: Discovers all infrastructure apps under `apps/infrastructure/*/overlays/{env}` (dev) or `apps/infrastructure/*/overlays/prod-tenant/<tenant>` (prod).
   - **Workload ApplicationSet**: Discovers all workload apps under `apps/workloads/*/overlays/{env}` (dev) or `apps/workloads/*/overlays/prod/tenant/<tenant>` (prod). It uses a **matrix generator** to read `config.json` for chart metadata.
4. **Layer 3 - Individual Apps** — Each generated Application deploys actual resources to the cluster. The Application name is derived from the directory structure: `{{app-name}}-dev` for dev and `{{app-name}}-prod-{tenant}` for prod.

### Bootstrap Commands

Each tenant requires **two `kubectl apply` calls**, in this order:

```bash
# dev
kubectl apply -f bootstrap/dev/appprojects-app.yaml -n argocd
kubectl apply -f bootstrap/dev/root-app.yaml         -n argocd

# prod tenant-a
kubectl apply -f bootstrap/prod/tenant-a/appprojects-app.yaml -n argocd
kubectl apply -f bootstrap/prod/tenant-a/root-app.yaml        -n argocd

# prod tenant-b
kubectl apply -f bootstrap/prod/tenant-b/appprojects-app.yaml -n argocd
kubectl apply -f bootstrap/prod/tenant-b/root-app.yaml        -n argocd
```

### Sync Waves

Sync waves control deployment order:

| Wave | Component | Source |
|------|-----------|--------|
| 0 | `appprojects-app` Application (bootstrap) | `bootstrap/{env,prod/<tenant>}/appprojects-app.yaml` |
| 2 | AppProject CRs, sealed-secrets, namespaces | `appprojects/{env}/`, `apps/infrastructure/{sealed-secrets,namespaces}/overlays/...` |
| 3 | infra-secrets, argocd-config | AppSet template sets wave based on `.path.segments[2]` |
| 4 | cert-manager, traefik, reflector, grafana-alloy | AppSet template sets wave based on `.path.segments[2]` |
| 5 | Workload applications | Hard-coded in the workload appset template |

> AppProject CRs themselves carry `sync-wave: "2"` — they need to exist before the appset-generated apps reference them in later waves.

## Tenant Deployment (prod)

The `prod` environment is split across two independent tenants: `tenant-a` and `tenant-b`. Each tenant runs its own ArgoCD instance that manages itself (no multi-cluster hub); the destination is always `https://kubernetes.default.svc`.

### Key Principles

- **Directory presence = deployment target** — Create `apps/infrastructure/{app}/overlays/prod-tenant/{tenant}/` to deploy that app to a tenant. Omit the directory and the app is not deployed to that tenant.
- **AppProjects are shared** — Both prod tenants deploy the same `appprojects/prod/` directory. AppProject CRs only differ in name (`infrastructure-dev` vs `infrastructure-prod`, etc.) and both target `kubernetes.default.svc`.
- **Per-tenant ApplicationSets** — `appsets/prod/{tenant-a,tenant-b}/` each scan only the matching tenant overlay path.
- **`selfHeal: false` on prod root-apps** — The prod tenant `root-app` does not self-heal; the ApplicationSets and the apps themselves still do.
- **Default = both tenants** — The scaffolder defaults to deploying to both tenants when prod is selected.

### Per-App Tenant Overlay Pattern

Infrastructure apps in prod have one shared `overlays/prod/` plus per-tenant kustomizations:

```
apps/infrastructure/traefik/
├── base/
│   ├── kustomization.yaml
│   └── values.yaml
└── overlays/
    ├── dev/                          # dev overlay
    └── prod/                         # shared prod config
        ├── kustomization.yaml
        └── *.yaml
    └── prod-tenant/                  # per-tenant kustomizations
        ├── tenant-a/
        │   └── kustomization.yaml    # resources: - ../..
        └── tenant-b/
            └── kustomization.yaml    # resources: - ../..
```

Workload apps in prod follow a different layout (nested under `prod/tenant/`):

```
apps/workloads/my-app/
├── base/
│   └── values.yaml
└── overlays/
    ├── dev/
    │   ├── config.json
    │   └── values.yaml
    └── prod/
        ├── values.yaml
        └── tenant/
            ├── tenant-a/
            │   ├── config.json       # chart metadata
            │   └── values.yaml
            └── tenant-b/
                ├── config.json
                └── values.yaml
```

For the full design discussion, see [plans/tenant-deployment-strategy.md](plans/tenant-deployment-strategy.md).

## Infrastructure Applications

Infrastructure apps are the foundation services that enable the cluster to operate. Located under `apps/infrastructure/{app-name}/`.

### sealed-secrets

**Purpose**: Encrypts secrets for safe storage in Git

- **Type**: Bitnami sealed-secrets controller
- **Namespace**: `kube-system`
- **Sync Wave**: 2 (deploys first)
- **What it does**:
  - Provides a public key for encrypting secrets
  - Decrypts sealed secrets in the cluster using a private key
  - Enables storing encrypted secrets in the Git repository safely
- **Usage**: Create sealed secrets locally, commit encrypted YAML to Git, controller decrypts on deployment

### infra-secrets

**Purpose**: Stores encrypted infrastructure credentials needed by other services

**Location**: `apps/infrastructure/infra-secrets/overlays/{env}/` for dev and shared `overlays/prod/`; per-tenant overlays in `overlays/prod-tenant/{tenant}/` for prod.

**Contents** (example):
- `traefik-secret.yaml` - Traefik dashboard credentials
- `certmanager-sealedsecret.yaml` - Certificate issuer credentials
- `grafana-cloud-sealedsecret.yaml` - Grafana Cloud integration secrets
- `dockerconfig-sealedsecret.yaml` - Docker registry pull secrets

**Sync Wave**: 3 (deploys after sealed-secrets is ready)

### reflector

**Purpose**: Automatically copies and reflects secrets across namespaces

- **Type**: Reflector controller (Helm chart from emberstack)
- **Version**: 10.0.16
- **Namespace**: managed via the ApplicationSet's `destination.namespace` (defaults to `argocd`)
- **What it does**:
  - Watches secrets in source namespace (e.g., `kube-system`)
  - Automatically copies them to target namespaces (e.g., workload namespaces)
  - Keeps copies in sync when source secret changes

**How it works with sealed-secrets**:
1. Sealed-secrets controller decrypts secrets in `kube-system` namespace
2. Reflector watches for these secrets
3. Any secret with a reflection annotation (e.g., `reflector.v1.mit.edu/reflection-allowed: "true"`) is copied
4. Reflector can be configured via target annotations (e.g., `reflector.v1.mit.edu/reflection-allowed: "true"`)
5. Target namespaces get a copy of the secret with the same name

**Configuration Example**:
```yaml
# In the secret that should be reflected:
metadata:
  annotations:
    reflector.v1.mit.edu/reflection-allowed: "true"  # Allow reflection
    reflector.v1.mit.edu/reflection-auto-enabled: "true"  # Auto-reflect to labeled namespaces
```

### Other Infrastructure Apps

- **argocd-config**: ArgoCD configuration, AppProjects, and RBAC policies
- **cert-manager**: Kubernetes certificate management (TLS certificates)
- **traefik**: Ingress controller and reverse proxy
- **namespaces**: Namespace resource definitions with labels and annotations
- **grafana-alloy**: Observability and monitoring stack

## Sealed Secrets & Reflector

### Creating Sealed Secrets

1. **Install kubeseal** (client-side tool):
   ```bash
   # Install from bitnami-labs/sealed-secrets
   # See docs: https://github.com/bitnami-labs/sealed-secrets#installation-from-source
   ```

2. **Create a sealed secret**:
   ```bash
   # Option A: With access to the cluster
   kubectl create secret generic secret-name \
     --dry-run=client \
     --from-literal=foo=bar \
     -o yaml | kubeseal \
       --controller-name=sealed-secrets \
       --controller-namespace=kube-system \
       --format yaml > mysealedsecret.yaml
   ```

   ```bash
   # Option B: Using local certificate (no cluster access needed)
   # Fetch the public cert:
   kubeseal \
     --controller-name=sealed-secrets \
     --controller-namespace=kube-system \
     --fetch-cert > ~/.secrets/sealed-secrets-cert.pem

   # Create sealed secret with local cert:
   kubectl create secret generic secret-name \
     --dry-run=client \
     --from-literal=foo=bar \
     -o yaml | kubeseal \
       --cert ~/.secrets/sealed-secrets-cert.pem \
       --format yaml > mysealedsecret.yaml
   ```

   Or run the bundled scaffolder:
   ```bash
   bash scripts/create-secrets.sh dev   # or "prod"
   ```

3. **Important Notes**:
   - Sealed secret and generated secret must have the same name and namespace
   - The encrypted file is safe to commit to Git
   - Only the cluster with the private key can decrypt it
   - Dev and prod clusters use different sealed-secrets key pairs. The dev pair is stored in `SEALED_SECRETS_PRIVATE_KEY` / `SEALED_SECRETS_CERT` (loaded by the devContainer). The prod pair is expected as `SEALED_SECRETS_PRIVATE_KEY_PROD` / `SEALED_SECRETS_CERT_PROD` by `post-create.sh` and needs to be added to the devContainer's `remoteEnv` block.

### How infra-secrets Uses Reflector

```
┌──────────────────────────────────────────────────────────────┐
│                                                              │
│  1. Sealed Secret in Git                                    │
│     └─ Encrypted with sealed-secrets public key             │
│                                                              │
│  2. ArgoCD deploys to kube-system namespace                 │
│     └─ sealed-secrets controller decrypts it                │
│                                                              │
│  3. Decrypted Secret in kube-system namespace               │
│     └─ Has annotation: reflector.v1.mit.edu/reflection...  │
│                                                              │
│  4. Reflector watches and copies secret                     │
│     └─ To all labeled namespaces (workload namespace)       │
│                                                              │
│  5. Workload apps can use the copied secret                 │
│     └─ Without having access to sealed-secrets keys         │
│                                                              │
└──────────────────────────────────────────────────────────────┘
```

## Workload Applications

Workload applications are business logic microservices deployed via Helm charts. Located under `apps/workloads/{app-name}/`.

### Directory Structure

Each workload application follows this pattern:

```
apps/workloads/my-microservice/
├── base/
│   ├── values.yaml              # Base values (common across envs)
│   └── kustomization.yaml       # (if needed)
│
├── overlays/
│   ├── dev/                     # Dev overlay (flat)
│   │   ├── values.yaml          # Dev-specific Helm values
│   │   └── config.json          # Chart metadata & repo info
│   │
│   └── prod/                    # Shared prod config
│       ├── values.yaml          # Shared prod Helm values
│       └── tenant/              # Per-tenant overlays
│           ├── tenant-a/
│           │   ├── values.yaml  # Tenant-specific Helm values
│           │   └── config.json  # Chart metadata & repo info
│           └── tenant-b/
│               ├── values.yaml
│               └── config.json
```

### config.json

Each scanned overlay (dev or prod tenant) must have a `config.json` file with chart metadata:

```json
{
    "appName": "my-microservice",
    "chartRepo": "https://my-helm-repo.com",
    "chartName": "my-chart",
    "chartVersion": "1.2.3",
    "isGitRepo": false
}
```

**Fields**:
- `appName`: Application identifier
- `chartRepo`: Helm repository URL
- `chartName`: Helm chart name
- `chartVersion`: Specific chart version
- `isGitRepo`: Whether chart is in a Git repo (`true`) or Helm registry (`false`)

**Where it lives**:
- Dev: `apps/workloads/{app}/overlays/dev/config.json`
- Prod: `apps/workloads/{app}/overlays/prod/tenant/{tenant-a,tenant-b}/config.json`

### How to Onboard a New Microservice

Use the interactive scaffolder, which walks through 5 steps:

```bash
bash scripts/create-app.sh
```

**Step 1/5 — App Type**: `infrastructure` or `workload`
**Step 2/5 — App Name**: identifier (letters, numbers, hyphens, underscores)
**Step 3/5 — Target Environments**: dev only, prod only, or both
**Step 4/5 — Target Tenants (prod)**: tenant-a only, tenant-b only, or both (default)
**Step 5/5 — Helm Chart Details** (optional): chart name/repo/version, namespace, isGitRepo

For dev-only, a single `config.json` is created directly in `overlays/dev/`. For prod, `config.json` and a placeholder `values.yaml` are created in `overlays/prod/tenant/{tenant}/` for each selected tenant.

After scaffolding, commit and push:

```bash
git add apps/workloads/my-app/
git commit -m "feat: onboard my-app microservice"
git push
```

ArgoCD then discovers the new directory and deploys automatically.

### Using the Microservice Template

A template is provided at `apps/workloads/microservice-template/` as a reference. The scaffolder generates the same layout, so you can also scaffold a new workload and then customize the files.

## Development Environment (devContainer)

### What is devContainer?

A devContainer provides a consistent, containerized development environment. When using GitHub Codespaces or VS Code Remote - Containers, it automatically sets up all tools needed to work with this repository.

### Configuration

**Location**: `.devcontainer/devcontainer.json`

**Base Image**: `quay.io/akuity/argo-cd-learning-assets/akuity-devcontainer:0.2.5`

**Features**:
- Docker-in-Docker enabled for building container images
- Pre-installed tools for Kubernetes and ArgoCD
- 4 CPU cores recommended

### Environment & Tenant Switch

The devContainer picks up `ENVIRONMENT` and `TENANT` from `.devcontainer/scripts/config.sh`:

```bash
export ENVIRONMENT=dev   # or "prod"
export TENANT=tenant-a   # or "tenant-b"
```

`post-start.sh` uses these to select the correct bootstrap path:

```bash
if [[ $ENVIRONMENT == "prod" ]]; then
    kubectl apply -f "bootstrap/prod/${TENANT:-tenant-a}/appprojects-app.yaml" -n argocd
    kubectl apply -f "bootstrap/prod/${TENANT:-tenant-a}/root-app.yaml"        -n argocd
else
    kubectl apply -f bootstrap/dev/appprojects-app.yaml -n argocd
    kubectl apply -f bootstrap/dev/root-app.yaml         -n argocd
fi
```

### Available Services (Port Forwarding)

When running in devContainer with K3d cluster, these services are automatically forwarded:

| Port | Service | Protocol | Purpose |
|------|---------|----------|---------|
| 30179 | Argo CD Dashboard | HTTPS | ArgoCD web UI |
| 30280 | Sample App | HTTP | Example application |
| 32056 | Microservice Template | HTTP | Template application |
| 30443 | Traefik Dashboard | HTTP | Ingress controller metrics |
| 30480 | Traefik Dashboard | HTTP | Alternative Traefik dashboard |

### Secrets in devContainer

The devContainer loads secrets from GitHub Codespaces secrets. The current `.devcontainer/devcontainer.json` `remoteEnv` block is:

```json
{
  "remoteEnv": {
    "SEALED_SECRETS_PRIVATE_KEY": "${{ secrets.SEALED_SECRETS_PRIVATE_KEY }}",
    "SEALED_SECRETS_CERT":        "${{ secrets.SEALED_SECRETS_CERT }}",
    "ARGOCD_GITOPS_AUTH_BOT_KEY": "${{ secrets.ARGOCD_GITOPS_AUTH_BOT_KEY }}"
  }
}
```

`post-create.sh` selects the dev or prod key pair based on `ENVIRONMENT` and writes them to `~/.secrets/`. For the prod path it expects `SEALED_SECRETS_PRIVATE_KEY_PROD` and `SEALED_SECRETS_CERT_PROD` to also be present in the environment; if you intend to use `ENVIRONMENT=prod`, add those two entries to both the Codespaces secrets **and** the `remoteEnv` block in `.devcontainer/devcontainer.json`.

**To set these secrets** in Codespaces:
1. Go to Settings → Codespaces → Secrets
2. Add the secrets:
   - `SEALED_SECRETS_PRIVATE_KEY` / `SEALED_SECRETS_CERT` — dev key pair
   - `SEALED_SECRETS_PRIVATE_KEY_PROD` / `SEALED_SECRETS_CERT_PROD` — prod key pair (only needed if you switch `ENVIRONMENT=prod`)
   - `ARGOCD_GITOPS_AUTH_BOT_KEY` — GitHub token for ArgoCD to access repos

### Lifecycle Scripts

**Post-Create** (`.devcontainer/scripts/post-create.sh`):
- Runs after the container is first created
- Installs dependencies and sets up the environment
- Creates K3d clusters with pre-configured manifests (`k3d-dev.yaml`, `k3d-managed.yaml`)
- Installs ArgoCD and kubeseal

**Post-Start** (`.devcontainer/scripts/post-start.sh`):
- Runs every time the container starts
- Waits for ArgoCD to be ready and updates the admin password
- Runs the dev or tenant-specific prod bootstrap based on `config.sh`

### Getting Started with devContainer

1. **Using GitHub Codespaces**:
   - Click "Code" → "Codespaces" → "Create codespace on main"
   - Wait for setup to complete (2-3 minutes)
   - Ports will be automatically forwarded

2. **Using VS Code Remote**:
   - Install "Remote - Containers" extension
   - Open folder in container: `Cmd/Ctrl + Shift + P` → "Open Folder in Container"
   - Select this repository directory
   - Wait for setup to complete

3. **Manual setup** (if devContainer not available):
   - Install: kubectl, helm, kubeseal, k3d
   - Run: `.devcontainer/scripts/post-create.sh`
   - Edit `.devcontainer/scripts/config.sh` to choose ENVIRONMENT and TENANT

### VS Code Extensions

The devContainer includes:
- Code Spell Checker
- Code Spell Checker (British English)

Add more extensions by modifying `.devcontainer/devcontainer.json` in the `customizations.vscode.extensions` array.
