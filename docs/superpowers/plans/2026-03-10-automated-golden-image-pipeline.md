# Automated Golden Image Pipeline Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Automate golden image rebuilds when upstream cloud images change, using Argo CronWorkflow as the watcher and GitLab CI as the builder.

**Architecture:** Argo CronWorkflow on rke2-prod polls upstream checksum files every 6 hours. When a change is detected, it commits updated version info to `upstream-versions.json` in the GitLab repo. GitLab CI triggers on that change and runs the build on a dedicated Rocky 9 shell runner. Build scripts are modified to accept an `IMAGE_NAME_OVERRIDE` env var for version-aware naming (`<distro>-<version>-<build-focus>-<date>`).

**Tech Stack:** Argo Workflows, GitLab CI, Bash, Terraform, Harvester HCI

**Spec:** `docs/superpowers/specs/2026-03-10-automated-golden-image-pipeline-design.md`

---

## File Structure

### New Files

| File | Responsibility |
|------|---------------|
| `upstream-versions.json` | Tracked version state — changes trigger GitLab CI |
| `.gitlab-ci.yml` | GitLab CI pipeline: detect, build, tag, cleanup stages |
| `argo/watcher-cronworkflow.yaml` | Argo CronWorkflow definition |
| `argo/scripts/check-upstream.sh` | Watcher script: fetch checksums, compare, commit if changed |

### Modified Files

| File | Change |
|------|--------|
| `cis/variables.tf` | Add `image_name_override` variable |
| `rke2/variables.tf` | Add `image_name_override` variable |
| `rke2/main.tf` | Add locals block to resolve `image_name_prefix` with override support |
| `cis/build.sh:114-124` | Respect `IMAGE_NAME_OVERRIDE` env var in `get_image_name()` |
| `rke2/build.sh:90-95` | Respect `IMAGE_NAME_OVERRIDE` env var in `get_image_name()` |
| `build.sh:156-166` | Pass `IMAGE_NAME_OVERRIDE` through to sub-builds |

---

## Chunk 1: Build Script Modifications (Image Name Override)

### Task 1: Add image_name_override variable to CIS Terraform

**Files:**
- Modify: `cis/variables.tf:133-137`

Note: The CIS image name override is handled entirely at the shell level (`get_image_name()` in `cis/build.sh`). The Terraform variable is needed so `build.sh` can pass `-var=image_name_override=...` without Terraform rejecting the unknown variable, but `cis/main.tf` doesn't need changes because it uses `local.image_name_prefix` for builder resource names (not the final golden image name — that's set via kubectl in the build script).

- [ ] **Step 1: Add variable to `cis/variables.tf`**

After the existing `image_name_prefix` variable (line 137), add:

```hcl
variable "image_name_override" {
  description = "Full image name override (set by CI pipeline). When set, replaces the auto-generated name entirely."
  type        = string
  default     = ""
}
```

- [ ] **Step 2: Validate Terraform**

Run: `cd /home/rocky/data/harvester-golden-images/cis && terraform init -backend=false && terraform validate`
Expected: Success

- [ ] **Step 3: Commit**

```bash
git add cis/variables.tf
git commit -m "feat(cis): add image_name_override variable for CI pipeline naming"
```

---

### Task 2: Add image_name_override variable to RKE2 Terraform

**Files:**
- Modify: `rke2/variables.tf:87-91`
- Modify: `rke2/main.tf:1-16` (resource names reference `var.image_name_prefix` directly)

Note: Unlike CIS (which has `locals.tf`), RKE2's `main.tf` uses `var.image_name_prefix` directly in resource names (lines 24, 44). The same pattern applies here — the override is shell-level for the golden image name. The Terraform variable just prevents `-var=image_name_override=...` from being rejected.

- [ ] **Step 1: Add variable to `rke2/variables.tf`**

After the existing `image_name_prefix` variable (line 91), add:

```hcl
variable "image_name_override" {
  description = "Full image name override (set by CI pipeline). When set, replaces the auto-generated name entirely."
  type        = string
  default     = ""
}
```

- [ ] **Step 2: Validate Terraform**

Run: `cd /home/rocky/data/harvester-golden-images/rke2 && terraform init -backend=false && terraform validate`
Expected: Success

- [ ] **Step 3: Commit**

```bash
git add rke2/variables.tf
git commit -m "feat(rke2): add image_name_override variable for CI pipeline naming"
```

---

### Task 3: Update CIS build.sh to respect IMAGE_NAME_OVERRIDE

**Files:**
- Modify: `cis/build.sh:114-124`

- [ ] **Step 1: Update `get_image_name()` function**

Replace the `get_image_name()` function at lines 114-124 with:

```bash
get_image_name() {
  # CI pipeline sets IMAGE_NAME_OVERRIDE for version-aware naming
  if [[ -n "${IMAGE_NAME_OVERRIDE:-}" ]]; then
    echo "$IMAGE_NAME_OVERRIDE"
    return
  fi
  local prefix
  prefix=$(_get_tfvar image_name_prefix)
  if [[ -z "$prefix" ]]; then
    local distro
    distro=$(_get_tfvar distro)
    [[ -z "$distro" ]] && distro="rocky9"
    prefix="${distro}-cis-golden"
  fi
  echo "${prefix}-${IMAGE_DATE}"
}
```

- [ ] **Step 2: Pass override to Terraform if set**

In `cmd_build()`, after line 231 (`terraform apply -auto-approve ${tf_var_file_arg}`), the Terraform apply already uses the tfvars. We need to pass `image_name_override` as a `-var` if `IMAGE_NAME_OVERRIDE` is set.

Replace line 231:

```bash
  terraform apply -auto-approve ${tf_var_file_arg}
```

With:

```bash
  local tf_override_arg=""
  if [[ -n "${IMAGE_NAME_OVERRIDE:-}" ]]; then
    tf_override_arg="-var=image_name_override=${IMAGE_NAME_OVERRIDE}"
  fi
  # shellcheck disable=SC2086 -- intentional word splitting: empty vars expand to nothing
  terraform apply -auto-approve ${tf_var_file_arg} ${tf_override_arg}
```

Also update the destroy command at line 345 similarly:

```bash
  # shellcheck disable=SC2086
  terraform destroy -auto-approve ${tf_var_file_arg} ${tf_override_arg}
```

- [ ] **Step 3: Run ShellCheck**

Run: `shellcheck cis/build.sh`
Expected: Clean (no new warnings)

- [ ] **Step 4: Commit**

```bash
git add cis/build.sh
git commit -m "feat(cis): respect IMAGE_NAME_OVERRIDE env var for CI naming"
```

---

### Task 4: Update RKE2 build.sh to respect IMAGE_NAME_OVERRIDE

**Files:**
- Modify: `rke2/build.sh:90-95`

- [ ] **Step 1: Update `get_image_name()` function**

Replace the `get_image_name()` function at lines 90-95 with:

```bash
get_image_name() {
  # CI pipeline sets IMAGE_NAME_OVERRIDE for version-aware naming
  if [[ -n "${IMAGE_NAME_OVERRIDE:-}" ]]; then
    echo "$IMAGE_NAME_OVERRIDE"
    return
  fi
  local prefix
  prefix=$(_get_tfvar image_name_prefix)
  [[ -z "$prefix" ]] && prefix="rke2-rocky9-golden"
  echo "${prefix}-${IMAGE_DATE}"
}
```

- [ ] **Step 2: Pass override to Terraform if set**

In `cmd_build()`, update the terraform apply at line 204:

Replace:

```bash
  terraform apply -auto-approve
```

With:

```bash
  local tf_override_arg=""
  if [[ -n "${IMAGE_NAME_OVERRIDE:-}" ]]; then
    tf_override_arg="-var=image_name_override=${IMAGE_NAME_OVERRIDE}"
  fi
  # shellcheck disable=SC2086
  terraform apply -auto-approve ${tf_override_arg}
```

Also update the destroy at line 301:

```bash
  # shellcheck disable=SC2086
  terraform destroy -auto-approve ${tf_override_arg}
```

- [ ] **Step 3: Run ShellCheck**

Run: `shellcheck rke2/build.sh`
Expected: Clean (no new warnings)

- [ ] **Step 4: Commit**

```bash
git add rke2/build.sh
git commit -m "feat(rke2): respect IMAGE_NAME_OVERRIDE env var for CI naming"
```

---

### Task 5: Update top-level build.sh to pass IMAGE_NAME_OVERRIDE

**Files:**
- Modify: `build.sh:156-166`

- [ ] **Step 1: Document env var in header comment**

Add to the header comment block (after line 29):

```bash
# Environment variables (set by CI pipeline):
#   IMAGE_NAME_OVERRIDE    Full image name (e.g., rocky-9.7-cis-20260310)
```

- [ ] **Step 2: Verify env passthrough**

The top-level `build.sh` calls sub-scripts directly (line 163: `"$script" build -f "$tfvars"`). Since `IMAGE_NAME_OVERRIDE` is an environment variable, it's automatically inherited by child processes. No code change needed — just the documentation.

- [ ] **Step 3: Commit**

```bash
git add build.sh
git commit -m "docs(build): document IMAGE_NAME_OVERRIDE env var for CI pipeline"
```

---

## Chunk 2: upstream-versions.json and Argo Watcher

### Task 6: Create initial upstream-versions.json

**Files:**
- Create: `upstream-versions.json`

- [ ] **Step 1: Create the file**

```json
{
  "rocky9": {
    "version": "",
    "build": "",
    "checksum": "",
    "detected_at": "",
    "image_url": ""
  },
  "debian12": {
    "version": "",
    "build": "",
    "checksum": "",
    "detected_at": "",
    "image_url": ""
  }
}
```

This initial empty state will trigger a build on the first watcher run (any checksum will differ from empty).

- [ ] **Step 2: Commit**

```bash
git add upstream-versions.json
git commit -m "feat: add initial upstream-versions.json for automated pipeline"
```

---

### Task 7: Create the upstream watcher script

**Files:**
- Create: `argo/scripts/check-upstream.sh`

- [ ] **Step 1: Create the watcher script**

```bash
#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# check-upstream.sh — Check upstream cloud images for new releases
# =============================================================================
# Fetches checksum files from upstream distro mirrors, compares against stored
# values, and commits updated upstream-versions.json if changes are detected.
#
# Required environment variables:
#   GITLAB_USER      GitLab username for git push
#   GITLAB_TOKEN     GitLab project access token
#   GITLAB_REPO_URL  GitLab repo URL (without protocol, e.g., gitlab.aegisgroup.ch/group/project.git)
#
# Optional:
#   GIT_BRANCH       Branch to push to (default: main)
#   DRY_RUN          Set to "true" to skip git push (for testing)
# =============================================================================

# --- Configuration ---
ROCKY_CHECKSUM_URL="https://dl.rockylinux.org/pub/rocky/9/images/x86_64/CHECKSUM"
DEBIAN_CHECKSUM_URL="https://cloud.debian.org/images/cloud/bookworm/latest/SHA512SUMS"
GIT_BRANCH="${GIT_BRANCH:-main}"
DRY_RUN="${DRY_RUN:-false}"
WORK_DIR="/tmp/upstream-check"

# --- Logging ---
log_info()  { echo "[INFO]  $*"; }
log_ok()    { echo "[OK]    $*"; }
log_warn()  { echo "[WARN]  $*" >&2; }
log_error() { echo "[ERROR] $*" >&2; }

die() {
  log_error "$@"
  exit 1
}

# --- Functions ---

# Parse Rocky 9 CHECKSUM file to extract version and checksum
# Format: SHA256 (Rocky-9-GenericCloud-Base-9.5-20241118.0.x86_64.qcow2) = abc123...
parse_rocky_checksum() {
  local checksum_file="$1"
  local line
  line=$(grep 'GenericCloud-Base.*\.qcow2' "$checksum_file" | grep '^SHA256' | head -1)

  if [[ -z "$line" ]]; then
    log_warn "Could not find Rocky GenericCloud qcow2 in checksum file"
    return 1
  fi

  # Extract filename: Rocky-9-GenericCloud-Base-9.5-20241118.0.x86_64.qcow2
  local filename
  filename=$(echo "$line" | sed -n 's/.*(\(.*\)).*/\1/p')

  # Extract version: 9.5
  local version
  version=$(echo "$filename" | sed -n 's/Rocky-9-GenericCloud-Base-\([0-9]*\.[0-9]*\)-.*/\1/p')

  # Extract build: 20241118.0
  local build
  build=$(echo "$filename" | sed -n 's/Rocky-9-GenericCloud-Base-[0-9]*\.[0-9]*-\([0-9]*\.[0-9]*\)\..*/\1/p')

  # Extract checksum
  local checksum
  checksum=$(echo "$line" | awk '{print $NF}')

  # Build download URL
  local image_url="https://dl.rockylinux.org/pub/rocky/9/images/x86_64/${filename}"

  echo "${version}|${build}|sha256:${checksum}|${image_url}"
}

# Parse Debian SHA512SUMS to extract build and checksum for generic-amd64 qcow2
# Format: abc123...  debian-12-generic-amd64-20260309-2019.qcow2
parse_debian_checksum() {
  local checksum_file="$1"
  local line
  line=$(grep 'debian-12-generic-amd64.*\.qcow2' "$checksum_file" | head -1)

  if [[ -z "$line" ]]; then
    log_warn "Could not find Debian 12 generic-amd64 qcow2 in checksum file"
    return 1
  fi

  local checksum
  checksum=$(echo "$line" | awk '{print $1}')

  local filename
  filename=$(echo "$line" | awk '{print $2}')

  # Extract build: 20260309-2019
  local build
  build=$(echo "$filename" | sed -n 's/debian-12-generic-amd64-\(.*\)\.qcow2/\1/p')

  local image_url="https://cloud.debian.org/images/cloud/bookworm/latest/${filename}"

  echo "12|${build}|sha512:${checksum}|${image_url}"
}

# Read current stored checksum for a distro from upstream-versions.json
read_stored_checksum() {
  local distro="$1"
  local versions_file="$2"

  if [[ ! -f "$versions_file" ]]; then
    echo ""
    return
  fi

  jq -r ".${distro}.checksum // \"\"" "$versions_file"
}

# Update upstream-versions.json for a specific distro
update_versions_json() {
  local distro="$1"
  local version="$2"
  local build="$3"
  local checksum="$4"
  local image_url="$5"
  local versions_file="$6"
  local now
  now=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

  jq --arg distro "$distro" \
     --arg version "$version" \
     --arg build "$build" \
     --arg checksum "$checksum" \
     --arg image_url "$image_url" \
     --arg detected_at "$now" \
     '.[$distro] = {
        version: $version,
        build: $build,
        checksum: $checksum,
        detected_at: $detected_at,
        image_url: $image_url
      }' "$versions_file" > "${versions_file}.tmp" && mv "${versions_file}.tmp" "$versions_file"
}

# --- Main ---

log_info "Starting upstream version check..."

# Validate required env vars
for var in GITLAB_USER GITLAB_TOKEN GITLAB_REPO_URL; do
  if [[ -z "${!var:-}" ]]; then
    die "Required environment variable ${var} is not set"
  fi
done

# Set up working directory
rm -rf "$WORK_DIR"
mkdir -p "$WORK_DIR"

# Fetch upstream checksum files
log_info "Fetching Rocky 9 checksums..."
curl -sfL "$ROCKY_CHECKSUM_URL" -o "${WORK_DIR}/rocky-checksum" || die "Failed to fetch Rocky checksums"

log_info "Fetching Debian 12 checksums..."
curl -sfL "$DEBIAN_CHECKSUM_URL" -o "${WORK_DIR}/debian-checksum" || die "Failed to fetch Debian checksums"

# Parse upstream checksums
log_info "Parsing checksums..."
rocky_data=$(parse_rocky_checksum "${WORK_DIR}/rocky-checksum") || die "Failed to parse Rocky checksum"
debian_data=$(parse_debian_checksum "${WORK_DIR}/debian-checksum") || die "Failed to parse Debian checksum"

IFS='|' read -r rocky_version rocky_build rocky_checksum rocky_url <<< "$rocky_data"
IFS='|' read -r debian_version debian_build debian_checksum debian_url <<< "$debian_data"

log_info "Rocky 9: version=${rocky_version} build=${rocky_build}"
log_info "Debian 12: version=${debian_version} build=${debian_build}"

# Clone repo
log_info "Cloning repository..."
git clone --depth 1 --branch "${GIT_BRANCH}" \
  "https://${GITLAB_USER}:${GITLAB_TOKEN}@${GITLAB_REPO_URL}" \
  "${WORK_DIR}/repo" || die "Failed to clone repository"

cd "${WORK_DIR}/repo"

# Configure git
git config user.name "Golden Image Watcher"
git config user.email "golden-image-watcher@aegisgroup.ch"

VERSIONS_FILE="${WORK_DIR}/repo/upstream-versions.json"

# Compare checksums
changed_distros=()

stored_rocky=$(read_stored_checksum "rocky9" "$VERSIONS_FILE")
if [[ "$stored_rocky" != "$rocky_checksum" ]]; then
  log_info "Rocky 9: checksum changed (${stored_rocky:-empty} -> ${rocky_checksum})"
  update_versions_json "rocky9" "$rocky_version" "$rocky_build" "$rocky_checksum" "$rocky_url" "$VERSIONS_FILE"
  changed_distros+=("Rocky ${rocky_version}")
else
  log_ok "Rocky 9: no change"
fi

stored_debian=$(read_stored_checksum "debian12" "$VERSIONS_FILE")
if [[ "$stored_debian" != "$debian_checksum" ]]; then
  log_info "Debian 12: checksum changed (${stored_debian:-empty} -> ${debian_checksum})"
  update_versions_json "debian12" "$debian_version" "$debian_build" "$debian_checksum" "$debian_url" "$VERSIONS_FILE"
  changed_distros+=("Debian ${debian_version}")
else
  log_ok "Debian 12: no change"
fi

# Commit and push if anything changed
if [[ ${#changed_distros[@]} -eq 0 ]]; then
  log_ok "No upstream changes detected. Exiting."
  exit 0
fi

commit_msg="chore: detected upstream $(IFS=', '; echo "${changed_distros[*]}")"
log_info "Changes detected. Committing: ${commit_msg}"

git add upstream-versions.json
git commit -m "$commit_msg"

if [[ "$DRY_RUN" == "true" ]]; then
  log_warn "DRY_RUN=true — skipping git push"
  git log --oneline -1
  jq '.' "$VERSIONS_FILE"
else
  git push origin "${GIT_BRANCH}"
  log_ok "Pushed to ${GIT_BRANCH}"
fi

log_ok "Done. Changed: ${changed_distros[*]}"
```

- [ ] **Step 2: Make executable**

Run: `chmod +x argo/scripts/check-upstream.sh`

- [ ] **Step 3: Run ShellCheck**

Run: `shellcheck argo/scripts/check-upstream.sh`
Expected: Clean

- [ ] **Step 4: Commit**

```bash
git add argo/scripts/check-upstream.sh
git commit -m "feat(argo): add upstream version watcher script"
```

---

### Task 8: Create Argo CronWorkflow

**Files:**
- Create: `argo/watcher-cronworkflow.yaml`

Note: No ConfigMap needed — the watcher uses `upstream-versions.json` in the git repo as its state store. This is simpler and provides a full git audit trail.

- [ ] **Step 1: Create the CronWorkflow**

```yaml
apiVersion: argoproj.io/v1alpha1
kind: CronWorkflow
metadata:
  name: golden-image-watcher
  namespace: argo
  labels:
    app: golden-image-watcher
spec:
  schedule: "0 */6 * * *"
  timezone: "Europe/Zurich"
  concurrencyPolicy: Replace
  successfulJobsHistoryLimit: 3
  failedJobsHistoryLimit: 3
  workflowSpec:
    entrypoint: check-upstream
    serviceAccountName: golden-image-watcher
    volumes:
      - name: watcher-script
        configMap:
          name: golden-image-watcher-script
          defaultMode: 0755
    templates:
      - name: check-upstream
        container:
          image: alpine/git:2.43.0
          command: ["/bin/sh", "-c"]
          args:
            - |
              apk add --no-cache curl jq bash coreutils &&
              bash /scripts/check-upstream.sh
          env:
            - name: GITLAB_USER
              valueFrom:
                secretKeyRef:
                  name: gitlab-golden-images-token
                  key: GITLAB_USER
            - name: GITLAB_TOKEN
              valueFrom:
                secretKeyRef:
                  name: gitlab-golden-images-token
                  key: GITLAB_TOKEN
            - name: GITLAB_REPO_URL
              valueFrom:
                secretKeyRef:
                  name: gitlab-golden-images-token
                  key: GITLAB_REPO_URL
          volumeMounts:
            - name: watcher-script
              mountPath: /scripts
          resources:
            requests:
              memory: "128Mi"
              cpu: "100m"
            limits:
              memory: "256Mi"
              cpu: "500m"
```

- [ ] **Step 2: Commit**

```bash
git add argo/watcher-cronworkflow.yaml
git commit -m "feat(argo): add CronWorkflow for upstream watcher"
```

---

## Chunk 3: GitLab CI Pipeline

### Task 9: Create .gitlab-ci.yml

**Files:**
- Create: `.gitlab-ci.yml`

- [ ] **Step 1: Create the pipeline file**

```yaml
# =============================================================================
# GitLab CI — Golden Image Automated Build Pipeline
# =============================================================================
# Triggered when upstream-versions.json is updated (by Argo watcher).
# Builds golden images with version-aware naming on a dedicated Rocky 9 runner.
# =============================================================================

stages:
  - detect
  - build
  - tag
  - cleanup

# Only run this pipeline when upstream-versions.json changes on main
workflow:
  rules:
    - if: $CI_PIPELINE_SOURCE == "push" && $CI_COMMIT_BRANCH == "main"
      changes:
        - upstream-versions.json
    # Allow manual trigger
    - if: $CI_PIPELINE_SOURCE == "web"

# -----------------------------------------------------------------------------
# Stage: detect — Diff upstream-versions.json to find which distros changed
# -----------------------------------------------------------------------------
detect-changes:
  stage: detect
  tags:
    - golden-image-builder
  script:
    - |
      set -euo pipefail

      IMAGE_DATE=$(date +%Y%m%d)
      echo "IMAGE_DATE=${IMAGE_DATE}" >> detect.env

      # Read current version info
      ROCKY_VERSION=$(jq -r '.rocky9.version // ""' upstream-versions.json)
      DEBIAN_VERSION=$(jq -r '.debian12.version // ""' upstream-versions.json)
      echo "ROCKY_VERSION=${ROCKY_VERSION}" >> detect.env
      echo "DEBIAN_VERSION=${DEBIAN_VERSION}" >> detect.env

      # Determine what actually changed using git diff against previous commit
      BUILD_ROCKY9="false"
      BUILD_DEBIAN12="false"

      if git diff HEAD~1 -- upstream-versions.json | grep -q '"rocky9"' 2>/dev/null; then
        BUILD_ROCKY9="true"
        echo "Rocky 9 ${ROCKY_VERSION} — checksum changed, will build"
      else
        echo "Rocky 9 — no change detected"
      fi

      if git diff HEAD~1 -- upstream-versions.json | grep -q '"debian12"' 2>/dev/null; then
        BUILD_DEBIAN12="true"
        echo "Debian 12 ${DEBIAN_VERSION} — checksum changed, will build"
      else
        echo "Debian 12 — no change detected"
      fi

      # On manual trigger, build everything that has version info
      if [ "$CI_PIPELINE_SOURCE" = "web" ]; then
        echo "Manual trigger — building all distros with version info"
        [ -n "$ROCKY_VERSION" ] && BUILD_ROCKY9="true"
        [ -n "$DEBIAN_VERSION" ] && BUILD_DEBIAN12="true"
      fi

      echo "BUILD_ROCKY9=${BUILD_ROCKY9}" >> detect.env
      echo "BUILD_DEBIAN12=${BUILD_DEBIAN12}" >> detect.env
  artifacts:
    reports:
      dotenv: detect.env

# -----------------------------------------------------------------------------
# Stage: build — Run golden image builds (conditional via script check)
# -----------------------------------------------------------------------------
# Note: Build jobs use script-level checks instead of rules:if for dotenv
# variables, since rules:if evaluates before dotenv artifacts are loaded.

build-cis-rocky9:
  stage: build
  tags:
    - golden-image-builder
  needs:
    - job: detect-changes
      artifacts: true
  timeout: 60m
  script:
    - |
      set -euo pipefail
      if [ "${BUILD_ROCKY9}" != "true" ]; then
        echo "Rocky 9 not changed — skipping"
        exit 0
      fi
      export IMAGE_NAME_OVERRIDE="rocky-${ROCKY_VERSION}-cis-${IMAGE_DATE}"
      echo "Building CIS Rocky 9 as: ${IMAGE_NAME_OVERRIDE}"
      ./build.sh build cis-rocky9

build-cis-debian12:
  stage: build
  tags:
    - golden-image-builder
  needs:
    - job: detect-changes
      artifacts: true
  timeout: 60m
  script:
    - |
      set -euo pipefail
      if [ "${BUILD_DEBIAN12}" != "true" ]; then
        echo "Debian 12 not changed — skipping"
        exit 0
      fi
      export IMAGE_NAME_OVERRIDE="debian-${DEBIAN_VERSION}-cis-${IMAGE_DATE}"
      echo "Building CIS Debian 12 as: ${IMAGE_NAME_OVERRIDE}"
      ./build.sh build cis-debian12

build-rke2:
  stage: build
  tags:
    - golden-image-builder
  needs:
    - job: detect-changes
      artifacts: true
  timeout: 60m
  script:
    - |
      set -euo pipefail
      if [ "${BUILD_ROCKY9}" != "true" ]; then
        echo "Rocky 9 not changed — skipping RKE2 build"
        exit 0
      fi
      export IMAGE_NAME_OVERRIDE="rocky-${ROCKY_VERSION}-rke2-${IMAGE_DATE}"
      echo "Building RKE2 Rocky 9 as: ${IMAGE_NAME_OVERRIDE}"
      ./build.sh build rke2

# -----------------------------------------------------------------------------
# Stage: tag — Git-tag the build
# -----------------------------------------------------------------------------
tag-build:
  stage: tag
  tags:
    - golden-image-builder
  needs:
    - job: detect-changes
      artifacts: true
    - job: build-cis-rocky9
    - job: build-cis-debian12
    - job: build-rke2
  script:
    - |
      set -euo pipefail

      # Use CI job token for push via HTTPS
      git remote set-url origin "https://gitlab-ci-token:${CI_JOB_TOKEN}@${CI_SERVER_HOST}/${CI_PROJECT_PATH}.git"
      git config user.name "GitLab CI"
      git config user.email "ci@aegisgroup.ch"

      TAGGED=0

      if [ "${BUILD_ROCKY9}" = "true" ]; then
        TAG="rocky9/${ROCKY_VERSION}-${IMAGE_DATE}"
        git tag -a "$TAG" -m "Rocky ${ROCKY_VERSION} golden images built ${IMAGE_DATE}"
        echo "Tagged: ${TAG}"
        TAGGED=1
      fi

      if [ "${BUILD_DEBIAN12}" = "true" ]; then
        TAG="debian12/${DEBIAN_VERSION}-${IMAGE_DATE}"
        git tag -a "$TAG" -m "Debian ${DEBIAN_VERSION} golden image built ${IMAGE_DATE}"
        echo "Tagged: ${TAG}"
        TAGGED=1
      fi

      if [ "$TAGGED" -eq 1 ]; then
        git push origin --tags
      else
        echo "No tags to push"
      fi

# -----------------------------------------------------------------------------
# Stage: cleanup — Remove old images (manual trigger only)
# -----------------------------------------------------------------------------
cleanup-old-images:
  stage: cleanup
  tags:
    - golden-image-builder
  when: manual
  allow_failure: true
  variables:
    KEEP_COUNT: "3"
  script:
    - |
      set -euo pipefail
      echo "Image cleanup — keeping last ${KEEP_COUNT} per type"
      echo "TODO: implement image retention policy"
      echo "This will use: ./build.sh list + ./build.sh delete"
```

- [ ] **Step 2: Validate YAML syntax**

Run: `python3 -c "import yaml; yaml.safe_load(open('.gitlab-ci.yml'))" && echo "Valid YAML"`
Expected: `Valid YAML`

- [ ] **Step 3: Commit**

```bash
git add .gitlab-ci.yml
git commit -m "feat: add GitLab CI pipeline for automated golden image builds"
```

---

## Chunk 4: GitLab Remote and Final Integration

### Task 10: Add GitLab remote

- [ ] **Step 1: Add the gitlab remote**

```bash
cd /home/rocky/data/harvester-golden-images
git remote add gitlab git@gitlab.aegisgroup.ch:infrastructure/harvester-golden-images.git
```

Note: The exact GitLab project path may need adjustment. The user should create the project on gitlab.aegisgroup.ch first if it doesn't exist.

- [ ] **Step 2: Push to GitLab**

```bash
git push gitlab main --tags
```

- [ ] **Step 3: Verify**

Run: `git remote -v`
Expected: Both `origin` (GitHub) and `gitlab` (gitlab.aegisgroup.ch) remotes listed.

---

### Task 11: Deploy Argo resources to rke2-prod

This task is manual — requires kubectl access to rke2-prod.

- [ ] **Step 1: Create the GitLab access Secret**

```bash
kubectl create secret generic gitlab-golden-images-token \
  --namespace argo \
  --from-literal=GITLAB_USER="golden-image-watcher" \
  --from-literal=GITLAB_TOKEN="<project-access-token>" \
  --from-literal=GITLAB_REPO_URL="gitlab.aegisgroup.ch/infrastructure/harvester-golden-images.git"
```

- [ ] **Step 2: Create the watcher script ConfigMap**

```bash
kubectl create configmap golden-image-watcher-script \
  --namespace argo \
  --from-file=check-upstream.sh=argo/scripts/check-upstream.sh
```

- [ ] **Step 3: Apply the CronWorkflow**

```bash
kubectl apply -f argo/watcher-cronworkflow.yaml
```

- [ ] **Step 4: Verify CronWorkflow is scheduled**

Run: `kubectl get cronworkflows -n argo`
Expected: `golden-image-watcher` with schedule `0 */6 * * *`

- [ ] **Step 5: Test with a manual trigger**

```bash
argo submit --from cronwf/golden-image-watcher -n argo
argo logs -n argo @latest
```

Expected: Script runs, detects current upstream versions, commits to GitLab (first run will always detect a change since stored checksums are empty).

---

### Task 12: Register GitLab Runner on builder VM

This task is manual — requires access to the dedicated Rocky 9 builder VM.

- [ ] **Step 1: Install GitLab Runner on the builder VM**

```bash
# On the builder VM
curl -L "https://packages.gitlab.com/install/repositories/runner/gitlab-runner/script.rpm.sh" | sudo bash
sudo dnf install -y gitlab-runner
```

- [ ] **Step 2: Register the runner**

```bash
sudo gitlab-runner register \
  --non-interactive \
  --url "https://gitlab.aegisgroup.ch" \
  --registration-token "<token-from-gitlab-project-settings>" \
  --executor "shell" \
  --tag-list "golden-image-builder" \
  --description "Golden Image Builder (Rocky 9)" \
  --run-untagged=false
```

- [ ] **Step 3: Ensure build tools are installed**

```bash
# Terraform
sudo dnf install -y yum-utils
sudo yum-config-manager --add-repo https://rpm.releases.hashicorp.com/RHEL/hashicorp.repo
sudo dnf install -y terraform

# libguestfs + virt-customize
sudo dnf install -y libguestfs-tools-c qemu-img

# Other tools
sudo dnf install -y kubectl jq git curl
```

- [ ] **Step 4: Place Harvester kubeconfig**

Copy `kubeconfig-harvester.yaml` to the repo checkout location on the runner VM. The runner clones to `~/builds/<runner-id>/<project>/` — the kubeconfig should be symlinked or placed in the expected location.

- [ ] **Step 5: Verify runner is online**

Check GitLab project > Settings > CI/CD > Runners — runner should show as active with tag `golden-image-builder`.
