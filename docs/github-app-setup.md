# GitHub App Authentication for ArgoCD

## Overview

This setup enables ArgoCD to authenticate with private GitHub repositories using GitHub Apps in a GitOps-managed way.

## File Structure

```
argocd/
├── secrets/
│   └── github-app-secret.yaml    # GitHub App credentials
├── config/
│   └── argocd-cm.yaml             # ArgoCD configuration
bootstrap/
└── argocd-config.yaml             # Application to manage argocd/ via GitOps
```

## GitHub App Creation Steps

### 1. Create the GitHub App

- Go to GitHub Settings → Developer settings → GitHub Apps → New GitHub App
- Fill in:
  - **App name**: `argocd`
  - **Homepage URL**: `https://<your-argocd-domain>`
  - **Webhook URL**: Leave blank (not needed for Git auth)
  - **Uncheck** "Active" under Webhooks
- Under **Repository permissions**, grant `Read-only` access to:
  - Contents
  - Metadata
- Click "Create GitHub App"
- Save the **App ID** shown on the app page

### 2. Generate and Save Private Key

- In your GitHub App settings, scroll to "Private keys"
- Click "Generate a private key"
- A `.pem` file will download
- Save it securely

### 3. Install App on Your Organization

- Go to the GitHub App's "Install app" tab
- Select your organization
- Choose "Only select repositories"
- Select `microservice-template` and other private repos ArgoCD needs
- Click "Install"
- From the installation URL, note the **Installation ID**
  - Format: `https://github.com/organizations/YOUR_ORG/settings/installations/INSTALLATION_ID`

## Configuration

### Update Secret

Edit `argocd/secrets/github-app-secret.yaml`:

1. Replace `REPLACE_WITH_APP_ID` with your App ID
2. Replace `REPLACE_WITH_INSTALLATION_ID` with your Installation ID
3. Replace `REPLACE_WITH_PRIVATE_KEY_CONTENT` with the contents of your `.pem` file (keep the BEGIN/END lines)

### Update ConfigMap

Edit `argocd/config/argocd-cm.yaml`:

1. Change `https://argocd.example.com` to your actual ArgoCD URL

## Deployment

### Option 1: Via GitOps (Recommended)

1. Commit the files to your repository
2. ArgoCD will sync the `argocd-config` Application automatically
3. The Secret and ConfigMap will be deployed to the `argocd` namespace

### Option 2: Manual Apply

```bash
kubectl apply -f argocd/secrets/github-app-secret.yaml
kubectl apply -f argocd/config/argocd-cm.yaml
```

## Usage in ApplicationSet

The `appsets/dev/microservice-appset.yaml` references the secret:

```yaml
auth:
  ssh:
    privateKeySecret:
      name: github-app-creds
      key: privateKey
```

This allows ArgoCD to authenticate to private repositories listed in your ApplicationSet.

## Security Considerations

⚠️ **Warning**: The private key in the Secret is sensitive data.

### Recommended Approaches:

1. **Sealed Secrets**: Encrypt secrets using Sealed Secrets (see `docs/sealed-secrets.md`)
2. **External Secrets Operator**: Sync from AWS Secrets Manager, HashiCorp Vault, etc.
3. **SOPS**: Encrypt with SOPS before committing to Git
4. **Manual Secret Management**: Create the Secret outside of Git

For production environments, **do not store unencrypted private keys in Git**.
