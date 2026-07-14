# Cross-Tenant Immich Route Design

**Date:** 2026-07-14
**Status:** Draft
**Author:** opencode

---

## Overview

Configure Traefik on tenant-a to route HTTPS traffic to Immich running on tenant-b, using Tailscale Connector for cross-cluster service discovery and the Tailscale IngressClass for automatic proxy provisioning.

## Context

### Current State
- **Tenant-a**: Runs Traefik (NodePort 30443), cert-manager, ArgoCD (manages both clusters), Tailscale operator
- **Tenant-b**: Runs Immich server (port 2283 in `workloads` namespace), PostgreSQL, Tailscale operator
- **Cross-cluster networking**: OCI LPG connecting tenant-a and tenant-b VCNs, Tailscale operator on both tenants
- **Traefik config**: `allowCrossNamespace: true` enabled, existing TLS via `newyeti-tls-cert` covering `*.newyeti.qzz.io`
- **Tailscale**: Operator deployed on both tenants with IngressClass enabled (`name: tailscale`)

### Requirements
1. **Public access**: Users access Immich via `https://immich.newyeti.qzz.io`
2. **TLS termination**: Traefik handles TLS using existing cert-manager setup
3. **Secure transport**: WireGuard encryption between clusters via Tailscale
4. **Automatic discovery**: Tailscale handles service discovery, no static IPs
5. **Network isolation**: NetworkPolicy restricts Immich pod access on tenant-b
6. **Consistency**: Keep Immich configuration self-contained while following existing workload patterns

## Architecture

```
User (browser)
     │
     │ HTTPS (443)
     ▼
┌──────────────────────────────────────────────────┐
│  Traefik (tenant-a, traefik namespace)           │
│  ├─ IngressRoute: Host(immich.newyeti.qzz.io)   │
│  ├─ ingressClassName: tailscale                  │
│  └─ TLS termination (newyeti-tls-cert)          │
└──────────────────────────────────────────────────┘
     │
     │ Tailscale WireGuard tunnel
     ▼
┌──────────────────────────────────────────────────┐
│  Tailscale Connector (tenant-b, workloads ns)    │
│  hostname: immich                                │
│  Routes to: immich-prod-tenant-b:2283            │
└──────────────────────────────────────────────────┘
     │
     │ Cluster-local
     ▼
┌──────────────────────────────────────────────────┐
│  Immich Server (tenant-b, workloads namespace)   │
│  service: immich-prod-tenant-b:2283              │
└──────────────────────────────────────────────────┘
```

**Connection flow:**
1. User visits `https://immich.newyeti.qzz.io`
2. DNS resolves to Traefik's IP on tenant-a
3. Traefik terminates TLS, routes via IngressRoute (`ingressClassName: tailscale`)
4. Tailscale operator on tenant-a proxies traffic to the Connector on tenant-b via WireGuard
5. Connector forwards to Immich server on port 2283

## Design Decisions

### 1. Tailscale IngressClass over Headless Service
**Decision:** Use Tailscale IngressClass (`ingressClassName: tailscale`) instead of a manually managed headless service pointing to a Tailscale IP.
**Rationale:** The Tailscale operator automatically manages the proxy service lifecycle. When Tailscale IPs change, the operator updates endpoints without manual intervention. This is more maintainable than tracking IPs in a headless service.

### 2. Tailscale Connector over Service Annotation
**Decision:** Use Tailscale Connector to expose Immich instead of service annotation.
**Rationale:** Dedicated proxy pod provides better isolation, configurable health checks, and explicit exposure. Better for stateful services.

### 3. Single TLS Certificate
**Decision:** Add `immich.newyeti.qzz.io` to the existing `newyeti-tls-cert` certificate instead of creating a separate certificate.
**Rationale:** Reduces cert-manager overhead. The wildcard `*.newyeti.qzz.io` already covers the domain, but adding the explicit name ensures compatibility with strict TLS clients.

### 4. Kustomization as Third Source in Workload Appset
**Decision:** Add kustomization as a third source in the workload appset for extra resources (Connector, NetworkPolicy).
**Rationale:** Keeps Immich configuration self-contained in one directory. Values.yaml files continue working through the existing multi-source pattern. Apps without a `kustomization.yaml` are unaffected.

## Files to Create/Modify

### Tenant-b Changes

| File | Action | Description |
|------|--------|-------------|
| `apps/workloads/immich/overlays/prod/tenant-b/immich-connector.yaml` | New | Tailscale Connector for Immich |
| `apps/workloads/immich/overlays/prod/tenant-b/immich-networkpolicy.yaml` | New | NetworkPolicy restricting access |
| `apps/workloads/immich/overlays/prod/tenant-b/kustomization.yaml` | New | Kustomization including above resources |

### Tenant-a Changes

| File | Action | Description |
|------|--------|-------------|
| `apps/infrastructure/traefik/overlays/prod/certificate.yaml` | Modify | Add `immich.newyeti.qzz.io` to `dnsNames` |
| `apps/infrastructure/traefik/overlays/prod/ingress-routes.yaml` | Modify | Add IngressRoute for Immich |

### Appset Changes

| File | Action | Description |
|------|--------|-------------|
| `appsets/prod/tenant-b/workload-appset.yaml` | Modify | Add kustomization as third source |

## Detailed Specifications

### 1. Tailscale Connector (Tenant-b)

Create `apps/workloads/immich/overlays/prod/tenant-b/immich-connector.yaml`:

```yaml
apiVersion: tailscale.com/v1alpha1
kind: Connector
metadata:
  name: immich-connector
  namespace: workloads
spec:
  hostname: immich
  service:
    kubernetes:
      name: immich-prod-tenant-b
      namespace: workloads
      ports:
        - port: 2283
```

This exposes Immich as `immich.<tailnet-name>.ts.net` on the Tailnet.

### 2. NetworkPolicy (Tenant-b)

Create `apps/workloads/immich/overlays/prod/tenant-b/immich-networkpolicy.yaml`:

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-immich-access
  namespace: workloads
spec:
  podSelector:
    matchLabels:
      app.kubernetes.io/name: immich
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
          port: 2283
    # Allow from tenant-b pods with immich-access=true label
    - from:
        - podSelector:
            matchLabels:
              immich-access: "true"
      ports:
        - protocol: TCP
          port: 2283
```

### 3. Kustomization (Tenant-b)

Create `apps/workloads/immich/overlays/prod/tenant-b/kustomization.yaml`:

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - immich-connector.yaml
  - immich-networkpolicy.yaml
```

### 4. TLS Certificate Update (Tenant-a)

Add `immich.newyeti.qzz.io` to `apps/infrastructure/traefik/overlays/prod/certificate.yaml`:

```yaml
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: newyeti-tls-cert
  namespace: traefik
  annotations:
    argocd.argoproj.io/sync-wave: "4"
spec:
  secretName: newyeti-tls-cert
  issuerRef:
    name: letsencrypt-prod
    kind: ClusterIssuer
  dnsNames:
    - newyeti.qzz.io
    - "*.newyeti.qzz.io"
    - immich.newyeti.qzz.io
  duration: 2160h
  renewBefore: 360h
```

### 5. IngressRoute (Tenant-a)

Add to `apps/infrastructure/traefik/overlays/prod/ingress-routes.yaml`:

```yaml
---
# ── IngressRoute: Immich via Tailscale (HTTPS) ──────────────
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
  ingressClassName: tailscale
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

### 6. Appset Update

Add kustomization as a third source in `appsets/prod/tenant-b/workload-appset.yaml`:

```yaml
sources:
  # ... existing sources (chart + values) ...
  - repoURL: <this-repo>
    targetRevision: HEAD
    ref: kustomize
    directory:
      recurse: false
      jsonnet: {}
      excludeKustomization: false
      include: ""
      exclude: ""
```

Apps without a `kustomization.yaml` in their overlay directory are unaffected.

## Connection Usage

### Public Access

```bash
# Browser
https://immich.newyeti.qzz.io

# CLI (if Immich CLI is configured)
immich login https://immich.newyeti.qzz.io <api-key>
```

### Direct Tailscale Access (from Tailnet-connected pods)

```bash
# If pod is in the Tailnet
curl http://immich.<tailnet-name>.ts.net:2283
```

## DNS Configuration

1. Create DNS record: `immich.newyeti.qzz.io` → Traefik's IP on tenant-a
2. Tailscale DNS: Automatic via MagicDNS (`immich.<tailnet-name>.ts.net`)

## Verification

1. **Test TLS connection:**
   ```bash
   openssl s_client -connect immich.newyeti.qzz.io:443 -servername immich.newyeti.qzz.io
   ```

2. **Test Immich access:**
   ```bash
   curl -I https://immich.newyeti.qzz.io
   # Expected: HTTP 200 or 302 (redirect to login)
   ```

3. **Verify Tailscale Connector:**
   ```bash
   # On tenant-b
   kubectl get connectors -n workloads
   kubectl describe connector immich-connector -n workloads
   ```

4. **Verify NetworkPolicy:**
   ```bash
   # From tenant-b pod without immich-access label (should fail)
   kubectl exec -n workloads <pod-without-label> -- curl -s immich-prod-tenant-b:2283

   # From tenant-b pod with immich-access=true label (should succeed)
   kubectl exec -n workloads <pod-with-label> -- curl -s immich-prod-tenant-b:2283
   ```

## Security Considerations

| Risk | Severity | Mitigation |
|------|----------|------------|
| Plaintext HTTP (Traefik → Connector) | Low | Tailscale WireGuard encryption between clusters |
| NodePort exposure | Low | No NodePort needed with Tailscale |
| Static IP dependency | None | Tailscale handles discovery automatically |
| No Traefik auth | Low | Immich handles its own authentication |
| Tailscale key exposure | Medium | SealedSecret + Reflector for secret management |
| Overly permissive NetworkPolicy | Medium | Label-based access (`immich-access: "true"`) |

## Prerequisites

1. Tailscale operator running on tenant-a (already deployed)
2. Tailscale operator running on tenant-b (already deployed)
3. OCI LPG connecting tenant-a and tenant-b VCNs (already established)
4. DNS record for `immich.newyeti.qzz.io` pointing to Traefik's IP
5. `immich-access: "true"` label added to any tenant-b pods that need direct access

## Future Improvements

1. **End-to-end TLS**: Configure Immich server to serve TLS for full encryption
2. **Rate limiting**: Add rate-limit middleware to the IngressRoute
3. **Monitoring**: Add Prometheus metrics for Immich connection monitoring
4. **Tailscale ACLs**: Configure fine-grained access control via Tailscale ACLs
