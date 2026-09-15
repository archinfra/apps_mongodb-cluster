#!/usr/bin/env python3
"""Validate the Archinfra MongoDB delivery contract."""

from __future__ import annotations

import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
IMAGE_JSON = ROOT / "images" / "image.json"
CHART = ROOT / "charts" / "mongodb" / "Chart.yaml"
DELIVERY = ROOT / "charts" / "mongodb" / "archinfra-values.yaml"
OVERLAY = ROOT / "scripts" / "install-overlay.sh"
BUILD = ROOT / "build.sh"
README = ROOT / "README.md"
WORKFLOW = ROOT / ".github" / "workflows" / "build-offline-installer.yml"


def require(path: Path, *needles: str) -> None:
    text = path.read_text(encoding="utf-8")
    for needle in needles:
        if needle not in text:
            raise SystemExit(f"{path}: missing required invariant: {needle}")


def reject(path: Path, *needles: str) -> None:
    text = path.read_text(encoding="utf-8")
    for needle in needles:
        if needle in text:
            raise SystemExit(f"{path}: forbidden invariant remains: {needle}")


def validate_images() -> None:
    items = json.loads(IMAGE_JSON.read_text(encoding="utf-8"))
    for arch in ("amd64", "arm64"):
        selected = {x["tar"]: x for x in items if x.get("arch") == arch}
        mongodb = selected.get(f"mongodb-{arch}.tar")
        exporter = selected.get(f"mongodb-exporter-{arch}.tar")
        if not mongodb or not exporter:
            raise SystemExit(f"{arch}: MongoDB/exporter image definition missing")
        if mongodb.get("build") != "mongodb-runtime":
            raise SystemExit(f"{arch}: MongoDB must be built from the pinned runtime source")
        if mongodb.get("tag") != "sealos.hub:5000/kube4/mongodb:8.0.32-archinfra1":
            raise SystemExit(f"{arch}: unexpected MongoDB target tag")
        if exporter.get("build") != "mongodb-exporter":
            raise SystemExit(f"{arch}: exporter wrapper build is required")
        if exporter.get("tag") != "sealos.hub:5000/kube4/mongodb-exporter:0.51.0-archinfra1":
            raise SystemExit(f"{arch}: unexpected exporter target tag")
        for item in selected.values():
            if item.get("platform") != f"linux/{arch}":
                raise SystemExit(f"{arch}: platform mismatch for {item.get('tar')}")


def main() -> int:
    validate_images()

    require(CHART, "appVersion: 8.0.32", "version: 17.0.1")
    require(
        DELIVERY,
        "tag: 8.0.32-archinfra1",
        "tag: 0.51.0-archinfra1",
        "externalAccess:\n  enabled: false",
        "startupProbe:\n  enabled: true",
        "terminationGracePeriodSeconds: 120",
        "whenDeleted: Retain",
        "backup:\n  enabled: false",
        "monitoring.archinfra.io/stack: default",
        "MongoDBExporterDown",
        "MongoDBReplicaSetPrimaryMissing",
        "MongoDBReplicationLagHigh",
        "MongoDBReplicationLagCritical",
        "MongoDBConnectionsHigh",
        "MongoDBConnectionsCritical",
        "MongoDBWiredTigerCacheHigh",
        "MongoDBPVCUsageHigh",
        "MongoDBPVCUsageCritical",
        "MongoDBPodRestartHigh",
    )
    require(
        OVERLAY,
        'APP_VERSION="0.2.0"',
        'RESOURCE_PROFILE="standard"',
        'AUTH_SECRET="mongodb-auth"',
        "resource-profile 仅支持 lite|standard|large",
        'REPLICA_COUNT="1"',
        'STORAGE_SIZE="20Gi"',
        'STORAGE_SIZE="100Gi"',
        'STORAGE_SIZE="500Gi"',
        "auth.existingSecret=${AUTH_SECRET}",
        "startupProbe.enabled=true",
        "terminationGracePeriodSeconds=120",
        "externalAccess.enabled=false",
        "backup.enabled=false",
        "persistentVolumeClaimRetentionPolicy.whenDeleted=Retain",
    )
    require(
        BUILD,
        'MONGODB_VERSION="8.0.32"',
        'MONGODB_EXPORTER_VERSION="0.51.0"',
        'MONGODB_RUNTIME_SOURCE_COMMIT="29e5d41625b1a629f06d6f3f75c7c354cfd2b1df"',
        "assemble_installer_template",
        "docker buildx build",
        "verify_mongodb_runtime",
        "verify_mongodb_exporter",
        "/opt/bitnami/mongodb/bin/mongod",
    )
    require(
        README,
        "MongoDB | `8.0.32`",
        "Percona `0.51.0`",
        "lite",
        "standard",
        "large",
        "Secret/mongodb-auth",
        "--storage-size 100Gi",
        "MongoDBReplicaSetPrimaryMissing",
        "MongoDBPVCUsageCritical",
        "不依赖 jq",
    )
    require(
        WORKFLOW,
        "python3 scripts/validate-delivery.py",
        "helm lint charts/mongodb -f charts/mongodb/archinfra-values.yaml",
        "matrix:",
        "arch: [amd64, arm64]",
    )

    # Documentation may mention jq to explicitly state that it is not required;
    # reject only executable dependency patterns.
    reject(BUILD, "command -v jq", "jq -r", "jq -c", "apt-get install -y jq")
    reject(
        OVERLAY,
        "MongoDB@Passw0rd",
        "ArchInfraMongoReplicaSetKey2026",
        'REGISTRY_USER="admin"',
        'REGISTRY_PASS="passw0rd"',
    )
    reject(
        README,
        "root password: `MongoDB@Passw0rd`",
        "ArchInfraMongoReplicaSetKey2026",
        "--resource-profile low",
        "--resource-profile mid",
        "--resource-profile high",
    )

    print(
        "validated MongoDB 8.0.32 delivery baseline: pinned dual-arch runtime, "
        "auth Secret lifecycle, lite/standard/large profiles, ClusterIP-only default, "
        "startup/graceful shutdown, PVC retention/reconcile, monitoring/alerts, "
        "exporter 0.51.0 and jq-free build path"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
