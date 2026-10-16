# Design: Daily Immich restart CronJob (prod tenant-b)

Date: 2026-10-16
Status: Approved

## Goal

Gracefully rolling-restart all Immich components (`server`, `microservices`,
`machine-learning`, `valkey`) every day at 12:01 AM US Eastern via a GitOps
CronJob, to clear accumulated in-process state without manual intervention.

## Decisions

- **Mechanism**: CronJob in ns `workloads` running `docker.io/alpine/k8s:1.37.1`
  (kubectl 1.37.1 + shell; `bitnami/kubectl` and `bitnamilegacy/kubectl:1.37`
  tags no longer exist as of 2026-10), issuing `kubectl rollout restart` against
  the four Immich deployments, then waiting with `rollout status`.
- **Targeting**: label selector
  `app.kubernetes.io/instance=immich-prod-tenant-b` (bjw-s chart convention —
  one Deployment per component, all carrying the release instance label)
  instead of hardcoded deployment names, so chart-added components are covered
  automatically.
- **Restart style**: graceful rolling restart (`rollout restart`), not pod
  deletion — user-requested near-zero downtime.
- **Schedule**: `1 0 * * *` with `timeZone: America/New_York` (cluster runs
  1.37; `timeZone` requires 1.27+). User wants midnight local time, not UTC.
- **RBAC (least privilege)**: dedicated ServiceAccount `immich-restart` in ns
  `workloads`, Role granting `get`/`list`/`watch`/`patch` on `deployments` and
  `get`/`list`/`watch` on `pods` (for `rollout status`), plus a RoleBinding.
  Rejected reusing cluster-admin `argocd-manager` — over-privileged for a
  scheduled patch job.
- **Placement**: no node pinning — the CronJob only talks to the API server,
  unlike Immich pods it needs no `tier=workload` nodeSelector.
- **Pattern source**: follows `apps/workloads/postgresql/overlays/prod/tenant-b/paperless-db-job.yaml`
  (the repo's only CronJob precedent): sync-wave "5", `concurrencyPolicy:
  Forbid`, history limits 3/3, `backoffLimit: 2`, `activeDeadlineSeconds: 300`,
  minimal resources, `securityContext` drop-all.

## Manifests

All new, in `apps/workloads/immich/overlays/prod/tenant-b/`, listed in that
dir's `kustomization.yaml` (the tenant-b workload appset's kustomize source
picks them up automatically — no appset change):

1. `immich-restart-cronjob.yaml` — CronJob `immich-restart`:
   - command:
     ```
     kubectl rollout restart deployment -n workloads \
       -l app.kubernetes.io/instance=immich-prod-tenant-b
     kubectl rollout status deployment -n workloads \
       -l app.kubernetes.io/instance=immich-prod-tenant-b --timeout=240s
     ```
   - `set -eu` shell wrapper; pod template label
     `app.kubernetes.io/name: immich-restart`; resource annotations
     `argocd.argoproj.io/sync-wave: "5"`.
2. `immich-restart-rbac.yaml` — ServiceAccount `immich-restart`, Role
   `immich-restart`, RoleBinding; same sync-wave.

## Failure handling

- If any rollout exceeds the 240s status timeout (within the 300s
  `activeDeadlineSeconds`), the Job fails; `backoffLimit: 2` retries once.
- Failures are visible in Job history and via Grafana Alloy label-based log
  discovery in ns `workloads` (no Alloy changes needed).
- `concurrencyPolicy: Forbid` prevents overlapping restarts if a run hangs.

## Verification

- `kubectl kustomize apps/workloads/immich/overlays/prod/tenant-b` renders all
  four resources.
- After ArgoCD sync: `kubectl -n workloads create job --from=cronjob/immich-restart
  manual-test` triggers an immediate run; `kubectl -n workloads get pods -l
  app.kubernetes.io/instance=immich-prod-tenant-b -w` shows pods cycling and
  `rollout status` succeeding.
- Confirm `kubectl auth can-i patch deployments -n workloads
  --as=system:serviceaccount:workloads:immich-restart` returns `yes`.
