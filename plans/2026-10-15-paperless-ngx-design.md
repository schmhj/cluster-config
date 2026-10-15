# Design: paperless-ngx in prod tenant-a (cross-cluster PostgreSQL)

Date: 2026-10-15
Status: Approved

## Goal

Deploy paperless-ngx as a GitOps workload in the `workloads` namespace of prod
tenant-a, using the existing tenant-b PostgreSQL over Tailscale and storage on
the `nfs-paperless` StorageClass. Tenant-a is chosen because its 16 GB
`workload-0` node leaves headroom for a future paperless-ai/paperless-gpt local
LLM.

## Architecture

```
tenant-a (local hub, 16 GB node workload-0)      tenant-b (remote)
ns workloads:                                    ns workloads:
  paperless-prod-tenant-a  ──egress proxy:5432──▶  postgresql-tailscale (tailscale.com/expose)
   chart: paperless-ngx 0.4.0                        ▶ postgresql-prod-tenant-b (existing)
   PVC: paperless-data (nfs-paperless, 20Gi)      db: paperless (new, owner paperless)
  IngressRoute: paperless.newyeti.qzz.io          CronJob: idempotent DB provisioning (@daily)
  bundled Valkey broker (small oci-bv PVC)
```

Traffic path (first cross-cluster consumer in this repo): paperless pod →
tenant-a egress ProxyGroup pod (`egress-proxies`, already deployed) →
WireGuard tailnet → tenant-b ingress proxy (`ts-postgresql-tailscale`, exposed
via `tailscale.com/expose`) → ClusterIP → postgres pods. Mirrors the working
`garage-s3` egress pattern.

## Decisions

- **Tenant**: prod tenant-a only (16 GB node; dev has no nfs-paperless SC).
- **Chart**: CodeOpsMS community chart `paperless-ngx` 0.4.0
  (`oci://ghcr.io/codeopsms/helm-charts`), paperless-ngx 3.1.3, digest-pinned,
  arm64-capable, k8s floor 1.34 (cluster runs 1.37). No official chart exists.
- **Database**: existing bitnami postgres release in tenant-b (shared with
  Immich). New role+db `paperless` provisioned by an idempotent CronJob
  (self-healing, no StatefulSet restart, no Immich outage). Cadence `@daily`.
- **Credentials**: dedicated `paperless` role. New key
  `postgresql-paperless-password` added to the existing SealedSecret
  `postgresql-secret` (user-sealed); reflector mirrors it into ns `workloads`
  on both tenants. Admin password used only by the CronJob to run DDL.
- **Deterministic tailnet name**: re-add `tailscale.com/hostname:
  postgresql-tenant-b` to the tenant-b expose Service so the tenant-a egress
  Service can reference `postgresql-tenant-b.<tailnet>.ts.net` via
  `tailscale.com/tailnet-fqdn`.
- **Storage**: chart-created PVC `paperless-data`, StorageClass `nfs-paperless`
  (subDir `paperless` on the Mac Mini export), 20Gi, retain on uninstall.
  Bundled Valkey uses its default small PVC on oci-bv.
  **As-built deviation**: the export is NFSv3-only (no file locking — the
  server refuses NFSv4 mounts), so the paperless DATA_DIR cannot live on it
  (`s6-setlock` on `migration_lock` fails with "No locks available"). The
  chart hardcodes the storage mount at `/usr/src/paperless/data` and the API
  server rejects duplicate mountPaths, so the data dir is an emptyDir
  mounted at `/paperless-data` with `PAPERLESS_DATA_DIR` pointing at it
  (media/consume/export stay on NFS; the search index rebuilds from the DB
  if the emptyDir is lost). Chart-managed Secret env changes are rolled out
  via `config.secretRevision`.
- **Service-link env guard**: Kubernetes injects
  `PAPERLESS_PORT=tcp://<svc>:80` for the chart's own `paperless` Service,
  which the granian webserver rejects; `GRANIAN_PORT: "8000"` is pinned in
  values (the webserver script prefers it over `PAPERLESS_PORT`).
- **Exposure**: IngressRoute in the tenant-a traefik overlay (repo idiom),
  cross-ns service `paperless.workloads:80`, existing wildcard TLS secret
  `newyeti-tls-cert` in ns traefik. Chart ingress disabled. Manual DNS record
  `paperless.newyeti.qzz.io` → tenant-a Traefik LB.
- **Scheduling**: immich pattern — required `tier=workload`, preferred
  `workload=workload-0`, tolerate `tier=workload:NoSchedule`. Resources:
  requests 500m/750Mi, limits 2/2Gi, reserving LLM headroom.
- **No appset changes**: tenant-a workload appset already globs
  `overlays/prod/tenant-a`; values-only tenant dir (tailscale-operator
  precedent). The missing kustomize source in the tenant-a appset is not
  needed because all extra manifests live in infra/postgresql apps.

## Components & files

| Change | File |
|---|---|
| SealedSecret +3 key (done by user) | `apps/infrastructure/infra-secrets/overlays/prod/postgresql-sealedsecret.yaml` |
| Script typo fix + key documented | `scripts/create-secrets.sh` |
| Deterministic hostname annotation | `apps/infrastructure/tailscale-connector/overlays/prod-tenant/tenant-b/postgresql-tailscale.yaml` |
| Egress ExternalName Service | `apps/infrastructure/tailscale-connector/overlays/prod-tenant/tenant-a/postgresql-tenant-b-service.yaml` (+ kustomization) |
| Idempotent DB CronJob | `apps/workloads/postgresql/overlays/prod/tenant-b/paperless-db-job.yaml` (+ kustomization) |
| New app | `apps/workloads/paperless/{base,overlays/prod,overlays/prod/tenant-a}/...` |
| IngressRoute | `apps/infrastructure/traefik/overlays/prod-tenant/tenant-a/traefik-ingress-routes.yaml` |

## Rollout order & verification

1. Push sealed secret → verify key reflected into ns `workloads` both tenants.
2. Hostname annotation + egress Service (infra wave 4) → verify `pg_isready`
   through the proxy from a tenant-a debug pod; tailnet ACL check (manual,
   Tailscale admin, if blocked).
3. CronJob (syncs with postgresql app) → kick one manual run → verify
   `paperless` database/role exist in tenant-b.
4. Paperless app dir → appset creates `paperless-prod-tenant-a` (wave 5) →
   pod on `10.1.1.56`, PVC bound to nfs-paperless, migrations green.
5. IngressRoute + user DNS record + `manage.py createsuperuser` (manual).
6. End-to-end: upload document, processing works, files on NFS, node still has
   ≥13 Gi free for the future LLM.

## Risks / accepted trade-offs

- Paperless availability now depends on tenant-b DB over the tailnet (chosen
  explicitly; tailnet already carries Garage S3 + NFS).
- Cross-cluster DB latency — acceptable for document-management traffic.
- Community chart, not officially endorsed — mitigated by digest pinning and
  values schema.
- NFS write permission quirks (mapall squash) — fsGroup applied if the write
  test requires it.

## Out of scope (follow-ups)

- Fixing the latent `primary.image`/`initdb` mis-indentation bug in
  `apps/workloads/postgresql` values (chart ignores both today).
- grafana-alloy log collection for tenant-a workloads.
- `PAPERLESS_SECRET_KEY` as a sealed secret (chart-managed upgrade-stable key
  used for now).
- Backups of the paperless NFS data.
