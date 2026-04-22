#!/usr/bin/env bash
# ----------------------------------------------------------------------------
# Build (and optionally push) the devsys-base image.
#
# Usage:
#   ./build.sh                  # local build, tags devsys-base:latest
#   ./build.sh push <username>  # multi-arch build + push to Docker Hub
# ----------------------------------------------------------------------------
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"

IMAGE_NAME="${IMAGE_NAME:-devsys-base}"
TAG="${TAG:-latest}"

MODE="${1:-local}"

case "$MODE" in
  local)
    echo "[build] local build → ${IMAGE_NAME}:${TAG}"
    docker build -t "${IMAGE_NAME}:${TAG}" .
    echo "[build] done. To use: reference image 'localhost/${IMAGE_NAME}:${TAG}' or '${IMAGE_NAME}:${TAG}' in compose."
    ;;
  push)
    DOCKERHUB_USER="${2:-}"
    if [ -z "$DOCKERHUB_USER" ]; then
      echo "error: Docker Hub username required"
      echo "usage: $0 push <username>"
      exit 1
    fi
    FULL="${DOCKERHUB_USER}/${IMAGE_NAME}:${TAG}"
    echo "[build] multi-arch build + push → ${FULL}"
    echo "[build] (make sure you've run 'docker login' first)"
    docker buildx create --use --name devsys-builder >/dev/null 2>&1 || \
      docker buildx use devsys-builder
    docker buildx build \
      --platform linux/amd64,linux/arm64 \
      --tag "${FULL}" \
      --push .
    echo "[build] pushed. Update compose files to use: ${FULL}"
    ;;
  *)
    echo "usage: $0 [local|push <username>]"
    exit 1
    ;;
esac
