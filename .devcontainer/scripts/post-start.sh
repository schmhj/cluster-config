#!/bin/bash

source .devcontainer/scripts/config.sh

echo "Starting $ENVIRONMENT environment" >> ~/.status.log
echo "post-start start" >>  ~/.status.log 

# this runs in background each time the container starts

# Ensure kubeconfig is set up. 
k3d kubeconfig merge dev --kubeconfig-merge-default | tee -a ~/.status.log 

# Publish the public paperless URL (PAPERLESS_URL) before any app is synced.
# The ConfigMap is intentionally NOT in git: the value is codespace-specific and
# Argo CD would revert it on every self-heal. paperless dev values read it via
# valueFrom (optional: true), so the pod still starts if this step is skipped.
if [[ $ENVIRONMENT != "prod" ]]; then
    if [[ -n "${CODESPACE_NAME:-}" ]]; then
        PAPERLESS_URL_VALUE="https://${CODESPACE_NAME}-32080.app.github.dev"
    else
        PAPERLESS_URL_VALUE="http://localhost:32080"
    fi
    # The workloads namespace is normally created by Argo CD (wave 2); create it
    # idempotently first so the ConfigMap can exist before the first sync.
    kubectl create namespace workloads --dry-run=client -o yaml | kubectl apply -f - | tee -a ~/.status.log
    kubectl create configmap paperless-codespace \
        --from-literal=url="${PAPERLESS_URL_VALUE}" \
        -n workloads --dry-run=client -o yaml | kubectl apply -f - | tee -a ~/.status.log
fi

# Wit for Argo CD to be ready
kubectl rollout status -n argocd sts/argocd-application-controller | tee -a  ~/.status.log

# Wait for the port to be ready
counter=0
until [[ $(curl -s -o /dev/null -w "%{http_code}" localhost:30179) -eq 307 ]]
do
    echo "Waiting for Argo CD endpoint to be ready..." | tee -a  ~/.status.log
    sleep 3
    counter=$((counter+1))
    if [[ $counter -gt 60 ]]; then
        echo "Port not available for Argo CD CLI" | tee -a  ~/.status.log
        exit 1
    fi
done

# Update Argo CD Admin Password
argopass=$(kubectl get secret argocd-initial-admin-secret -n argocd -o jsonpath='{.data.password}' | base64 -d)
argouri="localhost:30179"
argonewpass="password"
argocd login --insecure --username ${argouser:=admin} --password ${argopass} --grpc-web ${argouri} | tee -a  ~/.status.log 
argocd account --insecure update-password --insecure --current-password ${argopass} --new-password ${argonewpass} | tee -a  ~/.status.log 

# Patch URL value. 
kubectl patch cm/argocd-cm -n argocd --type=json  -p="[{\"op\": \"replace\", \"path\": \"/data/url\", \"value\":\"https://${CODESPACE_NAME}-30179.app.github.dev\"}]" | tee -a  ~/.status.log

# Update Argo CD to use cluster-admin service account for sync operations in the "default" project
kubectl apply -f .devcontainer/manifests/argocd-configupdate.yaml | tee -a  ~/.status.log

# Bootstrap apps

if [[ $ENVIRONMENT == "prod" ]]; then
    echo "Bootstrapping prod environment for tenant: ${TENANT:-tenant-a}" | tee -a ~/.status.log
    kubectl apply -f bootstrap/prod/${TENANT:-tenant-a}/appprojects-app.yaml -n argocd | tee -a  ~/.status.log
    sleep 2
    kubectl apply -f bootstrap/prod/${TENANT:-tenant-a}/root-app.yaml -n argocd | tee -a  ~/.status.log

    # If running on tenant-a, also bootstrap tenant-b
    if [[ "${TENANT:-tenant-a}" == "tenant-a" ]]; then
        echo "Also bootstrapping tenant-b from tenant-a" | tee -a ~/.status.log
        kubectl apply -f bootstrap/prod/tenant-b/root-app.yaml -n argocd | tee -a  ~/.status.log
    fi
else
    kubectl apply -f bootstrap/dev/appprojects-app.yaml -n argocd | tee -a  ~/.status.log
    sleep 2
    kubectl apply -f bootstrap/dev/root-app.yaml -n argocd | tee -a  ~/.status.log
fi

# Best effort env load
source ~/.bashrc

echo "post-start complete" >>  ~/.status.log 