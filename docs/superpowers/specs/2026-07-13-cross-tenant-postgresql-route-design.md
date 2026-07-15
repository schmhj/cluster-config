# Cross-Tenant PostgreSQL Route Design

**Date:** 2026-07-13
**Status:** Draft
**Author:** opencode

---

## Overview

Configure a Traefik-based database route to expose PostgreSQL from tenant-b to tenant-a and local machines, using TLS termination at Traefik and Tailscale for cross-cluster service discovery.

## Context

### Current State
- **Tenant-a**: Runs Traefik, cert-manager, ArgoCD (manages both clusters)
- **Tenant-b**: Runs PostgreSQL (`postgresql-prod-tenant-b` on port 5432 in `workloads` namespace), Immich, Tailscale operator
- **Cross-cluster networking**: OCI LPG connecting tenant-a and tenant-b VCNs
- **Traefik config**: `allowCrossNamespace: true` enabled, existing TLS via `newyeti-tls-cert`
- **Tailscale**: Already installed on tenant-b, same Tailnet to be used for tenant-a

### Requirements
1. **Internal service mesh**: Tenant-a workloads can reach PostgreSQL on tenant-b
2. **Local machine access**: External access to PostgreSQL through Traefik
3. **Secure connection**: TLS termination at Traefik using cert-manager
4. **Automatic discovery**: No static IPs, Tailscale handles service discovery
5. **Security**: NetworkPolicy to restrict access

## Architecture

```
Local Machine / Tenant-a Workloads
         │
         │ TLS (port 6432)
         ▼
┌─────────────────────────────────────────────────┐
│  Traefik (tenant-a, traefik namespace)          │
│  ├─ TCP EntryPoint: pg-db (:6432)              │
│  ├─ TLS termination (pg-tls-cert)              │
│  └─ TCPIngressRoute: HostSNI(`pg.newyeti.qzz.io`) │
└─────────────────────────────────────────────────┘
         │
         │ Tailscale IP (100.x.x.x)
         ▼
┌─────────────────────────────────────────────────┐
│  Tailscale Connector (tenant-b, workloads ns)   │
│  hostname: postgresql                           │
│  Routes to: postgresql-prod-tenant-b:5432       │
└─────────────────────────────────────────────────┘
         │
         │ Pod IP (within cluster)
         ▼
┌─────────────────────────────────────────────────┐
│  PostgreSQL (tenant-b, workloads namespace)     │
│  service: postgresql-prod-tenant-b:5432         │
└─────────────────────────────────────────────────┘
```

**Connection flow:**
1. Client connects to `pg.newyeti.qzz.io:6432` with TLS
2. Traefik terminates TLS, forwards to Tailscale IP of Connector
3. Tailscale Connector routes to PostgreSQL service
4. PostgreSQL responds back through the same path

## Design Decisions

### 1. Tailscale over Static IPs
**Decision:** Use Tailscale for cross-cluster service discovery instead of static IPs via LPG.
**Rationale:** Tailscale provides automatic service discovery, health checking, and WireGuard encryption. No manual IP management needed. Tailscale IPs follow pods, not nodes.

### 2. Tailscale Connector over Service Annotation
**Decision:** Use Tailscale Connector to expose PostgreSQL instead of service annotation.
**Rationale:** Dedicated proxy pod provides better isolation, configurable health checks, and explicit exposure. Better for stateful services like databases.

### 3. TLS Termination at Traefik
**Decision:** Terminate TLS at Traefik, forward to Tailscale (encrypted via WireGuard).
**Rationale:** Consistent with existing Traefik pattern. Tailscale provides WireGuard encryption between clusters, so traffic is encrypted end-to-end (TLS at Traefik + WireGuard between clusters).

### 4. Label-Based NetworkPolicy
**Decision:** Use `db-access: "true"` label for fine-grained internal access control.
**Rationale:** Allows explicit control over which pods can reach PostgreSQL within tenant-b. Immich and future workloads opt-in by adding the label.

## Files to Create/Modify

### Tenant-a Changes

| File | Action | Description |
|------|--------|-------------|
| `apps/workloads/tailscale-operator/overlays/prod/tenant-a/config.json` | New | Tailscale operator config for tenant-a |
| `apps/workloads/tailscale-operator/overlays/prod/tenant-a/values.yaml` | New | Tailscale operator values for tenant-a |
| `apps/infrastructure/infra-secrets/overlays/prod/tailscale-tenant-a-sealedsecret.yaml` | New | Tailscale auth key for tenant-a |
| `apps/infrastructure/traefik/base/values.yaml` | Modify | Add `pg-db` TCP entrypoint (port 6432) |
| `apps/infrastructure/traefik/overlays/prod/certificate.yaml` | Modify | Add `pg-tls-cert` for `pg.newyeti.qzz.io` |
| `apps/infrastructure/traefik/overlays/prod/ingress-routes.yaml` | Modify | Add `TCPIngressRoute` for PostgreSQL |

### Tenant-b Changes

| File | Action | Description |
|------|--------|-------------|
| `apps/workloads/postgresql/overlays/prod/tenant-b/postgresql-connector.yaml` | New | Tailscale Connector for PostgreSQL |
| `apps/workloads/postgresql/overlays/prod/tenant-b/postgresql-networkpolicy.yaml` | New | NetworkPolicy restricting access |
| `apps/workloads/postgresql/overlays/prod/tenant-b/kustomization.yaml` | Modify | Add new resources |

## Detailed Specifications

### 1. Tailscale Operator on Tenant-a

Create `apps/workloads/tailscale-operator/overlays/prod/tenant-a/config.json`:

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

Create `apps/workloads/tailscale-operator/overlays/prod/tenant-a/values.yaml`:

```yaml
operatorConfig:
  hostname: "tailscale-operator-tenant-a"
```

### 2. Tailscale Secret for Tenant-a

Create `apps/infrastructure/infra-secrets/overlays/prod/tailscale-tenant-a-sealedsecret.yaml`:

```yaml
apiVersion: bitnami.com/v1alpha1
kind: SealedSecret
metadata:
  name: tailscale-tenant-a-secret
  namespace: tailscale
  annotations:
    reflector.v1.k8s.emberstack.com/reflection-allowed: "true"
    reflector.v1.k8s.emberstack.com/reflection-allowed-namespaces: "tailscale"
    reflector.v1.k8s.emberstack.com/reflection-auto-enabled: "true"
spec:
  encryptedData:
    auth-key: <ENCRYPTED_AUTH_KEY>  # Use: kubeseal --format yaml < tailscale-tenant-a-auth-key.yaml
  template:
    metadata:
      name: tailscale-tenant-a-secret
      namespace: tailscale
      annotations:
        reflector.v1.k8s.emberstack.com/reflection-allowed: "true"
        reflector.v1.k8s.emberstack.com/reflection-allowed-namespaces: "tailscale"
        reflector.v1.k8s.emberstack.com/reflection-auto-enabled: "true"
    type: Opaque
    data:
      auth-key: ""
```

### 3. Tailscale Connector for PostgreSQL (Tenant-b)

Create `apps/workloads/postgresql/overlays/prod/tenant-b/postgresql-connector.yaml`:

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

This exposes PostgreSQL as `postgresql.<tailnet-name>.ts.net` on the Tailnet.

### 4. Traefik TCP EntryPoint

Add to `apps/infrastructure/traefik/base/values.yaml`:

```yaml
ports:
  pg-db:
    port: 6432
    expose:
      default: true
    exposedPort: 6432
    protocol: TCP
    tls:
      enabled: true
```

### 5. TLS Certificate

Add to `apps/infrastructure/traefik/overlays/prod/certificate.yaml`:

```yaml
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

### 6. TCPIngressRoute

Add to `apps/infrastructure/traefik/overlays/prod/ingress-routes.yaml`:

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

**Note:** The TCPIngressRoute targets the Tailscale Connector in tenant-b. Since Tailscale Connector is exposed on the Tailnet, Traefik on tenant-a needs to reach it via the Tailscale network. If Traefik is not in the Tailnet, you may need to use the Tailscale IP directly or install Tailscale on the Traefik pods.

**Alternative:** If Traefik is not in the Tailnet, create a headless service on tenant-a pointing to the Tailscale Connector's IP:

```yaml
# On tenant-a: Headless service pointing to Tailscale IP
apiVersion: v1
kind: Service
metadata:
  name: postgresql-connector
  namespace: traefik
spec:
  clusterIP: None
  ports:
    - port: 5432
      targetPort: 5432
---
apiVersion: v1
kind: Endpoints
metadata:
  name: postgresql-connector
  namespace: traefik
subsets:
  - addresses:
      - ip: <TAILSCALE_CONNECTOR_IP>  # Tailscale IP of the connector pod
    ports:
      - port: 5432
```

### 7. NetworkPolicy (Tenant-b)

Create `apps/workloads/postgresql/overlays/prod/tenant-b/postgresql-networkpolicy.yaml`:

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

## Connection Usage

### Local Machine Access

```bash
# Connection string (via Traefik TLS)
psql "host=pg.newyeti.qzz.io port=6432 sslmode=require dbname=immich user=immich"

# Or with environment variables
export PGHOST=pg.newyeti.qzz.io
export PGPORT=6432
export PGSSLMODE=require
export PGDATABASE=immich
export PGUSER=immich
psql
```

### Tenant-a Workload Access

From a pod in tenant-a, connect via Tailscale (if in the Tailnet):

```bash
# Direct Tailscale access (if pod is in Tailnet)
psql "host=postgresql.<tailnet-name>.ts.net port=5432 sslmode=require dbname=immich user=immich"

# Or via Traefik (if pod is not in Tailnet)
psql "host=pg.newyeti.qzz.io port=6432 sslmode=require dbname=immich user=immich"
```

## DNS Configuration

1. **Traefik DNS:** Create DNS record for `pg.newyeti.qzz.io` pointing to Traefik's IP
2. **Tailscale DNS:** Automatic via MagicDNS (`postgresql.<tailnet-name>.ts.net`)

## Verification

1. **Test TLS connection from local machine:**
   ```bash
   openssl s_client -connect pg.newyeti.qzz.io:6432 -servername pg.newyeti.qzz.io
   ```

2. **Test PostgreSQL connection:**
   ```bash
   psql "host=pg.newyeti.qzz.io port=6432 sslmode=require dbname=immich user=immich" -c "SELECT 1"
   ```

3. **Verify Tailscale Connector:**
   ```bash
   # On tenant-b
   kubectl get connectors -n workloads
   kubectl describe connector postgresql-connector -n workloads
   ```

4. **Verify NetworkPolicy:**
   ```bash
   # From tenant-b pod without db-access label (should fail)
   kubectl exec -n workloads <pod-without-label> -- psql -h postgresql-prod-tenant-b -U immich -d immich

   # From tenant-b pod with db-access=true label (should succeed)
   kubectl exec -n workloads <pod-with-label> -- psql -h postgresql-prod-tenant-b -U immich -d immich
   ```

## Security Considerations

| Risk | Severity | Mitigation |
|------|----------|------------|
| Plaintext TCP (Traefik → Connector) | Low | Tailscale WireGuard encryption between clusters |
| NodePort exposure | Low | No NodePort needed with Tailscale |
| Static IP dependency | None | Tailscale handles discovery automatically |
| No Traefik auth | Low | PostgreSQL `pg_hba.conf` handles auth |
| Tailscale key exposure | Medium | SealedSecret + Reflector for secret management |

## Prerequisites

1. Tailscale auth key for tenant-a (from existing Tailnet)
2. DNS record for `pg.newyeti.qzz.io` pointing to Traefik's IP
3. PostgreSQL `pg_hba.conf` configured for remote connections
4. `db-access: "true"` label added to Immich pods on tenant-b
5. Tailscale operator already running on tenant-b

## Future Improvements

1. **End-to-end TLS**: Configure PostgreSQL to serve TLS for full encryption
2. **Connection pooling**: Add PgBouncer for connection management
3. **Monitoring**: Add Prometheus metrics for PostgreSQL connection monitoring
4. **Tailscale ACLs**: Configure fine-grained access control via Tailscale ACLs
