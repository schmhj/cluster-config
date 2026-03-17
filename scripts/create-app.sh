#!/usr/bin/env bash
set -euo pipefail

# ─────────────────────────────────────────────
#  create-app.sh  –  ArgoCD app scaffolder
# ─────────────────────────────────────────────

# ── Helpers ──────────────────────────────────
red()    { printf '\033[0;31m%s\033[0m\n' "$*"; }
green()  { printf '\033[0;32m%s\033[0m\n' "$*"; }
yellow() { printf '\033[0;33m%s\033[0m\n' "$*"; }
cyan()   { printf '\033[0;36m%s\033[0m\n' "$*"; }
bold()   { printf '\033[1m%s\033[0m\n'   "$*"; }

# prompt_required <varname> <prompt-text>
#   Keeps asking until a non-empty value is entered.
prompt_required() {
  local __var="$1"
  local __prompt="$2"
  local __val=""
  while [[ -z "$__val" ]]; do
    printf "  %s: " "$__prompt"
    read -r __val
    __val="$(echo "$__val" | xargs)"
    [[ -z "$__val" ]] && red "  This field is required."
  done
  printf -v "$__var" '%s' "$__val"
}

# write_file <path> <content>
#   Creates the file; skips silently if it already exists.
write_file() {
  local path="$1"
  local content="$2"
  if [[ -f "$path" ]]; then
    yellow "  ~ skipping (exists): $path"
  else
    printf '%s' "$content" > "$path"
    green "  ✔ created: $path"
  fi
}

# ── Banner ────────────────────────────────────
echo ""
bold "╔══════════════════════════════════════╗"
bold "║       ArgoCD App Scaffolder          ║"
bold "╚══════════════════════════════════════╝"
echo ""

# ════════════════════════════════════════════
#  STEP 1 – App type
# ════════════════════════════════════════════
cyan "── Step 1/4: App Type ──────────────────"
while true; do
  echo "  (1) infrastructure"
  echo "  (2) workload"
  printf "  Enter choice [1/2]: "
  read -r type_choice
  case "$type_choice" in
    1) APP_TYPE="infrastructure"; break ;;
    2) APP_TYPE="workloads";      break ;;
    *) red "  Invalid choice. Please enter 1 or 2." ;;
  esac
done

# ════════════════════════════════════════════
#  STEP 2 – App name
# ════════════════════════════════════════════
echo ""
cyan "── Step 2/4: App Name ──────────────────"
while true; do
  printf "  Enter the name of the app: "
  read -r APP_NAME
  APP_NAME="$(echo "$APP_NAME" | xargs)"
  if [[ -z "$APP_NAME" ]]; then
    red "  App name cannot be empty."
  elif [[ ! "$APP_NAME" =~ ^[a-zA-Z0-9_-]+$ ]]; then
    red "  App name may only contain letters, numbers, hyphens, and underscores."
  else
    break
  fi
done

# ════════════════════════════════════════════
#  STEP 3 – Target environments
# ════════════════════════════════════════════
echo ""
cyan "── Step 3/4: Target Environments ──────"
while true; do
  echo "  (1) dev only"
  echo "  (2) prod only"
  echo "  (3) both dev and prod"
  printf "  Enter choice [1/2/3]: "
  read -r env_choice
  case "$env_choice" in
    1) ENVS=("dev");        break ;;
    2) ENVS=("prod");       break ;;
    3) ENVS=("dev" "prod"); break ;;
    *) red "  Invalid choice. Please enter 1, 2, or 3." ;;
  esac
done

# ════════════════════════════════════════════
#  STEP 4 – Helm chart details (optional)
# ════════════════════════════════════════════
echo ""
cyan "── Step 4/4: Helm Chart Details ────────"
HELM_DETAILS=false
CHART_NAME=""
CHART_REPO=""
CHART_VERSION=""
NAMESPACE=""
IS_GIT_REPO="false"

while true; do
  printf "  Do you want to enter helm chart details? [y/N]: "
  read -r helm_choice
  case "$helm_choice" in
    [yY]|[yY][eE][sS])
      HELM_DETAILS=true
      echo ""
      prompt_required CHART_NAME    "Chart name"
      prompt_required CHART_REPO    "Chart repo (URL)"
      prompt_required CHART_VERSION "Chart version"
      prompt_required NAMESPACE     "Namespace"

      # isGitRepo only relevant for workloads config.json
      if [[ "$APP_TYPE" == "workloads" ]]; then
        while true; do
          printf "  Is this a Git repo? [y/N]: "
          read -r git_choice
          case "$git_choice" in
            [yY]|[yY][eE][sS]) IS_GIT_REPO="true";  break ;;
            [nN]|[nN][oO]|"")  IS_GIT_REPO="false"; break ;;
            *) red "  Please enter y or n." ;;
          esac
        done
      fi
      break
      ;;
    [nN]|[nN][oO]|"")
      HELM_DETAILS=false
      break
      ;;
    *) red "  Please enter y or n." ;;
  esac
done

# ── Derived paths ─────────────────────────────
APP_ROOT="apps/${APP_TYPE}/${APP_NAME}"
BASE_DIR="${APP_ROOT}/base"

OVERLAY_DIRS=()
for env in "${ENVS[@]}"; do
  OVERLAY_DIRS+=("${APP_ROOT}/overlays/${env}")
done

# ── Summary ───────────────────────────────────
echo ""
bold "─────────────────── Summary ───────────────────"
echo "  Type         : $APP_TYPE"
echo "  Name         : $APP_NAME"
echo "  Environments : ${ENVS[*]}"
if $HELM_DETAILS; then
  echo "  Chart name   : $CHART_NAME"
  echo "  Chart repo   : $CHART_REPO"
  echo "  Chart version: $CHART_VERSION"
  echo "  Namespace    : $NAMESPACE"
  [[ "$APP_TYPE" == "workloads" ]] && echo "  Is Git repo  : $IS_GIT_REPO"
else
  echo "  Helm details : (placeholders will be used)"
fi
bold "───────────────────────────────────────────────"
echo ""

# ── Duplicate check ───────────────────────────
if [[ -d "$APP_ROOT" ]]; then
  yellow "⚠  Directory '$APP_ROOT' already exists."
  printf "   Continue and skip existing files? [y/N]: "
  read -r confirm
  case "$confirm" in
    [yY]|[yY][eE][sS]) ;;
    *) red "Aborted. No files were changed."; exit 0 ;;
  esac
fi

# ── Create directory tree ─────────────────────
mkdir -p "$BASE_DIR"
for od in "${OVERLAY_DIRS[@]}"; do
  mkdir -p "$od"
done

# ─────────────────────────────────────────────
#  INFRASTRUCTURE  templates
# ─────────────────────────────────────────────
create_infra_files() {
  # Resolve values or keep placeholders
  local cn="${CHART_NAME:-"{chartName}"}"
  local cr="${CHART_REPO:-"{chartRepo}"}"
  local cv="${CHART_VERSION:-"{chartVersion}"}"
  local ns="${NAMESPACE:-"{namespace}"}"

  # ── base/values.yaml (empty) ─────────────
  write_file "${BASE_DIR}/values.yaml" ""

  # ── base/kustomization.yaml ──────────────
  local base_content="apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
commonAnnotations:
  argocd.argoproj.io/sync-wave: \"3\"
helmCharts:
  - name: ${cn}
    repo: ${cr}
    version: \"${cv}\"
    namespace: ${ns}
    releaseName: ${cn}
    valuesFile: values.yaml
"
  write_file "${BASE_DIR}/kustomization.yaml" "$base_content"

  # ── overlays/{env}/kustomization.yaml ────
  for overlay_dir in "${OVERLAY_DIRS[@]}"; do
    local overlay_content="apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
commonAnnotations:
  argocd.argoproj.io/sync-wave: \"3\"
resources:
  - ../../base
patches:
  - target:
      group: kustomize.config.k8s.io
      version: v1beta1
      kind: Kustomization
    patch: |-
      - op: replace
        path: /helmCharts/0/valuesInline/fullnameOverride
        value: ${cn}
"
    write_file "${overlay_dir}/kustomization.yaml" "$overlay_content"
  done
}

# ─────────────────────────────────────────────
#  WORKLOAD  templates
# ─────────────────────────────────────────────
create_workload_files() {
  # ── base/values.yaml (empty) ─────────────
  write_file "${BASE_DIR}/values.yaml" ""

  # Resolve values or keep placeholders
  local an cr cn cv
  if $HELM_DETAILS; then
    an="$APP_NAME"
    cr="$CHART_REPO"
    cn="$CHART_NAME"
    cv="$CHART_VERSION"
  else
    an="{appName}"
    cr="{chartRepo}"
    cn="{chartName}"
    cv="{chartVersion}"
  fi

  # ── overlays/{env}/values.yaml & config.json ──
  for overlay_dir in "${OVERLAY_DIRS[@]}"; do
    write_file "${overlay_dir}/values.yaml" ""

    local config_content="{
    \"appName\": \"${an}\",
    \"chartRepo\": \"${cr}\",
    \"chartName\": \"${cn}\",
    \"chartVersion\": \"${cv}\",
    \"isGitRepo\": ${IS_GIT_REPO}
}
"
    write_file "${overlay_dir}/config.json" "$config_content"
  done
}

# ── Dispatch ──────────────────────────────────
echo "Creating files…"
echo ""
if [[ "$APP_TYPE" == "infrastructure" ]]; then
  create_infra_files
else
  create_workload_files
fi

# ── Final tree ────────────────────────────────
echo ""
green "✅  Done! Scaffold created for '${APP_NAME}' (${APP_TYPE})."
echo ""
echo "Directory tree:"
if command -v tree &>/dev/null; then
  tree "$APP_ROOT"
else
  # Portable fallback
  find "$APP_ROOT" | sort | while IFS= read -r f; do
    depth=$(printf '%s' "$f" | tr -cd '/' | wc -c)
    indent=$(printf '%*s' "$((depth * 2))" '')
    printf '%s%s\n' "$indent" "$(basename "$f")"
  done
fi