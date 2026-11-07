# paperless-gpt + Ollama (dev) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Deploy paperless-gpt + Ollama (`qwen2.5:3b`) as GitOps workloads in the dev environment so AI tag/title suggestions can be tested in the codespace against the existing paperless-ngx.

**Architecture:** Two new workload apps discovered by the dev workload appset: `ollama` (otwld community chart, model pulled at startup, PVC for model storage) and `paperless-gpt` (tiny in-repo Helm chart referenced via `isGitRepo: true` — no appset changes). Secrets flow Doppler → ExternalSecret → `paperless-gpt-credentials`. Exposed via NodePort 32081 (Codespaces forward) and a Traefik IngressRoute with basic auth (paperless-gpt has none, and 30480 is public).

**Tech Stack:** ArgoCD ApplicationSet (matrix generator), Helm (otwld/ollama 1.93.0 + in-repo chart), Traefik v3 IngressRoute, Bitnami SealedSecrets + External Secrets Operator (Doppler), k3d.

**Global Constraints:**
- Dev only — no prod overlays, no appset changes
- Appset revision is `develop` — nothing deploys until commits are pushed to `develop`
- Workload apps render via the appset's fixed 3-source template: helm chart source + `$values` ref (base + overlay values.yaml) + kustomize ref (overlay dir) — every app dir needs `config.json`, `kustomization.yaml`, `base/values.yaml`, `overlays/dev/values.yaml`
- RAG/embeddings out of scope; OCR vision model out of scope (tagging only)
- No plaintext secrets in git; SealedSecrets only
- Current local kubectl context is `context-tenant-a` (PROD) — never run `kubectl apply` against it; cluster mutations happen only inside the codespace (`k3d-dev`)
- All Kubernetes manifests use `apiVersion: kustomize.config.k8s.io/v1beta1` for Kustomization files
- Every kustomization gets `argocd.argoproj.io/sync-wave` annotation on the resources it creates (workload wave 5)

---

### Task 1: Design spec

**Files:**
- Create: `plans/2026-10-28-paperless-gpt-ollama-design.md`

**Steps:**
- [ ] Write the approved design: goal, two-app architecture, decisions (qwen2.5:3b, Doppler, SQLite/emptyDir, NodePort 32081 + Traefik, paperless-gpt over clusterzx/paperless-ai because maintained + lighter; RAG/OCR-vision out of scope), components table, test plan. Mirror the structure of `plans/2026-10-15-paperless-ngx-design.md`.
- [ ] Commit: `git add plans/2026-10-28-paperless-gpt-ollama-design.md && git commit -m "docs: paperless-gpt + ollama dev design"`

---

### Task 2: Ollama workload app

**Files:**
- Create: `apps/workloads/ollama/overlays/dev/config.json`
- Create: `apps/workloads/ollama/overlays/dev/kustomization.yaml`
- Create: `apps/workloads/ollama/base/values.yaml`
- Create: `apps/workloads/ollama/overlays/dev/values.yaml`

**Interfaces:**
- Produces: Service `ollama.workloads.svc:11434`, fullnameOverride `ollama` (consumed by paperless-gpt's `OLLAMA_HOST`)

**Steps:**
- [ ] `config.json`:
```json
{
    "appName": "ollama",
    "namespace": "workloads",
    "chartRepo": "https://helm.otwld.com",
    "chartName": "ollama",
    "chartVersion": "1.93.0",
    "isGitRepo": false
}
```
- [ ] `kustomization.yaml`:
```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources: []
```
- [ ] `base/values.yaml`:
```yaml
# Ollama (otwld chart) — shared local LLM server for dev AI apps.

fullnameOverride: ollama

ollama:
  models:
    pull:
      - qwen2.5:3b

persistentVolume:
  enabled: true
  size: 5Gi

resources:
  requests:
    cpu: "1"
    memory: 3Gi
  limits:
    cpu: "4"
    memory: 4Gi
```
- [ ] `overlays/dev/values.yaml` (dev deltas + comments — identical values, documented CPU-only rationale and codespace RAM note).
- [ ] Validate: `helm repo add otwld https://helm.otwld.com && helm repo update && helm template ollama otwld/ollama --version 1.93.0 -f apps/workloads/ollama/base/values.yaml -f apps/workloads/ollama/overlays/dev/values.yaml` → renders Deployment + PVC 5Gi + Service `ollama:11434`; contains `qwen2.5:3b` in the model-pull lifecycle hook. If 1.93.0 doesn't resolve, pick the latest from `helm search repo otwld/ollama --versions` and pin that.
- [ ] Commit: `feat(ollama): add ollama dev workload app (qwen2.5:3b)`

---

### Task 3: paperless-gpt chart skeleton + app wiring

**Files:**
- Create: `apps/workloads/paperless-gpt/chart/Chart.yaml`
- Create: `apps/workloads/paperless-gpt/chart/templates/deployment.yaml`
- Create: `apps/workloads/paperless-gpt/chart/templates/service.yaml`
- Create: `apps/workloads/paperless-gpt/overlays/dev/config.json`
- Create: `apps/workloads/paperless-gpt/overlays/dev/kustomization.yaml`
- Create: `apps/workloads/paperless-gpt/base/values.yaml`
- Create: `apps/workloads/paperless-gpt/overlays/dev/values.yaml`

**Interfaces:**
- Consumes: Service `paperless.workloads.svc:80` (existing), Secret `paperless-gpt-credentials` key `paperless-token` (Task 6), Service `ollama.workloads.svc:11434` (Task 2)
- Produces: Deployment/Service `paperless-gpt` port 8080 (Task 4 NodePort, Task 5 Traefik select it)

**Steps:**
- [ ] `chart/Chart.yaml`:
```yaml
apiVersion: v2
name: paperless-gpt
description: Minimal paperless-gpt chart for dev
type: application
version: 0.1.0
appVersion: "v0.31.0"
```
- [ ] `chart/templates/deployment.yaml`:
```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: {{ .Values.fullnameOverride | default .Release.Name }}
  labels:
    app.kubernetes.io/name: paperless-gpt
    app.kubernetes.io/instance: {{ .Release.Name }}
spec:
  replicas: {{ .Values.replicaCount }}
  selector:
    matchLabels:
      app.kubernetes.io/name: paperless-gpt
      app.kubernetes.io/instance: {{ .Release.Name }}
  template:
    metadata:
      labels:
        app.kubernetes.io/name: paperless-gpt
        app.kubernetes.io/instance: {{ .Release.Name }}
    spec:
      containers:
        - name: paperless-gpt
          image: "{{ .Values.image.repository }}:{{ .Values.image.tag }}"
          imagePullPolicy: {{ .Values.image.pullPolicy }}
          ports:
            - name: http
              containerPort: 8080
              protocol: TCP
          env:
            {{- range $name, $value := .Values.env }}
            - name: {{ $name }}
              value: {{ $value | quote }}
            {{- end }}
            - name: PAPERLESS_API_TOKEN
              valueFrom:
                secretKeyRef:
                  name: {{ .Values.existingSecret.name }}
                  key: {{ .Values.existingSecret.key }}
          volumeMounts:
            - name: app-data
              mountPath: /app/prompts
              subPath: prompts
            - name: app-data
              mountPath: /app/config
              subPath: config
            - name: app-data
              mountPath: /app/db
              subPath: db
          resources:
            {{- toYaml .Values.resources | nindent 12 }}
          readinessProbe:
            httpGet:
              path: /
              port: http
            initialDelaySeconds: 5
            periodSeconds: 10
      volumes:
        - name: app-data
          emptyDir: {}
```
- [ ] `chart/templates/service.yaml`:
```yaml
apiVersion: v1
kind: Service
metadata:
  name: {{ .Values.fullnameOverride | default .Release.Name }}
  labels:
    app.kubernetes.io/name: paperless-gpt
    app.kubernetes.io/instance: {{ .Release.Name }}
spec:
  type: {{ .Values.service.type }}
  ports:
    - name: http
      port: {{ .Values.service.port }}
      targetPort: http
      protocol: TCP
  selector:
    app.kubernetes.io/name: paperless-gpt
    app.kubernetes.io/instance: {{ .Release.Name }}
```
- [ ] `base/values.yaml`:
```yaml
# paperless-gpt (icereed, in-repo minimal chart) — dev.
# Tagging/title suggestions only; OCR-vision and RAG deliberately unconfigured.
# No built-in auth: exposure is NodePort (localhost) + Traefik basic auth.

fullnameOverride: paperless-gpt

image:
  repository: icereed/paperless-gpt
  tag: v0.31.0
  pullPolicy: IfNotPresent

replicaCount: 1

service:
  type: ClusterIP
  port: 8080

existingSecret:
  name: paperless-gpt-credentials
  key: paperless-token

env:
  PAPERLESS_BASE_URL: "http://paperless.workloads.svc.cluster.local"
  LLM_PROVIDER: "ollama"
  LLM_MODEL: "qwen2.5:3b"
  OLLAMA_HOST: "http://ollama.workloads.svc.cluster.local:11434"
  OLLAMA_KEEP_ALIVE: "10m"
  LLM_LANGUAGE: "English"
  TOKEN_LIMIT: "1000"
  SUGGESTION_WORKERS: "1"
  OCR_LIMIT_PAGES: "2"

resources:
  requests:
    cpu: 100m
    memory: 128Mi
  limits:
    cpu: "1"
    memory: 512Mi
```
- [ ] `overlays/dev/values.yaml`: comment block only (documents why env is in base; notes emptyDir = loseable dev state; notes default OCR_PROVIDER=llm stays unconfigured — if the pod fails startup validation for missing vision config, add `VISION_LLM_PROVIDER: ollama` + `VISION_LLM_MODEL: qwen2.5vl:3b` to base env and `qwen2.5vl:3b` to ollama's pull list as the documented fallback).
- [ ] `config.json`:
```json
{
    "appName": "paperless-gpt",
    "namespace": "workloads",
    "chartRepo": "https://github.com/schmhj/cluster-config.git",
    "chartName": "apps/workloads/paperless-gpt/chart",
    "chartVersion": "develop",
    "isGitRepo": true
}
```
- [ ] `kustomization.yaml` (resources filled in Task 4/6; start empty):
```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources: []
```
- [ ] Validate: `helm template paperless-gpt apps/workloads/paperless-gpt/chart -f apps/workloads/paperless-gpt/base/values.yaml -f apps/workloads/paperless-gpt/overlays/dev/values.yaml` → Deployment with the env block, secretKeyRef `paperless-gpt-credentials/paperless-token`, emptyDir mounts at `/app/{prompts,config,db}`; Service `paperless-gpt:8080`.
- [ ] Commit: `feat(paperless-gpt): add minimal chart + dev app wiring`

---

### Task 4: paperless-gpt NodePort service

**Files:**
- Create: `apps/workloads/paperless-gpt/overlays/dev/paperless-gpt-nodeport.yaml`
- Modify: `apps/workloads/paperless-gpt/overlays/dev/kustomization.yaml`

**Interfaces:**
- Consumes: pod labels `app.kubernetes.io/name: paperless-gpt` (Task 3)
- Produces: NodePort Service `paperless-gpt-nodeport` 32081

**Steps:**
- [ ] `paperless-gpt-nodeport.yaml` (mirrors `apps/workloads/paperless/overlays/dev/paperless-nodeport.yaml` idiom; selector uses name-only because we control the chart's labels):
```yaml
# nodePort 32081 must stay in sync with:
#   .devcontainer/manifests/k3d-dev.yaml   (port 32081:32081, applied at cluster creation)
#   .devcontainer/devcontainer.json        (forwardPorts + portsAttributes "Paperless GPT App")
apiVersion: v1
kind: Service
metadata:
  name: paperless-gpt-nodeport
  namespace: workloads
  annotations:
    argocd.argoproj.io/sync-wave: "5"
spec:
  type: NodePort
  selector:
    app.kubernetes.io/name: paperless-gpt
  ports:
    - name: http
      port: 8080
      protocol: TCP
      targetPort: http
      nodePort: 32081
```
- [ ] Update kustomization: `resources: [paperless-gpt-nodeport.yaml]`
- [ ] Validate: `kustomize build apps/workloads/paperless-gpt/overlays/dev` → NodePort Service.
- [ ] Commit: `feat(paperless-gpt): add NodePort 32081 for Codespaces forwarding`

---

### Task 5: Traefik IngressRoute (dev)

**Files:**
- Modify: `apps/infrastructure/traefik/overlays/dev/ingress-routes.yaml` (append)

**Interfaces:**
- Consumes: Service `paperless-gpt.workloads:8080`, existing Middleware `dashboard-auth` (basicAuth, `traefik-dashboard-secret`, `removeHeader: true` — reusing it since paperless-gpt has zero auth and port 30480 is public)

**Steps:**
- [ ] Append to the file (matching existing style):
```yaml
---
# ── Middleware: strip /paperless-gpt prefix ───────────────────
apiVersion: traefik.io/v1alpha1
kind: Middleware
metadata:
  name: strip-paperless-gpt-prefix
  namespace: traefik
spec:
  stripPrefix:
    prefixes:
      - /paperless-gpt

---
# ── IngressRoute: paperless-gpt (Codespaces HTTPS proxy) ─────
# paperless-gpt has NO built-in auth; dashboard-auth (basicAuth) gates it.
# Known caveat: the app assumes root paths for some redirects/assets —
# the NodePort route (32081) is the clean path; this is for quick testing.
apiVersion: traefik.io/v1alpha1
kind: IngressRoute
metadata:
  name: paperless-gpt
  namespace: traefik
  annotations:
    argocd.argoproj.io/sync-wave: "5"
spec:
  entryPoints:
    - web
    - websecure
  routes:
    - match: (Host(`127.0.0.1`) || Host(`localhost`) || HostRegexp(`^.+\.github\.dev$`)) && PathPrefix(`/paperless-gpt`)
      kind: Rule
      priority: 20
      middlewares:
        - name: dashboard-auth
          namespace: traefik
        - name: strip-paperless-gpt-prefix
          namespace: traefik
        - name: rate-limit
          namespace: traefik
        - name: secure-headers
          namespace: traefik
      services:
        - name: paperless-gpt
          namespace: workloads
          port: 8080
```
- [ ] Validate: `kustomize build apps/infrastructure/traefik/overlays/dev` renders cleanly.
- [ ] Commit: `feat(traefik): expose paperless-gpt at /paperless-gpt (dev, basic auth)`

---

### Task 6: Doppler bootstrap + credentials + Codespaces port wiring

**Files:**
- Modify: `.devcontainer/manifests/k3d-dev.yaml` (add `32081:32081` port mapping)
- Modify: `.devcontainer/devcontainer.json` (forwardPorts + portsAttributes `"32081": {"label": "Paperless GPT App", "protocol": "http"}`)
- Modify: `README.md` (port table ~line 554: add `| 32081 | Paperless GPT App | HTTP | paperless-gpt (Service/paperless-gpt-nodeport) |`)
- Create: `apps/workloads/paperless-gpt/overlays/dev/doppler-token-sealedsecret.yaml`
- Create: `apps/workloads/paperless-gpt/overlays/dev/doppler-secretstore.yaml`
- Create: `apps/workloads/paperless-gpt/overlays/dev/paperless-gpt-externalsecret.yaml`
- Modify: `apps/workloads/paperless-gpt/overlays/dev/kustomization.yaml` (add all three)

**Interfaces:**
- Consumes: Doppler project `paperless-gpt`, config `dev`, secret `PAPERLESS_TOKEN` + a service token for that config (USER PREREQUISITE); sealing cert `~/.secrets/sealed-secrets.pub` (codespace) or `kubeseal --fetch-cert` from `k3d-dev`
- Produces: Secret `paperless-gpt-credentials` key `paperless-token` (consumed by Task 3's Deployment)

**Steps:**
- [ ] **User checkpoint** (pause and confirm before sealing): (1) In paperless dev UI (localhost:32080) → user settings → API Tokens → create token. (2) In Doppler: create project `paperless-gpt`, config `dev`, add secret `PAPERLESS_TOKEN=<token>`. (3) Create a service token scoped to `paperless-gpt/dev` and provide it to the implementer.
- [ ] Seal the Doppler token (run where kubeseal + the dev cert exist — inside the codespace after a push, or locally if `~/.secrets/sealed-secrets.pub` is the dev cert; verify with the paperless precedent in commit `c8c52ca`):
```bash
kubectl create secret generic doppler-paperless-gpt-token \
  --namespace workloads \
  --from-literal=dopplerToken="$(tr -d '\n' < /tmp/doppler-paperless-gpt-token.txt)" \
  --dry-run=client -o yaml | \
  kubeseal --controller-namespace kube-system \
  --format yaml --cert ~/.secrets/sealed-secrets.pub \
  > apps/workloads/paperless-gpt/overlays/dev/doppler-token-sealedsecret.yaml
```
- [ ] `doppler-secretstore.yaml` (copy pattern from `apps/workloads/paperless/overlays/dev/doppler-secretstore.yaml`, name `doppler-paperless-gpt`, token secret `doppler-paperless-gpt-token`).
- [ ] `paperless-gpt-externalsecret.yaml`:
```yaml
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: paperless-gpt-credentials
  namespace: workloads
spec:
  secretStoreRef:
    kind: SecretStore
    name: doppler-paperless-gpt
  target:
    name: paperless-gpt-credentials
    creationPolicy: Owner
  data:
    - secretKey: paperless-token
      remoteRef:
        key: PAPERLESS_TOKEN
```
- [ ] Update kustomization resources list (order: sealedsecret, secretstore, externalsecret, nodeport).
- [ ] Validate: `kustomize build apps/workloads/paperless-gpt/overlays/dev` renders all 4 resources.
- [ ] Commit: `feat(paperless-gpt): Doppler-backed credentials + Codespaces port wiring`

---

### Task 7: Push and Argo CD rollout (codespace)

**Steps:**
- [ ] `git push origin develop` (appset tracks the GitHub repo, not the local tree).
- [ ] In the codespace (`kubectx k3d-dev`): `argocd app list` (or `kubectl -n argocd get applications`) → `ollama-dev` and `paperless-gpt-dev` appear; wait for `Synced`/`Healthy` (wave 5).
- [ ] `kubectl -n workloads get pvc` → `ollama` PVC bound; `kubectl -n workloads logs deploy/ollama | grep -i pulling` → `qwen2.5:3b` (first start takes minutes on CPU — image pull + ~2 GB model).
- [ ] `kubectl -n workloads exec deploy/ollama -- ollama list` → `qwen2.5:3b` present.
- [ ] `kubectl -n workloads get secret paperless-gpt-credentials -o jsonpath='{.data}' | jq -r 'keys[]'` → `paperless-token` (Doppler sync OK).
- [ ] `kubectl -n workloads logs deploy/paperless-gpt` → healthy; **if** it crashloops on missing vision/OCR config, apply the documented fallback from Task 3 (add `VISION_LLM_PROVIDER`/`VISION_LLM_MODEL` + pull `qwen2.5vl:3b`).
- [ ] Commit any fallback adjustments.

---

### Task 8: End-to-end test (codespace)

**Steps:**
- [ ] Open paperless dev (localhost:32080 / Codespaces "Paperless App" forward) → upload a small born-digital PDF (text layer — avoids OCR entirely).
- [ ] Tag it `paperless-gpt` (manual mode tag).
- [ ] Open paperless-gpt via NodePort forward (`localhost:32081`, "Paperless GPT App") → see the document queued; trigger suggestions; expect title/tag suggestion within seconds-to-tens-of-seconds on CPU.
- [ ] Accept a suggestion → verify it lands on the document in paperless UI.
- [ ] Traefik path: open `https://<codespace>-30443.app.github.dev/paperless-gpt` (or http localhost:30443) → basic-auth prompt (dashboard creds) → UI loads (accept minor sub-path jank per design).
- [ ] Sanity: `kubectl top pods -n workloads` (if metrics-server present) — ollama stays under its 4Gi limit during inference.
- [ ] Note results (latency, quality) back in the design doc's test section or a short `plans/` addendum; commit.

---

**Risks already accepted (from design):** sub-path Traefik jank; CPU inference latency; emptyDir state loss on pod restart; same-wave sync is fine (paperless-gpt doesn't need ollama at startup).

**Rollback:** delete the two app dirs (appset prunes apps), revert traefik/devcontainer commits, `k3d cluster delete dev` if the port mapping needs a clean recreate.
