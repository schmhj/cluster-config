# GitOps Cluster Configuration

A comprehensive GitOps configuration repository for managing Kubernetes clusters with ArgoCD, featuring a multi-layered application architecture, sealed secrets management, and automated deployment of infrastructure and workload services.

## Table of Contents

- [Project Summary](#project-summary)
- [Project Structure](#project-structure)
- [ArgoCD 3-Layer Application Architecture](#argocd-3-layer-application-architecture)
- [Infrastructure Applications](#infrastructure-applications)
- [Sealed Secrets & Reflector](#sealed-secrets--reflector)
- [Workload Applications](#workload-applications)
- [Development Environment (devContainer)](#development-environment-devcontainer)

## Project Summary

This repository implements a production-ready GitOps workflow using ArgoCD and Kubernetes. It manages infrastructure components and business applications across multiple environments (dev/prod) using a structured, declarative approach. The setup includes:

- **Multi-environment deployment** - Separate configurations for dev and prod environments
- **Sealed secrets management** - Secure credential storage using bitnami-labs sealed-secrets
- **Automated secret reflection** - Dynamic secret replication using Reflector
- **Helm-based workloads** - Microservices deployed via Helm charts with environment-specific values
- **GitOps automation** - Continuous reconciliation of desired vs actual cluster state

## Project Structure

```
cluster-config/
├── bootstrap/                    # Root application bootstrapping
│   ├── dev/
│   │   ├── root-app.yaml        # Entry point for dev environment
│   │   └── appprojects-app.yaml # AppProject definitions for dev
│   └── prod/
│       ├── root-app.yaml        # Entry point for prod environment
│       └── appprojects-app.yaml # AppProject definitions for prod
│
├── appsets/                      # ApplicationSet definitions (Layer 2)
│   ├── dev/
│   │   ├── infrastructure-appset.yaml
│   │   └── workload-appset.yaml
│   └── prod/
│       ├── infrastructure-appset.yaml
│       └── workload-appset.yaml
│
├── apps/                         # Actual applications (Layer 3)
│   ├── infrastructure/           # Infrastructure components
│   │   ├── sealed-secrets/       # Sealed secrets controller
│   │   ├── infra-secrets/        # Application secrets
│   │   ├── reflector/            # Secret reflection operator
│   │   ├── argocd-config/        # ArgoCD configuration
│   │   ├── cert-manager/         # Certificate management
│   │   ├── traefik/              # Ingress controller
│   │   ├── namespaces/           # Namespace definitions
│   │   └── grafana-alloy/        # Observability stack
│   │
│   └── workloads/                # Business applications
│       ├── sample-app/           # Example application
│       └── microservice-template/ # Template for new microservices
│
├── .devcontainer/                # Development container setup
│   ├── devcontainer.json         # DevContainer configuration
│   ├── scripts/                  # Setup and startup scripts
│   └── manifests/                # K3d cluster configuration
│
└── docs/                         # Documentation
    ├── sealed-secrets.md
    ├── github-app-setup.md
    ├── docker-registry-setup.md
    └── traefik.md
```

## ArgoCD 3-Layer Application Architecture

This repository follows a hierarchical 3-layer pattern in ArgoCD for managing deployments:

### Architecture Diagram

```
┌─────────────────────────────────────────────────────────────────────────┐
│                         ARGOCD NAMESPACE                                 │
└─────────────────────────────────────────────────────────────────────────┘

Layer 1: Root Application (Bootstrapping)
┌──────────────────────────────────────────────────────────────────────────┐
│                                                                           │
│  root-app (Application)                                                  │
│  ├─ Points to: appsets/{env}/ directory                                 │
│  ├─ Auto-syncs: Yes (with pruning)                                      │
│  └─ Purpose: Entry point for entire environment                         │
│                                                                           │
└──────────────────────────────────────────────────────────────────────────┘
                                    │
                                    ▼
Layer 2: ApplicationSets (Generators)
┌──────────────────────────────────────────────────────────────────────────┐
│                                                                           │
│  ┌─────────────────────────┐    ┌──────────────────────────────────────┐ │
│  │infrastructure-appset     │    │ workload-appset                      │ │
│  ├─Generator: Git Directory │    ├─Generator: Git Directory + Files    │ │
│  ├─Path Pattern:            │    ├─Path Pattern:                       │ │
│  │ apps/infrastructure/*/   │    │ apps/workloads/*/overlays/{env}     │ │
│  │ overlays/{env}           │    ├─Reads: config.json for values       │ │
│  ├─Sync Wave: 2,3,4         │    ├─Sync Wave: 5                        │ │
│  └─Namespace: argocd        │    └─Namespace: workload                 │ │
│     (auto-creates from path │                                          │ │
│      segments)              │                                          │ │
│                             │                                          │ │
│  Generated Apps:            │     Generated Apps:                      │ │
│  ├─ sealed-secrets-{env}    │     ├─ sample-app-{env}                │ │
│  ├─ cert-manager-{env}      │     ├─ microservice-template-{env}     │ │
│  ├─ traefik-{env}           │     └─ [other microservices-{env}]     │ │
│  ├─ reflector-{env}         │                                        │ │
│  ├─ infra-secrets-{env}     │                                        │ │
│  └─ [other infra apps]      │                                        │ │
│                             │                                          │ │
└─────────────────────────────┴──────────────────────────────────────────┘
                                    │
                                    ▼
Layer 3: Individual Applications (Deployed Resources)
┌──────────────────────────────────────────────────────────────────────────┐
│                                                                           │
│ Infrastructure Namespace          │  Workload Namespace                  │
│ ├─ sealed-secrets controller       │  ├─ sample-app pods/services       │
│ ├─ reflector controller            │  ├─ microservice-template services  │
│ ├─ cert-manager                    │  └─ [other microservices]          │
│ ├─ traefik ingress controller      │                                     │
│ ├─ ArgoCD configuration            │                                     │
│ └─ application secrets             │                                     │
│                                    │                                     │
└────────────────────────────────────┴─────────────────────────────────────┘
```

### How It Works

1. **Layer 1 - Root App**: The `root-app` Application in the argocd namespace points to the `appsets/{environment}` directory
2. **Layer 2 - ApplicationSets**: Two ApplicationSets generate individual Applications dynamically:
   - **Infrastructure ApplicationSet**: Discovers all infrastructure apps under `apps/infrastructure/*/overlays/{env}`
   - **Workload ApplicationSet**: Discovers all workload apps under `apps/workloads/*/overlays/{env}`
3. **Layer 3 - Individual Apps**: Each generated Application deploys actual resources to the cluster

### Sync Waves

Sync waves control deployment order:
- **Wave 2**: sealed-secrets (must deploy first)
- **Wave 3**: infra-secrets (depends on sealed-secrets)
- **Wave 4**: Other infrastructure (cert-manager, traefik, etc.)
- **Wave 5**: Workload applications

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

**Location**: `apps/infrastructure/infra-secrets/overlays/{env}/`

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
- **Namespace**: `infrastructure`
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

3. **Important Notes**:
   - Sealed secret and generated secret must have the same name and namespace
   - The encrypted file is safe to commit to Git
   - Only the cluster with the private key can decrypt it

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
│   ├── kustomization.yaml       # (if needed)
│   └── Chart.yaml               # (if Helm chart)
│
├── overlays/
│   ├── dev/
│   │   ├── values.yaml          # Dev-specific Helm values
│   │   ├── config.json          # Chart metadata & repo info
│   │   └── kustomization.yaml   # (if needed)
│   │
│   └── prod/
│       ├── values.yaml          # Prod-specific Helm values
│       ├── config.json          # Chart metadata & repo info
│       └── kustomization.yaml   # (if needed)
```

### config.json

Each overlay must have a `config.json` file with chart metadata:

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

### How to Onboard a New Microservice

1. **Create directory structure**:
   ```bash
   mkdir -p apps/workloads/my-app/base apps/workloads/my-app/overlays/{dev,prod}
   ```

2. **Create base values** (`apps/workloads/my-app/base/values.yaml`):
   ```yaml
   # Common values shared across all environments
   replicaCount: 1
   ```

3. **Create environment-specific values**:

   `apps/workloads/my-app/overlays/dev/values.yaml`:
   ```yaml
   # Dev-specific overrides
   replicaCount: 1
   image:
     tag: dev-latest
   ```

   `apps/workloads/my-app/overlays/prod/values.yaml`:
   ```yaml
   # Prod-specific overrides
   replicaCount: 3
   image:
     tag: v1.2.3
   ```

4. **Create config.json** in each overlay:

   `apps/workloads/my-app/overlays/dev/config.json`:
   ```json
   {
       "appName": "my-app",
       "chartRepo": "https://my-helm-repo.com",
       "chartName": "my-chart",
       "chartVersion": "1.2.3",
       "isGitRepo": false
   }
   ```

   Same for `prod/config.json` (can use different versions if needed).

5. **Commit and push**:
   ```bash
   git add apps/workloads/my-app/
   git commit -m "feat: onboard my-app microservice"
   git push
   ```

6. **ArgoCD discovers and deploys automatically**:
   - The workload ApplicationSet scans for `config.json` files
   - New applications are generated and deployed
   - Check ArgoCD UI to verify deployment

### Using the Microservice Template

A template is provided at `apps/workloads/microservice-template/` as a reference. Copy and customize it for your microservice.

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

The devContainer loads secrets from GitHub Codespaces secrets:

```json
{
  "remoteEnv": {
    "SEALED_SECRETS_PRIVATE_KEY": "${{ secrets.SEALED_SECRETS_PRIVATE_KEY }}",
    "SEALED_SECRETS_CERT": "${{ secrets.SEALED_SECRETS_CERT }}",
    "ARGOCD_GITOPS_AUTH_BOT_KEY": "${{ secrets.ARGOCD_GITOPS_AUTH_BOT_KEY }}"
  }
}
```

**To set these secrets** in Codespaces:
1. Go to Settings → Codespaces → Secrets
2. Add the three secrets:
   - `SEALED_SECRETS_PRIVATE_KEY`: Private key for decrypting sealed secrets
   - `SEALED_SECRETS_CERT`: Public certificate for sealed secrets
   - `ARGOCD_GITOPS_AUTH_BOT_KEY`: GitHub token for ArgoCD to access repos

### Lifecycle Scripts

**Post-Create** (`.devcontainer/scripts/post-create.sh`):
- Runs after the container is first created
- Installs dependencies and sets up the environment
- Creates K3d cluster with pre-configured manifests

**Post-Start** (`.devcontainer/scripts/post-start.sh`):
- Runs every time the container starts
- Can be used to sync state or start services

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

### VS Code Extensions

The devContainer includes:
- Code Spell Checker
- Code Spell Checker (British English)

Add more extensions by modifying `.devcontainer/devcontainer.json` in the `customizations.vscode.extensions` array.

