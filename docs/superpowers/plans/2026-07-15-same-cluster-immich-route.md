# Same-Cluster Immich Route Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Route HTTPS traffic from `immich.newyeti.qzz.io` through Traefik on tenant-b (same cluster as Immich), replacing cross-tenant routing via tenant-a.

**Architecture:** Deploy Traefik and cert-manager to tenant-b mirroring tenant-a's setup. Add Immich IngressRoute to tenant-b's traefik overlay. Remove cross-tenant IngressRoute from tenant-a. Clean up immich-specific Tailscale resources.

**Tech Stack:** Traefik, cert-manager, Kubernetes IngressRoute, Kustomize

## Global Constraints

- All Kubernetes manifests use `apiVersion: kustomize.config.k8s.io/v1beta1` for Kustomization files
- ArgoCD resources live in `namespace: argocd`
- Sync-wave annotations required on all ArgoCD-managed resources
- Secrets are encrypted (SealedSecret), never stored in plaintext
- `allowCrossNamespace: true` is already enabled on Traefik's kubernetesCRD provider
- Traefik and cert-manager use `tier=workload` tolerations in both tenant-a and tenant-b

---

### Task 1: Update Tenant-a Tolerations to tier=workload

**Files:**
- Modify: `apps/infrastructure/traefik/overlays/prod-tenant/tenant-a/tolerations-patch.yaml`
- Modify: `apps/infrastructure/cert-manager/overlays/prod-tenant/tenant-a/tolerations-patch.yaml`

**Interfaces:**
- Consumes: Existing tolerations-patch files
- Produces: Updated patches using `tier=workload` instead of `tier=infra`

- [ ] **Step 1: Update traefik tolerations-patch.yaml**

Edit `apps/infrastructure/traefik/overlays/prod-tenant/tenant-a/tolerations-patch.yaml`. Change from:

```yaml
- op: add
  path: /spec/template/spec/tolerations
  value:
    - key: "tier"
      operator: "Equal"
      value: "infra"
      effect: "NoSchedule"

- op: add
  path: /spec/template/spec/affinity
  value:
    nodeAffinity:
      requiredDuringSchedulingIgnoredDuringExecution:
        nodeSelectorTerms:
        - matchExpressions:
          - key: tier
            operator: In
            values:
            - infra
```

To:

```yaml
- op: add
  path: /spec/template/spec/tolerations
  value:
    - key: "tier"
      operator: "Equal"
      value: "workload"
      effect: "NoSchedule"

- op: add
  path: /spec/template/spec/affinity
  value:
    nodeAffinity:
      requiredDuringSchedulingIgnoredDuringExecution:
        nodeSelectorTerms:
        - matchExpressions:
          - key: tier
            operator: In
            values:
            - workload
```

- [ ] **Step 2: Update cert-manager tolerations-patch.yaml**

Edit `apps/infrastructure/cert-manager/overlays/prod-tenant/tenant-a/tolerations-patch.yaml`. Change from:

```yaml
- op: add
  path: /spec/template/spec/tolerations
  value:
    - key: "tier"
      operator: "Equal"
      value: "infra"
      effect: "NoSchedule"

- op: add
  path: /spec/template/spec/affinity
  value:
    nodeAffinity:
      requiredDuringSchedulingIgnoredDuringExecution:
        nodeSelectorTerms:
        - matchExpressions:
          - key: tier
            operator: In
            values:
            - infra
```

To:

```yaml
- op: add
  path: /spec/template/spec/tolerations
  value:
    - key: "tier"
      operator: "Equal"
      value: "workload"
      effect: "NoSchedule"

- op: add
  path: /spec/template/spec/affinity
  value:
    nodeAffinity:
      requiredDuringSchedulingIgnoredDuringExecution:
        nodeSelectorTerms:
        - matchExpressions:
          - key: tier
            operator: In
            values:
            - workload
```

- [ ] **Step 3: Commit**

```bash
git add apps/infrastructure/traefik/overlays/prod-tenant/tenant-a/tolerations-patch.yaml apps/infrastructure/cert-manager/overlays/prod-tenant/tenant-a/tolerations-patch.yaml
git commit -m "chore: update tenant-a traefik and cert-manager to tier=workload tolerations"
```

---

### Task 2: Create Tenant-b Traefik Overlay

**Files:**
- Create: `apps/infrastructure/traefik/overlays/prod-tenant/tenant-b/kustomization.yaml`
- Create: `apps/infrastructure/traefik/overlays/prod-tenant/tenant-b/tolerations-patch.yaml`
- Create: `apps/infrastructure/traefik/overlays/prod-tenant/tenant-b/immich-ingress-route.yaml`

**Interfaces:**
- Consumes: `apps/infrastructure/traefik/overlays/prod/` (shared prod overlay)
- Produces: Traefik deployment on tenant-b with Immich IngressRoute

- [ ] **Step 1: Create kustomization.yaml**

Create `apps/infrastructure/traefik/overlays/prod-tenant/tenant-b/kustomization.yaml`:

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - ../../prod
  - immich-ingress-route.yaml
patches:
  - target:
      kind: Deployment
      name: traefik
      namespace: traefik
    path: tolerations-patch.yaml
```

- [ ] **Step 2: Create tolerations-patch.yaml**

Create `apps/infrastructure/traefik/overlays/prod-tenant/tenant-b/tolerations-patch.yaml`:

```yaml
- op: add
  path: /spec/template/spec/tolerations
  value:
    - key: "tier"
      operator: "Equal"
      value: "workload"
      effect: "NoSchedule"

- op: add
  path: /spec/template/spec/affinity
  value:
    nodeAffinity:
      requiredDuringSchedulingIgnoredDuringExecution:
        nodeSelectorTerms:
        - matchExpressions:
          - key: tier
            operator: In
            values:
            - workload
```

- [ ] **Step 3: Create immich-ingress-route.yaml**

Create `apps/infrastructure/traefik/overlays/prod-tenant/tenant-b/immich-ingress-route.yaml`:

```yaml
apiVersion: traefik.io/v1alpha1
kind: IngressRoute
metadata:
  name: immich-server
  namespace: traefik
  annotations:
    argocd.argoproj.io/sync-wave: "5"
spec:
  entryPoints:
    - websecure
  routes:
    - match: Host(`immich.newyeti.qzz.io`)
      kind: Rule
      services:
        - name: immich
          namespace: workloads
          port: 2283
  tls:
    secretName: newyeti-tls-cert
```

- [ ] **Step 4: Verify kustomize build**

Run: `kustomize build apps/infrastructure/traefik/overlays/prod-tenant/tenant-b/`
Expected: Outputs Traefik resources from prod overlay plus the Immich IngressRoute

- [ ] **Step 5: Commit**

```bash
git add apps/infrastructure/traefik/overlays/prod-tenant/tenant-b/
git commit -m "feat: add traefik overlay for tenant-b with Immich IngressRoute"
```

---

### Task 3: Create Tenant-b cert-manager Overlay

**Files:**
- Create: `apps/infrastructure/cert-manager/overlays/prod-tenant/tenant-b/kustomization.yaml`
- Create: `apps/infrastructure/cert-manager/overlays/prod-tenant/tenant-b/tolerations-patch.yaml`

**Interfaces:**
- Consumes: `apps/infrastructure/cert-manager/overlays/prod/` (shared prod overlay)
- Produces: cert-manager deployment on tenant-b

- [ ] **Step 1: Create kustomization.yaml**

Create `apps/infrastructure/cert-manager/overlays/prod-tenant/tenant-b/kustomization.yaml`:

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - ../../prod
patches:
  - target:
      kind: Deployment
      name: cert-manager
      namespace: cert-manager
    path: tolerations-patch.yaml
  - target:
      kind: Deployment
      name: cert-manager-webhook
      namespace: cert-manager
    path: tolerations-patch.yaml
  - target:
      kind: Deployment
      name: cert-manager-cainjector
      namespace: cert-manager
    path: tolerations-patch.yaml
```

- [ ] **Step 2: Create tolerations-patch.yaml**

Create `apps/infrastructure/cert-manager/overlays/prod-tenant/tenant-b/tolerations-patch.yaml`:

```yaml
- op: add
  path: /spec/template/spec/tolerations
  value:
    - key: "tier"
      operator: "Equal"
      value: "workload"
      effect: "NoSchedule"

- op: add
  path: /spec/template/spec/affinity
  value:
    nodeAffinity:
      requiredDuringSchedulingIgnoredDuringExecution:
        nodeSelectorTerms:
        - matchExpressions:
          - key: tier
            operator: In
            values:
            - workload
```

- [ ] **Step 3: Verify kustomize build**

Run: `kustomize build apps/infrastructure/cert-manager/overlays/prod-tenant/tenant-b/`
Expected: Outputs cert-manager resources from prod overlay with workload tolerations

- [ ] **Step 4: Commit**

```bash
git add apps/infrastructure/cert-manager/overlays/prod-tenant/tenant-b/
git commit -m "feat: add cert-manager overlay for tenant-b"
```

---

### Task 4: Remove Cross-Tenant IngressRoute from Tenant-a

**Files:**
- Modify: `apps/infrastructure/traefik/overlays/prod/ingress-routes.yaml`

**Interfaces:**
- Consumes: Existing ingress-routes.yaml with Immich IngressRoute
- Produces: Updated file without Immich IngressRoute

- [ ] **Step 1: Remove Immich IngressRoute**

Edit `apps/infrastructure/traefik/overlays/prod/ingress-routes.yaml`. Remove lines 164-192 (the Immich Ingress section):

```yaml

---
# ── Ingress: Immich via Tailscale (HTTPS) ───────────────────
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: immich-server
  namespace: traefik
  annotations:
    argocd.argoproj.io/sync-wave: "5"
    traefik.ingress.kubernetes.io/router.entrypoints: websecure
    traefik.ingress.kubernetes.io/router.tls: "true"
    traefik.ingress.kubernetes.io/router.tls.certresolver: ""
spec:
  ingressClassName: tailscale
  tls:
    - hosts:
        - immich.newyeti.qzz.io
      secretName: newyeti-tls-cert
  rules:
    - host: immich.newyeti.qzz.io
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: immich
                port:
                  number: 2283
```

- [ ] **Step 2: Verify remaining IngressRoutes**

Verify the file still contains:
- TLSStore (default certificate)
- ServersTransport (argocd-transport)
- Middlewares (argocd-headers, redirect-to-https, strip-api-prefix, dashboard-redirect)
- IngressRoutes (http-to-https-redirect, traefik-dashboard, argocd-server)

- [ ] **Step 3: Commit**

```bash
git add apps/infrastructure/traefik/overlays/prod/ingress-routes.yaml
git commit -m "chore: remove cross-tenant Immich IngressRoute from tenant-a"
```

---

### Task 5: Clean Up Immich-specific Tailscale Resources

**Files:**
- Delete: `apps/workloads/immich/overlays/prod/tenant-b/immich-connector.yaml`
- Delete: `apps/workloads/immich/overlays/prod/tenant-b/immich-networkpolicy.yaml`
- Delete: `apps/workloads/immich/overlays/prod/tenant-b/kustomization.yaml`
- Delete: `apps/infrastructure/traefik/overlays/prod/immich-connector-service.yaml`

**Interfaces:**
- Consumes: Existing files to delete
- Produces: Cleaned up codebase without unused Tailscale resources

- [ ] **Step 1: Delete immich-specific Tailscale resources**

Run:
```bash
rm apps/workloads/immich/overlays/prod/tenant-b/immich-connector.yaml
rm apps/workloads/immich/overlays/prod/tenant-b/immich-networkpolicy.yaml
rm apps/workloads/immich/overlays/prod/tenant-b/kustomization.yaml
```

- [ ] **Step 2: Delete orphaned connector service**

Run:
```bash
rm apps/infrastructure/traefik/overlays/prod/immich-connector-service.yaml
```

- [ ] **Step 3: Commit**

```bash
git add -u
git commit -m "chore: remove unused Immich Tailscale resources and orphaned connector service"
```

---

### Task 6: Verify and Test

**Files:**
- None (verification only)

**Interfaces:**
- Consumes: All resources from Tasks 1-5
- Produces: Confirmation that Immich is accessible via `https://immich.newyeti.qzz.io`

- [ ] **Step 1: Verify tenant-b traefik is deployed**

Run on tenant-b cluster:
```bash
kubectl get pods -n traefik
```

Expected: Traefik pods running on workload nodes

- [ ] **Step 2: Verify tenant-b cert-manager is deployed**

Run on tenant-b cluster:
```bash
kubectl get pods -n cert-manager
```

Expected: cert-manager, cert-manager-webhook, cert-manager-cainjector pods running

- [ ] **Step 3: Verify Immich IngressRoute exists**

Run on tenant-b cluster:
```bash
kubectl get ingressroute immich-server -n traefik
```

Expected: IngressRoute exists

- [ ] **Step 4: Verify TLS certificate is issued**

Run on tenant-b cluster:
```bash
kubectl get certificate newyeti-tls-cert -n traefik
```

Expected: `READY: True`, `STATUS: CertificateIssued`

- [ ] **Step 5: Verify cross-tenant route removed from tenant-a**

Run on tenant-a cluster:
```bash
kubectl get ingressroute immich-server -n traefik
```

Expected: NotFound

- [ ] **Step 6: Test HTTPS access**

Run from a machine with DNS configured to tenant-b's Traefik IP:
```bash
curl -I https://immich.newyeti.qzz.io
```

Expected: HTTP 200 or 302 (redirect to login page)

- [ ] **Step 7: Test TLS certificate**

Run:
```bash
openssl s_client -connect immich.newyeti.qzz.io:443 -servername immich.newyeti.qzz.io </dev/null 2>/dev/null | openssl x509 -noout -subject -issuer
```

Expected: Certificate issued by Let's Encrypt for `immich.newyeti.qzz.io`

- [ ] **Step 8: Commit verification (optional)**

No commit needed for verification steps.
