#!/usr/bin/env bash

set -Eeuo pipefail

APP_NAME="mongodb-cluster"
APP_VERSION="0.1.1"
PACKAGE_PROFILE="integrated"
WORKDIR="/tmp/${APP_NAME}-installer"
CHART_DIR="${WORKDIR}/charts/mongodb"
IMAGE_DIR="${WORKDIR}/images"
IMAGE_INDEX="${IMAGE_DIR}/image-index.tsv"

ACTION="help"
RELEASE_NAME="mongodb-cluster"
NAMESPACE="aict"
ARCHITECTURE="replicaset"
REPLICA_COUNT="3"
REPLICA_SET_NAME="rs0"
ROOT_USER="root"
ROOT_PASSWORD="MongoDB@Passw0rd"
REPLICA_SET_KEY="ArchInfraMongoReplicaSetKey2026"
ENABLE_AUTH="true"
APP_DATABASE=""
APP_USERNAME=""
APP_PASSWORD=""
ENABLE_ARBITER="false"
HIDDEN_REPLICA_COUNT="0"
POD_ANTI_AFFINITY="soft"
VOLUME_PERMISSIONS="true"
STORAGE_CLASS="nfs"
STORAGE_SIZE="20Gi"
RESOURCE_PROFILE="mid"
IMAGE_PULL_POLICY="IfNotPresent"
WAIT_TIMEOUT="10m"
REGISTRY_REPO="sealos.hub:5000/kube4"
REGISTRY_REPO_EXPLICIT="false"
REGISTRY_USER="admin"
REGISTRY_PASS="passw0rd"
SKIP_IMAGE_PREPARE="false"
DELETE_PVC="false"
ENABLE_METRICS="true"
ENABLE_SERVICEMONITOR="true"
SERVICE_MONITOR_NAMESPACE=""
SERVICE_MONITOR_INTERVAL="30s"
SERVICE_MONITOR_SCRAPE_TIMEOUT=""
AUTO_YES="false"

HELM_ARGS=()

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

declare -A IMAGE_DEFAULT_TARGETS=()
declare -A IMAGE_EFFECTIVE_TARGETS=()
declare -A IMAGE_LOAD_REFS=()

log() {
  echo -e "${CYAN}[INFO]${NC} $*"
}

success() {
  echo -e "${GREEN}[OK]${NC} $*"
}

warn() {
  echo -e "${YELLOW}[WARN]${NC} $*" >&2
}

die() {
  echo -e "${RED}[ERROR]${NC} $*" >&2
  exit 1
}

section() {
  echo
  echo -e "${BLUE}${BOLD}============================================================${NC}"
  echo -e "${BLUE}${BOLD}$*${NC}"
  echo -e "${BLUE}${BOLD}============================================================${NC}"
}

program_name() {
  basename "$0"
}

banner() {
  echo
  echo -e "${GREEN}${BOLD}MongoDB Replica Set Offline Installer${NC}"
  echo -e "${CYAN}Version: ${APP_VERSION}${NC}"
  echo -e "${CYAN}Package: ${PACKAGE_PROFILE}${NC}"
}

usage() {
  local cmd="./$(program_name)"
  cat <<EOF
Usage:
  ${cmd} <install|uninstall|status|help> [options] [-- <helm_args>]
  ${cmd} -h|--help

Actions:
  install       Prepare images and install or upgrade the MongoDB Helm release
  uninstall     Uninstall the MongoDB Helm release
  status        Show Helm release and Kubernetes resource status
  help          Show this message

Core options:
  -n, --namespace <ns>                 Namespace, default: ${NAMESPACE}
  --release-name <name>                Helm release name, default: ${RELEASE_NAME}
  --architecture <mode>                replicaset|standalone, default: ${ARCHITECTURE}
  --replica-count <num>                Data-bearing replica count, default: ${REPLICA_COUNT}
  --replica-set-name <name>            Replica set name, default: ${REPLICA_SET_NAME}
  --root-user <name>                   Root username, default: ${ROOT_USER}
  --root-password <pwd>                Root password, default: ${ROOT_PASSWORD}
  --replica-set-key <value>            Replica set key, default: ${REPLICA_SET_KEY}
  --enable-auth                        Enable authentication, default: ${ENABLE_AUTH}
  --disable-auth                       Disable authentication
  --app-database <name>                Optional application database
  --app-username <name>                Optional application user
  --app-password <pwd>                 Optional application password
  --storage-class <name>               StorageClass, default: ${STORAGE_CLASS}
  --storage-size <size>                PVC size per data replica, default: ${STORAGE_SIZE}
  --resource-profile <name>            Resource profile: low|mid|midd|high, default: ${RESOURCE_PROFILE}
  --pod-anti-affinity <mode>           soft|hard|none, default: ${POD_ANTI_AFFINITY}
  --enable-volume-permissions          Enable volumePermissions init container, default: ${VOLUME_PERMISSIONS}
  --disable-volume-permissions         Disable volumePermissions init container
  --enable-arbiter                     Add a MongoDB arbiter pod
  --disable-arbiter                    Disable arbiter, default: ${ENABLE_ARBITER}
  --hidden-replica-count <num>         Number of hidden replicas, default: ${HIDDEN_REPLICA_COUNT}

Monitoring:
  --enable-metrics                     Enable mongodb-exporter sidecar, default: ${ENABLE_METRICS}
  --disable-metrics                    Disable metrics and ServiceMonitor
  --enable-servicemonitor              Create ServiceMonitor and auto-enable metrics, default: ${ENABLE_SERVICEMONITOR}
  --disable-servicemonitor             Disable ServiceMonitor
  --service-monitor-namespace <ns>     Optional namespace for the ServiceMonitor
  --service-monitor-interval <value>   ServiceMonitor interval, default: ${SERVICE_MONITOR_INTERVAL}
  --service-monitor-scrape-timeout <v> ServiceMonitor scrape timeout

Image and rollout:
  --registry <repo-prefix>             Target image repo prefix, default: ${REGISTRY_REPO}
  --registry-user <user>               Registry username, default: ${REGISTRY_USER}
  --registry-password <password>       Registry password, default: <hidden>
  --image-pull-policy <policy>         Always|IfNotPresent|Never, default: ${IMAGE_PULL_POLICY}
  --skip-image-prepare                 Reuse images already present in the target registry
  --wait-timeout <duration>            Helm wait timeout, default: ${WAIT_TIMEOUT}

Advanced:
  --helm-args "<args>"                 Append raw Helm arguments such as "--set foo=bar"
  --                                  Pass all remaining arguments directly to Helm

Other:
  --delete-pvc                         With uninstall, also delete PVCs created by the release
  -y, --yes                            Skip confirmation
  -h, --help                           Show help

Examples:
  ${cmd} install -y
  ${cmd} install --resource-profile high -y
  ${cmd} install --root-password 'MongoDB@Passw0rd' --replica-set-key 'ArchInfraMongoReplicaSetKey2026' -y
  ${cmd} install --app-database appdb --app-username app --app-password 'AppUser@2026' -y
  ${cmd} install --disable-servicemonitor --disable-metrics -y
  ${cmd} install --registry harbor.example.com/kube4 --skip-image-prepare -y
  ${cmd} install --helm-args "--set externalAccess.enabled=true --set externalAccess.service.type=LoadBalancer" -y
  ${cmd} status -n ${NAMESPACE}
  ${cmd} uninstall --delete-pvc -y
EOF
}

cleanup() {
  rm -rf "${WORKDIR}"
}

trap cleanup EXIT

append_helm_args_string() {
  local raw="$1"
  local parsed=()
  [[ -n "${raw}" ]] || return 0
  read -r -a parsed <<<"${raw}"
  [[ ${#parsed[@]} -gt 0 ]] && HELM_ARGS+=("${parsed[@]}")
}

parse_args() {
  if [[ $# -eq 0 ]]; then
    ACTION="help"
    return
  fi

  while [[ $# -gt 0 ]]; do
    case "$1" in
      install|uninstall|status|help)
        ACTION="$1"
        shift
        ;;
      -n|--namespace)
        [[ $# -ge 2 ]] || die "Missing value for $1"
        NAMESPACE="$2"
        shift 2
        ;;
      --release-name)
        [[ $# -ge 2 ]] || die "Missing value for $1"
        RELEASE_NAME="$2"
        shift 2
        ;;
      --architecture)
        [[ $# -ge 2 ]] || die "Missing value for $1"
        ARCHITECTURE="$2"
        shift 2
        ;;
      --replica-count)
        [[ $# -ge 2 ]] || die "Missing value for $1"
        REPLICA_COUNT="$2"
        shift 2
        ;;
      --replica-set-name)
        [[ $# -ge 2 ]] || die "Missing value for $1"
        REPLICA_SET_NAME="$2"
        shift 2
        ;;
      --root-user)
        [[ $# -ge 2 ]] || die "Missing value for $1"
        ROOT_USER="$2"
        shift 2
        ;;
      --root-password)
        [[ $# -ge 2 ]] || die "Missing value for $1"
        ROOT_PASSWORD="$2"
        shift 2
        ;;
      --replica-set-key)
        [[ $# -ge 2 ]] || die "Missing value for $1"
        REPLICA_SET_KEY="$2"
        shift 2
        ;;
      --enable-auth)
        ENABLE_AUTH="true"
        shift
        ;;
      --disable-auth)
        ENABLE_AUTH="false"
        shift
        ;;
      --app-database)
        [[ $# -ge 2 ]] || die "Missing value for $1"
        APP_DATABASE="$2"
        shift 2
        ;;
      --app-username)
        [[ $# -ge 2 ]] || die "Missing value for $1"
        APP_USERNAME="$2"
        shift 2
        ;;
      --app-password)
        [[ $# -ge 2 ]] || die "Missing value for $1"
        APP_PASSWORD="$2"
        shift 2
        ;;
      --storage-class)
        [[ $# -ge 2 ]] || die "Missing value for $1"
        STORAGE_CLASS="$2"
        shift 2
        ;;
      --storage-size)
        [[ $# -ge 2 ]] || die "Missing value for $1"
        STORAGE_SIZE="$2"
        shift 2
        ;;
      --resource-profile)
        [[ $# -ge 2 ]] || die "Missing value for $1"
        RESOURCE_PROFILE="$2"
        shift 2
        ;;
      --pod-anti-affinity)
        [[ $# -ge 2 ]] || die "Missing value for $1"
        POD_ANTI_AFFINITY="$2"
        shift 2
        ;;
      --enable-volume-permissions)
        VOLUME_PERMISSIONS="true"
        shift
        ;;
      --disable-volume-permissions)
        VOLUME_PERMISSIONS="false"
        shift
        ;;
      --enable-arbiter)
        ENABLE_ARBITER="true"
        shift
        ;;
      --disable-arbiter)
        ENABLE_ARBITER="false"
        shift
        ;;
      --hidden-replica-count)
        [[ $# -ge 2 ]] || die "Missing value for $1"
        HIDDEN_REPLICA_COUNT="$2"
        shift 2
        ;;
      --enable-metrics)
        ENABLE_METRICS="true"
        shift
        ;;
      --disable-metrics)
        ENABLE_METRICS="false"
        ENABLE_SERVICEMONITOR="false"
        shift
        ;;
      --enable-servicemonitor)
        ENABLE_SERVICEMONITOR="true"
        ENABLE_METRICS="true"
        shift
        ;;
      --disable-servicemonitor)
        ENABLE_SERVICEMONITOR="false"
        shift
        ;;
      --service-monitor-namespace)
        [[ $# -ge 2 ]] || die "Missing value for $1"
        SERVICE_MONITOR_NAMESPACE="$2"
        shift 2
        ;;
      --service-monitor-interval)
        [[ $# -ge 2 ]] || die "Missing value for $1"
        SERVICE_MONITOR_INTERVAL="$2"
        shift 2
        ;;
      --service-monitor-scrape-timeout)
        [[ $# -ge 2 ]] || die "Missing value for $1"
        SERVICE_MONITOR_SCRAPE_TIMEOUT="$2"
        shift 2
        ;;
      --registry)
        [[ $# -ge 2 ]] || die "Missing value for $1"
        REGISTRY_REPO="$2"
        REGISTRY_REPO_EXPLICIT="true"
        shift 2
        ;;
      --registry-user)
        [[ $# -ge 2 ]] || die "Missing value for $1"
        REGISTRY_USER="$2"
        shift 2
        ;;
      --registry-password)
        [[ $# -ge 2 ]] || die "Missing value for $1"
        REGISTRY_PASS="$2"
        shift 2
        ;;
      --image-pull-policy)
        [[ $# -ge 2 ]] || die "Missing value for $1"
        IMAGE_PULL_POLICY="$2"
        shift 2
        ;;
      --skip-image-prepare)
        SKIP_IMAGE_PREPARE="true"
        shift
        ;;
      --wait-timeout)
        [[ $# -ge 2 ]] || die "Missing value for $1"
        WAIT_TIMEOUT="$2"
        shift 2
        ;;
      --helm-args)
        [[ $# -ge 2 ]] || die "Missing value for $1"
        append_helm_args_string "$2"
        shift 2
        ;;
      --delete-pvc)
        DELETE_PVC="true"
        shift
        ;;
      -y|--yes)
        AUTO_YES="true"
        shift
        ;;
      -h|--help)
        ACTION="help"
        shift
        ;;
      --)
        shift
        while [[ $# -gt 0 ]]; do
          HELM_ARGS+=("$1")
          shift
        done
        ;;
      *)
        die "Unknown argument: $1"
        ;;
    esac
  done
}

is_positive_int() {
  [[ "$1" =~ ^[0-9]+$ ]]
}

normalize_flags() {
  ARCHITECTURE="$(echo "${ARCHITECTURE}" | tr '[:upper:]' '[:lower:]')"
  POD_ANTI_AFFINITY="$(echo "${POD_ANTI_AFFINITY}" | tr '[:upper:]' '[:lower:]')"

  [[ "${ARCHITECTURE}" == "replicaset" || "${ARCHITECTURE}" == "standalone" ]] || die "--architecture must be replicaset or standalone"
  [[ "${POD_ANTI_AFFINITY}" == "soft" || "${POD_ANTI_AFFINITY}" == "hard" || "${POD_ANTI_AFFINITY}" == "none" ]] || die "--pod-anti-affinity must be soft, hard or none"
  is_positive_int "${REPLICA_COUNT}" || die "--replica-count must be a non-negative integer"
  is_positive_int "${HIDDEN_REPLICA_COUNT}" || die "--hidden-replica-count must be a non-negative integer"
  [[ "${REPLICA_COUNT}" != "0" ]] || die "--replica-count must be at least 1"

  if [[ "${ENABLE_SERVICEMONITOR}" == "true" ]]; then
    ENABLE_METRICS="true"
  fi

  case "${RESOURCE_PROFILE,,}" in
    low)
      RESOURCE_PROFILE="low"
      ;;
    mid|midd|middle|medium)
      RESOURCE_PROFILE="mid"
      ;;
    high)
      RESOURCE_PROFILE="high"
      ;;
    *)
      die "Unsupported resource profile: ${RESOURCE_PROFILE}. Expected low|mid|midd|high"
      ;;
  esac

  if [[ -n "${APP_DATABASE}" || -n "${APP_USERNAME}" || -n "${APP_PASSWORD}" ]]; then
    [[ -n "${APP_DATABASE}" && -n "${APP_USERNAME}" && -n "${APP_PASSWORD}" ]] || die "--app-database, --app-username and --app-password must be provided together"
  fi

  if [[ "${ENABLE_AUTH}" != "true" && ( -n "${APP_DATABASE}" || -n "${APP_USERNAME}" || -n "${APP_PASSWORD}" ) ]]; then
    die "Application database/user settings require authentication to be enabled"
  fi

  if [[ "${ARCHITECTURE}" == "standalone" ]]; then
    if [[ "${REPLICA_COUNT}" != "1" ]]; then
      warn "Standalone mode only supports one data replica; forcing --replica-count to 1"
      REPLICA_COUNT="1"
    fi
    if [[ "${ENABLE_ARBITER}" == "true" ]]; then
      warn "Arbiter is only valid for replicaset mode; disabling arbiter"
      ENABLE_ARBITER="false"
    fi
    if [[ "${HIDDEN_REPLICA_COUNT}" != "0" ]]; then
      warn "Hidden replicas are only valid for replicaset mode; forcing hidden replicas to 0"
      HIDDEN_REPLICA_COUNT="0"
    fi
  fi

  if [[ "${ARCHITECTURE}" == "replicaset" && "${REPLICA_COUNT}" == "1" && "${ENABLE_ARBITER}" != "true" && "${HIDDEN_REPLICA_COUNT}" == "0" ]]; then
    warn "A single-node replicaset does not provide failover high availability"
  fi
}

check_deps() {
  command -v helm >/dev/null 2>&1 || die "helm is required"
  command -v kubectl >/dev/null 2>&1 || die "kubectl is required"
  if [[ "${ACTION}" == "install" && "${SKIP_IMAGE_PREPARE}" != "true" ]]; then
    command -v docker >/dev/null 2>&1 || die "docker is required unless --skip-image-prepare is used"
  fi
}

confirm() {
  [[ "${AUTO_YES}" == "true" ]] && return 0

  echo
  echo "Action                  : ${ACTION}"
  echo "Namespace               : ${NAMESPACE}"
  echo "Release                 : ${RELEASE_NAME}"
  echo "Architecture            : ${ARCHITECTURE}"
  echo "Data replicas           : ${REPLICA_COUNT}"
  echo "Replica set             : ${REPLICA_SET_NAME}"
  echo "Root user               : ${ROOT_USER}"
  echo "Authentication          : ${ENABLE_AUTH}"
  echo "Arbiter                 : ${ENABLE_ARBITER}"
  echo "Hidden replicas         : ${HIDDEN_REPLICA_COUNT}"
  echo "StorageClass            : ${STORAGE_CLASS}"
  echo "Storage size            : ${STORAGE_SIZE}"
  echo "Resource profile        : ${RESOURCE_PROFILE}"
  echo "Pod anti-affinity       : ${POD_ANTI_AFFINITY}"
  echo "Volume permissions      : ${VOLUME_PERMISSIONS}"
  echo "Metrics                 : ${ENABLE_METRICS}"
  echo "ServiceMonitor          : ${ENABLE_SERVICEMONITOR}"
  echo "Registry repo           : ${REGISTRY_REPO}"
  echo "Skip image prepare      : ${SKIP_IMAGE_PREPARE}"
  echo "Wait timeout            : ${WAIT_TIMEOUT}"
  if [[ -n "${APP_DATABASE}" ]]; then
    echo "Application DB/User     : ${APP_DATABASE}/${APP_USERNAME}"
  fi
  if [[ "${ACTION}" == "uninstall" ]]; then
    echo "Delete PVC              : ${DELETE_PVC}"
  fi
  if [[ ${#HELM_ARGS[@]} -gt 0 ]]; then
    echo "Helm extra args         : ${HELM_ARGS[*]}"
  fi
  echo
  read -r -p "Continue? [y/N] " answer
  [[ "${answer}" =~ ^[Yy]$ ]] || die "Cancelled"
}

payload_start_offset() {
  local marker_line payload_offset skip_bytes byte_hex
  marker_line="$(awk '/^__PAYLOAD_BELOW__$/ { print NR; exit }' "$0")"
  [[ -n "${marker_line}" ]] || die "Unable to locate embedded payload"
  payload_offset="$(( $(head -n "${marker_line}" "$0" | wc -c | tr -d ' ') + 1 ))"

  skip_bytes=0
  while :; do
    byte_hex="$(dd if="$0" bs=1 skip="$((payload_offset + skip_bytes - 1))" count=1 2>/dev/null | od -An -tx1 | tr -d ' \n')"
    case "${byte_hex}" in
      0a|0d)
        skip_bytes=$((skip_bytes + 1))
        ;;
      "")
        die "Installer payload boundary is invalid"
        ;;
      *)
        break
        ;;
    esac
  done

  printf '%s' "$((payload_offset + skip_bytes))"
}

extract_payload() {
  local payload_offset
  payload_offset="$(payload_start_offset)"

  section "Extract Payload"
  rm -rf "${WORKDIR}"
  mkdir -p "${WORKDIR}"
  tail -c +"${payload_offset}" "$0" | tar -xz -C "${WORKDIR}" || die "failed to extract payload"

  [[ -d "${CHART_DIR}" ]] || die "Missing chart payload"
  [[ -f "${IMAGE_INDEX}" ]] || die "Missing image metadata payload"
}

image_name_from_ref() {
  local ref="$1"
  local name_tag="${ref##*/}"
  echo "${name_tag%%:*}"
}

image_name_tag_from_ref() {
  local ref="$1"
  echo "${ref##*/}"
}

image_ref_without_tag() {
  local ref="$1"
  echo "${ref%:*}"
}

image_registry_part() {
  local ref="$1"
  local without_tag
  without_tag="$(image_ref_without_tag "${ref}")"
  echo "${without_tag%%/*}"
}

image_repository_part() {
  local ref="$1"
  local without_tag
  without_tag="$(image_ref_without_tag "${ref}")"
  echo "${without_tag#*/}"
}

image_tag_part() {
  local ref="$1"
  echo "${ref##*:}"
}

resolve_target_ref() {
  local default_ref="$1"
  if [[ "${REGISTRY_REPO_EXPLICIT}" == "true" ]]; then
    echo "${REGISTRY_REPO}/$(image_name_tag_from_ref "${default_ref}")"
  else
    echo "${default_ref}"
  fi
}

load_image_metadata() {
  while IFS=$'\t' read -r tar_name load_ref default_target_ref _platform; do
    [[ -n "${tar_name}" ]] || continue
    IMAGE_DEFAULT_TARGETS["${tar_name}"]="${default_target_ref}"
    IMAGE_EFFECTIVE_TARGETS["${tar_name}"]="$(resolve_target_ref "${default_target_ref}")"
    IMAGE_LOAD_REFS["${tar_name}"]="${load_ref}"
  done < "${IMAGE_INDEX}"
}

find_image_ref_by_name() {
  local image_name="$1"
  local tar_name default_ref
  for tar_name in "${!IMAGE_DEFAULT_TARGETS[@]}"; do
    default_ref="${IMAGE_DEFAULT_TARGETS[${tar_name}]}"
    if [[ "$(image_name_from_ref "${default_ref}")" == "${image_name}" ]]; then
      echo "${IMAGE_EFFECTIVE_TARGETS[${tar_name}]}"
      return 0
    fi
  done
  return 1
}

docker_login() {
  local registry_host="${REGISTRY_REPO%%/*}"
  [[ -n "${REGISTRY_USER}" && -n "${REGISTRY_PASS}" ]] || return 0

  log "Logging into registry ${registry_host}"
  if ! echo "${REGISTRY_PASS}" | docker login "${registry_host}" -u "${REGISTRY_USER}" --password-stdin >/dev/null 2>&1; then
    warn "docker login failed for ${registry_host}; continuing and letting push decide"
  fi
}

prepare_images() {
  [[ "${SKIP_IMAGE_PREPARE}" == "true" ]] && {
    log "Skipping image prepare because --skip-image-prepare was requested"
    return 0
  }

  docker_login

  local tar_name load_ref default_target_ref target_ref tar_path
  while IFS=$'\t' read -r tar_name load_ref default_target_ref _platform; do
    [[ -n "${tar_name}" ]] || continue
    tar_path="${IMAGE_DIR}/${tar_name}"
    [[ -f "${tar_path}" ]] || die "Missing image tar: ${tar_path}"

    target_ref="${IMAGE_EFFECTIVE_TARGETS[${tar_name}]}"

    if docker image inspect "${target_ref}" >/dev/null 2>&1; then
      log "Reusing local image ${target_ref}"
    else
      log "Loading ${tar_name}"
      docker load -i "${tar_path}" >/dev/null
      if [[ "${load_ref}" != "${target_ref}" ]]; then
        log "Tagging ${load_ref} -> ${target_ref}"
        docker tag "${load_ref}" "${target_ref}"
      fi
    fi

    log "Pushing ${target_ref}"
    docker push "${target_ref}" >/dev/null
  done < "${IMAGE_INDEX}"

  success "Image prepare completed"
}

check_servicemonitor_support() {
  if [[ "${ENABLE_SERVICEMONITOR}" != "true" ]]; then
    return 0
  fi

  if ! kubectl get crd servicemonitors.monitoring.coreos.com >/dev/null 2>&1; then
    warn "ServiceMonitor CRD not found; disabling ServiceMonitor for this install"
    ENABLE_SERVICEMONITOR="false"
  fi
}

preview_command() {
  local rendered=()
  local arg
  for arg in "$@"; do
    rendered+=("$(printf '%q' "${arg}")")
  done
  printf '%s ' "${rendered[@]}"
  echo
}

build_resource_profile_args() {
  RESOURCE_HELM_ARGS=(
    --set "resourcesPreset=none"
    --set "arbiter.resourcesPreset=none"
    --set "hidden.resourcesPreset=none"
    --set "metrics.resourcesPreset=none"
    --set "volumePermissions.resourcesPreset=none"
  )

  case "${RESOURCE_PROFILE}" in
    low)
      RESOURCE_HELM_ARGS+=(
        --set-string "resources.requests.cpu=300m"
        --set-string "resources.requests.memory=768Mi"
        --set-string "resources.limits.cpu=500m"
        --set-string "resources.limits.memory=1Gi"
        --set-string "arbiter.resources.requests.cpu=100m"
        --set-string "arbiter.resources.requests.memory=256Mi"
        --set-string "arbiter.resources.limits.cpu=300m"
        --set-string "arbiter.resources.limits.memory=512Mi"
        --set-string "hidden.resources.requests.cpu=300m"
        --set-string "hidden.resources.requests.memory=768Mi"
        --set-string "hidden.resources.limits.cpu=500m"
        --set-string "hidden.resources.limits.memory=1Gi"
        --set-string "metrics.resources.requests.cpu=50m"
        --set-string "metrics.resources.requests.memory=64Mi"
        --set-string "metrics.resources.limits.cpu=100m"
        --set-string "metrics.resources.limits.memory=128Mi"
        --set-string "volumePermissions.resources.requests.cpu=20m"
        --set-string "volumePermissions.resources.requests.memory=32Mi"
        --set-string "volumePermissions.resources.limits.cpu=100m"
        --set-string "volumePermissions.resources.limits.memory=64Mi"
      )
      ;;
    mid)
      RESOURCE_HELM_ARGS+=(
        --set-string "resources.requests.cpu=500m"
        --set-string "resources.requests.memory=1Gi"
        --set-string "resources.limits.cpu=1"
        --set-string "resources.limits.memory=2Gi"
        --set-string "arbiter.resources.requests.cpu=200m"
        --set-string "arbiter.resources.requests.memory=512Mi"
        --set-string "arbiter.resources.limits.cpu=500m"
        --set-string "arbiter.resources.limits.memory=1Gi"
        --set-string "hidden.resources.requests.cpu=500m"
        --set-string "hidden.resources.requests.memory=1Gi"
        --set-string "hidden.resources.limits.cpu=1"
        --set-string "hidden.resources.limits.memory=2Gi"
        --set-string "metrics.resources.requests.cpu=100m"
        --set-string "metrics.resources.requests.memory=128Mi"
        --set-string "metrics.resources.limits.cpu=200m"
        --set-string "metrics.resources.limits.memory=256Mi"
        --set-string "volumePermissions.resources.requests.cpu=50m"
        --set-string "volumePermissions.resources.requests.memory=64Mi"
        --set-string "volumePermissions.resources.limits.cpu=200m"
        --set-string "volumePermissions.resources.limits.memory=128Mi"
      )
      ;;
    high)
      RESOURCE_HELM_ARGS+=(
        --set-string "resources.requests.cpu=1"
        --set-string "resources.requests.memory=2Gi"
        --set-string "resources.limits.cpu=2"
        --set-string "resources.limits.memory=4Gi"
        --set-string "arbiter.resources.requests.cpu=500m"
        --set-string "arbiter.resources.requests.memory=1Gi"
        --set-string "arbiter.resources.limits.cpu=1"
        --set-string "arbiter.resources.limits.memory=2Gi"
        --set-string "hidden.resources.requests.cpu=1"
        --set-string "hidden.resources.requests.memory=2Gi"
        --set-string "hidden.resources.limits.cpu=2"
        --set-string "hidden.resources.limits.memory=4Gi"
        --set-string "metrics.resources.requests.cpu=200m"
        --set-string "metrics.resources.requests.memory=256Mi"
        --set-string "metrics.resources.limits.cpu=500m"
        --set-string "metrics.resources.limits.memory=512Mi"
        --set-string "volumePermissions.resources.requests.cpu=100m"
        --set-string "volumePermissions.resources.requests.memory=128Mi"
        --set-string "volumePermissions.resources.limits.cpu=300m"
        --set-string "volumePermissions.resources.limits.memory=256Mi"
      )
      ;;
  esac
}

ensure_namespace() {
  if ! kubectl get namespace "${NAMESPACE}" >/dev/null 2>&1; then
    log "Creating namespace ${NAMESPACE}"
    kubectl create namespace "${NAMESPACE}" >/dev/null
  fi
}

pod_anti_affinity_value() {
  if [[ "${POD_ANTI_AFFINITY}" == "none" ]]; then
    echo ""
  else
    echo "${POD_ANTI_AFFINITY}"
  fi
}

replicaset_hosts_csv() {
  local hosts=()
  local i
  for (( i=0; i<REPLICA_COUNT; i++ )); do
    hosts+=("${RELEASE_NAME}-${i}.${RELEASE_NAME}-headless.${NAMESPACE}.svc.cluster.local:27017")
  done
  local joined
  joined="$(IFS=,; echo "${hosts[*]}")"
  echo "${joined}"
}

install_release() {
  local mongodb_image exporter_image kubectl_image os_shell_image nginx_image anti_affinity
  mongodb_image="$(find_image_ref_by_name "mongodb")" || die "Unable to resolve mongodb image"
  exporter_image="$(find_image_ref_by_name "mongodb-exporter")" || die "Unable to resolve mongodb-exporter image"
  kubectl_image="$(find_image_ref_by_name "kubectl")" || die "Unable to resolve kubectl image"
  os_shell_image="$(find_image_ref_by_name "os-shell")" || die "Unable to resolve os-shell image"
  nginx_image="$(find_image_ref_by_name "nginx")" || die "Unable to resolve nginx image"
  anti_affinity="$(pod_anti_affinity_value)"
  build_resource_profile_args

  local helm_cmd=(
    helm upgrade --install "${RELEASE_NAME}" "${CHART_DIR}"
    -n "${NAMESPACE}"
    --create-namespace
    --wait
    --timeout "${WAIT_TIMEOUT}"
    --set "global.security.allowInsecureImages=true"
    --set-string "global.defaultStorageClass=${STORAGE_CLASS}"
    --set-string "image.registry=$(image_registry_part "${mongodb_image}")"
    --set-string "image.repository=$(image_repository_part "${mongodb_image}")"
    --set-string "image.tag=$(image_tag_part "${mongodb_image}")"
    --set-string "image.pullPolicy=${IMAGE_PULL_POLICY}"
    --set-string "architecture=${ARCHITECTURE}"
    --set "replicaCount=${REPLICA_COUNT}"
    --set-string "replicaSetName=${REPLICA_SET_NAME}"
    --set-string "persistence.storageClass=${STORAGE_CLASS}"
    --set "persistence.size=${STORAGE_SIZE}"
    --set-string "podAntiAffinityPreset=${anti_affinity}"
    --set "volumePermissions.enabled=${VOLUME_PERMISSIONS}"
    --set-string "volumePermissions.image.registry=$(image_registry_part "${os_shell_image}")"
    --set-string "volumePermissions.image.repository=$(image_repository_part "${os_shell_image}")"
    --set-string "volumePermissions.image.tag=$(image_tag_part "${os_shell_image}")"
    --set-string "volumePermissions.image.pullPolicy=${IMAGE_PULL_POLICY}"
    --set "metrics.enabled=${ENABLE_METRICS}"
    --set-string "metrics.image.registry=$(image_registry_part "${exporter_image}")"
    --set-string "metrics.image.repository=$(image_repository_part "${exporter_image}")"
    --set-string "metrics.image.tag=$(image_tag_part "${exporter_image}")"
    --set-string "metrics.image.pullPolicy=${IMAGE_PULL_POLICY}"
    --set "metrics.serviceMonitor.enabled=${ENABLE_SERVICEMONITOR}"
    --set-string "metrics.serviceMonitor.interval=${SERVICE_MONITOR_INTERVAL}"
    --set-string "metrics.serviceMonitor.labels.monitoring\\.archinfra\\.io/stack=default"
    --set "externalAccess.enabled=false"
    --set-string "externalAccess.autoDiscovery.image.registry=$(image_registry_part "${kubectl_image}")"
    --set-string "externalAccess.autoDiscovery.image.repository=$(image_repository_part "${kubectl_image}")"
    --set-string "externalAccess.autoDiscovery.image.tag=$(image_tag_part "${kubectl_image}")"
    --set-string "externalAccess.autoDiscovery.image.pullPolicy=${IMAGE_PULL_POLICY}"
    --set-string "externalAccess.dnsCheck.image.registry=$(image_registry_part "${os_shell_image}")"
    --set-string "externalAccess.dnsCheck.image.repository=$(image_repository_part "${os_shell_image}")"
    --set-string "externalAccess.dnsCheck.image.tag=$(image_tag_part "${os_shell_image}")"
    --set-string "externalAccess.dnsCheck.image.pullPolicy=${IMAGE_PULL_POLICY}"
    --set "tls.enabled=false"
    --set-string "tls.image.registry=$(image_registry_part "${nginx_image}")"
    --set-string "tls.image.repository=$(image_repository_part "${nginx_image}")"
    --set-string "tls.image.tag=$(image_tag_part "${nginx_image}")"
    --set-string "tls.image.pullPolicy=${IMAGE_PULL_POLICY}"
    --set "arbiter.enabled=${ENABLE_ARBITER}"
    --set-string "arbiter.podAntiAffinityPreset=${anti_affinity}"
    --set "hidden.enabled=false"
  )

  if [[ "${ENABLE_AUTH}" == "true" ]]; then
    helm_cmd+=(
      --set "auth.enabled=true"
      --set-string "auth.rootUser=${ROOT_USER}"
      --set-string "auth.rootPassword=${ROOT_PASSWORD}"
    )
    if [[ "${ARCHITECTURE}" == "replicaset" ]]; then
      helm_cmd+=(--set-string "auth.replicaSetKey=${REPLICA_SET_KEY}")
    fi
  else
    helm_cmd+=(--set "auth.enabled=false")
  fi

  if [[ "${ARCHITECTURE}" == "standalone" ]]; then
    helm_cmd+=(
      --set "useStatefulSet=true"
      --set-string "service.type=ClusterIP"
    )
  fi

  if [[ "${HIDDEN_REPLICA_COUNT}" != "0" ]]; then
    helm_cmd+=(
      --set "hidden.enabled=true"
      --set-string "hidden.replicaCount=${HIDDEN_REPLICA_COUNT}"
      --set-string "hidden.persistence.storageClass=${STORAGE_CLASS}"
      --set-string "hidden.persistence.size=${STORAGE_SIZE}"
      --set-string "hidden.podAntiAffinityPreset=${anti_affinity}"
    )
  fi

  if [[ -n "${APP_DATABASE}" ]]; then
    helm_cmd+=(
      --set-string "auth.usernames[0]=${APP_USERNAME}"
      --set-string "auth.passwords[0]=${APP_PASSWORD}"
      --set-string "auth.databases[0]=${APP_DATABASE}"
    )
  fi

  if [[ -n "${SERVICE_MONITOR_NAMESPACE}" && "${ENABLE_SERVICEMONITOR}" == "true" ]]; then
    helm_cmd+=(--set-string "metrics.serviceMonitor.namespace=${SERVICE_MONITOR_NAMESPACE}")
  fi

  if [[ -n "${SERVICE_MONITOR_SCRAPE_TIMEOUT}" && "${ENABLE_SERVICEMONITOR}" == "true" ]]; then
    helm_cmd+=(--set-string "metrics.serviceMonitor.scrapeTimeout=${SERVICE_MONITOR_SCRAPE_TIMEOUT}")
  fi

  if [[ ${#RESOURCE_HELM_ARGS[@]} -gt 0 ]]; then
    helm_cmd+=("${RESOURCE_HELM_ARGS[@]}")
  fi

  if [[ ${#HELM_ARGS[@]} -gt 0 ]]; then
    helm_cmd+=("${HELM_ARGS[@]}")
  fi

  section "Helm Command Preview"
  preview_command "${helm_cmd[@]}"

  ensure_namespace
  "${helm_cmd[@]}"
  success "MongoDB install or upgrade completed"
}

show_post_install_info() {
  section "Deployment Result"
  kubectl get pods,sts,svc,pvc -n "${NAMESPACE}" -l "app.kubernetes.io/instance=${RELEASE_NAME}" || true

  if kubectl get crd servicemonitors.monitoring.coreos.com >/dev/null 2>&1; then
    echo
    kubectl get servicemonitor -A -l "app.kubernetes.io/instance=${RELEASE_NAME}" || true
  fi

  echo
  if [[ "${ARCHITECTURE}" == "replicaset" ]]; then
    echo "Replica set members      : $(replicaset_hosts_csv)"
    if [[ "${ENABLE_AUTH}" == "true" ]]; then
      echo "Sample connection        : mongodb://${ROOT_USER}:<password>@$(replicaset_hosts_csv)/admin?replicaSet=${REPLICA_SET_NAME}&authSource=admin"
    else
      echo "Sample connection        : mongodb://$(replicaset_hosts_csv)/admin?replicaSet=${REPLICA_SET_NAME}"
    fi
  else
    if [[ "${ENABLE_AUTH}" == "true" ]]; then
      echo "Sample connection        : mongodb://${ROOT_USER}:<password>@${RELEASE_NAME}.${NAMESPACE}.svc.cluster.local:27017/admin?authSource=admin"
    else
      echo "Sample connection        : mongodb://${RELEASE_NAME}.${NAMESPACE}.svc.cluster.local:27017/admin"
    fi
  fi
}

uninstall_release() {
  if helm status "${RELEASE_NAME}" -n "${NAMESPACE}" >/dev/null 2>&1; then
    helm uninstall "${RELEASE_NAME}" -n "${NAMESPACE}"
    success "Release ${RELEASE_NAME} uninstalled"
  else
    warn "Helm release ${RELEASE_NAME} not found in namespace ${NAMESPACE}"
  fi

  if [[ "${DELETE_PVC}" == "true" ]]; then
    kubectl delete pvc -n "${NAMESPACE}" -l "app.kubernetes.io/instance=${RELEASE_NAME}" --ignore-not-found=true
    success "PVC cleanup requested"
  fi
}

show_status() {
  section "Helm Status"
  helm status "${RELEASE_NAME}" -n "${NAMESPACE}" || warn "Release ${RELEASE_NAME} not found"

  echo
  kubectl get pods,sts,svc,pvc -n "${NAMESPACE}" -l "app.kubernetes.io/instance=${RELEASE_NAME}" || true

  if kubectl get crd servicemonitors.monitoring.coreos.com >/dev/null 2>&1; then
    echo
    kubectl get servicemonitor -A -l "app.kubernetes.io/instance=${RELEASE_NAME}" || true
  fi
}

main() {
  parse_args "$@"
  normalize_flags
  banner

  case "${ACTION}" in
    help)
      usage
      ;;
    install)
      check_deps
      confirm
      extract_payload
      load_image_metadata
      check_servicemonitor_support
      prepare_images
      install_release
      show_post_install_info
      ;;
    uninstall)
      check_deps
      confirm
      uninstall_release
      ;;
    status)
      check_deps
      show_status
      ;;
    *)
      die "Unsupported action: ${ACTION}"
      ;;
  esac
}

main "$@"
exit 0

__PAYLOAD_BELOW__
