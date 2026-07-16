# Same-Cluster Immich Route Design

**Date:** 2026-07-15
**Status:** Approved
**Author:** opencode

---

## Overview

Route HTTPS traffic for `immich.newyeti.qzz.io` through Traefik on tenant-b (same cluster as Immich), replacing the cross-tenant routing via tenant-a. Deploy Traefik and cert-manager to tenant-b, add an Immich IngressRoute, and remove the cross-tenant route from tenant-a.

## Context

### Current State
- **Tenant-a**: Runs Traefik (LoadBalancer), cert-manager, ArgoCD, Tailscale operator
- **Tenant-b**: Runs Immich (port 2283 in `workloads` namespace), PostgreSQL, Tailscale operator
- **Cross-tenant routing**: User → Traefik (tenant-a) → Tailscale WireGuard → Connector (tenant-b) → Immich
- **DNS**: `immich.newyeti.qzz.io` resolves to tenant-a's Traefik IP

### Problem
The cross-tenant routing through Tailscale is complex for a single-service exposure. Since Immich and the user-facing Traefik ingress can coexist on tenant-b, same-cluster routing is simpler.

### Requirements
1. **Simplified routing**: Traefik on tenant-b handles Immich traffic directly
2. **TLS**: cert-manager on tenant-b with same Let's Encrypt + Cloudflare DNS01 setup
3. **Same Traefik config**: Mirror tenant-a's Traefik setup (dashboard, HTTP→HTTPS, TLSStore, middlewares)
4. **DNS update**: `immich.newyeti.qzz.io` points to tenant-b's Traefik LoadBalancer
5. **Cleanup**: Remove cross-tenant IngressRoute from tenant-a
6. **Retain for future**: Keep kustomize source in workload appset and Tailscale on tenant-a

## Architecture

**Before:**
```
User → DNS → Traefik (tenant-a) → Tailscale WireGuard → Connector (tenant-b) → Immich
```

**After:**
```
User → DNS → Traefik (tenant-b) → Immich (same cluster, workloads namespace)
```

## Design Decisions

### 1. Shared prod overlay + tenant-b-only IngressRoute
**Decision:** Use the existing shared `overlays/prod/` traefik config as the base for tenant-b, with a tenant-b-specific overlay that adds the Immich IngressRoute.
**Rationale:** Minimizes duplication. Shared IngressRoutes (dashboard, ArgoCD, HTTP→HTTPS redirect) stay in one place. Only the Immich route is tenant-specific.

### 2. Traefik IngressRoute (not standard Ingress)
**Decision:** Use Traefik `IngressRoute` CRD with `namespace: workloads` for cross-namespace service reference.
**Rationale:** Standard Kubernetes `Ingress` cannot reference services in other namespaces. Traefik's `allowCrossNamespace: true` enables this.

### 3. cert-manager on tenant-b
**Decision:** Deploy cert-manager on tenant-b with the same ClusterIssuer (Let's Encrypt + Cloudflare DNS01).
**Rationale:** TLS certificates are managed per-cluster. tenant-b needs its own cert-manager to issue certificates for `immich.newyeti.qzz.io`.

### 4. Retain kustomize source and Tailscale
**Decision:** Keep the kustomize source in the workload appset (third source) and Tailscale operator on tenant-a, but remove immich-specific Tailscale resources.
**Rationale:** Infrastructure for future cross-tenant routing. The kustomize source enables deploying extra Kustomize resources per workload. Tailscale on tenant-a is ready for future services.

## Files to Create

### 1. `apps/infrastructure/traefik/overlays/prod-tenant/tenant-b/kustomization.yaml`

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

### 2. `apps/infrastructure/traefik/overlays/prod-tenant/tenant-b/tolerations-patch.yaml`

Patches Traefik Deployment with workload node tolerations (`tier=workload:NoSchedule`) and node affinity for `tier=workload` nodes (same pattern as tenant-a after update).

### 3. `apps/infrastructure/traefik/overlays/prod-tenant/tenant-b/immich-ingress-route.yaml`

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

### 4. `apps/infrastructure/cert-manager/overlays/prod-tenant/tenant-b/kustomization.yaml`

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

### 5. `apps/infrastructure/cert-manager/overlays/prod-tenant/tenant-b/tolerations-patch.yaml`

Patches cert-manager Deployments with workload node tolerations (`tier=workload:NoSchedule`) and node affinity for `tier=workload` nodes (same pattern as tenant-a after update).

## Files to Modify

### 1. `apps/infrastructure/traefik/overlays/prod/ingress-routes.yaml`

**Remove** the Immich IngressRoute (lines 164-192). The remaining IngressRoutes (dashboard, ArgoCD, HTTP→HTTPS redirect) stay unchanged.

### 2. `apps/infrastructure/traefik/overlays/prod/certificate.yaml`

No change — `immich.newyeti.qzz.io` is already in `dnsNames`. This certificate will be deployed to tenant-b via the new cert-manager overlay.

## Files to Delete

| File | Reason |
|------|--------|
| `apps/workloads/immich/overlays/prod/tenant-b/immich-connector.yaml` | Tailscale Connector no longer needed for same-cluster routing |
| `apps/workloads/immich/overlays/prod/tenant-b/immich-networkpolicy.yaml` | NetworkPolicy for Tailscale access no longer needed |
| `apps/workloads/immich/overlays/prod/tenant-b/kustomization.yaml` | Kustomization for above resources no longer needed |
| `apps/infrastructure/traefik/overlays/prod/immich-connector-service.yaml` | Orphaned headless service, never deployed |

## Resources Retained (for future use)

| Resource | Location | Purpose |
|----------|----------|---------|
| Kustomize source | `appsets/prod/tenant-b/workload-appset.yaml` (third source) | Enables deploying extra Kustomize resources per workload |
| Tailscale operator | `apps/workloads/tailscale-operator/` | Ready for future cross-tenant routing |

## DNS Configuration

Update DNS record: `immich.newyeti.qzz.io` → tenant-b's Traefik LoadBalancer IP.

## Sync Waves

| Wave | Component | Notes |
|------|-----------|-------|
| 0 | `appprojects-app` (bootstrap) | Creates AppProject CRs |
| 2 | sealed-secrets, namespaces, AppProject CRs | AppProjects must exist before apps reference them |
| 3 | infra-secrets, argocd-config, **cert-manager**, **traefik** | Traefik and cert-manager now deployed to tenant-b |
| 4 | reflector, grafana-alloy, other infra | Standard infra wave |
| 5 | Workload apps + Immich IngressRoute | IngressRoute deployed via traefik overlay |

## Verification

1. **Check Traefik deployed on tenant-b:**
   ```bash
   kubectl get pods -n traefik --context tenant-b
   ```

2. **Check cert-manager deployed on tenant-b:**
   ```bash
   kubectl get pods -n cert-manager --context tenant-b
   ```

3. **Check Immich IngressRoute exists:**
   ```bash
   kubectl get ingressroute immich-server -n traefik --context tenant-b
   ```

4. **Check TLS certificate issued:**
   ```bash
   kubectl get certificate newyeti-tls-cert -n traefik --context tenant-b
   ```

5. **Test Immich access:**
   ```bash
   curl -I https://immich.newyeti.qzz.io
   # Expected: HTTP 200 or 302 (redirect to login)
   ```

6. **Verify cross-tenant route removed from tenant-a:**
   ```bash
   kubectl get ingressroute immich-server -n traefik --context tenant-a
   # Expected: NotFound
   ```
