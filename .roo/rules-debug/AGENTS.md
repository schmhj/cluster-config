# Debug Rules (Non-Obvious Only)

- **Dev environment uses k3d clusters** created by [`post-create.sh`](.devcontainer/scripts/post-create.sh:32) — there are two clusters: `k3d-dev` (for the GitOps apps) and `k3d-managed` (for additional targets). Always verify you're on the right context with `kubectx`.
- **ArgoCD login credentials** are set via [`post-start.sh`](.devcontainer/scripts/post-start.sh:30) — the admin password is reset to `password` after initial setup. Log in with `argocd login --insecure --username admin --password password --grpc-web localhost:30179`.
- **Sealed secrets keys** live in `~/.secrets/` — `sealed-secrets.pub` (cert) and `sealed-secrets` (private key). The [`post-create.sh`](.devcontainer/scripts/post-create.sh:18) writes them from devcontainer secrets env vars.
- **Status logs** are written to `~/.status.log` by the devcontainer setup scripts — check this file when the devcontainer doesn't come up properly.
- **Production `selfHeal: false`** (see `bootstrap/prod/us-ashburn-1/root-app.yaml` / `bootstrap/prod/us-chicago-1/root-app.yaml`) means ArgoCD won't auto-correct drift in prod — you must manually sync or trigger a refresh.
- When [`create-secrets.sh`](scripts/create-secrets.sh) fails, verify the sealed-secrets controller is running in `kube-system` and `~/.secrets/sealed-secrets.pub` exists.
- **Sync waves are critical**: If sealed-secrets (wave 2) isn't healthy, infra-secrets (wave 3) will sit in `Progressing` indefinitely because the SealedSecret resources can't be decrypted.