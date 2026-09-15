#!/usr/bin/env bash

set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEMP_DIR="${ROOT_DIR}/.build-payload"
PAYLOAD_DIR="${TEMP_DIR}/payload"
PAYLOAD_FILE="${TEMP_DIR}/payload.tar.gz"
ASSEMBLED_INSTALLER="${TEMP_DIR}/installer-assembled.sh"
DIST_DIR="${ROOT_DIR}/dist"
IMAGES_DIR="${ROOT_DIR}/images"
IMAGE_JSON="${IMAGES_DIR}/image.json"
CHART_DIR="${ROOT_DIR}/charts/mongodb"
INSTALLER_TEMPLATE="${ROOT_DIR}/install.sh"
INSTALLER_OVERLAY="${ROOT_DIR}/scripts/install-overlay.sh"
INSTALLER_BASENAME="mongodb-cluster-installer"

MONGODB_VERSION="8.0.32"
MONGODB_RUNTIME_SOURCE="https://github.com/dlavrenuek/bitnami-mongodb-arm.git"
MONGODB_RUNTIME_SOURCE_COMMIT="29e5d41625b1a629f06d6f3f75c7c354cfd2b1df"
MONGODB_RUNTIME_SOURCE_DIR="8.0/debian-13"
MONGODB_EXPORTER_VERSION="0.51.0"

ARCH="amd64"
PLATFORM="linux/amd64"
BUILD_ALL_ARCH="false"

RED='\033[0;31m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
NC='\033[0m'

log() { echo -e "${CYAN}[INFO]${NC} $*"; }
success() { echo -e "${GREEN}[OK]${NC} $*"; }
die() { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }
cleanup() { rm -rf "${TEMP_DIR}"; }
trap cleanup EXIT

usage() {
  cat <<'EOF'
Usage:
  ./build.sh [--arch amd64|arm64|all]

Build dependencies:
  docker/buildx, git, helm, python3 (or python)
  jq is intentionally NOT required.

Examples:
  ./build.sh --arch amd64
  ./build.sh --arch arm64
  ./build.sh --arch all
EOF
}

normalize_arch() {
  case "$1" in
    amd64|amd|x86_64) ARCH="amd64"; PLATFORM="linux/amd64"; BUILD_ALL_ARCH="false" ;;
    arm64|arm|aarch64) ARCH="arm64"; PLATFORM="linux/arm64"; BUILD_ALL_ARCH="false" ;;
    all) BUILD_ALL_ARCH="true" ;;
    *) die "Unsupported arch: $1" ;;
  esac
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --arch|-a) [[ $# -ge 2 ]] || die "Missing value for $1"; normalize_arch "$2"; shift 2 ;;
      -h|--help) usage; exit 0 ;;
      *) die "Unknown argument: $1" ;;
    esac
  done
}

python_cmd() {
  if command -v python3 >/dev/null 2>&1; then printf 'python3'; else printf 'python'; fi
}

check_requirements() {
  command -v docker >/dev/null 2>&1 || die "docker is required"
  docker buildx version >/dev/null 2>&1 || die "docker buildx is required"
  command -v git >/dev/null 2>&1 || die "git is required to build the pinned MongoDB runtime source"
  command -v helm >/dev/null 2>&1 || die "helm is required"
  (command -v python3 >/dev/null 2>&1 || command -v python >/dev/null 2>&1) || die "python3 or python is required"
  [[ -f "${INSTALLER_TEMPLATE}" ]] || die "install.sh is missing"
  [[ -f "${INSTALLER_OVERLAY}" ]] || die "scripts/install-overlay.sh is missing"
  [[ -f "${IMAGE_JSON}" ]] || die "images/image.json is missing"
  [[ -d "${CHART_DIR}" ]] || die "charts/mongodb is missing"
  grep -q '^__PAYLOAD_BELOW__$' "${INSTALLER_TEMPLATE}" || die "install.sh is missing __PAYLOAD_BELOW__ marker"
}

assemble_installer_template() {
  awk '$0 == "main \"$@\"" {exit} {print}' "${INSTALLER_TEMPLATE}" > "${ASSEMBLED_INSTALLER}"
  printf '\n' >> "${ASSEMBLED_INSTALLER}"
  cat "${INSTALLER_OVERLAY}" >> "${ASSEMBLED_INSTALLER}"
  printf '\n' >> "${ASSEMBLED_INSTALLER}"
  awk 'BEGIN{emit=0} $0 == "main \"$@\"" {emit=1} emit {print}' "${INSTALLER_TEMPLATE}" >> "${ASSEMBLED_INSTALLER}"

  # The help text is emitted from an unquoted heredoc so shell substitutions are
  # intentional for variables, but Markdown-style backticks must never execute.
  sed -i 's/Run `\${cmd} help install`/Run ${cmd} help install/' "${ASSEMBLED_INSTALLER}"

  chmod +x "${ASSEMBLED_INSTALLER}"
  bash -n "${ASSEMBLED_INSTALLER}" || die "assembled installer failed bash syntax validation"
}

prepare_chart_dependencies() {
  log "Building Helm chart dependencies for mongodb"
  helm dependency build "${CHART_DIR}" >/dev/null
}

prepare_directories() {
  rm -rf "${TEMP_DIR}"
  mkdir -p "${PAYLOAD_DIR}/charts" "${PAYLOAD_DIR}/images" "${DIST_DIR}"
}

image_name_tag_from_ref() { local ref="$1"; echo "${ref##*/}"; }
build_local_load_ref() {
  local target_ref="$1" arch="$2"
  local name_tag="$(image_name_tag_from_ref "${target_ref}")"
  echo "archinfra-payload/${name_tag}-${arch}"
}

build_index_for_arch() {
  local arch="$1" output="$2"
  "$(python_cmd)" - "${IMAGE_JSON}" "${arch}" > "${output}" <<'PY'
import json, sys
path, arch = sys.argv[1], sys.argv[2]
with open(path, encoding="utf-8") as fh:
    items = json.load(fh)
matched = [x for x in items if x.get("arch") == arch]
if not matched:
    raise SystemExit(f"no image definitions for arch={arch}")
for item in matched:
    # Use a non-whitespace delimiter so an intentionally empty `pull` field does
    # not collapse adjacent columns when Bash reads locally-built image entries.
    print("|".join([
        item["tar"], item.get("build", "pull"), item.get("pull", ""),
        item["tag"], item.get("platform", f"linux/{arch}")
    ]))
PY
}

prepare_mongodb_runtime_context() {
  local context_dir="${TEMP_DIR}/mongodb-runtime-context"
  local source_dir="${TEMP_DIR}/mongodb-runtime-source"
  [[ -d "${context_dir}" ]] && return 0

  log "Fetching pinned MongoDB Bitnami-compatible runtime source ${MONGODB_RUNTIME_SOURCE_COMMIT}"
  git init -q "${source_dir}"
  git -C "${source_dir}" remote add origin "${MONGODB_RUNTIME_SOURCE}"
  git -C "${source_dir}" fetch -q --depth 1 origin "${MONGODB_RUNTIME_SOURCE_COMMIT}"
  git -C "${source_dir}" checkout -q FETCH_HEAD
  [[ "$(git -C "${source_dir}" rev-parse HEAD)" == "${MONGODB_RUNTIME_SOURCE_COMMIT}" ]] || \
    die "MongoDB runtime source commit verification failed"
  cp -R "${source_dir}/${MONGODB_RUNTIME_SOURCE_DIR}" "${context_dir}"

  # Pinned upstream supplies the Bitnami-compatible lifecycle scripts. MongoDB
  # packages themselves are installed from MongoDB's official 8.0 apt repository.
  sed -i "s/8\\.0\\.9/${MONGODB_VERSION}/g" "${context_dir}/Dockerfile"
  grep -q "ENV MONGO_VERSION ${MONGODB_VERSION}" "${context_dir}/Dockerfile" || \
    die "failed to pin MongoDB runtime to ${MONGODB_VERSION}"
}

verify_mongodb_runtime() {
  local platform="$1" load_ref="$2" output
  output="$(docker run --rm --platform "${platform}" \
    --entrypoint /opt/bitnami/mongodb/bin/mongod "${load_ref}" --version 2>&1)" || {
      printf '%s\n' "${output}" >&2
      die "MongoDB runtime version check failed for ${platform}"
    }
  printf '%s\n' "${output}"
  grep -Eq "db version v?${MONGODB_VERSION}([[:space:]]|$)" <<<"${output}" || \
    die "built MongoDB runtime does not report ${MONGODB_VERSION} for ${platform}"
  success "Verified MongoDB ${MONGODB_VERSION} runtime for ${platform}"
}

build_mongodb_runtime() {
  local platform="$1" load_ref="$2"
  prepare_mongodb_runtime_context
  log "Building MongoDB ${MONGODB_VERSION} runtime for ${platform}"
  docker buildx build --platform "${platform}" --load \
    -t "${load_ref}" "${TEMP_DIR}/mongodb-runtime-context"
  verify_mongodb_runtime "${platform}" "${load_ref}"
}

verify_mongodb_exporter() {
  local platform="$1" load_ref="$2" output
  output="$(docker run --rm --platform "${platform}" \
    --entrypoint /bin/mongodb_exporter "${load_ref}" --version 2>&1)" || {
      printf '%s\n' "${output}" >&2
      die "MongoDB exporter version check failed for ${platform}"
    }
  printf '%s\n' "${output}"
  grep -q "${MONGODB_EXPORTER_VERSION}" <<<"${output}" || \
    die "built MongoDB exporter does not report ${MONGODB_EXPORTER_VERSION} for ${platform}"
  success "Verified MongoDB exporter ${MONGODB_EXPORTER_VERSION} for ${platform}"
}

build_mongodb_exporter() {
  local platform="$1" load_ref="$2"
  log "Building MongoDB exporter ${MONGODB_EXPORTER_VERSION} wrapper for ${platform}"
  docker buildx build --platform "${platform}" --load \
    --build-arg "EXPORTER_IMAGE=percona/mongodb_exporter:${MONGODB_EXPORTER_VERSION}" \
    -t "${load_ref}" "${IMAGES_DIR}/mongodb-exporter"
  verify_mongodb_exporter "${platform}" "${load_ref}"
}

prepare_images() {
  local arch="$1" platform="$2" count=0
  local index="${PAYLOAD_DIR}/images/build-index.psv"
  : > "${PAYLOAD_DIR}/images/image-index.tsv"
  build_index_for_arch "${arch}" "${index}"

  "$(python_cmd)" - "${IMAGE_JSON}" "${arch}" > "${PAYLOAD_DIR}/images/image.json" <<'PY'
import json, sys
with open(sys.argv[1], encoding="utf-8") as fh:
    items = json.load(fh)
json.dump([x for x in items if x.get("arch") == sys.argv[2]], sys.stdout, indent=2)
print()
PY

  while IFS='|' read -r tar_name build_kind pull target_ref item_platform; do
    [[ -n "${tar_name}" ]] || continue
    [[ -n "${target_ref}" ]] || die "image ${tar_name} is missing target tag"
    [[ -n "${item_platform}" ]] || item_platform="${platform}"
    local load_ref="$(build_local_load_ref "${target_ref}" "${arch}")"

    case "${build_kind}" in
      mongodb-runtime) build_mongodb_runtime "${item_platform}" "${load_ref}" ;;
      mongodb-exporter) build_mongodb_exporter "${item_platform}" "${load_ref}" ;;
      pull)
        [[ -n "${pull}" ]] || die "pull image ${tar_name} is missing pull reference"
        log "Pulling ${pull} for ${item_platform}"
        docker pull --platform "${item_platform}" "${pull}"
        docker tag "${pull}" "${load_ref}"
        ;;
      *) die "unsupported image build kind: ${build_kind}" ;;
    esac

    log "Saving ${load_ref} -> ${tar_name} (target ${target_ref})"
    docker save -o "${PAYLOAD_DIR}/images/${tar_name}" "${load_ref}"
    printf '%s\t%s\t%s\t%s\n' \
      "${tar_name}" "${load_ref}" "${target_ref}" "${item_platform}" >> "${PAYLOAD_DIR}/images/image-index.tsv"
    count=$((count + 1))
  done < "${index}"

  (( count > 0 )) || die "No image definitions found for arch=${arch}"
  success "Prepared ${count} image(s) for arch=${arch}"
}

package_payload() {
  local arch="$1" installer_path="${DIST_DIR}/${INSTALLER_BASENAME}-${arch}.run"
  cp -R "${CHART_DIR}" "${PAYLOAD_DIR}/charts/"
  tar -C "${PAYLOAD_DIR}" -czf "${PAYLOAD_FILE}" .
  tar -tzf "${PAYLOAD_FILE}" >/dev/null
  cat "${ASSEMBLED_INSTALLER}" "${PAYLOAD_FILE}" > "${installer_path}"
  chmod +x "${installer_path}"
  sha256sum "${installer_path}" > "${installer_path}.sha256"
  success "Generated $(basename "${installer_path}")"
}

build_one() {
  local arch="$1" platform="$2"
  prepare_directories
  assemble_installer_template
  prepare_images "${arch}" "${platform}"
  package_payload "${arch}"
}

main() {
  parse_args "$@"
  check_requirements
  prepare_chart_dependencies
  if [[ "${BUILD_ALL_ARCH}" == "true" ]]; then
    build_one amd64 linux/amd64
    build_one arm64 linux/arm64
  else
    build_one "${ARCH}" "${PLATFORM}"
  fi
  success "All requested MongoDB installers built"
}

main "$@"
