You should now be able to create sealed secrets.

1. Install the client-side tool (kubeseal) as explained in the docs below:
```
    ********/bitnami-labs/sealed-secrets#installation-from-source
```

2. Create a sealed secret file running the command below:
```
    kubectl create secret generic secret-name --dry-run=client --from-literal=foo=bar -o [json|yaml] | \
    kubeseal \
      --controller-name=sealed-secrets \
      --controller-namespace=kube-system \
      --format yaml > mysealedsecret.[json|yaml]
```

The file mysealedsecret.[json|yaml] is a commitable file.

If you would rather not need access to the cluster to generate the sealed secret you can run:

```
    kubeseal \
      --controller-name=sealed-secrets \
      --controller-namespace=kube-system \
      --fetch-cert > mycert.pem
```

to retrieve the public cert used for encryption and store it locally. You can then run 'kubeseal --cert mycert.pem' instead to use the local cert e.g.

```
    kubectl create secret generic secret-name --dry-run=client --from-literal=foo=bar -o [json|yaml] | \
    kubeseal \
      --controller-name=sealed-secrets \
      --controller-namespace=kube-system \
      --format [json|yaml] --cert mycert.pem > mysealedsecret.[json|yaml]
```

3. Apply the sealed secret
```
    kubectl create -f mysealedsecret.[json|yaml]
```

Running 'kubectl get secret secret-name -o [json|yaml]' will show the decrypted secret that was generated from the sealed secret.

Both the SealedSecret and generated Secret must have the same name and namespace.

---

## GitOps-Managed Docker Registry Credentials (GHCR)

This section documents how to manage private container registry credentials via GitOps using sealed secrets.

### Overview

When deploying applications that pull images from private registries (like GitHub Container Registry), you need image pull secrets. This guide shows how to:
1. Generate docker registry credentials
2. Create a sealed secret to store them safely in Git
3. Reference the secret in your Helm values

### Prerequisites

- `kubeseal` CLI installed (see installation above)
- Sealed Secrets controller running in the cluster
- Public cert from the sealed-secrets controller

### Step 1: Create Docker Config JSON

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

**To generate the `auth` field:**

```bash
echo -n "YOUR_GITHUB_USERNAME:YOUR_GITHUB_PAT" | base64
```

So your config becomes:
```json
{
  "auths": {
    "ghcr.io": {
      "username": "schmhj",
      "password": "ghp_xxxxxxxxxxxxxxxxxxxx",
      "auth": ""
    }
  }
}
```

### Step 2: Encode Config to Base64

```bash
cat ~/.docker/config-ghcr.json | base64 -w 0 && echo
```

Example output:
```
eyJhdXRocyI6eyJnaGNyLmlvIjp7InVzZXJuYW1lIjoic2NoaWpiYWoiLCJwYXNzd29yZCI6ImdocF94eHh4eHh4eHh4eHh4eHh4eHh4eHgiLCJhdXRoIjoiV1UOVVJfUkhJVEhVQl9VU0VSsk5BTUU6WU9VUl9HSVRIVUJfUEFUIn19fQ==
```

### Step 3: Create Kubernetes Secret (Dry Run)

```bash
apiVersion: v1
kind: Secret
metadata:
  name: ghcr-io-secret
  namespace: dev-microservice-app
type: kubernetes.io/dockerconfigjson
data:
  .dockerconfigjson: <paste-base64-string-here>
```

OR

```bash
kubectl create secret docker-registry ghcr-io-secret \
  --docker-server=ghcr.io \
  --docker-username=YOUR_GITHUB_USERNAME \
  --docker-password=YOUR_GITHUB_PAT \
  --docker-email=your-email@example.com \
  --dry-run=client \
  -o yaml > ghcr-io-secret.yaml
```

This generates an unencrypted secret YAML file.

### Step 4: Seal the Secret

Fetch the public cert (if not already cached):

```bash
kubeseal \
  --controller-name=sealed-secrets \
  --controller-namespace=kube-system \
  --fetch-cert > sealed-secrets-cert.pem
```

Create the sealed secret:

```bash
cat ghcr-io-secret.yaml | kubeseal \
  --controller-name=sealed-secrets \
  --controller-namespace=kube-system \
  --format yaml \
  --cert sealed-secrets-cert.pem > argocd/secrets/ghcr-io-secret-sealed.yaml
```

### Step 5: Store in GitOps

Copy the sealed secret to your repository:

```bash
mv argocd/secrets/ghcr-io-secret-sealed.yaml argocd/secrets/ghcr-io-secret.yaml
git add argocd/secrets/ghcr-io-secret.yaml
git commit -m "Add sealed GHCR credentials"
git push
```

The sealed secret YAML is safe to commit to Git. Only the cluster with the sealing key can decrypt it.

### Step 6: Reference in Helm Values

Update your application values to use the image pull secret:

**`apps/microservice-app/values/envs/dev/values.yaml`:**

```yaml
imagePullSecrets:
  - name: ghcr-io-secret

image:
  repository: ghcr.io/schmhj/microservice-template
  pullPolicy: IfNotPresent
  tag: "v0.0.6"
```

### Step 7: Deploy via ArgoCD

1. Ensure the sealed secret is applied:
   ```bash
   kubectl apply -f argocd/secrets/ghcr-io-secret.yaml
   ```

2. Or sync via ArgoCD (if managed through `argocd-config` Application):
   ```bash
   argocd app sync argocd-config
   ```

3. Restart the application deployment:
   ```bash
   kubectl rollout restart deployment <app-name> -n <namespace>
   ```

### Verification

Verify the secret was created:

```bash
kubectl get secret ghcr-io-secret -n dev-microservice-app -o yaml
```

The secret should be automatically decrypted by the Sealed Secrets controller.

Test that pods can pull images:

```bash
kubectl get pods -n dev-microservice-app
kubectl describe pod <pod-name> -n dev-microservice-app
```

Look for successful image pull events without `ImagePullBackOff` errors.

### Security Benefits

- **Safe in Git**: Sealed secrets are encrypted with the cluster's public key
- **Automatic Decryption**: The Sealed Secrets controller decrypts them at runtime
- **Per-Cluster Secrets**: Each cluster has its own sealing key
- **Immutable**: Once sealed, the secret cannot be modified without re-sealing

### Troubleshooting

**Error: "failed to fetch certificate"**
- Ensure sealed-secrets controller is running: `kubectl get pods -n kube-system | grep sealed-secrets`

**Error: "cannot decode secret"**
- Verify the secret name and namespace match: `Both the SealedSecret and generated Secret must have the same name and namespace`

**Pods still have ImagePullBackOff**
- Check secret exists: `kubectl get secret ghcr-io-secret -n <namespace>`
- Verify pod spec has `imagePullSecrets`
- Check pod events: `kubectl describe pod <pod-name> -n <namespace>`