#!/usr/bin/env bash
#
# Pull every `image:` referenced by docker/docker-compose.yaml, retag it under
# a private namespace, and push. Intended for mirroring upstream images into
# an Aliyun ARM registry.
#
# Usage:
#   scripts/mirror-images.sh                       # pull + tag + push all
#   scripts/mirror-images.sh --dry-run             # only print what it would do
#   scripts/mirror-images.sh --no-push             # pull + tag, skip push
#   scripts/mirror-images.sh langgenius/dify-api:1.15.0  # only the given refs
#
# Environment overrides:
#   TARGET_REGISTRY   default: registry.cn-shenzhen.aliyuncs.com/vanchans_arm
#   COMPOSE_FILE      default: <repo>/docker/docker-compose.yaml
#
# `docker pull` is called without --platform, so the host's default architecture
# is used (run this script on an arm64 host to mirror arm64 images).
#
# Requires: docker, and `docker login` already done for TARGET_REGISTRY.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

TARGET_REGISTRY="${TARGET_REGISTRY:-registry.cn-shenzhen.aliyuncs.com/vanchans_arm}"
COMPOSE_FILE="${COMPOSE_FILE:-${REPO_ROOT}/docker/docker-compose.yaml}"

DRY_RUN=0
DO_PUSH=1
FILTERS=()

for arg in "$@"; do
    case "${arg}" in
        --dry-run)  DRY_RUN=1 ;;
        --no-push)  DO_PUSH=0 ;;
        -h|--help)
            sed -n '3,20p' "$0"; exit 0 ;;
        *)          FILTERS+=("${arg}") ;;
    esac
done

if [[ ! -f "${COMPOSE_FILE}" ]]; then
    echo "error: compose file not found: ${COMPOSE_FILE}" >&2
    exit 1
fi

# --- extract image references from docker-compose.yaml -----------------------
# Grabs the token after `image:`, keeps the original ref (registry/org/name:tag).
# Uses a while-read loop for bash 3 (macOS) compatibility.
IMAGES=()
while IFS= read -r line; do
    [[ -n "${line}" ]] && IMAGES+=("${line}")
done < <(
    grep -E '^[[:space:]]*image:[[:space:]]+[^[:space:]]+' "${COMPOSE_FILE}" \
        | awk '{print $2}' \
        | sort -u
)

if [[ ${#IMAGES[@]} -eq 0 ]]; then
    echo "error: no image: references found in ${COMPOSE_FILE}" >&2
    exit 1
fi

# --- optional filter ---------------------------------------------------------
if [[ ${#FILTERS[@]} -gt 0 ]]; then
    filtered=()
    for img in "${IMAGES[@]}"; do
        for f in "${FILTERS[@]}"; do
            if [[ "${img}" == *"${f}"* ]]; then
                filtered+=("${img}"); break
            fi
        done
    done
    IMAGES=("${filtered[@]}")
fi

# --- helpers -----------------------------------------------------------------
# Turn `registry/org/name:tag` (or `org/name`, `name:tag`, `name`) into
# `<basename>:<tag>`, where tag defaults to `latest`.
target_ref() {
    local src="$1"
    local name_tag="${src##*/}"          # drop everything up to last slash
    if [[ "${name_tag}" != *:* ]]; then
        name_tag="${name_tag}:latest"
    fi
    printf '%s/%s' "${TARGET_REGISTRY}" "${name_tag}"
}

run() {
    echo "+ $*"
    if [[ "${DRY_RUN}" -eq 0 ]]; then
        "$@"
    fi
}

# --- main loop ---------------------------------------------------------------
echo "==> target registry : ${TARGET_REGISTRY}"
echo "==> compose file    : ${COMPOSE_FILE}"
echo "==> images (${#IMAGES[@]}):"
for img in "${IMAGES[@]}"; do echo "    - ${img}"; done
echo

failed=()
for src in "${IMAGES[@]}"; do
    dst="$(target_ref "${src}")"
    echo "==> ${src}  ->  ${dst}"
    if ! run docker pull "${src}"; then
        failed+=("${src} (pull)"); continue
    fi
    if ! run docker tag "${src}" "${dst}"; then
        failed+=("${src} (tag)"); continue
    fi
    if [[ "${DO_PUSH}" -eq 1 ]]; then
        if ! run docker push "${dst}"; then
            failed+=("${dst} (push)"); continue
        fi
    fi
done

echo
if [[ ${#failed[@]} -eq 0 ]]; then
    echo "==> done. mirrored ${#IMAGES[@]} image(s)."
else
    echo "==> finished with ${#failed[@]} failure(s):" >&2
    for f in "${failed[@]}"; do echo "    - ${f}" >&2; done
    exit 1
fi
