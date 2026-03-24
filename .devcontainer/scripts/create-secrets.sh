kubectl create secret generic grafana-admin-secret \
  --namespace=monitoring \
  --from-literal=admin-user='admin' \
  --from-literal=admin-password='' \
  --dry-run=client -o yaml | \
  kubeseal --controller-namespace kube-system \
  --format yaml --cert ~/.secrets/sealed-secrets.pub > apps/infrastructure/infra-secrets/base/grafana-secret.yaml

kubectl create secret generic grafana-cloud-credentials \
  --namespace=infrastructure \
  --from-literal=prometheus-url='https://prometheus-prod-13-prod-us-east-0.grafana.net/api/prom/push' \
  --from-literal=prometheus-username='1147486' \
  --from-literal=loki-url='https://logs-prod-006.grafana.net/loki/api/v1/push' \
  --from-literal=loki-username='672823' \
  --from-literal=tempo-url='https://tempo-prod-04-prod-us-east-0.grafana.net/tempo' \
  --from-literal=tempo-username='669326' \
  --from-literal=password=' \
  --dry-run=client -o yaml | \
  kubeseal --controller-namespace kube-system \
  --format yaml --cert ~/.secrets/sealed-secrets.pub > apps/infrastructure/infra-secrets/base/grafana-cloud-secret.yaml