# Multi-Tenant ArgoCD: Managing Both Tenants from tenant-a

## Overview

ArgoCD in tenant-a's cluster will manage deployments for both tenant-a and tenant-b clusters. tenant-b's cluster will be registered as a target cluster in tenant-a's ArgoCD.

## Architecture

```
tenant-a cluster:
  ArgoCD (argocd namespace)
  ├── root-app-prod-tenant-a → appsets/prod/tenant-a/
  │   ├── infrastructure-appset-prod-tenant-a → scans apps/infrastructure/*/overlays/prod-tenant/tenant-a
  │   └── workload-appset-prod-tenant-a → scans apps/workloads/*/overlays/prod/tenant/tenant-a
  ├── root-app-prod-tenant-b → appsets/prod/tenant-b/
  │   ├── infrastructure-appset-prod-tenant-b → scans apps/infrastructure/*/overlays/prod-tenant/tenant-b
  │   └── workload-appset-prod-tenant-b → scans apps/workloads/*/overlays/prod/tenant/tenant-b
  └── cluster-tenant-b Secret → registered target cluster
      └── deploys to https://129.158.33.235:6443 (tenant-b API server)
```

## Prerequisites

- Access to both clusters via kubeconfig
- kubeseal installed with `~/.secrets/sealed-secrets.pub`
- OCI CLI configured with TENANT_B profile (for tenant-b cluster access)
- Network connectivity between clusters on port 6443

## Step 1: Create ServiceAccount + RBAC on tenant-b

The tenant-b kubeconfig uses OCI CLI exec-based auth, which ArgoCD cannot use directly. Create a long-lived service account token instead.

```bash
KUBECONFIG=~/.kube/tenant-b-config kubectl apply -f - <<EOF
apiVersion: v1
kind: ServiceAccount
metadata:
  name: argocd-manager
  namespace: kube-system
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: argocd-manager-admin
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: cluster-admin
subjects:
  - kind: ServiceAccount
    name: argocd-manager
    namespace: kube-system
EOF
```

## Step 2: Create long-lived token Secret on tenant-b

```bash
KUBECONFIG=~/.kube/tenant-b-config kubectl apply -f - <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: argocd-manager-token
  namespace: kube-system
  annotations:
    kubernetes.io/service-account.name: argocd-manager
type: kubernetes.io/service-account-token
EOF
```

## Step 3: Extract credentials from tenant-b

```bash
# Token
TOKEN=$(KUBECONFIG=~/.kube/tenant-b-config kubectl get secret argocd-manager-token -n kube-system -o jsonpath='{.data.token}' | base64 -d)

# CA cert
CA=$(KUBECONFIG=~/.kube/tenant-b-config kubectl config view --raw --minify -o jsonpath='{.clusters[0].cluster.certificate-authority-data}')

# Server URL
SERVER="https://129.158.33.235:6443"

echo "Token: $TOKEN"
echo "CA: $CA"
echo "Server: $SERVER"
```

## Step 4: Seal the credentials

```bash
# Seal server URL
echo -n "$SERVER" | kubeseal --controller-namespace kube-system --format yaml --cert ~/.secrets/sealed-secrets.pub

# Seal cluster name
echo -n 'cluster-tenant-b' | kubeseal --controller-namespace kube-system --format yaml --cert ~/.secrets/sealed-secrets.pub

# Seal config JSON (replace TOKEN and CA with actual values from step 3)
echo -n "{\"bearerToken\":\"$TOKEN\",\"tlsClientConfig\":{\"insecure\":false,\"caData\":\"$CA\"}}" | kubeseal --controller-namespace kube-system --format yaml --cert ~/.secrets/sealed-secrets.pub
```

## Step 5: Files to create/modify

### 5a. Create cluster-tenant-b SealedSecret

**File:** `apps/infrastructure/argocd-config/overlays/prod/cluster-tenant-b-secret.yaml`

```yaml
apiVersion: bitnami.com/v1alpha1
kind: SealedSecret
metadata:
  name: cluster-tenant-b
  namespace: argocd
spec:
  encryptedData:
    name: <sealed value from step 4>
    server: <sealed value from step 4>
    config: <sealed value from step 4>
  template:
    metadata:
      labels:
        argocd.argoproj.io/secret-type: cluster
      name: cluster-tenant-b
      namespace: argocd
    type: Opaque
```

The `argocd.argoproj.io/secret-type: cluster` label tells ArgoCD this secret represents a target cluster.

### 5b. Update AppProjects to allow tenant-b cluster

**File:** `appprojects/prod/infrastructure.yaml`

Add tenant-b server to destinations:

```yaml
spec:
  destinations:
    - namespace: "*"
      server: "https://kubernetes.default.svc"
    - namespace: "*"
      server: "https://129.158.33.235:6443"
```

**File:** `appprojects/prod/workloads.yaml`

Same change — add tenant-b server to destinations.

### 5c. Modify tenant-b ApplicationSets

**File:** `appsets/prod/tenant-b/infrastructure-appset.yaml`

Change `destination.server`:

```yaml
    spec:
      project: infrastructure-prod
      source:
        repoURL: https://github.com/schmhj/cluster-config.git
        targetRevision: HEAD
        path: "{{.path.path}}"
      destination:
        server: https://129.158.33.235:6443
        namespace: argocd
```

**File:** `appsets/prod/tenant-b/workload-appset.yaml`

Same change — update `destination.server` to `https://129.158.33.235:6443`.

### 5d. Remove tenant-b appprojects-app.yaml (avoids collision)

Both tenant-a and tenant-b bootstrap deploy the same `appprojects/prod/` directory, which creates `infrastructure-prod` and `workload-prod` AppProjects. Since both are now on the same cluster, this causes a naming collision.

**Solution:** Remove `bootstrap/prod/tenant-b/appprojects-app.yaml` since tenant-a's bootstrap already creates the shared AppProjects.

### 5e. Update post-start.sh for dual-tenant bootstrap

**File:** `.devcontainer/scripts/post-start.sh`

Add logic to also bootstrap tenant-b when running on tenant-a:

```bash
if [[ $ENVIRONMENT == "prod" ]]; then
    echo "Bootstrapping prod environment for tenant: ${TENANT:-tenant-a}" | tee -a ~/.status.log
    kubectl apply -f bootstrap/prod/${TENANT:-tenant-a}/appprojects-app.yaml -n argocd | tee -a  ~/.status.log
    sleep 2
    kubectl apply -f bootstrap/prod/${TENANT:-tenant-a}/root-app.yaml -n argocd | tee -a  ~/.status.log

    # If tenant-a, also bootstrap tenant-b
    if [[ "${TENANT:-tenant-a}" == "tenant-a" ]]; then
        echo "Also bootstrapping tenant-b from tenant-a" | tee -a ~/.status.log
        kubectl apply -f bootstrap/prod/tenant-b/root-app.yaml -n argocd | tee -a ~/.status.log
    fi
else
    kubectl apply -f bootstrap/dev/appprojects-app.yaml -n argocd | tee -a  ~/.status.log
    sleep 2
    kubectl apply -f bootstrap/dev/root-app.yaml -n argocd | tee -a  ~/.status.log
fi
```

## Step 6: Apply changes

### Bootstrap from tenant-a cluster

```bash
# Existing (tenant-a)
kubectl apply -f bootstrap/prod/tenant-a/appprojects-app.yaml -n argocd
kubectl apply -f bootstrap/prod/tenant-a/root-app.yaml -n argocd

# New (tenant-b) — only root-app, no appprojects-app
kubectl apply -f bootstrap/prod/tenant-b/root-app.yaml -n argocd
```

## Verification

1. **Cluster registered:** `argocd cluster list` should show both clusters
2. **Applications exist:** `kubectl get apps -n argocd | grep tenant-b`
3. **Correct destinations:**
   ```bash
   kubectl get apps -n argocd -o json | \
     jq '.items[] | select(.metadata.name | contains("tenant-b")) | .spec.destination'
   ```
4. **Pods on tenant-b nodes:**
   ```bash
   KUBECONFIG=~/.kube/tenant-b-config kubectl get pods -A
   ```

## Token Refresh

The service account token created via Secret is long-lived but does not auto-rotate. When it expires:

1. Delete and recreate the token Secret on tenant-b (step 2)
2. Extract the new token (step 3)
3. Re-seal and update the SealedSecret in Git (step 4)
4. ArgoCD will pick up the updated secret automatically

## Files Changed

| File | Action |
|------|--------|
| `apps/infrastructure/argocd-config/overlays/prod/cluster-tenant-b-secret.yaml` | **Create** — SealedSecret for cluster registration |
| `appprojects/prod/infrastructure.yaml` | **Edit** — Add tenant-b server to destinations |
| `appprojects/prod/workloads.yaml` | **Edit** — Add tenant-b server to destinations |
| `appsets/prod/tenant-b/infrastructure-appset.yaml` | **Edit** — Change `destination.server` to tenant-b URL |
| `appsets/prod/tenant-b/workload-appset.yaml` | **Edit** — Change `destination.server` to tenant-b URL |
| `bootstrap/prod/tenant-b/appprojects-app.yaml` | **Delete** — Avoid AppProject naming collision |
| `.devcontainer/scripts/post-start.sh` | **Edit** — Add tenant-b bootstrap when running on tenant-a |
