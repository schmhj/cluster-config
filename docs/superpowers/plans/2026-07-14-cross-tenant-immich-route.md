# Cross-Tenant Immich Route Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Route HTTPS traffic from `immich.newyeti.qzz.io` on tenant-a's Traefik to Immich running on tenant-b via Tailscale Connector.

**Architecture:** Tailscale Connector on tenant-b exposes Immich on the Tailnet. Tailscale operator on tenant-a provisions a proxy via IngressClass. Traefik terminates TLS and routes to the proxy. NetworkPolicy restricts Immich access on tenant-b.

**Tech Stack:** Traefik, Tailscale Operator, cert-manager, Kubernetes NetworkPolicy, Kustomize

## Global Constraints

- All Kubernetes manifests use `apiVersion: kustomize.config.k8s.io/v1beta1` for Kustomization files
- ArgoCD resources live in `namespace: argocd`
- Sync-wave annotations required on all ArgoCD-managed resources
- Secrets are encrypted (SealedSecret), never stored in plaintext
- `allowCrossNamespace: true` is already enabled on Traefik's kubernetesCRD provider
- Tailscale operator already deployed on both tenants with IngressClass enabled

---

### Task 1: Create Tailscale Connector for Immich (Tenant-b)

**Files:**
- Create: `apps/workloads/immich/overlays/prod/tenant-b/immich-connector.yaml`

**Interfaces:**
- Consumes: `immich-prod-tenant-b` service (already exists in `workloads` namespace on tenant-b)
- Produces: Tailscale Connector `immich-connector` exposing port 2283 on Tailnet as `immich.<tailnet>.ts.net`

- [ ] **Step 1: Create the Connector manifest**

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

- [ ] **Step 2: Verify YAML validity**

Run: `kubectl apply --dry-run=client -f apps/workloads/immich/overlays/prod/tenant-b/immich-connector.yaml`
Expected: No errors (CRD validation may not work client-side for Tailscale CRDs, but YAML syntax should be valid)

- [ ] **Step 3: Commit**

```bash
git add apps/workloads/immich/overlays/prod/tenant-b/immich-connector.yaml
git commit -m "feat: add Tailscale Connector for Immich on tenant-b"
```

---

### Task 2: Create NetworkPolicy for Immich (Tenant-b)

**Files:**
- Create: `apps/workloads/immich/overlays/prod/tenant-b/immich-networkpolicy.yaml`

**Interfaces:**
- Consumes: Immich pods with label `app.kubernetes.io/name: immich`, Tailscale pods with label `app.kubernetes.io/name: tailscale`
- Produces: NetworkPolicy `allow-immich-access` restricting ingress to port 2283

- [ ] **Step 1: Create the NetworkPolicy manifest**

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
    - from:
        - podSelector:
            matchLabels:
              app.kubernetes.io/name: tailscale
      ports:
        - protocol: TCP
          port: 2283
    - from:
        - podSelector:
            matchLabels:
              immich-access: "true"
      ports:
        - protocol: TCP
          port: 2283
```

- [ ] **Step 2: Verify YAML validity**

Run: `kubectl apply --dry-run=client -f apps/workloads/immich/overlays/prod/tenant-b/immich-networkpolicy.yaml`
Expected: No errors

- [ ] **Step 3: Commit**

```bash
git add apps/workloads/immich/overlays/prod/tenant-b/immich-networkpolicy.yaml
git commit -m "feat: add NetworkPolicy for Immich access control on tenant-b"
```

---

### Task 3: Create Kustomization for Immich Overlay (Tenant-b)

**Files:**
- Create: `apps/workloads/immich/overlays/prod/tenant-b/kustomization.yaml`

**Interfaces:**
- Consumes: `immich-connector.yaml`, `immich-networkpolicy.yaml` (from Tasks 1-2)
- Produces: Kustomization resource list for ArgoCD kustomize source

- [ ] **Step 1: Create the Kustomization manifest**

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - immich-connector.yaml
  - immich-networkpolicy.yaml
```

- [ ] **Step 2: Verify kustomize build**

Run: `kustomize build apps/workloads/immich/overlays/prod/tenant-b/`
Expected: Outputs both the Connector and NetworkPolicy resources concatenated

- [ ] **Step 3: Commit**

```bash
git add apps/workloads/immich/overlays/prod/tenant-b/kustomization.yaml
git commit -m "feat: add kustomization for Immich overlay resources on tenant-b"
```

---

### Task 4: Update TLS Certificate (Tenant-a)

**Files:**
- Modify: `apps/infrastructure/traefik/overlays/prod/certificate.yaml:22-24`

**Interfaces:**
- Consumes: Existing `newyeti-tls-cert` Certificate resource
- Produces: Updated `dnsNames` list including `immich.newyeti.qzz.io`

- [ ] **Step 1: Add immich DNS name to certificate**

Edit `apps/infrastructure/traefik/overlays/prod/certificate.yaml`. Change the `dnsNames` section from:

```yaml
  dnsNames:
    - newyeti.qzz.io
    - "*.newyeti.qzz.io"
```

To:

```yaml
  dnsNames:
    - newyeti.qzz.io
    - "*.newyeti.qzz.io"
    - immich.newyeti.qzz.io
```

- [ ] **Step 2: Verify YAML validity**

Run: `kubectl apply --dry-run=client -f apps/infrastructure/traefik/overlays/prod/certificate.yaml`
Expected: No errors

- [ ] **Step 3: Commit**

```bash
git add apps/infrastructure/traefik/overlays/prod/certificate.yaml
git commit -m "feat: add immich.newyeti.qzz.io to TLS certificate"
```

---

### Task 5: Add IngressRoute for Immich (Tenant-a)

**Files:**
- Modify: `apps/infrastructure/traefik/overlays/prod/ingress-routes.yaml`

**Interfaces:**
- Consumes: `newyeti-tls-cert` TLS secret, `immich` service via Tailscale IngressClass
- Produces: IngressRoute `immich-server` routing `Host(immich.newyeti.qzz.io)` to port 2283

- [ ] **Step 1: Append IngressRoute to ingress-routes.yaml**

Add the following to the end of `apps/infrastructure/traefik/overlays/prod/ingress-routes.yaml`:

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

- [ ] **Step 2: Verify YAML validity**

Run: `kubectl apply --dry-run=client -f apps/infrastructure/traefik/overlays/prod/ingress-routes.yaml`
Expected: No errors

- [ ] **Step 3: Commit**

```bash
git add apps/infrastructure/traefik/overlays/prod/ingress-routes.yaml
git commit -m "feat: add IngressRoute for Immich via Tailscale on tenant-a"
```

---

### Task 6: Update Workload Appset with Kustomization Source (Tenant-b)

**Files:**
- Modify: `appsets/prod/tenant-b/workload-appset.yaml:51-69`

**Interfaces:**
- Consumes: Existing appset templatePatch with chart source + values source
- Produces: Updated templatePatch with third kustomize source for apps that have a `kustomization.yaml`

- [ ] **Step 1: Add kustomize source to templatePatch**

Edit `appsets/prod/tenant-b/workload-appset.yaml`. In the `templatePatch` section, add a third source after the existing `values` source. The full templatePatch should become:

```yaml
  templatePatch: |
    spec:
      sources:
        - repoURL: '{{ .chartRepo }}'
          targetRevision: '{{ .chartVersion }}'
      {{- if .isGitRepo }}
          path: '{{ .chartName }}'
      {{- else }}
          chart: '{{ .chartName }}'
      {{- end }}
          helm:
            valueFiles:
              - $values/apps/workloads/{{index .path.segments 2}}/base/values.yaml
              - $values/apps/workloads/{{index .path.segments 2}}/overlays/prod/values.yaml
              - $values/apps/workloads/{{index .path.segments 2}}/overlays/prod/tenant-b/values.yaml
              
        - repoURL: https://github.com/schmhj/cluster-config.git
          targetRevision: main
          ref: values

        - repoURL: https://github.com/schmhj/cluster-config.git
          targetRevision: main
          ref: kustomize
          path: '{{ .path.path }}'
```

- [ ] **Step 2: Verify YAML validity**

Run: `kubectl apply --dry-run=client -f appsets/prod/tenant-b/workload-appset.yaml`
Expected: No errors

- [ ] **Step 3: Commit**

```bash
git add appsets/prod/tenant-b/workload-appset.yaml
git commit -m "feat: add kustomize source to tenant-b workload appset"
```

---

### Task 7: Verify and Test

**Files:**
- None (verification only)

**Interfaces:**
- Consumes: All resources from Tasks 1-6
- Produces: Confirmation that Immich is accessible via `https://immich.newyeti.qzz.io`

- [ ] **Step 1: Verify tenant-b resources are applied**

Run on tenant-b cluster:
```bash
kubectl get connectors -n workloads
kubectl get networkpolicies -n workloads
```

Expected:
- `immich-connector` connector exists
- `allow-immich-access` network policy exists

- [ ] **Step 2: Verify Tailscale Connector is healthy**

Run on tenant-b cluster:
```bash
kubectl describe connector immich-connector -n workloads
```

Expected: Status shows `Ready: True` and the Connector pod is running

- [ ] **Step 3: Verify TLS certificate is issued**

Run on tenant-a cluster:
```bash
kubectl get certificate -n traefik newyeti-tls-cert -o wide
```

Expected: `READY: True`, `STATUS: CertificateIssued`

- [ ] **Step 4: Verify IngressRoute is created**

Run on tenant-a cluster:
```bash
kubectl get ingressroute -n traefik immich-server -o yaml
```

Expected: IngressRoute exists with `Host(immich.newyeti.qzz.io)` route

- [ ] **Step 5: Test HTTPS access**

Run from a machine with DNS configured:
```bash
curl -I https://immich.newyeti.qzz.io
```

Expected: HTTP 200 or 302 (redirect to login page)

- [ ] **Step 6: Test TLS certificate**

Run:
```bash
openssl s_client -connect immich.newyeti.qzz.io:443 -servername immich.newyeti.qzz.io </dev/null 2>/dev/null | openssl x509 -noout -subject -issuer
```

Expected: Certificate issued by Let's Encrypt for `immich.newyeti.qzz.io`

- [ ] **Step 7: Commit verification (optional)**

No commit needed for verification steps.
