#!/usr/bin/env bash

set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEMP_DIR="${ROOT_DIR}/.build-payload"
PAYLOAD_DIR="${TEMP_DIR}/payload"
PAYLOAD_FILE="${TEMP_DIR}/payload.tar.gz"
DIST_DIR="${ROOT_DIR}/dist"
IMAGES_DIR="${ROOT_DIR}/images"
IMAGE_JSON="${IMAGES_DIR}/image.json"
CHART_DIR="${ROOT_DIR}/charts/mongodb"
INSTALLER_TEMPLATE="${ROOT_DIR}/install.sh"
INSTALLER_BASENAME="mongodb-cluster-installer"

ARCH="amd64"
PLATFORM="linux/amd64"
BUILD_ALL_ARCH="false"

RED='\033[0;31m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
NC='\033[0m'

log() {
  echo -e "${CYAN}[INFO]${NC} $*"
}

success() {
  echo -e "${GREEN}[OK]${NC} $*"
}

die() {
  echo -e "${RED}[ERROR]${NC} $*" >&2
  exit 1
}

cleanup() {
  rm -rf "${TEMP_DIR}"
}

trap cleanup EXIT

usage() {
  cat <<'EOF'
Usage:
  ./build.sh [--arch amd64|arm64|all]

Examples:
  ./build.sh --arch amd64
  ./build.sh --arch arm64
  ./build.sh --arch all
EOF
}

normalize_arch() {
  case "$1" in
    amd64|amd|x86_64)
      ARCH="amd64"
      PLATFORM="linux/amd64"
      BUILD_ALL_ARCH="false"
      ;;
    arm64|arm|aarch64)
      ARCH="arm64"
      PLATFORM="linux/arm64"
      BUILD_ALL_ARCH="false"
      ;;
    all)
      BUILD_ALL_ARCH="true"
      ;;
    *)
      die "Unsupported arch: $1"
      ;;
  esac
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --arch|-a)
        [[ $# -ge 2 ]] || die "Missing value for $1"
        normalize_arch "$2"
        shift 2
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        die "Unknown argument: $1"
        ;;
    esac
  done
}

check_requirements() {
  command -v jq >/dev/null 2>&1 || die "jq is required"
  command -v docker >/dev/null 2>&1 || die "docker is required"
  command -v helm >/dev/null 2>&1 || die "helm is required"
  [[ -f "${INSTALLER_TEMPLATE}" ]] || die "install.sh is missing"
  [[ -f "${IMAGE_JSON}" ]] || die "images/image.json is missing"
  [[ -d "${CHART_DIR}" ]] || die "charts/mongodb is missing"
  grep -q '^__PAYLOAD_BELOW__$' "${INSTALLER_TEMPLATE}" || die "install.sh is missing __PAYLOAD_BELOW__ marker"
}

prepare_chart_dependencies() {
  log "Building Helm chart dependencies for mongodb"
  helm dependency build "${CHART_DIR}" >/dev/null
}

prepare_directories() {
  rm -rf "${TEMP_DIR}"
  mkdir -p "${PAYLOAD_DIR}/charts" "${PAYLOAD_DIR}/images" "${DIST_DIR}"
}

image_name_tag_from_ref() {
  local ref="$1"
  echo "${ref##*/}"
}

build_local_load_ref() {
  local default_target_ref="$1"
  local image_name_tag
  image_name_tag="$(image_name_tag_from_ref "${default_target_ref}")"
  echo "archinfra-payload/${image_name_tag}-${ARCH}"
}

prepare_images() {
  local arch="$1"
  local platform="$2"
  local count=0

  : > "${PAYLOAD_DIR}/images/image-index.tsv"
  jq --arg arch "${arch}" '[.[] | select(.arch == $arch)]' "${IMAGE_JSON}" > "${PAYLOAD_DIR}/images/image.json"

  while IFS= read -r item; do
    [[ -n "${item}" ]] || continue

    local pull default_target_ref tar_name load_ref item_platform
    pull="$(jq -r '.pull' <<<"${item}")"
    default_target_ref="$(jq -r '.tag' <<<"${item}")"
    tar_name="$(jq -r '.tar' <<<"${item}")"
    item_platform="$(jq -r '.platform // empty' <<<"${item}")"
    [[ -n "${item_platform}" ]] || item_platform="${platform}"
    load_ref="$(build_local_load_ref "${default_target_ref}")"

    log "Pulling ${pull} for ${item_platform}"
    docker pull --platform "${item_platform}" "${pull}"

    log "Tagging ${pull} -> ${load_ref}"
    docker tag "${pull}" "${load_ref}"

    log "Saving ${load_ref} -> ${PAYLOAD_DIR}/images/${tar_name}"
    docker save -o "${PAYLOAD_DIR}/images/${tar_name}" "${load_ref}"

    printf '%s\t%s\t%s\t%s\n' "${tar_name}" "${load_ref}" "${default_target_ref}" "${item_platform}" >> "${PAYLOAD_DIR}/images/image-index.tsv"
    count=$((count + 1))
  done < <(jq -c --arg arch "${arch}" '.[] | select(.arch == $arch)' "${IMAGE_JSON}")

  (( count > 0 )) || die "No image definitions found for arch=${arch}"
  success "Prepared ${count} image(s) for arch=${arch}"
}

package_payload() {
  local arch="$1"
  local installer_path="${DIST_DIR}/${INSTALLER_BASENAME}-${arch}.run"
  local checksum_path="${installer_path}.sha256"

  log "Copying chart payload"
  cp -R "${CHART_DIR}" "${PAYLOAD_DIR}/charts/"

  log "Creating payload archive"
  tar -C "${PAYLOAD_DIR}" -czf "${PAYLOAD_FILE}" .
  tar -tzf "${PAYLOAD_FILE}" >/dev/null

  log "Assembling installer ${installer_path}"
  cat "${INSTALLER_TEMPLATE}" "${PAYLOAD_FILE}" > "${installer_path}"
  chmod +x "${installer_path}"

  sha256sum "${installer_path}" | awk '{print $1}' > "${checksum_path}"
  success "Generated $(basename "${installer_path}")"
}

show_result() {
  local arch="$1"
  local installer_path="${DIST_DIR}/${INSTALLER_BASENAME}-${arch}.run"
  local checksum_path="${installer_path}.sha256"

  echo
  success "Build complete for ${arch}"
  echo "Installer: ${installer_path}"
  echo "Checksum : $(cat "${checksum_path}")"
}

build_one() {
  local arch="$1"
  local platform="$2"

  ARCH="${arch}"
  PLATFORM="${platform}"

  prepare_directories
  prepare_chart_dependencies
  prepare_images "${arch}" "${platform}"
  package_payload "${arch}"
  show_result "${arch}"
}

main() {
  parse_args "$@"
  check_requirements

  if [[ "${BUILD_ALL_ARCH}" == "true" ]]; then
    build_one "amd64" "linux/amd64"
    build_one "arm64" "linux/arm64"
  else
    build_one "${ARCH}" "${PLATFORM}"
  fi
}

main "$@"
