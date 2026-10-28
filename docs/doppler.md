# Doppler + External Secrets Operator (ESO) Migration

Reference for migrating an app's credentials from SealedSecrets to Doppler via External Secrets Operator. The `paperless` pilot (dev on `develop`, prod tenant-a on `main`) proved this pattern — migrate the remaining apps one at a time using the checklist below.

## Architecture

- **One Doppler project per app** (`<app>`, e.g. `paperless`) with two **configs**: `dev` and `prod`. Secret values live only in the Doppler dashboard — never in this repo.
- **ESO** is deployed by [`apps/infrastructure/external-secrets/`](../apps/infrastructure/external-secrets/) — Helm chart `external-secrets` `2.14.0` from `https://charts.external-secrets.io`, namespace `external-secrets`, sync-wave `2` via the infra appset template special-case (`sealed-secrets` → 2, `external-secrets` → 2, `infra-secrets` → 3, else 4).
- **Per-app manifests** in the workload overlay (namespace `workloads`), live-verified names for the pilot:

  | Manifest | Example (paperless) | Purpose |
  |----------|---------------------|---------|
  | SealedSecret (token) | `doppler-paperless-token` (key `dopplerToken`) | Bootstrap only: holds the Doppler service token; the only SealedSecret left after an app migrates |
  | SecretStore | `doppler-paperless` | Tells ESO how to reach Doppler (via the token) |
  | ExternalSecret + target Secret | `paperless-credentials` | Pulls values from Doppler into a native Kubernetes Secret |

- Flow: SealedSecret decrypts to `doppler-<app>-token` → SecretStore reads the token → ExternalSecret syncs → target Secret created with `creationPolicy: Owner`.
- Unmigrated apps keep getting credentials from `apps/infrastructure/infra-secrets` SealedSecrets (wave 3), mirrored into `workloads` by Reflector.

### Key mapping rule

Each entry under `ExternalSecret.spec.data` maps one key:

- `data[].secretKey` — the key in the **target Kubernetes Secret** (keep the exact key name the app already reads; unchanged from the old SealedSecret).
- `data[].remoteRef.key` — the key in **Doppler** (`UPPER_SNAKE_CASE` as stored in the dashboard).

Do not rename k8s keys during migration — only the source changes.

## Per-app rollout checklist

### (a) Create/seed the Doppler project + config

In the Doppler dashboard: create project `<app>`, configs `dev` and `prod`, and seed both with the app's current values (copy from the existing SealedSecret / running Secret). **Never commit these values anywhere in this repo.**

### (b) Generate a service token

Generate a service token scoped to the project + config (one token per project+config binding). Constraints learned in the pilot:

- **The token must be a single line.** A token file with a trailing second line corrupts the value → Doppler 401.
- The token is bound to **one** project+config, so the SecretStore carries **no** `project`/`config` fields — they would be wrong for the other config anyway (dev and prod each get their own token/SecretStore in their own overlay).
- Keep the raw token out of git (e.g. `/tmp/doppler-<app>-token.txt`, chmod 600). Placeholder form: `dp.st.…`.

### (c) Seal the token with the cert for **that** cluster

Sealing certs differ per environment:

- **Codespace**: `~/.secrets/sealed-secrets.pub` matches the **dev k3d** cluster.
- **Local Mac**: `~/.secrets/sealed-secrets.pub` may not match **any** cluster — verify with `kubeseal --fetch-cert` before sealing (see note at the end).
- **Prod**: fetch the cluster's cert first. The controller service is named `sealed-secrets`, **not** the kubeseal default `sealed-secrets-controller`:

```bash
kubeseal --fetch-cert --controller-namespace kube-system --controller-name sealed-secrets \
  --context <prod-ctx> > sealed-secrets-prod.pub
```

Seal (example: dev overlay; swap `--cert` and output path for prod):

```bash
kubectl create secret generic doppler-paperless-token \
  --namespace workloads --dry-run=client \
  --from-literal=dopplerToken="$(tr -d '\n' < /tmp/doppler-paperless-token.txt)" \
  -o yaml | \
kubeseal --controller-name=sealed-secrets --controller-namespace=kube-system \
  --cert ~/.secrets/sealed-secrets.pub --format yaml \
  > apps/workloads/paperless/overlays/dev/doppler-token-sealedsecret.yaml
```

The `tr -d '\n'` guarantees a single-line value.

### (d) Add the three manifests

Full YAML as shipped for the pilot (dev overlay; the prod tenant overlay is identical apart from living in `apps/workloads/<app>/overlays/prod/<tenant>/`):

`doppler-<app>-token-sealedsecret.yaml` (output of step c):

```yaml
apiVersion: bitnami.com/v1alpha1
kind: SealedSecret
metadata:
  name: doppler-paperless-token
  namespace: workloads
spec:
  encryptedData:
    dopplerToken: AgA...kubeseal-output...
  template:
    metadata:
      name: doppler-paperless-token
      namespace: workloads
```

`doppler-secretstore.yaml`:

```yaml
apiVersion: external-secrets.io/v1
kind: SecretStore
metadata:
  name: doppler-paperless
  namespace: workloads
spec:
  provider:
    doppler:
      auth:
        secretRef:
          dopplerToken:
            name: doppler-paperless-token   # the SealedSecret-generated Secret
            key: dopplerToken
```

`<app>-externalsecret.yaml`:

```yaml
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: paperless-credentials
  namespace: workloads
spec:
  secretStoreRef:
    kind: SecretStore
    name: doppler-paperless
  target:
    name: paperless-credentials
    creationPolicy: Owner
  data:
    # secretKey = key in the target Kubernetes Secret (keep existing k8s key name unchanged)
    # remoteRef.key = key in Doppler (UPPER_SNAKE_CASE as stored in the dashboard)
    - secretKey: admin-username
      remoteRef:
        key: ADMIN_USERNAME
    - secretKey: admin-password
      remoteRef:
        key: ADMIN_PASSWORD
```

List all three in the overlay's `kustomization.yaml` (keeping any pre-existing resources such as the dev nodeport):

```yaml
resources:
  - doppler-token-sealedsecret.yaml
  - doppler-secretstore.yaml
  - paperless-externalsecret.yaml
```

**Prod tenant overlay caveat:** a workload prod overlay only renders if the tenant workload appset has the third (kustomize) source — `tenant-a` now has it (mirrors `tenant-b`). The tenant dir needs a `kustomization.yaml` listing the extra manifests once they exist; a tenant dir holding only `values.yaml` still works (ArgoCD tolerates kustomize dirs without `kustomization.yaml`).

### (e) Remove the corresponding SealedSecret from infra-secrets

Delete `apps/infrastructure/infra-secrets/overlays/{dev,prod}/<app>-sealedsecret.yaml` **and** its entry in that overlay's `kustomization.yaml`.

- For **per-app** secrets: remove it (step d replaces it).
- For **shared** secrets (multiple consuming namespaces): keep the SealedSecret and add a consuming-namespace ExternalSecret instead — see the shared-secret topology below.

**Wave ordering / expected brief gap:** infra-secrets (wave 3) prunes the old SealedSecret → Reflector removes the mirror → workload app (wave 5) creates the ES-owned Secret. A short window with no Secret is expected; pods self-heal via kubelet backoff. If ESO fails with an ownership conflict because the old Secret lingers, delete the leftover Secret after the SealedSecret is gone (see Troubleshooting).

### (f) Verify the kustomize build

```bash
kustomize build apps/workloads/paperless/overlays/dev > /dev/null
kustomize build apps/infrastructure/infra-secrets/overlays/dev > /dev/null
# prod:
kustomize build apps/workloads/paperless/overlays/prod/tenant-a > /dev/null
kustomize build apps/infrastructure/infra-secrets/overlays/prod > /dev/null
kustomize build apps/infrastructure/infra-secrets/overlays/prod-tenant/tenant-a > /dev/null
```

Both must build clean; the infra-secrets build must no longer contain the removed SealedSecret.

### (g) Commit + push

One commit per app, pushed to the branch ArgoCD tracks for that environment (`develop` for dev, `main` for prod). Never stage token files or any plaintext values.

### (h) Verify in-cluster

```bash
# conditions — expect Ready/Valid on the store and SecretSynced on the ExternalSecret
kubectl -n workloads get secretstore doppler-paperless
kubectl -n workloads get externalsecret paperless-credentials
kubectl -n workloads get secretstore doppler-paperless -o jsonpath='{.status.conditions[*].type}{" "}{.status.conditions[*].status}{"\n"}'
kubectl -n workloads get externalsecret paperless-credentials -o jsonpath='{.status.conditions[*].reason}{"\n"}'

# value diff — compare key sets only; do not print values
kubectl -n workloads get secret paperless-credentials -o jsonpath='{.data}' | jq -r 'keys[]'

# app health
kubectl -n argocd get applications.argoproj.io | grep <app>

# regression — infra-secrets still healthy, old SealedSecret gone, mirror restored
kustomize build apps/infrastructure/infra-secrets/overlays/dev > /dev/null
kubectl -n infrastructure get sealedsecrets
kubectl -n workloads get secrets | grep <app>
```

Also spot-check the app actually starts (pod Ready) since the Secret name/keys must be unchanged.

## Shared-secret fallback topology

For secrets consumed from more than one namespace (dockerconfig, grafana-cloud, …):

```
Doppler (project <app>)
  → ExternalSecret in namespace `infrastructure` (+ SecretStore/token there)
    → Secret created in `infrastructure`
      → Reflector mirrors it to the namespaces listed in
        reflection-allowed-namespaces
```

- Keep the Secret's name and keys identical to today's mirrored SealedSecret so consumers don't change.
- Carry the Reflector annotations on the ES-created Secret via `spec.target.template.metadata.annotations` (`reflector.v1.k8s.emberstack.com/reflection-allowed` + `reflection-allowed-namespaces`), matching what `infra-secrets` sets today via its kustomize patch.
- The SealedSecret in `infrastructure` can then be removed as above; Reflector itself stays.

## Rollout order for remaining apps

Migrate one app per commit, in this order:

1. **immich**
2. **newrelic**
3. **tailscale**
4. **traefik**
5. **grafana-cloud**
6. **cert-manager**
7. **dockerconfig**
8. **postgresql** (hybrid — some consumers still read the mirrored Secret)
9. **argocd-config LAST** — ArgoCD repo credentials chicken-egg: a gap there can lock ArgoCD out of this repo before it can sync the replacement. Migrate it only after the pattern is proven everywhere else, keeping the SealedSecret in place until the ES-owned Secret is confirmed live.

## Troubleshooting

**`InvalidProviderConfig` / Doppler 401** — token problems: the token value is corrupted (most often a **multi-line token file** with a trailing newline), the token was revoked, or the SealedSecret was sealed with a cert from the wrong cluster (controller can't unseal → token Secret missing/garbage). Fix: re-read the token as a single line (`tr -d '\n'`), reseal with the correct cert, resync.

**`SecretSyncedError`** on the ExternalSecret — usually a key mapping or scope problem: `remoteRef.key` doesn't match the exact Doppler `UPPER_SNAKE_CASE` key, or the token is scoped to a different project/config. Fix the mapping or regenerate a token for the right project+config.

**SecretStore/ExternalSecret stuck not-Ready after a token fix** — ESO may take a while to re-reconcile on its own. Force an immediate reconcile with an annotation bump, then remove the annotation afterward:

```bash
kubectl -n workloads annotate secretstore doppler-paperless \
  reconcile.external-secrets.io/reconcile-trigger=$(date +%s) --overwrite
# after it goes Ready, remove it:
kubectl -n workloads annotate secretstore doppler-paperless \
  reconcile.external-secrets.io/reconcile-trigger-
```

(The same annotation works on `externalsecret/<name>`.)

**Ownership conflict creating the target Secret** — the old SealedSecret's Secret is still present when the ExternalSecret runs with `creationPolicy: Owner`. The wave ordering (infra-secrets wave 3 prune → workload app wave 5) normally prevents this; if it happens, ensure the SealedSecret is gone, then `kubectl -n workloads delete secret <name>` — ESO recreates it on the next sync.

**Token Secret missing or wrong key** — the SealedSecret name/key must match `spec.provider.doppler.auth.secretRef` exactly: name `doppler-<app>-token`, key `dopplerToken`.

## What stays / what's next

- The **SealedSecrets controller** and **Reflector** remain installed until **all** apps have migrated (bootstrap tokens, shared secrets, and unmigrated apps still depend on them). Do not remove `sealed-secrets` or `reflector` from the infra appset in the meantime.
- **OIDC** authentication for the Doppler SecretStore is a planned follow-up for prod, to replace long-lived service tokens.

## Note: sealing certs on the local Mac

On the local Mac, `~/.secrets/sealed-secrets.pub` may not match **any** cluster — always verify before sealing:

```bash
kubeseal --fetch-cert --controller-namespace kube-system --controller-name sealed-secrets \
  --context <ctx> > /tmp/sealed-secrets-<env>.pub
```

and seal with `--cert /tmp/sealed-secrets-<env>.pub`. A SealedSecret sealed with a mismatched cert simply never decrypts (the controller can't unseal it) and the target Secret never appears.
