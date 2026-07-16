#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# deploy.sh  —  build image locally, ship it to the VPS, reload the service.
#
# Usage:
#   ./deploy/deploy.sh
#
# Prerequisites (local machine):
#   - Docker installed and running
#   - SSH access to the VPS: ssh root@supdf.suplo.my.id (or your user)
#
# Run once before first deploy:
#   chmod +x deploy/deploy.sh
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

# Guard: Docker must be available. If running in WSL without Docker Desktop
# integration, print a helpful error and exit.
if ! command -v docker &>/dev/null; then
  echo "ERROR: docker not found."
  echo "If you are in WSL, run this script from PowerShell or Command Prompt instead."
  echo "Docker Desktop on Windows is not accessible from WSL by default."
  echo "See: https://docs.docker.com/go/wsl2/"
  exit 1
fi

VPS_USER="root"                        # change if you use a non-root SSH user
VPS_HOST="76.13.22.198"
VPS_DIR="/opt/pdf-finalizer"
IMAGE_NAME="pdf-finalizer"
IMAGE_TAG="latest"
TAR_FILE="pdf-finalizer.tar"

echo "──── [1/5] Building Docker image (linux/amd64 cross-compile) ────"

# Ensure buildx is available and a cross-platform builder exists.
# Windows ARM64 → Linux x86_64 requires QEMU emulation, which the
# docker-container driver provides automatically.
if ! docker buildx inspect pdfbuilder >/dev/null 2>&1; then
  docker buildx create --name pdfbuilder --driver docker-container --use
else
  docker buildx use pdfbuilder
fi

docker buildx build \
  --platform linux/amd64 \
  --tag "${IMAGE_NAME}:${IMAGE_TAG}" \
  --load \
  .

# Restore default builder so later `docker save` works against the default context.
# Newer Docker Desktop requires `docker context use default` when buildx
# use fails with "run `docker context use default` to switch".
if ! docker buildx use default 2>/dev/null; then
  docker context use default
fi

echo "──── [2/5] Exporting image to ${TAR_FILE} ────"
docker save "${IMAGE_NAME}:${IMAGE_TAG}" -o "${TAR_FILE}"

echo "──── [3/5] Copying image to VPS (${VPS_HOST}) ────"
scp "${TAR_FILE}" "${VPS_USER}@${VPS_HOST}:${VPS_DIR}/"

echo "──── [4/5] Copying compose + nginx configs to VPS ────"
scp docker-compose.yml "${VPS_USER}@${VPS_HOST}:${VPS_DIR}/"
scp -r nginx            "${VPS_USER}@${VPS_HOST}:${VPS_DIR}/"

echo "──── [5/5] Loading image and restarting service on VPS ────"
ssh "${VPS_USER}@${VPS_HOST}" bash <<EOF
  set -euo pipefail
  cd ${VPS_DIR}
  docker load -i ${TAR_FILE}
  docker compose up -d --force-recreate pdf-finalizer nginx
  echo "Done. Container status:"
  docker compose ps
EOF

echo ""
echo "✓ Deploy complete. Service running at https://supdf.suplo.my.id"
echo "  Test: curl https://supdf.suplo.my.id/api/v1/forms/ping"
