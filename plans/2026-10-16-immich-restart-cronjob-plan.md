# Immich Daily Restart CronJob Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a CronJob that gracefully rolling-restarts all Immich deployments in prod tenant-b daily at 12:01 AM US Eastern, with least-privilege RBAC.

**Architecture:** Two new raw manifests in `apps/workloads/immich/overlays/prod/tenant-b/` (RBAC + CronJob), registered in that directory's `kustomization.yaml`. The tenant-b workload appset's existing `ref: kustomize` source deploys them with the `immich-prod-tenant-b` Application — no appset changes. The CronJob runs `bitnami/kubectl` to `rollout restart` deployments selected by label `app.kubernetes.io/instance=immich-prod-tenant-b`, then waits via `rollout status`.

**Tech Stack:** Kubernetes batch/v1 CronJob, rbac.authorization.k8s.io/v1, Kustomize, ArgoCD sync-waves.

**Spec:** `plans/2026-10-16-immich-restart-cronjob-design.md` (approved).

## Global Constraints

- Namespace for all resources: `workloads`
- Sync-wave annotation on every resource: `argocd.argoproj.io/sync-wave: "5"`
- CronJob schedule: `"1 0 * * *"` with `timeZone: America/New_York`
- Restart target selector: `app.kubernetes.io/instance=immich-prod-tenant-b`
- kubectl image: `docker.io/bitnami/kubectl:1.37` (cluster runs 1.37; do not use `:latest`)
- Security context: `allowPrivilegeEscalation: false`, `capabilities.drop: ["ALL"]`
- Every new file added to `apps/workloads/immich/overlays/prod/tenant-b/kustomization.yaml` `resources:`
- Commit messages: conventional-commit style (`feat(immich): ...`, `docs(immich): ...`)

---

### Task 1: RBAC for the restart CronJob

**Files:**
- Create: `apps/workloads/immich/overlays/prod/tenant-b/immich-restart-rbac.yaml`

**Interfaces:**
- Produces: ServiceAccount `immich-restart` (ns `workloads`) — referenced as `serviceAccountName` by the CronJob in Task 2. Role `immich-restart`: `get`/`list`/`watch`/`patch` on `apps/deployments`, `get`/`list`/`watch` on `pods`. RoleBinding `immich-restart` binds the SA to the Role.

- [ ] **Step 1: Create the RBAC manifest**

Create `apps/workloads/immich/overlays/prod/tenant-b/immich-restart-rbac.yaml`:

```yaml
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: immich-restart
  namespace: workloads
  annotations:
    argocd.argoproj.io/sync-wave: "5"
---
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: immich-restart
  namespace: workloads
  annotations:
    argocd.argoproj.io/sync-wave: "5"
rules:
  - apiGroups: ["apps"]
    resources: ["deployments"]
    verbs: ["get", "list", "watch", "patch"]
  - apiGroups: [""]
    resources: ["pods"]
    verbs: ["get", "list", "watch"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: immich-restart
  namespace: workloads
  annotations:
    argocd.argoproj.io/sync-wave: "5"
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: Role
  name: immich-restart
subjects:
  - kind: ServiceAccount
    name: immich-restart
    namespace: workloads
```

- [ ] **Step 2: Syntax-check the manifest**

Run:
```bash
kubectl apply --dry-run=client -f apps/workloads/immich/overlays/prod/tenant-b/immich-restart-rbac.yaml
```
Expected: four lines of `... configured (dry run)` / `... created (dry run)` for ServiceAccount, Role, RoleBinding — no errors. (client dry-run; no cluster needed)

- [ ] **Step 3: Commit**

```bash
git add apps/workloads/immich/overlays/prod/tenant-b/immich-restart-rbac.yaml
git commit -m "feat(immich): add least-privilege RBAC for restart cronjob"
```

---

### Task 2: Restart CronJob + kustomization registration

**Files:**
- Create: `apps/workloads/immich/overlays/prod/tenant-b/immich-restart-cronjob.yaml`
- Modify: `apps/workloads/immich/overlays/prod/tenant-b/kustomization.yaml`

**Interfaces:**
- Consumes: ServiceAccount `immich-restart` from Task 1 (`serviceAccountName`)
- Produces: CronJob `immich-restart` (ns `workloads`), scheduled `1 0 * * *` `America/New_York`, restarting all deployments labeled `app.kubernetes.io/instance=immich-prod-tenant-b`

- [ ] **Step 1: Create the CronJob manifest**

Create `apps/workloads/immich/overlays/prod/tenant-b/immich-restart-cronjob.yaml`:

```yaml
---
apiVersion: batch/v1
kind: CronJob
metadata:
  name: immich-restart
  namespace: workloads
  annotations:
    argocd.argoproj.io/sync-wave: "5"
spec:
  schedule: "1 0 * * *"
  timeZone: America/New_York
  concurrencyPolicy: Forbid
  successfulJobsHistoryLimit: 3
  failedJobsHistoryLimit: 3
  jobTemplate:
    spec:
      backoffLimit: 2
      activeDeadlineSeconds: 300
      template:
        metadata:
          labels:
            app.kubernetes.io/name: immich-restart
        spec:
          restartPolicy: OnFailure
          serviceAccountName: immich-restart
          containers:
            - name: restart
              image: docker.io/bitnami/kubectl:1.37
              imagePullPolicy: IfNotPresent
              command: ["/bin/sh", "-c"]
              args:
                - |
                  set -eu
                  kubectl rollout restart deployment -n workloads \
                    -l app.kubernetes.io/instance=immich-prod-tenant-b
                  kubectl rollout status deployment -n workloads \
                    -l app.kubernetes.io/instance=immich-prod-tenant-b --timeout=240s
              resources:
                requests:
                  cpu: 10m
                  memory: 32Mi
                limits:
                  cpu: 100m
                  memory: 128Mi
              securityContext:
                allowPrivilegeEscalation: false
                capabilities:
                  drop: ["ALL"]
```

- [ ] **Step 2: Register both new files in the kustomization**

Modify `apps/workloads/immich/overlays/prod/tenant-b/kustomization.yaml` to:

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - immich-pvc.yaml
  - immich-restart-rbac.yaml
  - immich-restart-cronjob.yaml
```

- [ ] **Step 3: Verify kustomize renders all resources**

Run:
```bash
kubectl kustomize apps/workloads/immich/overlays/prod/tenant-b | grep -E '^kind:|^  name:'
```
Expected: includes `PersistentVolumeClaim/immich-data`, `ServiceAccount/immich-restart`, `Role/immich-restart`, `RoleBinding/immich-restart`, `CronJob/immich-restart` — no kustomize errors.

- [ ] **Step 4: Sanity-check rendered CronJob fields**

Run:
```bash
kubectl kustomize apps/workloads/immich/overlays/prod/tenant-b | grep -A2 'timeZone\|serviceAccountName\|schedule:'
```
Expected: `schedule: 1 0 * * *`, `timeZone: America/New_York`, `serviceAccountName: immich-restart`.

- [ ] **Step 5: Commit**

```bash
git add apps/workloads/immich/overlays/prod/tenant-b/
git commit -m "feat(immich): add daily restart cronjob (12:01 AM ET)"
```

---

### Task 3: Post-sync live verification (cluster)

**Files:** none created; verifies Tasks 1–2 after ArgoCD syncs `main`.

**Interfaces:**
- Consumes: CronJob + RBAC from Tasks 1–2
- Produces: confirmation that the manual test Job completes and Immich pods restart

- [ ] **Step 1: Confirm ArgoCD synced the resources**

Run:
```bash
kubectl -n workloads get cronjob immich-restart sa immich-restart role immich-restart rolebinding immich-restart
```
Expected: all four resources exist; CronJob schedule shows `1m past 0 * * *` (or similar for America/New_York).

- [ ] **Step 2: Verify RBAC grants**

Run:
```bash
kubectl auth can-i patch deployments -n workloads --as=system:serviceaccount:workloads:immich-restart
kubectl auth can-i list pods -n workloads --as=system:serviceaccount:workloads:immich-restart
```
Expected: `yes` twice.

- [ ] **Step 3: Trigger a manual run**

Run:
```bash
kubectl -n workloads create job --from=cronjob/immich-restart immich-restart-manual-test
kubectl -n workloads get jobs immich-restart-manual-test -w
```
Expected: job reaches `COMPLETIONS: 1/1` within ~5 minutes; pod logs (`kubectl -n workloads logs job/immich-restart-manual-test`) show `deployment.apps/immich-prod-tenant-b-... restarted` for each component, then rollout status lines with no errors.

- [ ] **Step 4: Confirm Immich pods cycled and are healthy**

Run:
```bash
kubectl -n workloads get pods -l app.kubernetes.io/instance=immich-prod-tenant-b
```
Expected: all component pods `Running`/`Ready` with recent restart timestamps (AGE in the last few minutes).

- [ ] **Step 5: Clean up the manual test Job and note the result**

```bash
kubectl -n workloads delete job immich-restart-manual-test
```

If any step fails (e.g. `bitnami/kubectl:1.37` pull error — Bitnami moved free images to the `bitnamilegacy` org in 2025; retry with `docker.io/bitnamilegacy/kubectl:1.37` as an image change in the CronJob manifest), fix via a follow-up commit on `main` and re-sync before proceeding.
