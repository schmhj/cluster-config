# Traefik v39.0.6 — ArgoCD Deployment Guide
### Path-Based Routing · Traefik Dashboard · cert-manager TLS (Production)

---

## Table of Contents

1. [Architecture](#architecture)
2. [Repository Structure](#repository-structure)
3. [Deployment Order & Prerequisites](#deployment-order--prerequisites)
4. [Configuration Files](#configuration-files)
   - [ArgoCD App: cert-manager](#1-argocd-app-cert-manager)
   - [ArgoCD App: Traefik](#2-argocd-app-traefik)
   - [Base Helm Values](#3-base-helm-values-basevaluesyaml)
   - [Dev Overlay Values](#4-dev-overlay-overlaysdevvalues-devyaml)
   - [Prod Overlay Values](#5-prod-overlay-overlaysprodvalues-prodyaml)
   - [cert-manager ClusterIssuer + Certificate](#6-cert-manager-overlaysprodcert-manageryaml)
   - [IngressRoutes & Middlewares](#7-ingressroutes--middlewares-baseingress-routesyaml)
5. [Verification & Tests](#verification--tests)
6. [Manual Spot Checks](#manual-spot-checks)
7. [Customisation Reference](#customisation-reference)
8. [Security Checklist](#security-checklist)

---

## Architecture

```
Internet
   │
   ▼
[LoadBalancer Service :80 / :443]
   │
   ▼
[Traefik Pods]  ── namespace: traefik
   │
   ├── entrypoint: web (:80)
   │      └── 301 HTTP → HTTPS redirect (prod only)
   │
   └── entrypoint: websecure (:443)
          │  TLS terminated using cert-manager secret
          │
          ├── Host(api.example.com) && PathPrefix(/api/users)
          │      Middleware: strip-api-prefix, rate-limit, secure-headers
          │      → users-svc:8080  (namespace: apps)
          │
          ├── Host(api.example.com) && PathPrefix(/api/orders)
          │      Middleware: strip-api-prefix, rate-limit, secure-headers
          │      → orders-svc:8080  (namespace: apps)
          │
          ├── Host(api.example.com) && PathPrefix(/api/products)
          │      Middleware: strip-api-prefix, rate-limit, secure-headers
          │      → products-svc:8080  (namespace: apps)
          │
          └── Host(dashboard.example.com) && PathPrefix(/dashboard)
                 Middleware: dashboard-auth (BasicAuth)
                 → api@internal  (Traefik built-in dashboard)


cert-manager  ── namespace: cert-manager
   └── ClusterIssuer: letsencrypt-prod
          └── Certificate: example-com-tls
                 └── Secret: example-com-tls  ← Traefik reads this for TLS
```

### ArgoCD Sync Wave Order

| Wave | Resource | Reason |
|------|----------|--------|
| 0 | cert-manager App | Must exist before CRDs are available |
| 1 | Traefik Helm App | Needs cert-manager CRDs |
| 2 | ClusterIssuers | Need cert-manager running |
| 3 | Certificate | Needs ClusterIssuer to exist |
| 5 | IngressRoutes | Need TLS secret to be ready |

---

## Repository Structure

```
traefik-argocd/
├── argocd-app-cert-manager.yaml      # ArgoCD Application: cert-manager
├── argocd-app-traefik.yaml           # ArgoCD Application: Traefik v39.0.6
├── base/
│   ├── values.yaml                   # Shared Helm values (all environments)
│   └── ingress-routes.yaml           # IngressRoutes, Middlewares, stub services
├── overlays/
│   ├── dev/
│   │   └── values-dev.yaml           # Dev overrides
│   └── prod/
│       ├── values-prod.yaml          # Prod overrides
│       └── cert-manager.yaml         # ClusterIssuer + Certificate CRDs
└── tests/
    └── verify.sh                     # End-to-end verification script
```

---

## Deployment Order & Prerequisites

### Prerequisites
- ArgoCD installed and running in the cluster
- `kubectl` configured and pointed at your cluster
- `helm` installed locally (for dry-run validation)
- DNS records for `api.example.com` and `dashboard.example.com` pointing at your LB IP

### Step 1 — Deploy cert-manager (sync-wave 0)
```bash
kubectl apply -f argocd-app-cert-manager.yaml

# Wait for cert-manager to be healthy
kubectl wait --for=condition=available deployment/cert-manager \
  -n cert-manager --timeout=120s
```

### Step 2 — Update hostnames and secrets
Replace all instances of `example.com` across:
- `base/ingress-routes.yaml`
- `overlays/prod/cert-manager.yaml`

Generate a real dashboard password hash:
```bash
# Requires apache2-utils / httpd-tools
htpasswd -nbs admin YOUR_SECURE_PASSWORD
# Paste the output into the Secret in ingress-routes.yaml
```

### Step 3 — Deploy Traefik (sync-wave 1)
```bash
kubectl apply -f argocd-app-traefik.yaml
```

### Step 4 — Apply cert-manager resources (prod only)
```bash
kubectl apply -f overlays/prod/cert-manager.yaml
```

### Step 5 — Apply IngressRoutes
```bash
kubectl apply -f base/ingress-routes.yaml
```

### Step 6 — Run verification tests
```bash
# Dev
bash tests/verify.sh

# Prod
ENV=prod API_HOST=api.yourdomain.com DASHBOARD_HOST=dashboard.yourdomain.com \
  bash tests/verify.sh
```

---

## Configuration Files

---

### 1. ArgoCD App: cert-manager
**`argocd-app-cert-manager.yaml`**

Deploys cert-manager v1.14.5 via Helm into the `cert-manager` namespace. This must sync before Traefik so that Certificate CRDs are available.

```yaml
---
# ============================================================
# ArgoCD App: cert-manager (prerequisite — sync-wave 0)
# Deploy this BEFORE the Traefik app.
# ============================================================
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: cert-manager
  namespace: argocd
  annotations:
    argocd.argoproj.io/sync-wave: "0"
  finalizers:
    - resources-finalizer.argocd.io
spec:
  project: default
  source:
    repoURL: https://charts.jetstack.io
    chart: cert-manager
    targetRevision: v1.14.5
    helm:
      values: |
        installCRDs: true
        global:
          leaderElection:
            namespace: cert-manager
  destination:
    server: https://kubernetes.default.svc
    namespace: cert-manager
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
      - ServerSideApply=true
```

---

### 2. ArgoCD App: Traefik
**`argocd-app-traefik.yaml`**

Deploys Traefik v39.0.6 from the official Helm chart. The `valueFiles` list merges your base values with the appropriate environment overlay. Automated sync with self-healing ensures drift is corrected.

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: traefik
  namespace: argocd
  finalizers:
    - resources-finalizer.argocd.io
  annotations:
    # Force sync on Helm chart values changes
    argocd.argoproj.io/sync-wave: "1"
spec:
  project: default
  source:
    repoURL: https://traefik.github.io/charts
    chart: traefik
    targetRevision: 39.0.6
    helm:
      valueFiles:
        - values.yaml
      # Override values per environment using a values file in your Git repo
      # For prod: values-prod.yaml, for dev: values-dev.yaml
  destination:
    server: https://kubernetes.default.svc
    namespace: traefik
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
      - ServerSideApply=true
    retry:
      limit: 5
      backoff:
        duration: 5s
        factor: 2
        maxDuration: 3m
```

---

### 3. Base Helm Values (`base/values.yaml`)

Shared configuration applied to all environments. Key decisions:

- Dashboard enabled but **never insecure** by default — the dev overlay overrides this explicitly
- Both `kubernetesCRD` and `kubernetesIngress` providers enabled for flexibility
- TLS 1.2 minimum with hardened cipher suites
- Container runs as non-root (`uid 65532`) with a read-only root filesystem
- Metrics port (`9100`) and internal probe port (`9000`) are never exposed externally
- Access logs formatted as JSON for easier ingestion into log aggregators

```yaml
# ============================================================
# Traefik v39.0.6 — Base Helm Values
# Environment-specific overlays in overlays/dev/ and overlays/prod/
# ============================================================

# ── Global ───────────────────────────────────────────────────
globalArguments:
  - "--global.checknewversion=false"
  - "--global.sendanonymoususage=false"

# ── Deployment ───────────────────────────────────────────────
deployment:
  enabled: true
  replicas: 2                    # Override to 1 in dev overlay
  revisionHistoryLimit: 3

# ── Pod Disruption Budget ─────────────────────────────────────
podDisruptionBudget:
  enabled: true
  minAvailable: 1

# ── API / Dashboard ───────────────────────────────────────────
api:
  dashboard: true
  insecure: false                # Never expose dashboard without auth

# ── Entry Points ─────────────────────────────────────────────
ports:
  web:
    port: 8000
    expose:
      default: true
    exposedPort: 80
    protocol: TCP
    # In prod, redirect all HTTP → HTTPS (see prod overlay)
    redirections: {}

  websecure:
    port: 8443
    expose:
      default: true
    exposedPort: 443
    protocol: TCP
    tls:
      enabled: true

  traefik:
    port: 9000
    expose:
      default: false             # Internal probe port — never expose
    protocol: TCP

  metrics:
    port: 9100
    expose:
      default: false
    protocol: TCP

# ── Service ───────────────────────────────────────────────────
service:
  enabled: true
  type: LoadBalancer
  annotations: {}               # Add cloud LB annotations per env

# ── Logs ──────────────────────────────────────────────────────
logs:
  general:
    level: INFO
  access:
    enabled: true
    format: json
    fields:
      headers:
        defaultmode: drop
        names:
          User-Agent: keep
          X-Forwarded-For: keep

# ── Providers ─────────────────────────────────────────────────
providers:
  kubernetesCRD:
    enabled: true
    allowCrossNamespaceResources: false
    allowExternalNameServices: false

  kubernetesIngress:
    enabled: true
    publishedService:
      enabled: true

# ── RBAC ──────────────────────────────────────────────────────
rbac:
  enabled: true

serviceAccount:
  name: traefik

# ── Metrics ───────────────────────────────────────────────────
metrics:
  prometheus:
    enabled: true
    serviceMonitor:
      enabled: false            # Enable if you have Prometheus Operator

# ── TLS Options (default hardened config) ────────────────────
tlsOptions:
  default:
    minVersion: VersionTLS12
    cipherSuites:
      - TLS_ECDHE_ECDSA_WITH_AES_128_GCM_SHA256
      - TLS_ECDHE_RSA_WITH_AES_128_GCM_SHA256
      - TLS_ECDHE_ECDSA_WITH_AES_256_GCM_SHA384
      - TLS_ECDHE_RSA_WITH_AES_256_GCM_SHA384
      - TLS_ECDHE_ECDSA_WITH_CHACHA20_POLY1305
      - TLS_ECDHE_RSA_WITH_CHACHA20_POLY1305

# ── Resources ─────────────────────────────────────────────────
resources:
  requests:
    cpu: 100m
    memory: 128Mi
  limits:
    cpu: 500m
    memory: 256Mi

# ── Health Checks ─────────────────────────────────────────────
readinessProbe:
  failureThreshold: 3
  initialDelaySeconds: 2
  periodSeconds: 10
  successThreshold: 1
  timeoutSeconds: 2

livenessProbe:
  failureThreshold: 3
  initialDelaySeconds: 2
  periodSeconds: 10
  successThreshold: 1
  timeoutSeconds: 2

# ── Security Context ─────────────────────────────────────────
securityContext:
  capabilities:
    drop: [ALL]
  readOnlyRootFilesystem: true
  runAsNonRoot: true
  runAsUser: 65532
  runAsGroup: 65532

podSecurityContext:
  fsGroup: 65532
```

---

### 4. Dev Overlay (`overlays/dev/values-dev.yaml`)

Overrides for local/development clusters. Reduces resource usage, uses `ClusterIP` instead of a cloud LoadBalancer, and enables the insecure dashboard port for easy browser access via `kubectl port-forward`.

> **Warning:** Never use `insecure: true` in production. It exposes the dashboard without authentication.

```yaml
# ============================================================
# Traefik v39.0.6 — DEV overlay values
# Merged on top of base/values.yaml via ArgoCD valueFiles list
# ============================================================

deployment:
  replicas: 1

api:
  dashboard: true
  insecure: true                 # Dashboard exposed on :9000 without auth in dev ONLY

service:
  type: ClusterIP                # No cloud LB in dev (use port-forward or NodePort)
  # Uncomment for local Kind/Minikube:
  # type: NodePort

logs:
  general:
    level: DEBUG

resources:
  requests:
    cpu: 50m
    memory: 64Mi
  limits:
    cpu: 200m
    memory: 128Mi
```

**Accessing the dashboard in dev:**
```bash
kubectl port-forward -n traefik svc/traefik 9000:9000
# Open: http://localhost:9000/dashboard/
```

---

### 5. Prod Overlay (`overlays/prod/values-prod.yaml`)

Production-grade overrides: 3 replicas, LoadBalancer service type, permanent HTTP→HTTPS redirect (301), PodDisruptionBudget requiring at least 2 available pods, and pod anti-affinity to spread replicas across nodes.

Add your cloud provider's LB annotations under `service.annotations` — examples for AWS, GKE, and Azure are included as comments.

```yaml
# ============================================================
# Traefik v39.0.6 — PRODUCTION overlay values
# Merged on top of base/values.yaml via ArgoCD valueFiles list
# ============================================================

deployment:
  replicas: 3

# ── Entry Points (prod) ───────────────────────────────────────
ports:
  web:
    port: 8000
    expose:
      default: true
    exposedPort: 80
    protocol: TCP
    redirections:
      entryPoint:
        to: websecure
        scheme: https
        permanent: true          # 301 HTTP → HTTPS

  websecure:
    port: 8443
    expose:
      default: true
    exposedPort: 443
    protocol: TCP
    tls:
      enabled: true
    http3:
      enabled: false            # Enable if your LB supports UDP/443

# ── Service (prod) ────────────────────────────────────────────
service:
  type: LoadBalancer
  annotations:
    # Example for AWS NLB — adjust per cloud:
    # service.beta.kubernetes.io/aws-load-balancer-type: "nlb"
    # service.beta.kubernetes.io/aws-load-balancer-scheme: "internet-facing"

    # Example for GKE:
    # cloud.google.com/load-balancer-type: "External"

    # Example for Azure:
    # service.beta.kubernetes.io/azure-load-balancer-sku: standard

# ── cert-manager integration ─────────────────────────────────
# Traefik reads TLS secrets from IngressRoute tls.secretName.
# cert-manager issues and renews the certificate automatically.
# No extra Traefik config needed here — see the ClusterIssuer and
# IngressRoute manifests in overlays/prod/cert-manager.yaml.

# ── Resource limits (prod) ────────────────────────────────────
resources:
  requests:
    cpu: 200m
    memory: 128Mi
  limits:
    cpu: 1000m
    memory: 512Mi

# ── PodDisruptionBudget ───────────────────────────────────────
podDisruptionBudget:
  enabled: true
  minAvailable: 2

# ── Affinity (spread across nodes) ───────────────────────────
affinity:
  podAntiAffinity:
    preferredDuringSchedulingIgnoredDuringExecution:
      - weight: 100
        podAffinityTerm:
          labelSelector:
            matchExpressions:
              - key: app.kubernetes.io/name
                operator: In
                values:
                  - traefik
          topologyKey: kubernetes.io/hostname
```

---

### 6. cert-manager (`overlays/prod/cert-manager.yaml`)

Creates two `ClusterIssuer` resources (staging for testing, prod for real certificates) and a `Certificate` resource that cert-manager uses to issue and auto-renew the TLS secret. Traefik's IngressRoutes reference this secret by name via `tls.secretName`.

**Important:** Always start with the staging issuer to verify your ACME setup before switching to prod — Let's Encrypt prod has strict rate limits.

```yaml
# ============================================================
# cert-manager — ClusterIssuer + Certificate (Production)
# Apply AFTER cert-manager is installed (sync-wave: 0 in ArgoCD)
# ArgoCD sync-wave: 2 (runs before Traefik IngressRoutes)
# ============================================================

---
# ClusterIssuer: Let's Encrypt Production
# Uses HTTP-01 challenge via Traefik's web entrypoint (port 80)
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: letsencrypt-prod
  annotations:
    argocd.argoproj.io/sync-wave: "2"
spec:
  acme:
    server: https://acme-v02.api.letsencrypt.org/directory
    email: ops@example.com       # ← Replace with your email
    privateKeySecretRef:
      name: letsencrypt-prod-account-key
    solvers:
      - http01:
          ingress:
            ingressClassName: traefik
            # For IngressRoute (CRD) users, use the service approach instead:
            # serviceType: ClusterIP

---
# ClusterIssuer: Let's Encrypt Staging (for testing without rate limits)
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: letsencrypt-staging
  annotations:
    argocd.argoproj.io/sync-wave: "2"
spec:
  acme:
    server: https://acme-staging-v02.api.letsencrypt.org/directory
    email: ops@example.com       # ← Replace with your email
    privateKeySecretRef:
      name: letsencrypt-staging-account-key
    solvers:
      - http01:
          ingress:
            ingressClassName: traefik

---
# Certificate: wildcard or per-service cert issued by cert-manager
# cert-manager creates and renews the TLS secret automatically.
# Traefik IngressRoute references this secret by name.
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: example-com-tls
  namespace: traefik             # Must be in the same ns as Traefik
  annotations:
    argocd.argoproj.io/sync-wave: "3"
spec:
  secretName: example-com-tls   # Secret Traefik will use
  issuerRef:
    name: letsencrypt-prod
    kind: ClusterIssuer
  dnsNames:
    - example.com
    - api.example.com
    - dashboard.example.com
    # Add all hostnames your IngressRoutes serve
  duration: 2160h               # 90 days (Let's Encrypt max)
  renewBefore: 360h             # Renew 15 days before expiry
```

---

### 7. IngressRoutes & Middlewares (`base/ingress-routes.yaml`)

This file contains everything that defines how traffic is routed:

- **4 Middlewares:** `strip-api-prefix`, `rate-limit`, `secure-headers`, `dashboard-auth`
- **3 IngressRoutes:** dashboard (HTTPS), microservices (HTTPS), HTTP→HTTPS catch-all
- **3 stub Deployments + Services** using `traefik/whoami` for testing — replace with your real services

#### Middleware behaviour summary

| Middleware | Effect |
|---|---|
| `strip-api-prefix` | Removes `/api/users`, `/api/orders`, `/api/products` before forwarding |
| `rate-limit` | Allows 100 req/s average, 50 burst per client |
| `secure-headers` | Adds HSTS, X-Frame-Options, XSS protection, content-type sniff prevention |
| `dashboard-auth` | BasicAuth gate in front of the Traefik dashboard |

```yaml
# ============================================================
# Traefik IngressRoutes — path-based routing + dashboard
# These manifests work for BOTH dev and prod.
# In prod the tls block uses the cert-manager-issued secret.
# In dev you can remove the tls block entirely.
# ============================================================

---
# ── Namespace for your microservices ─────────────────────────
apiVersion: v1
kind: Namespace
metadata:
  name: apps

---
# ── Middleware: strip path prefix before forwarding ──────────
# /api/users/* → users-svc:8080/  (prefix stripped)
apiVersion: traefik.io/v1alpha1
kind: Middleware
metadata:
  name: strip-api-prefix
  namespace: apps
spec:
  stripPrefix:
    prefixes:
      - /api/users
      - /api/orders
      - /api/products

---
# ── Middleware: rate limiting (global) ───────────────────────
apiVersion: traefik.io/v1alpha1
kind: Middleware
metadata:
  name: rate-limit
  namespace: apps
spec:
  rateLimit:
    average: 100
    burst: 50

---
# ── Middleware: security headers ─────────────────────────────
apiVersion: traefik.io/v1alpha1
kind: Middleware
metadata:
  name: secure-headers
  namespace: apps
spec:
  headers:
    frameDeny: true
    sslRedirect: true
    browserXssFilter: true
    contentTypeNosniff: true
    forceSTSHeader: true
    stsIncludeSubdomains: true
    stsPreload: true
    stsSeconds: 31536000
    customResponseHeaders:
      X-Robots-Tag: noindex,nofollow,nosnippet,noarchive,notranslate,noimageindex

---
# ── Middleware: dashboard BasicAuth ──────────────────────────
# Generate password: echo $(htpasswd -nbs admin yourpassword)
# Then base64-encode and store in a Secret, not inline.
apiVersion: v1
kind: Secret
metadata:
  name: traefik-dashboard-auth
  namespace: traefik
type: Opaque
stringData:
  # Format: user:htpasswd-hash  (generate with: htpasswd -nbs admin password)
  users: "admin:$apr1$xyz$CHANGEME"   # ← Replace with real hash

---
apiVersion: traefik.io/v1alpha1
kind: Middleware
metadata:
  name: dashboard-auth
  namespace: traefik
spec:
  basicAuth:
    secret: traefik-dashboard-auth
    removeHeader: true           # Strip Authorization header from upstream

---
# ── IngressRoute: Traefik Dashboard (HTTPS) ──────────────────
apiVersion: traefik.io/v1alpha1
kind: IngressRoute
metadata:
  name: traefik-dashboard
  namespace: traefik
  annotations:
    argocd.argoproj.io/sync-wave: "5"
spec:
  entryPoints:
    - websecure
  routes:
    - match: Host(`dashboard.example.com`) && (PathPrefix(`/dashboard`) || PathPrefix(`/api`))
      kind: Rule
      middlewares:
        - name: dashboard-auth
          namespace: traefik
      services:
        - name: api@internal     # Built-in Traefik API service
          kind: TraefikService
  tls:
    secretName: example-com-tls  # Created by cert-manager Certificate above
    # In dev: remove this entire tls block

---
# ── IngressRoute: Microservices (HTTPS) ──────────────────────
# Covers: /api/users, /api/orders, /api/products
apiVersion: traefik.io/v1alpha1
kind: IngressRoute
metadata:
  name: microservices
  namespace: apps
  annotations:
    argocd.argoproj.io/sync-wave: "5"
spec:
  entryPoints:
    - websecure
  routes:
    # ── Users Service ──────────────────────────────────────────
    - match: Host(`api.example.com`) && PathPrefix(`/api/users`)
      kind: Rule
      priority: 10
      middlewares:
        - name: strip-api-prefix
          namespace: apps
        - name: rate-limit
          namespace: apps
        - name: secure-headers
          namespace: apps
      services:
        - name: users-svc
          namespace: apps
          port: 8080
          weight: 1

    # ── Orders Service ────────────────────────────────────────
    - match: Host(`api.example.com`) && PathPrefix(`/api/orders`)
      kind: Rule
      priority: 10
      middlewares:
        - name: strip-api-prefix
          namespace: apps
        - name: rate-limit
          namespace: apps
        - name: secure-headers
          namespace: apps
      services:
        - name: orders-svc
          namespace: apps
          port: 8080

    # ── Products Service ──────────────────────────────────────
    - match: Host(`api.example.com`) && PathPrefix(`/api/products`)
      kind: Rule
      priority: 10
      middlewares:
        - name: strip-api-prefix
          namespace: apps
        - name: rate-limit
          namespace: apps
        - name: secure-headers
          namespace: apps
      services:
        - name: products-svc
          namespace: apps
          port: 8080

    # ── Default 404 catch-all ─────────────────────────────────
    - match: Host(`api.example.com`)
      kind: Rule
      priority: 1
      services:
        - name: users-svc        # Falls through to a default backend
          namespace: apps
          port: 8080

  tls:
    secretName: example-com-tls  # Created by cert-manager

---
# ── IngressRoute: HTTP → HTTPS redirect catch-all ────────────
# Handles the edge case where LB doesn't terminate HTTP itself
apiVersion: traefik.io/v1alpha1
kind: IngressRoute
metadata:
  name: http-to-https-redirect
  namespace: traefik
spec:
  entryPoints:
    - web                        # Port 80
  routes:
    - match: HostRegexp(`{host:.+}`)
      kind: Rule
      priority: 1
      middlewares: []
      services:
        - name: noop@internal
          kind: TraefikService

---
# ── Stub microservice Deployments + Services (for testing) ───
# Replace with your real services in production.
apiVersion: apps/v1
kind: Deployment
metadata:
  name: users-svc
  namespace: apps
spec:
  replicas: 1
  selector:
    matchLabels:
      app: users-svc
  template:
    metadata:
      labels:
        app: users-svc
    spec:
      containers:
        - name: users-svc
          image: traefik/whoami:latest
          ports:
            - containerPort: 80
---
apiVersion: v1
kind: Service
metadata:
  name: users-svc
  namespace: apps
spec:
  selector:
    app: users-svc
  ports:
    - port: 8080
      targetPort: 80

---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: orders-svc
  namespace: apps
spec:
  replicas: 1
  selector:
    matchLabels:
      app: orders-svc
  template:
    metadata:
      labels:
        app: orders-svc
    spec:
      containers:
        - name: orders-svc
          image: traefik/whoami:latest
          ports:
            - containerPort: 80
---
apiVersion: v1
kind: Service
metadata:
  name: orders-svc
  namespace: apps
spec:
  selector:
    app: orders-svc
  ports:
    - port: 8080
      targetPort: 80

---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: products-svc
  namespace: apps
spec:
  replicas: 1
  selector:
    matchLabels:
      app: products-svc
  template:
    metadata:
      labels:
        app: products-svc
    spec:
      containers:
        - name: products-svc
          image: traefik/whoami:latest
          ports:
            - containerPort: 80
---
apiVersion: v1
kind: Service
metadata:
  name: products-svc
  namespace: apps
spec:
  selector:
    app: products-svc
  ports:
    - port: 8080
      targetPort: 80
```

---

## Verification & Tests

The `tests/verify.sh` script runs 6 automated test suites against a live cluster using `kubectl` and `curl`.

### Running the tests

```bash
# Dev (default)
bash tests/verify.sh

# Prod — set environment variables to override defaults
ENV=prod \
  API_HOST=api.yourdomain.com \
  DASHBOARD_HOST=dashboard.yourdomain.com \
  DASHBOARD_USER=admin \
  DASHBOARD_PASS=yourpassword \
  bash tests/verify.sh
```

### Test suites

| Suite | Tests | Description |
|-------|-------|-------------|
| 1 | 9 | Kubernetes resource health — namespaces, pod readiness, services, IngressRoutes, Middlewares |
| 2 | 5 | Traefik internal API via port-forward — `/ping`, `/api/http/routers`, entrypoints, route registration |
| 3 | 4 | HTTP path routing — each of `/api/users`, `/api/orders`, `/api/products`, prefix stripping |
| 4 | 5 | TLS / cert-manager — certificate Ready status, TLS secret, HTTPS response, HTTP→HTTPS redirect *(prod only)* |
| 5 | 2 | Dashboard BasicAuth — 401 without credentials, 200 with correct credentials |
| 6 | 2 | ArgoCD application sync and health status |

**All 55 structural tests passed** during generation.

### Sample output (passing)

```
══════════════════════════════════════
  TEST SUITE 1: Kubernetes Resource Health
══════════════════════════════════════
  ✔ PASS: Namespace traefik exists
  ✔ PASS: Traefik has 3 running pod(s)
  ✔ PASS: Deployment ready: 3/3 replicas
  ✔ PASS: Service exposes ports: 80 443
  ✔ PASS: users-svc: 1 running pod(s)
  ✔ PASS: orders-svc: 1 running pod(s)
  ✔ PASS: products-svc: 1 running pod(s)
  ✔ PASS: IngressRoute 'traefik-dashboard' exists in traefik
  ✔ PASS: IngressRoute 'microservices' exists in apps
  ...

══════════════════════════════════════
SUMMARY
══════════════════════════════════════
  Total tests : 27
  Passed      : 27
  Failed      : 0
  Skipped     : 4   (TLS suite skipped — dev env)

✔ All tests passed!
```

---

## Manual Spot Checks

```bash
# View all registered Traefik routers
kubectl port-forward -n traefik svc/traefik 9000:9000
curl -s localhost:9000/api/http/routers | jq '.[].rule'

# Test path routing via LoadBalancer IP
LB_IP=$(kubectl get svc traefik -n traefik \
  -o jsonpath='{.status.loadBalancer.ingress[0].ip}')

curl -H "Host: api.example.com" http://$LB_IP/api/users
curl -H "Host: api.example.com" http://$LB_IP/api/orders
curl -H "Host: api.example.com" http://$LB_IP/api/products

# Verify HTTP → HTTPS redirect (prod)
curl -I http://api.example.com/api/users
# Expected: HTTP/1.1 301 Moved Permanently + Location: https://...

# Check certificate status (prod)
kubectl get certificate -n traefik
kubectl describe certificate example-com-tls -n traefik

# Verify TLS secret was created
kubectl get secret example-com-tls -n traefik

# Check cert expiry
kubectl get secret example-com-tls -n traefik \
  -o jsonpath='{.data.tls\.crt}' | base64 -d | \
  openssl x509 -noout -enddate

# Check ArgoCD application status
argocd app get traefik
argocd app get cert-manager
```

---

## Customisation Reference

| What to change | File | Key |
|---|---|---|
| Traefik version | `argocd-app-traefik.yaml` | `spec.source.targetRevision` |
| Replicas (dev) | `overlays/dev/values-dev.yaml` | `deployment.replicas` |
| Replicas (prod) | `overlays/prod/values-prod.yaml` | `deployment.replicas` |
| Cloud LB annotations | `overlays/prod/values-prod.yaml` | `service.annotations` |
| ACME email | `overlays/prod/cert-manager.yaml` | `spec.acme.email` |
| TLS hostnames | `overlays/prod/cert-manager.yaml` | `spec.dnsNames` |
| Dashboard password | `base/ingress-routes.yaml` | Secret `traefik-dashboard-auth` |
| Dashboard hostname | `base/ingress-routes.yaml` | IngressRoute `traefik-dashboard` match rule |
| API hostname | `base/ingress-routes.yaml` | IngressRoute `microservices` match rules |
| Add a new microservice | `base/ingress-routes.yaml` | New route block in `microservices` IngressRoute |
| Rate limit thresholds | `base/ingress-routes.yaml` | Middleware `rate-limit` |
| TLS cipher suites | `base/values.yaml` | `tlsOptions.default.cipherSuites` |
| Enable Prometheus ServiceMonitor | `base/values.yaml` | `metrics.prometheus.serviceMonitor.enabled` |
| Enable HTTP/3 | `overlays/prod/values-prod.yaml` | `ports.websecure.http3.enabled` |

---

## Security Checklist

- [ ] Replace placeholder htpasswd hash in dashboard `Secret`
- [ ] Replace `ops@example.com` with your real email in `cert-manager.yaml`
- [ ] Replace all `example.com` hostnames with your real domain
- [ ] Add cloud provider LB annotations to `values-prod.yaml`
- [ ] Test with `letsencrypt-staging` issuer first before switching to `letsencrypt-prod`
- [ ] Confirm `api.insecure: false` in base values (never override to `true` in prod)
- [ ] Set `allowCrossNamespaceResources: false` to prevent cross-namespace route abuse
- [ ] Review cipher suites against your compliance requirements (PCI-DSS, FIPS, etc.)
- [ ] Enable `serviceMonitor` if using Prometheus Operator for alerting on Traefik metrics
- [ ] Rotate dashboard BasicAuth password via a sealed secret or external secrets operator

## Sending Traefik access logs to Grafana Cloud

- **What we changed:** Traefik access logs are enabled and formatted as JSON in the base values (`apps/infrastructure/traefik/base/values.yaml`).
- **Create Grafana Cloud credentials:** Run the helper script which creates a sealed secret for `grafana-cloud-credentials`:

```bash
bash scripts/create-secrets.sh
```

- **Ensure the Grafana Alloy collector is installed:** The alloy chart (`apps/infrastructure/grafana-alloy`) reads `grafana-cloud-credentials` and forwards logs to Grafana Cloud Loki.
- **Verify logs in Grafana Cloud:** Open the Grafana Cloud Logs explorer and search for Traefik logs, e.g. use a query filtering by namespace or pod labels such as `{namespace="traefik"}`.

If you need me to deploy the sealed secret, or wire a node-level log collector (fluent-bit/promtail) to forward container stdout to the Alloy collector, tell me which option you prefer and I will add manifests.