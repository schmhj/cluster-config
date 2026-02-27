# Docker Registry Credentials (GHCR) with Sealed Secrets

This guide documents how to manage private container registry credentials (GitHub Container Registry) via GitOps using sealed secrets for secure encryption.

## Overview

When deploying applications that pull images from private registries (like GitHub Container Registry), you need image pull secrets. This guide shows how to:

1. Generate docker registry credentials
2. Create a secret YAML file
3. Encrypt it using Sealed Secrets
4. Store the sealed secret safely in Git
5. Reference the secret in your Helm values

## Prerequisites

- `kubeseal` CLI installed (see [Sealed Secrets Setup](./sealed-secrets.md))
- Sealed Secrets controller running in the cluster (`kube-system` namespace)
- Public cert from the sealed-secrets controller for encryption

## Step 1: Create Docker Config JSON

First, create a docker config file with your GitHub credentials:

```bash
cat > ~/.docker/config-ghcr.json << 'EOF'
{
  "auths": {
    "ghcr.io": {
      "username": "YOUR_GITHUB_USERNAME",
      "password": "YOUR_GITHUB_PAT_WITH_READ_PACKAGES_SCOPE",
      "auth": "BASE64_ENCODED_USERNAME:PASSWORD"
    }
  }
}
EOF
```

### Getting the Credentials

1. **GitHub Username**: Your GitHub username (e.g., `schmhj`)

2. **Personal Access Token (PAT)**:
   - Go to GitHub Settings → Developer settings → Personal access tokens → Tokens (classic)
   - Click "Generate new token"
   - Select scopes: `read:packages`
   - Copy the token

3. **Auth Field** (base64 encoded username:password):

```bash
echo -n "YOUR_GITHUB_USERNAME:YOUR_GITHUB_PAT" | base64
```

Example:
```bash
echo -n "schmhj:ghp_xxxxxxxxxxxxxxxxxxxx" | base64
# Output: c2NoaWpiYWo6Z2hwX3h4eHg=
```

### Example Config

```json
{
  "auths": {
    "ghcr.io": {
      "username": "schmhj",
      "password": "ghp_xxxxxxxxxxxxxxxxxxxx",
      "auth": "c2NoaWpiYWo6Z2hwX3h4eHg="
    }
  }
}
```

## Step 2: Create Kubernetes Secret (Unencrypted)

Create an unencrypted secret YAML file using `kubectl`:

```bash
kubectl create secret docker-registry ghcr-auth-secret \
  --docker-server=ghcr.io \
  --docker-username=YOUR_GITHUB_USERNAME \
  --docker-password=YOUR_GITHUB_PAT \
  --docker-email=your-email@example.com \
  --dry-run=client \
  -o yaml > /tmp/ghcr-auth-secret.yaml
```

This generates:
```yaml
apiVersion: v1
kind: Secret
metadata:
  creationTimestamp: null
  name: ghcr-auth-secret
type: kubernetes.io/dockerconfigjson
data:
  .dockerconfigjson: eyJhdXRoc...
```

**Or manually create it:**

```bash
cat > /tmp/ghcr-auth-secret.yaml << 'EOF'
apiVersion: v1
kind: Secret
metadata:
  name: ghcr-auth-secret
  namespace: dev-microservice-app
type: kubernetes.io/dockerconfigjson
data:
  .dockerconfigjson: <BASE64_ENCODED_DOCKER_CONFIG>
EOF
```

Where `<BASE64_ENCODED_DOCKER_CONFIG>` is:
```bash
cat ~/.docker/config-ghcr.json | base64 -w 0
```

## Step 3: Seal the Secret

Fetch and cache the public cert from the sealed-secrets controller:

```bash
kubeseal \
  --controller-name=sealed-secrets \
  --controller-namespace=kube-system \
  --fetch-cert > ~/.sealed-secrets/sealed-secrets-cert.pem
```

Create the sealed secret:

```bash
cat /tmp/ghcr-auth-secret.yaml | kubeseal \
  --controller-name=sealed-secrets \
  --controller-namespace=kube-system \
  --format yaml \
  --cert ~/.sealed-secrets/sealed-secrets-cert.pem \
  > argocd/secrets/ghcr-auth-secret.yaml
```

The output should be a `SealedSecret` resource (not a regular Secret):

```yaml
apiVersion: bitnami.com/v1alpha1
kind: SealedSecret
metadata:
  name: ghcr-auth-secret
  namespace: dev-microservice-app
spec:
  encryptedData:
    .dockerconfigjson: AgBj+Xk3F8p...
  template:
    metadata:
      name: ghcr-auth-secret
      namespace: dev-microservice-app
    type: kubernetes.io/dockerconfigjson
```

## Step 4: Update kustomization.yaml

Add the sealed secret to your `argocd/kustomization.yaml`:

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

resources:
  - config/argocd-cm.yaml
  - secrets/github-app-secret.yaml
  - secrets/ghcr-auth-secret.yaml
```

## Step 5: Store in Git

```bash
git add argocd/secrets/ghcr-auth-secret.yaml
git add argocd/kustomization.yaml
git commit -m "Add sealed GHCR credentials"
git push
```

The sealed secret YAML is safe to commit to Git. Only the cluster with the matching sealing key can decrypt and use it.

## Step 6: Reference in Helm Values

Update your application values to use the image pull secret:

### For microservice-app

**`apps/microservice-app/values/envs/dev/values.yaml`:**

```yaml
imagePullSecrets:
  - name: ghcr-auth-secret

image:
  repository: ghcr.io/schmhj/microservice-template
  pullPolicy: IfNotPresent
  tag: "v0.0.6"
```

### For sample-app

**`apps/sample-app/values/envs/dev/values.yaml`:**

```yaml
imagePullSecrets:
  - name: ghcr-auth-secret

image:
  repository: ghcr.io/schmhj/sample-app
  pullPolicy: IfNotPresent
  tag: "latest"
```

## Step 7: Deploy via GitOps

Commit all changes:

```bash
git add apps/*/values/envs/dev/values.yaml
git commit -m "Add GHCR image pull secret references"
git push
```

Sync ArgoCD to deploy the sealed secret:

```bash
argocd app sync argocd-config
```

This will:
1. Apply the `SealedSecret` to the cluster
2. The sealed-secrets controller automatically decrypts it
3. Creates a regular `Secret` with the decrypted credentials

Restart your applications to pick up the new credentials:

```bash
kubectl rollout restart deployment/microservice-app -n dev-microservice-app
kubectl rollout restart deployment/sample-app -n dev-sample-app
```

## Verification

### 1. Check Secret Exists

```bash
kubectl get secret ghcr-auth-secret -n dev-microservice-app
```

### 2. Verify Decryption

The sealed-secrets controller should have automatically decrypted it:

```bash
kubectl get secret ghcr-auth-secret -n dev-microservice-app -o yaml
```

You should see the decrypted `.dockerconfigjson` data (base64 encoded).

### 3. Check Pod Events

```bash
kubectl get pods -n dev-microservice-app
kubectl describe pod <pod-name> -n dev-microservice-app
```

Look for:
- ✅ `Pulling image "ghcr.io/..."`
- ✅ `Successfully pulled image`
- ❌ NO `ImagePullBackOff` errors

### 4. Check Pod Logs

```bash
kubectl logs <pod-name> -n dev-microservice-app
```

## Troubleshooting

### Error: "failed to fetch certificate"

The sealed-secrets controller is not running or the namespace is wrong.

**Fix:**
```bash
kubectl get pods -n kube-system | grep sealed-secrets
kubectl logs -n kube-system -l app.kubernetes.io/name=sealed-secrets
```

### Error: "cannot decode secret" / "no key could decrypt"

The sealing key doesn't match the cluster's key. This happens when:
- The codespace restarted and generated a new sealing key
- You're using a different cluster

**Fix:**
- Restore the old sealing key (see [Sealed Secrets](./sealed-secrets.md))
- Or re-seal with the new cluster's cert

### Pods still have ImagePullBackOff

**Check:**
1. Secret exists:
   ```bash
   kubectl get secret ghcr-auth-secret -n dev-microservice-app
   ```

2. Pod spec references it:
   ```bash
   kubectl get pod <pod-name> -n dev-microservice-app -o yaml | grep -A 5 imagePullSecrets
   ```

3. Credentials are correct:
   ```bash
   # Decode and verify the .dockerconfigjson
   kubectl get secret ghcr-auth-secret -n dev-microservice-app -o jsonpath='{.data.\.dockerconfigjson}' | base64 -d | jq
   ```

4. Image repository is accessible:
   ```bash
   docker login ghcr.io -u YOUR_USERNAME -p YOUR_PAT
   docker pull ghcr.io/schmhj/microservice-template:v0.0.6
   ```

## Security Benefits

- **Encrypted in Git**: Sealed secrets are encrypted with the cluster's public key and safe to commit
- **Automatic Decryption**: The sealed-secrets controller decrypts at runtime in the cluster
- **Per-Cluster Keys**: Each cluster has its own sealing key - secrets sealed for one cluster won't decrypt on another
- **Immutable**: Once sealed, secrets can't be modified without re-sealing
- **No External Dependencies**: Encryption/decryption happens entirely within the cluster

## Rotation

To rotate/update credentials:

1. Generate new credentials:
   ```bash
   kubectl create secret docker-registry ghcr-auth-secret \
     --docker-server=ghcr.io \
     --docker-username=NEW_USERNAME \
     --docker-password=NEW_PAT \
     --docker-email=your-email@example.com \
     --dry-run=client -o yaml > /tmp/ghcr-auth-secret.yaml
   ```

2. Re-seal:
   ```bash
   cat /tmp/ghcr-auth-secret.yaml | kubeseal \
     --controller-name=sealed-secrets \
     --controller-namespace=kube-system \
     --format yaml \
     --cert ~/.sealed-secrets/sealed-secrets-cert.pem \
     > argocd/secrets/ghcr-auth-secret.yaml
   ```

3. Commit and sync:
   ```bash
   git add argocd/secrets/ghcr-auth-secret.yaml
   git commit -m "Update GHCR credentials"
   git push
   argocd app sync argocd-config
   ```

4. Restart deployments:
   ```bash
   kubectl rollout restart deployment/microservice-app -n dev-microservice-app
   kubectl rollout restart deployment/sample-app -n dev-sample-app
   ```

## Related Documentation

- [Sealed Secrets Setup](./sealed-secrets.md) - Core sealed-secrets configuration
- [GitHub App Setup](./github-app-setup.md) - Sealing GitHub App credentials
- [Kubernetes Docker Registry Secrets](https://kubernetes.io/docs/tasks/configure-pod-container/pull-image-private-registry/)
