#!/usr/bin/env bash
#
# Build the dify-api and dify-web images for linux/amd64 and push them to
# the private registry defined by ${ALIHUB} in docker/.env.
#
#   dify-api   built from ./api/Dockerfile   (context = repo root)
#   dify-web   built from ./web/Dockerfile   (context = web/)
#
# Usage:
#   scripts/build-images.sh                    # both
#   scripts/build-images.sh api                # subset
#   NO_PUSH=1 scripts/build-images.sh          # build locally, skip push
#   BUILDER=my-builder scripts/build-images.sh # use a specific buildx builder
#
# Requires: docker buildx, and `docker login` already done for ${ALIHUB}.

set -euo pipefail

# --- resolve paths -----------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
ENV_FILE="${REPO_ROOT}/docker/.env"

if [[ ! -f "${ENV_FILE}" ]]; then
    echo "error: ${ENV_FILE} not found. Copy docker/.env.example first." >&2
    exit 1
fi

# --- load .env (only the keys we need, ignore quoting quirks) ----------------
load_var() {
    local key="$1"
    local val
    val="$(grep -E "^${key}=" "${ENV_FILE}" | tail -n1 | cut -d= -f2- || true)"
    val="${val%$'\r'}"
    val="${val%\"}"; val="${val#\"}"
    val="${val%\'}"; val="${val#\'}"
    printf '%s' "${val}"
}

ALIHUB="$(load_var ALIHUB)"
DIFY_API_VERSION="$(load_var DIFY_API_VERSION)"
DIFY_WEB_VERSION="$(load_var DIFY_WEB_VERSION)"

: "${ALIHUB:?ALIHUB not set in ${ENV_FILE}}"
: "${DIFY_API_VERSION:?DIFY_API_VERSION not set in ${ENV_FILE}}"
: "${DIFY_WEB_VERSION:?DIFY_WEB_VERSION not set in ${ENV_FILE}}"

PLATFORM="linux/amd64"
PUSH_FLAG="--push"
if [[ "${NO_PUSH:-0}" == "1" ]]; then
    PUSH_FLAG="--load"
fi

# --- buildx builder ----------------------------------------------------------
BUILDER="${BUILDER:-dify-builder}"
if ! docker buildx inspect "${BUILDER}" >/dev/null 2>&1; then
    echo "==> creating buildx builder '${BUILDER}'"
    docker buildx create --name "${BUILDER}" --driver docker-container --use >/dev/null
else
    docker buildx use "${BUILDER}"
fi
docker buildx inspect --bootstrap >/dev/null

# --- build helper ------------------------------------------------------------
build_from_source() {
    local name="$1" context="$2" dockerfile="$3" version="$4"
    local tag="${ALIHUB}/${name}:${version}"
    echo "==> [build] ${tag}"
    docker buildx build \
        --platform "${PLATFORM}" \
        -f "${dockerfile}" \
        -t "${tag}" \
        ${PUSH_FLAG} \
        "${context}"
}

# --- dispatch ----------------------------------------------------------------
targets=("$@")
if [[ ${#targets[@]} -eq 0 ]]; then
    targets=(api web)
fi

for t in "${targets[@]}"; do
    case "${t}" in
        api)
            build_from_source dify-api "${REPO_ROOT}" \
                "${REPO_ROOT}/api/Dockerfile" "${DIFY_API_VERSION}"
            ;;
        web)
            build_from_source dify-web "${REPO_ROOT}/web" \
                "${REPO_ROOT}/web/Dockerfile" "${DIFY_WEB_VERSION}"
            ;;
        *)
            echo "unknown target: ${t} (want: api | web)" >&2
            exit 2
            ;;
    esac
done

echo "==> done"
