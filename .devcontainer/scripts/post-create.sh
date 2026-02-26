#!/bin/bash

echo "post-create start" >> ~/.status.log

# Install Git LFS
sudo apt-get update && sudo apt-get install -y git-lfs | tee -a ~/.status.log

# Set up Sealed Secrets keys. Keys are stored in GitHub secrets and passed as environment variables to the container. We need to write them to files for Sealed Secrets to use.
mkdir -p ~/.secrets
echo "$SEALED_SECRETS_PRIVATE_KEY" > ~/.secrets/sealed-secrets.key
echo "$SEALED_SECRETS_CERT" > ~/.secrets/sealed-secrets.crt
echo "$ARGOCD_GITOPS_AUTH_BOT_KEY" > ~/.secrets/gitops-secret.key
chmod 600 ~/.secrets/sealed-secrets.key

# Install the K3D cluster for Argo CD
k3d cluster create --config .devcontainer/manifests/k3d-dev.yaml --wait | tee -a ~/.status.log

# Install the managed K3D cluster
k3d cluster create --api-port=$(hostname -I | awk '{print $1}'):6550 --config .devcontainer/manifests/k3d-managed.yaml --wait | tee -a ~/.status.log

# Make sure we're on the right context
kubectx k3d-dev | tee -a ~/.status.log

# Create secret using sealed-secrets keys
kubectl create secret tls sealed-secrets-key \
  --cert=$HOME/.secrets/sealed-secrets.crt \
  --key=$HOME/.secrets/sealed-secrets.key \
  -n kube-system

# Install Argo CD using Helm
helm repo add argo https://argoproj.github.io/argo-helm | tee -a  ~/.status.log 
helm repo update | tee -a  ~/.status.log 
helm install argocd argo/argo-cd --version 7.8.26 --namespace argocd --create-namespace --set server.service.type="NodePort" --set server.service.nodePortHttps=30179 --set configs.cm."kustomize\.buildOptions"="--enable-helm" --set configs.cm."application\.sync\.impersonation\.enabled"="true" | tee -a  ~/.status.log 

# Install Sealed Secrets
helm repo add sealed-secrets https://bitnami-labs.github.io/sealed-secrets | tee -a ~/.status.log
helm install sealed-secrets sealed-secrets/sealed-secrets --namespace kube-system --set existingSecret=$HOME/.secrets/sealed-secrets.key | tee -a ~/.status.log

# Install kubeseal
curl -OL "https://github.com/bitnami-labs/sealed-secrets/releases/download/v0.34.0/kubeseal-0.34.0-linux-amd64.tar.gz" | tee -a ~/.status.log
tar -xvzf kubeseal-0.34.0-linux-amd64.tar.gz kubeseal  | tee -a ~/.status.log
sudo install -m 755 kubeseal /usr/local/bin/kubeseal  | tee -a ~/.status.log

rm kubeseal-0.34.0-linux-amd64.tar.gz
rm kubeseal

echo "post-create complete" >> ~/.status.log
