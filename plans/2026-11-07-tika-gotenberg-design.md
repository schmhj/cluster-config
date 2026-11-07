# Design: Tika + Gotenberg for paperless (dev)

Date: 2026-11-07
Status: Approved

## Goal

Enable Office-document (`.doc`, `.xlsx`, `.odt`, …) and email (`.eml`)
parsing in the existing dev paperless-ngx by deploying Apache Tika
(content extraction) and Gotenberg (HTML/email → PDF conversion) as two
new workload apps, and pointing paperless at them via environment
variables. Dev only; prod tenant-a is a follow-up once validated.

## Architecture

```
k3d-dev, ns workloads:
  paperless-dev (existing, CodeOpsMS chart 0.3.23)
    env → PAPERLESS_TIKA_ENABLED=true
          PAPERLESS_TIKA_ENDPOINT=http://tika.workloads.svc.cluster.local:9998
          PAPERLESS_TIKA_GOTENBERG_ENDPOINT=http://gotenberg.workloads.svc.cluster.local:3000
  tika-dev (new)                 gotenberg-dev (new)
    chart: apache/tika             chart: maikumori/gotenberg
      oci://apache.jfrog.io          oci://ghcr.io/maikumori/
      /tika-helm/tika 4.0.0           helm-charts/gotenberg 1.29.0
    ClusterIP :9998               ClusterIP service.port 3000 → api :3000
    requests 250m/512Mi           requests 100m/256Mi
```

Both new apps are picked up automatically by the existing dev workload
appset (`apps/workloads/*/overlays/dev` glob, wave 5). No appset
changes. Paperless rolls once via `config.secretRevision` when the env
lands.

## Decisions

- **Approach**: two separate workload apps (Approach A), matching the
  `ollama` + `paperless-gpt` precedent. Rejected: combined in-repo
  chart (custom maintenance); sidecars on the paperless pod (CodeOpsMS
  chart has no extra-container extension point — would require a fork).
- **Tika chart**: official Apache chart `oci://apache.jfrog.io/tika-helm/tika`
  4.0.0 (appVersion `4.0.0-1-full`). `fullnameOverride: tika` → Service
  `tika:9998`. Full image variant (includes OCR extras; ~1.5 GB —
  acceptable for dev, minimal variant is a later option).
- **Gotenberg chart**: community chart
  `oci://ghcr.io/maikumori/helm-charts/gotenberg` 1.29.0 (appVersion
  8.38.1). `fullnameOverride: gotenberg`.
  - `service.port: 3000` — chart default is 80 (→ container :3000);
    overriding keeps the endpoint URL on the conventional `:3000` that
    paperless docs use.
  - `chromium.disableJavaScript: true` and
    `chromium.allowList: "file:///tmp/.*"` — the paperless reference
    compose hardening that blocks tracking-pixel/remote fetches when
    rendering `.eml` HTML.
  - `enableServiceLinks: false` — chart documents that K8s service-link
    env vars can collide with Gotenberg's own configuration.
- **Paperless env names** (paperless-ngx docs; the short
  `PAPERLESS_GOTENBERG_URL` name does not exist):
  - `PAPERLESS_TIKA_ENABLED=true`
  - `PAPERLESS_TIKA_ENDPOINT=http://tika.workloads.svc.cluster.local:9998`
  - `PAPERLESS_TIKA_GOTENBERG_ENDPOINT=http://gotenberg.workloads.svc.cluster.local:3000`
- **secretRevision**: bump dev paperless `config.secretRevision` 1 → 2
  so the chart-managed Secret (and pod) rolls with the new env.
- **Resources** (Codespace-sized): Tika requests 250m/512Mi, limits
  1/1Gi (chart defaults are 1 CPU/1500Mi — too heavy). Gotenberg
  requests 100m/256Mi, limits 500m/512Mi. No node affinity (dev does
  not pin like prod).
- **State / exposure**: both stateless — no PVCs, no secrets, no
  NodePorts/IngressRoutes. Internal ClusterIP only; paperless talks to
  them in-cluster.
- **Chart versions** pinned in each `config.json` (repo convention).

## Components & files

| Change | File |
|---|---|
| New app | `apps/workloads/tika/base/values.yaml` (empty) |
| New app | `apps/workloads/tika/overlays/dev/{config.json,values.yaml,kustomization.yaml}` |
| New app | `apps/workloads/gotenberg/base/values.yaml` (empty) |
| New app | `apps/workloads/gotenberg/overlays/dev/{config.json,values.yaml,kustomization.yaml}` |
| Paperless env + roll | `apps/workloads/paperless/overlays/dev/values.yaml` |

## Rollout order & verification

1. Create the two app dirs → push to `develop` → appset generates
   `tika-dev` and `gotenberg-dev` (wave 5) → both Synced/Healthy.
2. From a debug pod: `curl http://tika:9998/version` and
   `curl http://gotenberg:3000/health`.
3. Paperless values change (`secretRevision` bump) → pod restarts with
   the three new env vars (verify via `kubectl exec … env | grep TIKA`).
4. End-to-end: upload a `.docx` and a `.eml` → content extracted and an
   archived PDF produced (Tika + Gotenberg path), not failed/skipped.

## Risks / accepted trade-offs

- Full Tika image (~1.5 GB) pull may be slow on first Codespace start.
- Gotenberg Chromium is memory-hungry under concurrent conversions —
  512Mi limit is dev-only sizing; raise if OOMKilled.
- If either app is deleted while paperless still points at it,
  Office/.eml ingest fails (PDF/image OCR unaffected). All three are
  wave-5 apps in one appset, so prune order is safe when removed
  together.

## Out of scope (follow-ups)

- prod tenant-a rollout (after dev validation)
- Minimal Tika image variant
- NodePort/Ingress exposure (internal only)
