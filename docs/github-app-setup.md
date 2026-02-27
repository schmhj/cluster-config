# GitHub App Authentication for ArgoCD

This guide explains how to set up GitHub App authentication for ArgoCD to access private GitHub repositories using HTTPS in a GitOps-managed way.

## Overview

GitHub App authentication provides:
- ✅ Fine-grained permissions (read-only for repositories)
- ✅ Installation per organization/repository
- ✅ Token-based authentication for HTTPS
- ✅ Easy credential rotation
- ✅ Better audit trails

## File Structure

```
argocd/
├── secrets/
│   └── github-app-secret.yaml    # GitHub App credentials (Secret)
├── config/
│   └── argocd-cm.yaml             # ArgoCD configuration with repository mappings
bootstrap/
└── argocd-config.yaml             # Application to manage argocd/ via GitOps
```

## Step 1: Create a GitHub App

1. Go to **GitHub Organization Settings** → **Developer settings** → **GitHub Apps** → **New GitHub App**

2. Fill in the app details:
   - **App name**: `argocd` (or any name)
   - **Homepage URL**: `https://argocd.your-domain.com` (or your ArgoCD URL)
   - **Webhook URL**: Leave blank (not needed for Git access)
   - **Uncheck** "Active" under Webhooks section

3. Set **Repository permissions** to:
   - ✅ **Contents**: Read-only
   - ✅ **Metadata**: Read-only
   
4. Click **"Create GitHub App"**

5. On the app details page, note your:
   - **App ID** (visible on the app page)
   - **Client ID** (visible on app settings)

## Step 2: Create a Private Key

1. In your GitHub App settings, scroll to **"Private keys"**
2. Click **"Generate a private key"**
3. A `.pem` file will be downloaded automatically
4. Save it securely: `~/.github-app-private-key.pem`

## Step 3: Get the Installation ID

1. Go to **Organization Settings** → **Developer settings** → **GitHub Apps** → **Installed GitHub Apps**
2. Find your `argocd` app
3. The installation URL shows: `https://github.com/organizations/YOUR_ORG/settings/installations/INSTALLATION_ID`
4. Note the `INSTALLATION_ID` from the URL

Or find it via CLI:
```bash
curl -H "Authorization: token YOUR_PAT" https://api.github.com/user/installations
```

## Step 4: Install GitHub App on Your Repositories

1. In the GitHub App settings, go to **"Install app"** tab
2. Click the gear icon next to your organization
3. Select **"Only select repositories"**
4. Choose the repositories ArgoCD needs access to (e.g., `microservice-template`, `sample-app`)
5. Click **"Install"**

## Step 5: Update ArgoCD Secret

Edit [argocd/secrets/github-app-secret.yaml](argocd/secrets/github-app-secret.yaml):

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: ghaap-auth-secret
  namespace: argocd
type: Opaque
stringData:
  appID: "YOUR_APP_ID"
  installationID: "YOUR_INSTALLATION_ID"
  privateKey: |
    -----BEGIN RSA PRIVATE KEY-----
    [Your complete private key content from step 2]
    -----END RSA PRIVATE KEY-----
```

**Example:**
```yaml
apiVersion: v1
kind: Secret
metadata:
  name: ghaap-auth-secret
  namespace: argocd
type: Opaque
stringData:
  appID: "123456"
  installationID: "12345678"
  privateKey: |
    -----BEGIN RSA PRIVATE KEY-----
    MIIEpAIBAAKCAQEA2x3F8p/j0K...
    [rest of the key]
    -----END RSA PRIVATE KEY-----
```

## Step 6: Update ArgoCD ConfigMap

Edit [argocd/config/argocd-cm.yaml](argocd/config/argocd-cm.yaml) to configure repository credentials:

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: argocd-cm-githubapps
  namespace: argocd
data:
  url: https://argocd.default.svc.cluster.local
  application.instanceLabelKey: argocd.argoproj.io/instance
  server.insecure: "false"
  accounts.ghapp: login=ghapp
  account.ghapp.tokens: $ghaap-auth-secret:githubAppID!$ghaap-auth-secret:githubAppInstallationID!$ghaap-auth-secret:githubAppPrivateKey
```

The `password` field references the GitHub App token from the Secret.

## Step 7: Update Repository URLs in config.json

Each app's `config.json` should use **HTTPS** format:

**`apps/microservice-app/values/envs/dev/config.json`:**
```json
{
  "appName": "microservice-app",
  "chartRepo": "https://github.com/schmhj/microservice-template.git",
  "chartPath": "helm/microservice",
  "chartVersion": "HEAD",
  "isGitRepo": true
}
```

**`apps/sample-app/values/envs/dev/config.json`:**
```json
{
  "appName": "sample-app",
  "chartRepo": "https://github.com/schmhj/sample-app.git",
  "chartPath": "helm/sample",
  "chartVersion": "HEAD",
  "isGitRepo": true
}
```

## Step 8: Update ApplicationSet

Ensure [appsets/dev/microservice-appset.yaml](../appsets/dev/microservice-appset.yaml) uses basic auth (not SSH):

```yaml
templatePatch: |
  spec:
    sources:
      - repoURL: '{{ .chartRepo }}'
        targetRevision: '{{ .chartVersion }}'
        {{ if .isGitRepo }}
        path: '{{ .chartPath }}'
        {{ else }}
        chart: '{{ .chartPath }}'
        {{ end }}
        helm:
          valueFiles:
            - $values/apps/{{index .path.segments 1}}/values/common/values.yaml
            - $values/apps/{{index .path.segments 1}}/values/envs/dev/values.yaml
            
      - repoURL: https://github.com/schmhj/cluster-config.git
        targetRevision: HEAD
        ref: values
```

## Step 9: Deploy via GitOps

1. Commit your changes:
```bash
git add argocd/secrets/github-app-secret.yaml
git add argocd/config/argocd-cm.yaml
git add apps/*/values/envs/dev/config.json
git add appsets/dev/microservice-appset.yaml
git commit -m "Add GitHub App authentication for private repositories"
git push
```

2. Sync ArgoCD configs:
```bash
argocd app sync argocd-config
```

3. Restart ArgoCD to pick up the new ConfigMap:
```bash
kubectl rollout restart deployment/argocd-application-controller -n argocd
kubectl rollout restart deployment/argocd-server -n argocd
```

4. Resync your applications:
```bash
argocd app sync dev-microservice-app
argocd app sync dev-sample-app
```

## Verification

Check if the credentials are recognized:

```bash
# Verify the secret exists
kubectl get secret ghaap-auth-secret -n argocd

# Check the ConfigMap
kubectl get cm argocd-cm -n argocd -o yaml

# Watch ArgoCD logs
kubectl logs -n argocd deployment/argocd-application-controller -f
```

Look for successful `git clone` operations without authentication errors.

## Troubleshooting

### Error: "401 Unauthorized"
- GitHub App is not installed on the repository
- **Fix**: Reinstall the app on the repository (Step 3)

### Error: "Repository not found"
- The HTTPS URL is incorrect
- The GitHub App doesn't have access to the repository
- **Fix**: Verify the URL and that the app is installed

### Error: "Authentication failed"
- The credentials are incorrect
- The secret is not being referenced properly
- **Fix**: Verify secret values in [argocd/secrets/github-app-secret.yaml](argocd/secrets/github-app-secret.yaml)

### Pods still have ImagePullBackOff
- Use the image pull secret as documented in `docs/sealed-secrets.md`
- Verify the secret exists in proper namespace

## Security Best Practices

⚠️ **Important**: This implementation stores a plain Secret in Git. For production:

### Option 1: Use Sealed Secrets (Recommended)
Encrypt the secret before committing:
```bash
kubeseal -f argocd/secrets/github-app-secret.yaml -o yaml > argocd/secrets/github-app-secret-sealed.yaml
```
See `docs/sealed-secrets.md` for detailed instructions.

### Option 2: Use External Secrets Operator
Store credentials in AWS Secrets Manager, HashiCorp Vault, or Azure Key Vault.

### Option 3: Use SOPS
Encrypt secrets with SOPS before committing to Git.

### Option 4: Manual Secret Management
Create the secret outside of Git:
```bash
kubectl create secret generic ghaap-auth-secret \
  --from-literal=appID=<APP_ID> \
  --from-literal=installationID=<INSTALLATION_ID> \
  --from-file=privateKey=/path/to/private-key.pem \
  -n argocd
```

Then do NOT commit the secret file to Git.

## Related Documentation

- [Sealed Secrets Setup](./sealed-secrets.md)
- [GitHub App API Docs](https://docs.github.com/en/developers/apps)
- [ArgoCD Repository Configuration](https://argo-cd.readthedocs.io/en/stable/operator-manual/declarative-setup/#repositories)

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
