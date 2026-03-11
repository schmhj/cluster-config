#!/bin/bash

echo "post-create start" >> ~/.status.log

SECRETS_DIR="$HOME/.secrets"
SECRETS_PUB_KEY="${SECRETS_DIR}/sealed-secrets.pub"
SECRETS_PRIV_KEY="${SECRETS_DIR}/sealed-secrets"
SECRETS_GITOPS_AUTH_KEY="${SECRETS_DIR}/gitops-secret.key"


# Install Git LFS
sudo apt-get update && sudo apt-get install -y git-lfs | tee -a ~/.status.log

# Set up Sealed Secrets keys. Keys are stored in GitHub secrets and passed as environment variables to the container. We need to write them to files for Sealed Secrets to use.
mkdir -p $SECRETS_DIR
echo "$SEALED_SECRETS_PRIVATE_KEY" > "$SECRETS_PRIV_KEY"
echo "$SEALED_SECRETS_CERT" > "$SECRETS_PUB_KEY"
echo "$ARGOCD_GITOPS_AUTH_BOT_KEY" > "$SECRETS_GITOPS_AUTH_KEY"
chmod 600 "$SECRETS_DIR/$SECRETS_PRIV_KEY"

# Install the K3D cluster for Argo CD
k3d cluster create --config .devcontainer/manifests/k3d-dev.yaml --wait | tee -a ~/.status.log

# Install the managed K3D cluster
k3d cluster create --api-port=$(hostname -I | awk '{print $1}'):6550 --config .devcontainer/manifests/k3d-managed.yaml --wait | tee -a ~/.status.log

# Make sure we're on the right context
kubectx k3d-dev | tee -a ~/.status.log

# Create secret using sealed-secrets keys
kubectl create secret tls sealed-secrets-key \
  --cert="$SECRETS_PUB_KEY" \
  --key="$SECRETS_PRIV_KEY" \
  -n kube-system \
  --dry-run=client -o yaml > /tmp/custom-sealed-secret-key.yaml

kubectl apply -f /tmp/custom-sealed-secret-key.yaml | tee -a ~/.status.log

# Install Argo CD using Helm
helm repo add argo https://argoproj.github.io/argo-helm | tee -a  ~/.status.log 
helm repo update | tee -a  ~/.status.log 
helm install argocd argo/argo-cd --version 7.8.26 --namespace argocd --create-namespace --set server.service.type="NodePort" --set server.service.nodePortHttps=30179 --set configs.cm."kustomize\.buildOptions"="--enable-helm" --set configs.cm."application\.sync\.impersonation\.enabled"="true" | tee -a  ~/.status.log 

# Install Sealed Secrets
# helm repo add sealed-secrets https://bitnami-labs.github.io/sealed-secrets | tee -a ~/.status.log
# helm install sealed-secrets sealed-secrets/sealed-secrets --namespace kube-system --set existingSecret="$SECRETS_PRIV_KEY" | tee -a ~/.status.log

# Install emberstack to reflect secrets across namespaces
# helm repo add emberstack https://emberstack.github.io/helm-charts
# helm repo update
# helm install reflector emberstack/reflector --namespace kube-system

# Install kubeseal
curl -OL "https://github.com/bitnami-labs/sealed-secrets/releases/download/v0.34.0/kubeseal-0.34.0-linux-amd64.tar.gz" | tee -a ~/.status.log
tar -xvzf kubeseal-0.34.0-linux-amd64.tar.gz kubeseal  | tee -a ~/.status.log
sudo install -m 755 kubeseal /usr/local/bin/kubeseal  | tee -a ~/.status.log

rm kubeseal-0.34.0-linux-amd64.tar.gz
rm kubeseal

rm /tmp/custom-sealed-secret-key.yaml

echo "post-create complete" >> ~/.status.log
