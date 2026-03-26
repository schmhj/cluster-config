# Grafana admin credentials. These are used to secure access to the Grafana dashboard, which provides insights into the cluster's performance and health. The credentials are stored as secrets in Kubernetes and sealed using kubeseal for secure storage in Git.
kubectl create secret generic grafana-admin-secret \
  --namespace=monitoring \
  --from-literal=admin-user='admin' \
  --from-literal=admin-password='***' \
  --dry-run=client -o yaml | \
  kubeseal --controller-namespace kube-system \
  --format yaml --cert ~/.secrets/sealed-secrets.pub > apps/infrastructure/infra-secrets/base/grafana-secret.yaml

# Grafana Cloud credentials. These are used to authenticate with Grafana Cloud services, such as Prometheus, Loki, and Tempo. The credentials are stored as secrets in Kubernetes and sealed using kubeseal for secure storage in Git.
kubectl create secret generic grafana-cloud-credentials \
  --namespace=infrastructure \
  --from-literal=prometheus-url='https://prometheus-prod-13-prod-us-east-0.grafana.net/api/prom/push' \
  --from-literal=prometheus-username='1147486' \
  --from-literal=loki-url='https://logs-prod-006.grafana.net/loki/api/v1/push' \
  --from-literal=loki-username='672823' \
  --from-literal=tempo-url='https://tempo-prod-04-prod-us-east-0.grafana.net/tempo' \
  --from-literal=tempo-username='669326' \
  --from-literal=password='***' \
  --dry-run=client -o yaml | \
  kubeseal --controller-namespace kube-system \
  --format yaml --cert ~/.secrets/sealed-secrets.pub > apps/infrastructure/infra-secrets/base/grafana-cloud-secret.yaml

# Traefik dashboard credentials. These are used to secure access to the Traefik dashboard, which provides insights into the traffic flowing through the cluster. The credentials are stored as secrets in Kubernetes and sealed using kubeseal for secure storage in Git.
kubectl create secret generic traefik-dashboard-secret \
  --namespace=infrastructure \
  --from-literal=users=`echo $(htpasswd -nbs admin ***)` \
  --dry-run=client -o yaml | \
  kubeseal --controller-namespace kube-system \
  --format yaml --cert ~/.secrets/sealed-secrets.pub > apps/infrastructure/infra-secrets/overlays/dev/traefik-secret.yaml

# Cert Manager account keys for Let's Encrypt. These are used by cert-manager to create and manage TLS certificates for the cluster. The keys are stored as secrets in Kubernetes and sealed using kubeseal for secure storage in Git.
kubectl create secret generic traefik-dashboard-secret \
  --namespace=infrastructure \
  --from-literal=letsencrypt-prod-account-key=`echo $(htpasswd -nbs ***)` \
  --from-literal=letsencrypt-staging-account-key=`echo $(htpasswd -nbs ***)` \
  --dry-run=client -o yaml | \
  kubeseal --controller-namespace kube-system \
  --format yaml --cert ~/.secrets/sealed-secrets.pub > apps/infrastructure/infra-secrets/overlays/dev/cert-manager-secret.yaml