# Cross-Tenant PostgreSQL Route Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Configure a Traefik-based database route to expose PostgreSQL from tenant-b to tenant-a and local machines, using Tailscale for cross-cluster service discovery and TLS termination at Traefik.

**Architecture:** Install Tailscale operator on tenant-a, create Tailscale Connector on tenant-b to expose PostgreSQL, add TCP entrypoint to Traefik for TLS-terminated database access, and configure NetworkPolicy for security.

**Tech Stack:** Traefik, Tailscale, cert-manager, Kustomize, ArgoCD, PostgreSQL, Bitnami Sealed Secrets

## Global Constraints

- All Kubernetes manifests use `apiVersion: kustomize.config.k8s.io/v1beta1` for Kustomization files
- Infrastructure apps use Helm charts via `helmCharts:` in kustomization
- Every kustomization gets `argocd.argoproj.io/sync-wave` annotation
- All ArgoCD Application/AppProject resources live in `namespace: argocd`
- Secrets are encrypted (SealedSecret), never stored in plaintext
- Use `set -euo pipefail` in all shell scripts
- Tailscale operator version: `v1.98.5-51a6973`
- Chart repo: `oci://ghcr.io/coreweave/tailscale/chart/tailscale-operator`

---

## File Structure

### New Files
| File | Purpose |
|------|---------|
| `apps/workloads/tailscale-operator/overlays/prod/tenant-a/config.json` | Tailscale operator Helm config for tenant-a |
| `apps/workloads/tailscale-operator/overlays/prod/tenant-a/values.yaml` | Tailscale operator values for tenant-a |
| `apps/infrastructure/infra-secrets/overlays/prod/tailscale-tenant-a-sealedsecret.yaml` | Tailscale auth key for tenant-a |
| `apps/infrastructure/postgresql-cross-tenant/base/kustomization.yaml` | Kustomization for cross-tenant resources |
| `apps/infrastructure/postgresql-cross-tenant/base/connector.yaml` | Tailscale Connector for PostgreSQL |
| `apps/infrastructure/postgresql-cross-tenant/base/networkpolicy.yaml` | NetworkPolicy for PostgreSQL access |
| `apps/infrastructure/postgresql-cross-tenant/overlays/prod-tenant/tenant-b/kustomization.yaml` | Tenant-b overlay for cross-tenant resources |

### Modified Files
| File | Change |
|------|--------|
| `apps/infrastructure/traefik/base/values.yaml` | Add `pg-db` TCP entrypoint (port 6432) |
| `apps/infrastructure/traefik/overlays/prod/certificate.yaml` | Add `pg-tls-cert` for `pg.newyeti.qzz.io` |
| `apps/infrastructure/traefik/overlays/prod/ingress-routes.yaml` | Add `TCPIngressRoute` for PostgreSQL |
| `apps/infrastructure/infra-secrets/overlays/prod/kustomization.yaml` | Add `tailscale-tenant-a-sealedsecret.yaml` |

---

## Task 1: Create Tailscale Operator App for Tenant-a

**Files:**
- Create: `apps/workloads/tailscale-operator/overlays/prod/tenant-a/config.json`
- Create: `apps/workloads/tailscale-operator/overlays/prod/tenant-a/values.yaml`

**Interfaces:**
- Produces: Tailscale operator workload app deployed to tenant-a cluster

- [ ] **Step 1: Create config.json for tenant-a**

```json
{
    "appName": "tailscale-tenant-a",
    "namespace": "tailscale",
    "chartRepo": "oci://ghcr.io/coreweave/tailscale/chart/tailscale-operator",
    "chartName": "tailscale-operator",
    "chartVersion": "v1.98.5-51a6973",
    "isGitRepo": false
}
```

- [ ] **Step 2: Create values.yaml for tenant-a**

```yaml
operatorConfig:
  hostname: "tailscale-operator-tenant-a"
```

- [ ] **Step 3: Verify directory structure**

Run: `ls -la apps/workloads/tailscale-operator/overlays/prod/tenant-a/`
Expected: `config.json` and `values.yaml` files exist

- [ ] **Step 4: Commit**

```bash
git add apps/workloads/tailscale-operator/overlays/prod/tenant-a/
git commit -m "feat: add tailscale operator config for tenant-a"
```

---

## Task 2: Create Tailscale Secret for Tenant-a

**Files:**
- Create: `apps/infrastructure/infra-secrets/overlays/prod/tailscale-tenant-a-sealedsecret.yaml`
- Modify: `apps/infrastructure/infra-secrets/overlays/prod/kustomization.yaml`

**Interfaces:**
- Consumes: Tailscale auth key (to be encrypted)
- Produces: SealedSecret in infrastructure namespace, reflected to tailscale namespace

- [ ] **Step 1: Create plaintext secret file for encryption**

```yaml
# /tmp/tailscale-tenant-a-auth-key.yaml
apiVersion: v1
kind: Secret
metadata:
  name: tailscale-tenant-a-secret
  namespace: tailscale
type: Opaque
stringData:
  auth-key: "<YOUR_TAILSCALE_AUTH_KEY>"
```

- [ ] **Step 2: Encrypt the secret with kubeseal**

Run: `kubeseal --format yaml < /tmp/tailscale-tenant-a-auth-key.yaml > /tmp/tailscale-tenant-a-sealed.yaml`

- [ ] **Step 3: Create SealedSecret with reflector annotations**

```yaml
---
apiVersion: bitnami.com/v1alpha1
kind: SealedSecret
metadata:
  name: tailscale-tenant-a-secret
  namespace: infrastructure
  annotations:
    reflector.v1.k8s.emberstack.com/reflection-allowed: "true"
    reflector.v1.k8s.emberstack.com/reflection-allowed-namespaces: "tailscale"
    reflector.v1.k8s.emberstack.com/reflection-auto-enabled: "true"
spec:
  encryptedData:
    auth-key: <ENCRYPTED_VALUE_FROM_STEP_2>
  template:
    metadata:
      name: tailscale-tenant-a-secret
      namespace: infrastructure
      annotations:
        reflector.v1.k8s.emberstack.com/reflection-allowed: "true"
        reflector.v1.k8s.emberstack.com/reflection-allowed-namespaces: "tailscale"
        reflector.v1.k8s.emberstack.com/reflection-auto-enabled: "true"
    type: Opaque
    data:
      auth-key: ""
```

- [ ] **Step 4: Add to kustomization.yaml**

Add `- tailscale-tenant-a-sealedsecret.yaml` to the `resources` list in `apps/infrastructure/infra-secrets/overlays/prod/kustomization.yaml`.

- [ ] **Step 5: Verify kustomization builds**

Run: `kustomize build apps/infrastructure/infra-secrets/overlays/prod/`
Expected: Output includes the new SealedSecret

- [ ] **Step 6: Commit**

```bash
git add apps/infrastructure/infra-secrets/overlays/prod/tailscale-tenant-a-sealedsecret.yaml
git add apps/infrastructure/infra-secrets/overlays/prod/kustomization.yaml
git commit -m "feat: add tailscale sealed secret for tenant-a"
```

---

## Task 3: Create Cross-Tenant PostgreSQL Infrastructure App

**Files:**
- Create: `apps/infrastructure/postgresql-cross-tenant/base/kustomization.yaml`
- Create: `apps/infrastructure/postgresql-cross-tenant/base/connector.yaml`
- Create: `apps/infrastructure/postgresql-cross-tenant/base/networkpolicy.yaml`
- Create: `apps/infrastructure/postgresql-cross-tenant/overlays/prod-tenant/tenant-b/kustomization.yaml`

**Interfaces:**
- Produces: Tailscale Connector and NetworkPolicy deployed to tenant-b

- [ ] **Step 1: Create base kustomization.yaml**

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
commonAnnotations:
  argocd.argoproj.io/sync-wave: "4"
resources:
  - connector.yaml
  - networkpolicy.yaml
```

- [ ] **Step 2: Create Tailscale Connector**

```yaml
---
apiVersion: tailscale.com/v1alpha1
kind: Connector
metadata:
  name: postgresql-connector
  namespace: workloads
spec:
  hostname: postgresql
  service:
    kubernetes:
      name: postgresql-prod-tenant-b
      namespace: workloads
      ports:
        - port: 5432
```

- [ ] **Step 3: Create NetworkPolicy**

```yaml
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-postgresql-access
  namespace: workloads
spec:
  podSelector:
    matchLabels:
      app.kubernetes.io/name: postgresql
  policyTypes:
    - Ingress
  ingress:
    # Allow from Tailscale Connector
    - from:
        - podSelector:
            matchLabels:
              app.kubernetes.io/name: tailscale
      ports:
        - protocol: TCP
          port: 5432
    # Allow from tenant-b pods with db-access=true label
    - from:
        - podSelector:
            matchLabels:
              db-access: "true"
      ports:
        - protocol: TCP
          port: 5432
```

- [ ] **Step 4: Create tenant-b overlay kustomization**

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - ../../base
```

- [ ] **Step 5: Verify directory structure**

Run: `find apps/infrastructure/postgresql-cross-tenant -type f`
Expected: 4 files (base/kustomization.yaml, base/connector.yaml, base/networkpolicy.yaml, overlays/prod-tenant/tenant-b/kustomization.yaml)

- [ ] **Step 6: Verify kustomization builds**

Run: `kustomize build apps/infrastructure/postgresql-cross-tenant/overlays/prod-tenant/tenant-b/`
Expected: Output includes Connector, NetworkPolicy, and commonAnnotations

- [ ] **Step 7: Commit**

```bash
git add apps/infrastructure/postgresql-cross-tenant/
git commit -m "feat: add cross-tenant postgresql connector and networkpolicy"
```

---

## Task 4: Add Traefik TCP EntryPoint

**Files:**
- Modify: `apps/infrastructure/traefik/base/values.yaml`

**Interfaces:**
- Produces: Traefik TCP entrypoint `pg-db` on port 6432 with TLS enabled

- [ ] **Step 1: Read current values.yaml**

Run: `cat apps/infrastructure/traefik/base/values.yaml`
Note the existing `ports` section

- [ ] **Step 2: Add pg-db port to values.yaml**

Add the following under the `ports:` section:

```yaml
  pg-db:
    port: 6432
    expose:
      default: true
    exposedPort: 6432
    protocol: TCP
    tls:
      enabled: true
```

- [ ] **Step 3: Verify YAML syntax**

Run: `python3 -c "import yaml; yaml.safe_load(open('apps/infrastructure/traefik/base/values.yaml'))"`
Expected: No output (valid YAML)

- [ ] **Step 4: Commit**

```bash
git add apps/infrastructure/traefik/base/values.yaml
git commit -m "feat: add pg-db TCP entrypoint to traefik"
```

---

## Task 5: Add TLS Certificate for PostgreSQL

**Files:**
- Modify: `apps/infrastructure/traefik/overlays/prod/certificate.yaml`

**Interfaces:**
- Produces: cert-manager Certificate resource for `pg.newyeti.qzz.io`

- [ ] **Step 1: Read current certificate.yaml**

Run: `cat apps/infrastructure/traefik/overlays/prod/certificate.yaml`
Note the existing Certificate resource

- [ ] **Step 2: Add pg-tls-cert Certificate**

Append the following to the file:

```yaml
---
# ── Certificate: PostgreSQL TLS ──────────────────────────────
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: pg-tls-cert
  namespace: traefik
  annotations:
    argocd.argoproj.io/sync-wave: "4"
spec:
  secretName: pg-tls-cert
  issuerRef:
    name: letsencrypt-prod
    kind: ClusterIssuer
  dnsNames:
    - pg.newyeti.qzz.io
  duration: 2160h
  renewBefore: 360h
```

- [ ] **Step 3: Verify YAML syntax**

Run: `python3 -c "import yaml; list(yaml.safe_load_all(open('apps/infrastructure/traefik/overlays/prod/certificate.yaml')))"`
Expected: No output (valid YAML)

- [ ] **Step 4: Commit**

```bash
git add apps/infrastructure/traefik/overlays/prod/certificate.yaml
git commit -m "feat: add pg-tls-cert for postgresql route"
```

---

## Task 6: Add TCPIngressRoute for PostgreSQL

**Files:**
- Modify: `apps/infrastructure/traefik/overlays/prod/ingress-routes.yaml`

**Interfaces:**
- Consumes: Tailscale Connector service name (`postgresql-connector` in `workloads` namespace)
- Produces: TCPIngressRoute routing TLS traffic to PostgreSQL via Tailscale Connector

- [ ] **Step 1: Read current ingress-routes.yaml**

Run: `cat apps/infrastructure/traefik/overlays/prod/ingress-routes.yaml`
Note the existing IngressRoutes and Middlewares

- [ ] **Step 2: Add TCPIngressRoute for PostgreSQL**

Append the following to the file:

```yaml
---
# ── TCPIngressRoute: PostgreSQL via Traefik ──────────────────
apiVersion: traefik.io/v1alpha1
kind: TCPIngressRoute
metadata:
  name: postgresql-route
  namespace: traefik
  annotations:
    argocd.argoproj.io/sync-wave: "5"
spec:
  entryPoints:
    - pg-db
  routes:
    - match: HostSNI(`pg.newyeti.qzz.io`)
      kind: Rule
      services:
        - name: postgresql-connector
          namespace: workloads
          port: 5432
  tls:
    secretName: pg-tls-cert
    passthrough: false
```

- [ ] **Step 3: Verify YAML syntax**

Run: `python3 -c "import yaml; list(yaml.safe_load_all(open('apps/infrastructure/traefik/overlays/prod/ingress-routes.yaml')))"`
Expected: No output (valid YAML)

- [ ] **Step 4: Commit**

```bash
git add apps/infrastructure/traefik/overlays/prod/ingress-routes.yaml
git commit -m "feat: add TCPIngressRoute for postgresql via traefik"
```

---

## Task 7: Verify Kustomization Builds

**Files:**
- No new files (verification only)

**Interfaces:**
- Consumes: All modified kustomization files
- Produces: Confirmation that all builds pass

- [ ] **Step 1: Verify infra-secrets kustomization**

Run: `kustomize build apps/infrastructure/infra-secrets/overlays/prod/`
Expected: Output includes all SealedSecrets including the new tailscale-tenant-a-secret

- [ ] **Step 2: Verify postgresql-cross-tenant kustomization**

Run: `kustomize build apps/infrastructure/postgresql-cross-tenant/overlays/prod-tenant/tenant-b/`
Expected: Output includes Connector, NetworkPolicy with commonAnnotations

- [ ] **Step 3: Verify traefik base kustomization (if applicable)**

Run: `kustomize build apps/infrastructure/traefik/base/`
Expected: Output includes updated values.yaml

- [ ] **Step 4: Verify all YAML files are valid**

Run: `find apps/infrastructure -name "*.yaml" -exec python3 -c "import yaml; yaml.safe_load(open('{}'))" \;`
Expected: No errors

---

## Task 8: DNS Configuration (Manual)

**Files:**
- No files (manual step)

**Interfaces:**
- Consumes: Traefik LoadBalancer IP
- Produces: DNS record for `pg.newyeti.qzz.io`

- [ ] **Step 1: Get Traefik LoadBalancer IP**

Run: `kubectl get svc traefik -n traefik -o jsonpath='{.status.loadBalancer.ingress[0].ip}'`
Expected: IP address (e.g., `129.158.x.x`)

- [ ] **Step 2: Create DNS record**

Create an A record or CNAME for `pg.newyeti.qzz.io` pointing to the Traefik LoadBalancer IP.

- [ ] **Step 3: Verify DNS resolution**

Run: `nslookup pg.newyeti.qzz.io`
Expected: Returns the Traefik LoadBalancer IP

---

## Task 9: Deployment Verification

**Files:**
- No new files (verification only)

**Interfaces:**
- Consumes: All deployed resources
- Produces: Confirmation that PostgreSQL route is working

- [ ] **Step 1: Verify Tailscale operator on tenant-a**

Run: `kubectl get pods -n tailscale`
Expected: Tailscale operator pod running

- [ ] **Step 2: Verify Tailscale Connector on tenant-b**

Run: `kubectl get connectors -n workloads`
Expected: `postgresql-connector` exists

- [ ] **Step 3: Verify TLS certificate**

Run: `kubectl get certificate -n traefik`
Expected: `pg-tls-cert` shows READY=True

- [ ] **Step 4: Test TLS connection**

Run: `openssl s_client -connect pg.newyeti.qzz.io:6432 -servername pg.newyeti.qzz.io`
Expected: TLS handshake succeeds

- [ ] **Step 5: Test PostgreSQL connection**

Run: `psql "host=pg.newyeti.qzz.io port=6432 sslmode=require dbname=immich user=immich" -c "SELECT 1"`
Expected: Returns `1`

- [ ] **Step 6: Verify NetworkPolicy**

Run: `kubectl get networkpolicy -n workloads`
Expected: `allow-postgresql-access` exists

---

## Commit Summary

| Task | Commit Message |
|------|----------------|
| 1 | `feat: add tailscale operator config for tenant-a` |
| 2 | `feat: add tailscale sealed secret for tenant-a` |
| 3 | `feat: add cross-tenant postgresql connector and networkpolicy` |
| 4 | `feat: add pg-db TCP entrypoint to traefik` |
| 5 | `feat: add pg-tls-cert for postgresql route` |
| 6 | `feat: add TCPIngressRoute for postgresql via traefik` |
| 7 | (no commit - verification only) |
| 8 | (no commit - manual DNS step) |
| 9 | (no commit - verification only) |
