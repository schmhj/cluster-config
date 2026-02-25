# SSH Key Authentication for ArgoCD

This guide explains how to set up SSH key authentication for ArgoCD to access private GitHub repositories in a GitOps-managed way.

## File Structure

```
argocd/
├── secrets/
│   └── github-app-secret.yaml    # SSH private key (renamed from github-app-secret.yaml)
├── config/
│   └── argocd-cm.yaml             # ArgoCD configuration
bootstrap/
└── argocd-config.yaml             # Application to manage argocd/ via GitOps
```

## Setup Steps

### 1. Generate SSH Key Pair

Generate a new SSH key for ArgoCD:

```bash
ssh-keygen -t ed25519 -f ~/.ssh/argocd-github -N "" -C "argocd@example.com"
```

This creates:
- `~/.ssh/argocd-github` (private key)
- `~/.ssh/argocd-github.pub` (public key)

### 2. Add Public Key as GitHub Deploy Key

1. Go to your private repository on GitHub (e.g., `microservice-template`)
2. Navigate to Settings → Deploy keys → Add deploy key
3. Paste the contents of `~/.ssh/argocd-github.pub`
4. Title: `argocd-deploy-key` (or any descriptive name)
5. Check "Allow write access" only if ArgoCD needs to push (usually not needed for pull-only)
6. Click "Add key"

Repeat for each private repository ArgoCD needs to access.

### 3. Update Secret with Private Key

Edit `argocd/secrets/github-app-secret.yaml` and replace `REPLACE_WITH_YOUR_SSH_PRIVATE_KEY` with the full contents of your private key file:

```bash
cat ~/.ssh/argocd-github
```

Copy the entire output (including BEGIN/END lines) and paste it into the secret, maintaining proper indentation.

Example:
```yaml
apiVersion: v1
kind: Secret
metadata:
  name: github-ssh-key
  namespace: argocd
type: Opaque
stringData:
  ssh-privatekey: |
    -----BEGIN OPENSSH PRIVATE KEY-----
    REPLACE_WITH_YOUR_SSH_PRIVATE_KEY
    -----END OPENSSH PRIVATE KEY-----
```

### 4. Deploy Configuration

#### Option 1: Via GitOps (Recommended)

1. Commit and push changes to your repository:
   ```bash
   git add argocd/ bootstrap/
   git commit -m "Add SSH authentication for private repositories"
   git push
   ```

2. ArgoCD will sync the `argocd-config` Application automatically
3. The Secret and ConfigMap will be deployed to the `argocd` namespace

#### Option 2: Manual Apply

```bash
kubectl apply -f argocd/secrets/github-app-secret.yaml
kubectl apply -f argocd/config/argocd-cm.yaml
```

## Usage in ApplicationSet

The ApplicationSet in `appsets/dev/microservice-appset.yaml` uses SSH authentication for private Git repositories:

```yaml
auth:
  ssh:
    privateKeySecret:
      name: github-ssh-key
      key: ssh-privatekey
```

This enables ArgoCD to authenticate to repositories like `https://github.com/schmhj/microservice-template.git` when marked with `"isGitRepo": true` in their `config.json`.

## Repository URLs

Ensure your repository URLs in `config.json` use SSH format if using git@:

```json
{
  "appName": "microservice-app",
  "chartRepo": "git@github.com:schmhj/microservice-template.git",
  "chartPath": "helm/microservice",
  "chartVersion": "HEAD",
  "isGitRepo": true
}
```

Or HTTPS format (ArgoCD handles both):
```json
{
  "chartRepo": "https://github.com/schmhj/microservice-template.git",
  ...
}
```

## Security Considerations

⚠️ **Warning**: The SSH private key in the Secret is sensitive data.

### Recommended Approaches for Production:

1. **Sealed Secrets**: Encrypt the secret using Sealed Secrets before committing to Git
   - See `docs/sealed-secrets.md` for instructions

2. **External Secrets Operator**: Sync from a vault
   - AWS Secrets Manager
   - HashiCorp Vault
   - Azure Key Vault

3. **SOPS (Secrets Operations)**: Encrypt secrets with SOPS before committing

4. **Manual Secret Management**: Create the Secret outside of Git and do not track it in version control

**Best Practice**: For production, do NOT store unencrypted private keys in Git repositories.

## Troubleshooting

### ArgoCD cannot access repository

1. Verify the SSH key is correctly added to GitHub:
   ```bash
   ssh -T git@github.com
   ```

2. Check ArgoCD logs:
   ```bash
   kubectl logs -n argocd deployment/argocd-application-controller
   ```

3. Verify the secret exists:
   ```bash
   kubectl get secret github-ssh-key -n argocd -o yaml
   ```

4. Test with a simple Git repo Application:
   ```yaml
   apiVersion: argoproj.io/v1alpha1
   kind: Application
   metadata:
     name: test-ssh
     namespace: argocd
   spec:
     project: default
     source:
       repoURL: git@github.com:schmhj/microservice-template.git
       path: .
       targetRevision: HEAD
     destination:
       server: https://kubernetes.default.svc
       namespace: default
   ```
