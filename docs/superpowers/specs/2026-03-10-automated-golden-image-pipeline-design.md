# Automated Golden Image Pipeline Design

## Overview

Automated pipeline that detects new upstream cloud image releases and triggers golden image rebuilds with version-aware naming. Argo Workflows on rke2-prod watches upstream sources; GitLab CI on gitlab.aegisgroup.ch builds the images via a dedicated Rocky 9 runner VM.

## Architecture

```
┌─────────────────────────┐
│  rke2-prod cluster      │
│                         │
│  Argo CronWorkflow      │
│  (every 6 hours)        │
│    │                    │
│    ▼                    │
│  check-upstream.sh      │
│    │ fetch checksums    │
│    │ compare git state  │
│    │                    │
│    ▼ (if changed)       │
│  git commit + push      │
│  upstream-versions.json │
│  to gitlab.aegisgroup.ch│
└─────────────────────────┘
          │
          ▼
┌─────────────────────────┐
│  GitLab CI              │
│  gitlab.aegisgroup.ch   │
│                         │
│  Trigger: change to     │
│  upstream-versions.json │
│    │                    │
│    ▼                    │
│  detect → build → tag   │
│           → cleanup     │
└─────────────────────────┘
          │
          ▼
┌─────────────────────────┐
│  GitLab Runner VM       │
│  (Rocky 9, shell exec)  │
│                         │
│  terraform + libguestfs │
│  + virt-customize       │
│    │                    │
│    ▼                    │
│  Harvester API          │
│  (kubeconfig)           │
│  → golden image import  │
└─────────────────────────┘
```

## Component Details

### 1. Upstream Version Watcher (Argo CronWorkflow)

**Schedule:** `0 */6 * * *` (every 6 hours)

**Namespace:** `argo` on rke2-prod

**Container:** Lightweight image with `curl`, `jq`, `git`, `sha256sum`

**Checksum sources:**

| Distro | URL | Version Extraction |
|--------|-----|-------------------|
| Rocky 9 | `https://dl.rockylinux.org/pub/rocky/9/images/x86_64/CHECKSUM` | Filename: `Rocky-9-GenericCloud-Base-9.X-YYYYMMDD.0.x86_64.qcow2` |
| Debian 12 | `https://cloud.debian.org/images/cloud/bookworm/latest/SHA512SUMS` | Filename: `debian-12-generic-amd64-YYYYMMDD-XXXX.qcow2` |

**Flow:**

1. Clone repo from gitlab.aegisgroup.ch (shallow clone)
2. Read stored checksums from `upstream-versions.json` in the repo
3. Fetch upstream checksum files via HTTP
4. Parse checksums and version strings
5. Compare against stored values
6. If changed:
   - Update `upstream-versions.json` with new version info
   - Commit with message: `chore: detected upstream <distro> <version>`
   - Push to main
7. If unchanged: exit 0

**Authentication:** GitLab project access token in Secret `gitlab-golden-images-token`

### 2. upstream-versions.json

Tracked file in repo root. Changes to this file trigger the GitLab CI pipeline.

```json
{
  "rocky9": {
    "version": "9.7",
    "build": "20260301.0",
    "checksum": "sha256:abc123...",
    "detected_at": "2026-03-10T12:00:00Z",
    "image_url": "https://dl.rockylinux.org/pub/rocky/9/images/x86_64/Rocky-9-GenericCloud-Base-9.7-20260301.0.x86_64.qcow2"
  },
  "debian12": {
    "version": "12",
    "build": "20260309-2019",
    "checksum": "sha256:def456...",
    "detected_at": "2026-03-10T12:00:00Z",
    "image_url": "https://cloud.debian.org/images/cloud/bookworm/latest/debian-12-generic-amd64.qcow2"
  }
}
```

### 3. GitLab CI Pipeline

**Trigger:** Changes to `upstream-versions.json` on `main`

**Runner:** Dedicated Rocky 9 VM with shell executor

- Pre-installed: Terraform >= 1.5.0, libguestfs, virt-customize, kubectl, curl
- Harvester kubeconfig at known path
- Registered to gitlab.aegisgroup.ch

**Stages:**

```yaml
stages:
  - detect
  - build
  - tag
  - cleanup
```

**detect:** Parse `upstream-versions.json`, determine which distros changed, set build variables.

**build:** Parallel jobs per target (only if the relevant distro changed):

- `build-cis-rocky9` → `./build.sh build cis-rocky9`
- `build-cis-debian12` → `./build.sh build cis-debian12`
- `build-rke2` → `./build.sh build rke2`

Each job passes `IMAGE_NAME_OVERRIDE` env var for version-aware naming.

**tag:** Git-tag the commit (e.g., `rocky9/9.7-20260310`, `debian12/12-20260310`).

**cleanup:** Optional/manual job to remove old images beyond retention count.

### 4. Image Naming

Format: `<distro>-<version>-<build-focus>-<date>`

Examples:

- `rocky-9.7-cis-20260310`
- `rocky-9.7-rke2-20260310`
- `debian-12-cis-20260310`

The version comes from `upstream-versions.json`, the date from build time.

### 5. Build Script Modifications

Existing `build.sh` workflow continues to work unmodified for manual builds.

**Changes:**

- `build.sh`: Accept `IMAGE_NAME_OVERRIDE` env var to override default naming
- `cis/build.sh`: Pass through image name prefix to Terraform via `-var`
- `rke2/build.sh`: Same
- `cis/variables.tf` / `rke2/variables.tf`: Add `image_name_override` variable (Terraform sink — prevents `-var` rejection; override logic is in shell scripts)

### 6. Authentication & Networking

**Argo pods on rke2-prod need:**

- Outbound HTTPS to `dl.rockylinux.org` (Rocky checksums)
- Outbound HTTPS to `cloud.debian.org` (Debian checksums)
- Outbound HTTPS to `gitlab.aegisgroup.ch` (git push)

**Secrets on rke2-prod:**

- `gitlab-golden-images-token`: GitLab project access token with `write_repository` scope

**GitLab Runner VM needs:**

- Access to Harvester API (kubeconfig)
- Access to upstream image URLs / proxy-cache equivalents
- Same network access as current dev VM

### 7. New Files

```
argo/
  watcher-cronworkflow.yaml       # Argo CronWorkflow definition
  scripts/
    check-upstream.sh             # Watcher script
.gitlab-ci.yml                    # GitLab CI pipeline
upstream-versions.json            # Tracked version state file
```

## Out of Scope

- GitHub push (deferred — will add GitHub remote later)
- GitLab Runner VM provisioning (manual setup)
- Argo Workflows installation on rke2-prod (already running)
- Notification on build success/failure (future enhancement)
- Image promotion workflow (future enhancement)
