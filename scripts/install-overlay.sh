#!/usr/bin/env bash
# shellcheck shell=bash
# Archinfra MongoDB delivery overlay injected into the generated .run installer.

APP_VERSION="0.2.0"
RESOURCE_PROFILE="standard"
REGISTRY_USER=""
REGISTRY_PASS=""
ROOT_PASSWORD=""
REPLICA_SET_KEY=""
AUTH_SECRET="mongodb-auth"
ROOT_PASSWORD_EXPLICIT="false"
REPLICA_SET_KEY_EXPLICIT="false"
STORAGE_SIZE_EXPLICIT="false"
REPLICA_COUNT_EXPLICIT="false"
HELP_TOPIC="overview"
HELM_STORAGE_SIZE=""

# Preserve proven legacy plumbing and replace only the delivery contract.
eval "$(declare -f parse_args | sed '1s/^parse_args /legacy_parse_args /')"
eval "$(declare -f normalize_flags | sed '1s/^normalize_flags /legacy_normalize_flags /')"
eval "$(declare -f install_release | sed '1s/^install_release /legacy_install_release /')"
eval "$(declare -f uninstall_release | sed '1s/^uninstall_release /legacy_uninstall_release /')"
eval "$(declare -f show_status | sed '1s/^show_status /legacy_show_status /')"

show_help_overview() {
  local cmd="./$(program_name)"
  cat <<EOF
MongoDB Cluster Offline Installer ${APP_VERSION}

Usage:
  ${cmd} <install|uninstall|status|help> [options] [-- <helm_args>]
  ${cmd} help <overview|install|params|examples|architecture>

Delivery baseline:
  MongoDB                  8.0.32
  Default architecture     replicaset
  Default replicas         3 data-bearing members
  Authentication           ON
  Managed credential       Secret/${AUTH_SECRET}
  External access          OFF
  Service                  ClusterIP
  Metrics                  ON
  ServiceMonitor           ON when CRD exists
  PrometheusRule           ON when CRD exists
  Resource profile         standard
  Backup                   deferred / chart backup disabled

Canonical profiles only:
  lite       1 replica,  limit 1C/2Gi per data node,   new PVC 20Gi
  standard   3 replicas, limit 2C/8Gi per data node,   new PVC 100Gi (default)
  large      3 replicas, limit 4C/16Gi per data node,  new PVC 500Gi

Legacy low/mid/high aliases are intentionally rejected.
Run `${cmd} help install` for the recommended standard command.
EOF
}

show_help_install() {
  local cmd="./$(program_name)"
  cat <<EOF
Recommended standard installation:

  ${cmd} install \
    --namespace aict \
    --architecture replicaset \
    --resource-profile standard \
    --storage-class ceph-rbd \
    --storage-size 100Gi \
    --enable-auth \
    --enable-metrics \
    --enable-servicemonitor \
    --enable-prometheusrule \
    --pod-anti-affinity hard \
    --wait-timeout 15m \
    -y

Standard profile:
  data replicas      3
  per-node request   1 CPU / 4Gi
  per-node limit     2 CPU / 8Gi
  new PVC            100Gi per data replica
  exporter           Percona mongodb_exporter 0.51.0, compatibility mode ON

Credentials:
  --root-password and --replica-set-key are optional on a NEW install.
  If omitted, strong random values are generated and stored in Secret/${AUTH_SECRET}.
  Credentials are not rendered into the Helm command preview.

Existing installations:
  The installer reuses Secret/${AUTH_SECRET}. For pre-0.2.0 releases it first
  attempts to migrate the existing chart Secret safely. If the current
  credentials cannot be recovered, explicit current credentials are required.

PVC behavior:
  Profile size is used only for a new install. Existing StatefulSet templates
  retain their original request. An explicit --storage-size attempts PVC
  expansion separately; Kubernetes/StorageClass must support expansion and
  shrinking is never supported.
EOF
}

show_help_params() {
  cat <<EOF
Core:
  -n, --namespace <ns>                 Default: ${NAMESPACE}
  --release-name <name>                Default: ${RELEASE_NAME}
  --architecture replicaset|standalone Default: replicaset
  --replica-count <num>                Profile default unless explicitly set
  --replica-set-name <name>            Default: ${REPLICA_SET_NAME}
  --resource-profile <name>            lite|standard|large; default: standard

Security:
  --enable-auth / --disable-auth        Authentication default: enabled
  --auth-secret <name>                 Default: ${AUTH_SECRET}
  --root-user <name>                   Default: root
  --root-password <pwd>                Optional on new install; random if omitted
  --replica-set-key <value>            Optional on new replica set; random if omitted
  external access                      Disabled by delivery baseline
  TLS                                  Not enabled by default; explicit future hardening item

Storage:
  --storage-class <name>               Default compatibility value: ${STORAGE_CLASS}
  --storage-size <size>                Overrides profile default for new install / expansion
  lite                                 20Gi per data replica
  standard                             100Gi per data replica
  large                                500Gi per data replica

Resources per data-bearing MongoDB pod:
  lite       request 500m/1Gi  limit 1C/2Gi
  standard   request 1C/4Gi    limit 2C/8Gi
  large      request 2C/8Gi    limit 4C/16Gi

Monitoring:
  --enable-metrics / --disable-metrics
  --enable-servicemonitor / --disable-servicemonitor
  --enable-prometheusrule / --disable-prometheusrule
  --service-monitor-namespace <ns>
  --service-monitor-interval <value>   Default: ${SERVICE_MONITOR_INTERVAL}
  --service-monitor-scrape-timeout <v>

Topology / scheduling:
  --pod-anti-affinity soft|hard|none
  --enable-arbiter / --disable-arbiter
  --hidden-replica-count <num>
  --enable-volume-permissions / --disable-volume-permissions

Registry:
  --registry <repo-prefix>             Default: ${REGISTRY_REPO}
  --registry-user <user>               No fixed default
  --registry-password <password>       No fixed default
  --skip-image-prepare

Lifecycle:
  --wait-timeout <duration>
  --delete-pvc                         Destructive: delete data PVCs and managed auth Secret
  -y, --yes
EOF
}

show_help_examples() {
  local cmd="./$(program_name)"
  cat <<EOF
Examples:
  # Recommended production baseline
  ${cmd} install --resource-profile standard --storage-class ceph-rbd --storage-size 100Gi --pod-anti-affinity hard -y

  # Small test environment (not HA)
  ${cmd} install --resource-profile lite --storage-class nfs -y

  # Larger data nodes
  ${cmd} install --resource-profile large --storage-class ceph-rbd -y

  # Explicit credentials instead of generated values
  ${cmd} install --root-password '<CURRENT_OR_NEW_PASSWORD>' --replica-set-key '<CURRENT_OR_NEW_KEY>' -y

  # Expand existing PVCs; StorageClass must allow volume expansion
  ${cmd} install --storage-size 300Gi -y

  # Retrieve generated root password
  kubectl get secret -n ${NAMESPACE} ${AUTH_SECRET} -o jsonpath='{.data.mongodb-root-password}' | base64 -d; echo

  # Print replica-set connection seed list
  ${cmd} status -n ${NAMESPACE}
EOF
}

show_help_architecture() {
  cat <<EOF
Architecture guidance:
  replicaset   Standard delivery. Default profile uses 3 data-bearing members.
  standalone   Compatibility/dev mode only; no replica-set high availability.

Networking:
  externalAccess.enabled=false is enforced by the installer baseline.
  MongoDB is reachable through Kubernetes services only unless raw Helm args are
  deliberately used to change the exposure model.

Scheduling:
  Standard production recommendation: --pod-anti-affinity hard when the cluster
  has enough worker nodes. Use soft only where node count/capacity requires it.

SecurityContext:
  The vendored chart already runs MongoDB as non-root, drops Linux capabilities,
  disables privilege escalation and uses RuntimeDefault seccomp.
EOF
}

usage() {
  case "${HELP_TOPIC}" in
    overview) show_help_overview ;;
    install) show_help_install ;;
    params) show_help_params ;;
    examples) show_help_examples ;;
    architecture) show_help_architecture ;;
    *) die "Unknown help topic: ${HELP_TOPIC}" ;;
  esac
}

parse_args() {
  local passthrough=()
  while [[ $# -gt 0 ]]; do
    case "$1" in
      help)
        passthrough+=("help")
        if [[ $# -ge 2 ]]; then
          case "$2" in
            overview|install|params|examples|architecture)
              HELP_TOPIC="$2"
              shift 2
              continue
              ;;
          esac
        fi
        shift
        ;;
      --auth-secret)
        [[ $# -ge 2 ]] || die "--auth-secret requires a value"
        AUTH_SECRET="$2"
        shift 2
        ;;
      --root-password)
        [[ $# -ge 2 ]] || die "--root-password requires a value"
        ROOT_PASSWORD="$2"
        ROOT_PASSWORD_EXPLICIT="true"
        shift 2
        ;;
      --replica-set-key)
        [[ $# -ge 2 ]] || die "--replica-set-key requires a value"
        REPLICA_SET_KEY="$2"
        REPLICA_SET_KEY_EXPLICIT="true"
        shift 2
        ;;
      --storage-size)
        [[ $# -ge 2 ]] || die "--storage-size requires a value"
        STORAGE_SIZE="$2"
        STORAGE_SIZE_EXPLICIT="true"
        shift 2
        ;;
      --replica-count)
        [[ $# -ge 2 ]] || die "--replica-count requires a value"
        REPLICA_COUNT="$2"
        REPLICA_COUNT_EXPLICIT="true"
        shift 2
        ;;
      --)
        passthrough+=("--")
        shift
        while [[ $# -gt 0 ]]; do passthrough+=("$1"); shift; done
        ;;
      *)
        passthrough+=("$1")
        shift
        ;;
    esac
  done
  legacy_parse_args "${passthrough[@]}"
}

normalize_flags() {
  local canonical="${RESOURCE_PROFILE,,}"
  case "${canonical}" in
    lite|standard|large) ;;
    *) die "resource-profile 仅支持 lite|standard|large" ;;
  esac

  # Let the legacy validator process the rest without preserving old profile names.
  case "${canonical}" in
    lite) RESOURCE_PROFILE="low" ;;
    standard) RESOURCE_PROFILE="mid" ;;
    large) RESOURCE_PROFILE="high" ;;
  esac
  legacy_normalize_flags
  RESOURCE_PROFILE="${canonical}"

  case "${RESOURCE_PROFILE}" in
    lite)
      [[ "${REPLICA_COUNT_EXPLICIT}" == "true" ]] || REPLICA_COUNT="1"
      [[ "${STORAGE_SIZE_EXPLICIT}" == "true" ]] || STORAGE_SIZE="20Gi"
      ;;
    standard)
      [[ "${REPLICA_COUNT_EXPLICIT}" == "true" ]] || REPLICA_COUNT="3"
      [[ "${STORAGE_SIZE_EXPLICIT}" == "true" ]] || STORAGE_SIZE="100Gi"
      ;;
    large)
      [[ "${REPLICA_COUNT_EXPLICIT}" == "true" ]] || REPLICA_COUNT="3"
      [[ "${STORAGE_SIZE_EXPLICIT}" == "true" ]] || STORAGE_SIZE="500Gi"
      ;;
  esac

  [[ "${ARCHITECTURE}" != "standalone" || "${REPLICA_COUNT_EXPLICIT}" != "true" || "${REPLICA_COUNT}" == "1" ]] || \
    die "standalone architecture only supports replica-count=1"
  [[ "${ARCHITECTURE}" != "standalone" ]] || REPLICA_COUNT="1"
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
    lite)
      RESOURCE_HELM_ARGS+=(
        --set-string resources.requests.cpu=500m --set-string resources.requests.memory=1Gi
        --set-string resources.limits.cpu=1 --set-string resources.limits.memory=2Gi
        --set-string hidden.resources.requests.cpu=500m --set-string hidden.resources.requests.memory=1Gi
        --set-string hidden.resources.limits.cpu=1 --set-string hidden.resources.limits.memory=2Gi
        --set-string arbiter.resources.requests.cpu=100m --set-string arbiter.resources.requests.memory=256Mi
        --set-string arbiter.resources.limits.cpu=300m --set-string arbiter.resources.limits.memory=512Mi
        --set-string metrics.resources.requests.cpu=50m --set-string metrics.resources.requests.memory=64Mi
        --set-string metrics.resources.limits.cpu=100m --set-string metrics.resources.limits.memory=128Mi
        --set-string volumePermissions.resources.requests.cpu=20m --set-string volumePermissions.resources.requests.memory=32Mi
        --set-string volumePermissions.resources.limits.cpu=100m --set-string volumePermissions.resources.limits.memory=64Mi
      )
      ;;
    standard)
      RESOURCE_HELM_ARGS+=(
        --set-string resources.requests.cpu=1 --set-string resources.requests.memory=4Gi
        --set-string resources.limits.cpu=2 --set-string resources.limits.memory=8Gi
        --set-string hidden.resources.requests.cpu=1 --set-string hidden.resources.requests.memory=4Gi
        --set-string hidden.resources.limits.cpu=2 --set-string hidden.resources.limits.memory=8Gi
        --set-string arbiter.resources.requests.cpu=200m --set-string arbiter.resources.requests.memory=512Mi
        --set-string arbiter.resources.limits.cpu=500m --set-string arbiter.resources.limits.memory=1Gi
        --set-string metrics.resources.requests.cpu=100m --set-string metrics.resources.requests.memory=128Mi
        --set-string metrics.resources.limits.cpu=200m --set-string metrics.resources.limits.memory=256Mi
        --set-string volumePermissions.resources.requests.cpu=50m --set-string volumePermissions.resources.requests.memory=64Mi
        --set-string volumePermissions.resources.limits.cpu=200m --set-string volumePermissions.resources.limits.memory=128Mi
      )
      ;;
    large)
      RESOURCE_HELM_ARGS+=(
        --set-string resources.requests.cpu=2 --set-string resources.requests.memory=8Gi
        --set-string resources.limits.cpu=4 --set-string resources.limits.memory=16Gi
        --set-string hidden.resources.requests.cpu=2 --set-string hidden.resources.requests.memory=8Gi
        --set-string hidden.resources.limits.cpu=4 --set-string hidden.resources.limits.memory=16Gi
        --set-string arbiter.resources.requests.cpu=500m --set-string arbiter.resources.requests.memory=1Gi
        --set-string arbiter.resources.limits.cpu=1 --set-string arbiter.resources.limits.memory=2Gi
        --set-string metrics.resources.requests.cpu=200m --set-string metrics.resources.requests.memory=256Mi
        --set-string metrics.resources.limits.cpu=500m --set-string metrics.resources.limits.memory=512Mi
        --set-string volumePermissions.resources.requests.cpu=100m --set-string volumePermissions.resources.requests.memory=128Mi
        --set-string volumePermissions.resources.limits.cpu=300m --set-string volumePermissions.resources.limits.memory=256Mi
      )
      ;;
  esac
}

generate_hex_secret() {
  local bytes="$1"
  od -An -N"${bytes}" -tx1 /dev/urandom | tr -d ' \n'
}

secret_value() {
  local secret="$1" key="$2"
  kubectl get secret -n "${NAMESPACE}" "${secret}" -o "jsonpath={.data.${key}}" 2>/dev/null | base64 -d 2>/dev/null || true
}

find_legacy_auth_secret() {
  local candidate
  candidate="$(kubectl get secret -n "${NAMESPACE}" -l "app.kubernetes.io/instance=${RELEASE_NAME},app.kubernetes.io/component=mongodb" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
  [[ -n "${candidate}" ]] || candidate="${RELEASE_NAME}"
  if kubectl get secret -n "${NAMESPACE}" "${candidate}" >/dev/null 2>&1; then printf '%s' "${candidate}"; fi
}

prepare_auth_secret() {
  [[ "${ENABLE_AUTH}" == "true" ]] || return 0
  ensure_namespace

  local existing_root="" existing_key="" existing_passwords="" existing_metrics="" legacy_secret="" release_exists="false"
  helm status "${RELEASE_NAME}" -n "${NAMESPACE}" >/dev/null 2>&1 && release_exists="true"

  if kubectl get secret -n "${NAMESPACE}" "${AUTH_SECRET}" >/dev/null 2>&1; then
    existing_root="$(secret_value "${AUTH_SECRET}" mongodb-root-password)"
    existing_key="$(secret_value "${AUTH_SECRET}" mongodb-replica-set-key)"
    existing_passwords="$(secret_value "${AUTH_SECRET}" mongodb-passwords)"
    existing_metrics="$(secret_value "${AUTH_SECRET}" mongodb-metrics-password)"
  elif [[ "${release_exists}" == "true" ]]; then
    legacy_secret="$(find_legacy_auth_secret)"
    if [[ -n "${legacy_secret}" ]]; then
      existing_root="$(secret_value "${legacy_secret}" mongodb-root-password)"
      existing_key="$(secret_value "${legacy_secret}" mongodb-replica-set-key)"
      existing_passwords="$(secret_value "${legacy_secret}" mongodb-passwords)"
      existing_metrics="$(secret_value "${legacy_secret}" mongodb-metrics-password)"
      [[ -n "${existing_root}" ]] && log "Migrating existing MongoDB credentials from Secret/${legacy_secret} to Secret/${AUTH_SECRET}"
    fi
  fi

  if [[ -n "${existing_root}" ]]; then
    [[ "${ROOT_PASSWORD_EXPLICIT}" != "true" || "${ROOT_PASSWORD}" == "${existing_root}" ]] || \
      die "Secret/${AUTH_SECRET} 中 root 密码与 --root-password 不一致；普通 install 不执行密码轮换"
    ROOT_PASSWORD="${existing_root}"
  elif [[ "${ROOT_PASSWORD_EXPLICIT}" != "true" ]]; then
    [[ "${release_exists}" != "true" ]] || die "已有 MongoDB release 但无法恢复当前 root 密码；请提供 --root-password '<CURRENT_PASSWORD>'"
    ROOT_PASSWORD="$(generate_hex_secret 24)"
  fi

  if [[ "${ARCHITECTURE}" == "replicaset" ]]; then
    if [[ -n "${existing_key}" ]]; then
      [[ "${REPLICA_SET_KEY_EXPLICIT}" != "true" || "${REPLICA_SET_KEY}" == "${existing_key}" ]] || \
        die "Secret/${AUTH_SECRET} 中 replicaSetKey 与 --replica-set-key 不一致；普通 install 不执行 key 轮换"
      REPLICA_SET_KEY="${existing_key}"
    elif [[ "${REPLICA_SET_KEY_EXPLICIT}" != "true" ]]; then
      [[ "${release_exists}" != "true" ]] || die "已有 MongoDB replica set 但无法恢复当前 replicaSetKey；请提供 --replica-set-key '<CURRENT_KEY>'"
      REPLICA_SET_KEY="$(generate_hex_secret 32)"
    fi
  fi

  [[ -n "${ROOT_PASSWORD}" ]] || die "MongoDB root password must not be empty"
  [[ "${ARCHITECTURE}" != "replicaset" || -n "${REPLICA_SET_KEY}" ]] || die "MongoDB replicaSetKey must not be empty"

  local args=(create secret generic "${AUTH_SECRET}" -n "${NAMESPACE}" --from-literal=mongodb-root-password="${ROOT_PASSWORD}")
  [[ "${ARCHITECTURE}" != "replicaset" ]] || args+=(--from-literal=mongodb-replica-set-key="${REPLICA_SET_KEY}")
  if [[ -n "${APP_DATABASE}" ]]; then
    [[ -n "${APP_USERNAME}" && -n "${APP_PASSWORD}" ]] || die "app database requires --app-username and --app-password"
    existing_passwords="${APP_PASSWORD}"
  fi
  [[ -z "${existing_passwords}" ]] || args+=(--from-literal=mongodb-passwords="${existing_passwords}")
  [[ -z "${existing_metrics}" ]] || args+=(--from-literal=mongodb-metrics-password="${existing_metrics}")
  kubectl "${args[@]}" --dry-run=client -o yaml | kubectl apply -f - >/dev/null

  # Never let secrets appear in the legacy Helm command preview.
  ROOT_PASSWORD=""
  REPLICA_SET_KEY=""
}

prepare_storage_reconcile() {
  HELM_STORAGE_SIZE="${STORAGE_SIZE}"
  local template_size=""
  template_size="$(kubectl get sts -n "${NAMESPACE}" -l "app.kubernetes.io/instance=${RELEASE_NAME}" -o jsonpath='{.items[0].spec.volumeClaimTemplates[0].spec.resources.requests.storage}' 2>/dev/null || true)"
  [[ -n "${template_size}" ]] || return 0

  HELM_STORAGE_SIZE="${template_size}"
  if [[ "${STORAGE_SIZE_EXPLICIT}" != "true" ]]; then
    STORAGE_SIZE="${template_size}"
    log "Existing StatefulSet detected; preserving volumeClaimTemplate size ${template_size}"
    return 0
  fi

  if [[ "${STORAGE_SIZE}" == "${template_size}" ]]; then return 0; fi
  local pvc
  while IFS= read -r pvc; do
    [[ -n "${pvc}" ]] || continue
    log "Requesting PVC ${pvc} expansion to ${STORAGE_SIZE}"
    kubectl patch pvc -n "${NAMESPACE}" "${pvc}" --type merge \
      -p "{\"spec\":{\"resources\":{\"requests\":{\"storage\":\"${STORAGE_SIZE}\"}}}}" >/dev/null || \
      die "PVC ${pvc} resize failed. Shrinking is unsupported; expansion requires StorageClass allowVolumeExpansion=true."
  done < <(kubectl get pvc -n "${NAMESPACE}" -l "app.kubernetes.io/instance=${RELEASE_NAME}" -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null || true)
}

confirm() {
  [[ "${AUTO_YES}" == "true" ]] && return 0
  echo
  echo "Action              : ${ACTION}"
  echo "MongoDB             : 8.0.32"
  echo "Namespace           : ${NAMESPACE}"
  echo "Release             : ${RELEASE_NAME}"
  echo "Architecture        : ${ARCHITECTURE}"
  echo "Replica count       : ${REPLICA_COUNT}"
  echo "Resource profile    : ${RESOURCE_PROFILE}"
  echo "StorageClass        : ${STORAGE_CLASS}"
  echo "Requested PVC       : ${STORAGE_SIZE}"
  echo "Authentication      : ${ENABLE_AUTH}"
  echo "Auth Secret         : ${AUTH_SECRET}"
  echo "External access     : false"
  echo "Metrics             : ${ENABLE_METRICS}"
  echo "ServiceMonitor      : ${ENABLE_SERVICEMONITOR}"
  echo "PrometheusRule      : ${ENABLE_PROMETHEUSRULE}"
  echo "Registry            : ${REGISTRY_REPO}"
  echo
  read -r -p "Continue? [y/N] " answer
  [[ "${answer}" =~ ^[Yy]$ ]] || die "Aborted"
}

install_release() {
  prepare_storage_reconcile
  prepare_auth_secret

  local user_helm_args=("${HELM_ARGS[@]}")
  HELM_ARGS=(
    --set-string "persistence.size=${HELM_STORAGE_SIZE}"
    --set "startupProbe.enabled=true"
    --set "startupProbe.initialDelaySeconds=5"
    --set "startupProbe.periodSeconds=10"
    --set "startupProbe.timeoutSeconds=5"
    --set "startupProbe.failureThreshold=60"
    --set "metrics.startupProbe.enabled=true"
    --set "terminationGracePeriodSeconds=120"
    --set "persistentVolumeClaimRetentionPolicy.enabled=true"
    --set-string "persistentVolumeClaimRetentionPolicy.whenDeleted=Retain"
    --set-string "persistentVolumeClaimRetentionPolicy.whenScaled=Retain"
    --set "backup.enabled=false"
    --set "externalAccess.enabled=false"
    --set-string "service.type=ClusterIP"
    --set "metrics.compatibleMode=true"
  )
  if [[ "${ENABLE_AUTH}" == "true" ]]; then
    HELM_ARGS+=(--set-string "auth.existingSecret=${AUTH_SECRET}")
  fi
  HELM_ARGS+=("${user_helm_args[@]}")

  legacy_install_release
}

uninstall_release() {
  legacy_uninstall_release
  if [[ "${DELETE_PVC}" == "true" ]]; then
    kubectl delete secret -n "${NAMESPACE}" "${AUTH_SECRET}" --ignore-not-found=true >/dev/null
    success "Managed auth Secret/${AUTH_SECRET} deleted with PVC cleanup"
  elif kubectl get secret -n "${NAMESPACE}" "${AUTH_SECRET}" >/dev/null 2>&1; then
    warn "Secret/${AUTH_SECRET} retained with data PVCs for safe reinstall"
  fi
}

show_status() {
  legacy_show_status
  echo
  section "Delivery Baseline"
  echo "MongoDB            : 8.0.32"
  echo "Resource profile   : ${RESOURCE_PROFILE}"
  echo "Authentication     : ${ENABLE_AUTH}"
  echo "Managed auth Secret: ${AUTH_SECRET}"
  if kubectl get secret -n "${NAMESPACE}" "${AUTH_SECRET}" >/dev/null 2>&1; then
    echo "Secret state       : present"
  else
    echo "Secret state       : not found"
  fi
}
