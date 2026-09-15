# apps_mongodb-cluster

Archinfra MongoDB 8.0 高可用副本集离线交付仓库。

当前交付基线聚焦于 **安全、可重复、双架构、可观测、可升级**：安装器负责镜像准备、Helm 安装、凭证 Secret 生命周期、资源规格、PVC 策略、Prometheus/Grafana 接入和离线包构建。

## 当前交付基线

| 项目 | 基线 |
| --- | --- |
| Installer | `v0.2.0` |
| MongoDB | `8.0.32` |
| mongodb_exporter | Percona `0.51.0` |
| 默认架构 | ReplicaSet |
| 默认数据节点 | `3` |
| 默认资源规格 | `standard` |
| 认证 | 默认开启 |
| root 密码 | 首次安装随机生成，写入 Secret |
| replicaSetKey | 首次安装随机生成，写入 Secret |
| 外部访问 | 默认关闭 |
| Service | `ClusterIP` |
| startupProbe | 开启 |
| terminationGracePeriodSeconds | `120` |
| PVC retention | `Retain` |
| Metrics | 默认开启 |
| ServiceMonitor | CRD 存在时开启 |
| PrometheusRule | CRD 存在时开启 |
| Grafana Dashboard | 默认开启 |
| Backup | 本轮关闭，后续统一接 Data Protection |
| 架构 | `amd64` / `arm64` |

> MongoDB 8.0.32 是 8.0 稳定线的安全/可靠性补丁版本。本仓库将 MongoDB 运行时构建固定到一个经过 pin 的 Bitnami-compatible lifecycle source commit，并从 MongoDB 官方 8.0 apt 仓库安装 8.0.32 软件包；amd64/arm64 使用同一套构建逻辑，不再分别依赖两套 MongoDB 成品镜像供应链。

---

## 推荐标准安装

正式交付推荐显式写出关键参数：

```bash
./mongodb-cluster-installer-amd64.run install \
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
```

ARM64 使用：

```bash
./mongodb-cluster-installer-arm64.run install \
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
```

这套标准安装得到：

```text
MongoDB                  8.0.32
ReplicaSet               rs0
Data replicas            3
Per-node request         1 CPU / 4Gi
Per-node limit           2 CPU / 8Gi
Per-node PVC             100Gi
Authentication           ON
External access          OFF
Service                  ClusterIP
Metrics                  ON
ServiceMonitor           ON
PrometheusRule           ON
startupProbe             ON
Graceful termination     120s
PVC retention            Retain
Backup                    OFF
```

`ceph-rbd` 是生产示例，不是硬编码要求。现场可以替换为经过验证的 Ceph RBD、SAN、云块存储或本地高性能块存储。**生产 MongoDB 不推荐把 NFS 作为默认数据盘。**

---

## Resource Profile

对外交付只允许三种规格：

- `lite`
- `standard`
- `large`

不再支持 `low / mid / midd / middle / medium / high` 等旧名称。

| Profile | 数据节点 | 单节点 Request | 单节点 Limit | 新装 PVC/节点 | 适用场景 |
| --- | ---: | ---: | ---: | ---: | --- |
| `lite` | 1 | `500m / 1Gi` | `1C / 2Gi` | `20Gi` | Demo、开发、冒烟；**非 HA** |
| `standard` | 3 | `1C / 4Gi` | `2C / 8Gi` | `100Gi` | **默认生产交付** |
| `large` | 3 | `2C / 8Gi` | `4C / 16Gi` | `500Gi` | 更大 working set / 更高读写压力 |

Exporter 和 volumePermissions 还有少量独立资源开销，因此上表是 **MongoDB 主容器** 的资源规格，不等于整个 Pod 的精确总资源。

### 精简模式

```bash
./mongodb-cluster-installer-amd64.run install \
  --resource-profile lite \
  --storage-class nfs \
  -y
```

`lite` 默认只有 1 个数据节点，只用于测试/开发，不提供副本集故障转移能力。

### 大规格

```bash
./mongodb-cluster-installer-amd64.run install \
  --resource-profile large \
  --storage-class ceph-rbd \
  -y
```

### 单独覆盖 PVC

```bash
./mongodb-cluster-installer-amd64.run install \
  --resource-profile standard \
  --storage-class ceph-rbd \
  --storage-size 300Gi \
  -y
```

---

## 凭证与认证

### 默认行为

认证默认开启：

```text
auth.enabled=true
```

首次安装如果没有传：

```text
--root-password
--replica-set-key
```

安装器会生成强随机值并写入：

```text
Secret/mongodb-auth
```

主要 keys：

```text
mongodb-root-password
mongodb-replica-set-key
mongodb-passwords        # 配置业务用户时存在
```

获取 root 密码：

```bash
kubectl get secret -n aict mongodb-auth \
  -o jsonpath='{.data.mongodb-root-password}' | base64 -d; echo
```

获取 replicaSetKey：

```bash
kubectl get secret -n aict mongodb-auth \
  -o jsonpath='{.data.mongodb-replica-set-key}' | base64 -d; echo
```

### 显式指定凭证

如果交付规范要求由密码系统提供：

```bash
./mongodb-cluster-installer-amd64.run install \
  --root-password '<STRONG_PASSWORD>' \
  --replica-set-key '<STRONG_REPLICA_SET_KEY>' \
  -y
```

不要把真实密码写进 Git、README、项目交付模板或长期保存的 shell history。

### 旧环境 reconcile

对已有 MongoDB release：

1. 优先复用 `Secret/mongodb-auth`；
2. 如果是旧版安装器创建的 Secret，会尝试迁移当前 root password / replicaSetKey；
3. 如果已有 release 但当前凭证无法恢复，安装器**不会生成一个新密码去覆盖旧 PVC**；
4. 此时必须显式提供当前真实凭证。

示例：

```bash
./mongodb-cluster-installer-amd64.run install \
  --root-password '<CURRENT_PASSWORD>' \
  --replica-set-key '<CURRENT_REPLICA_SET_KEY>' \
  --resource-profile standard \
  -y
```

普通 `install` / reconcile 不承担密码轮换。密码轮换应作为独立运维动作处理。

### 业务用户

初始化业务库/用户仍支持：

```bash
./mongodb-cluster-installer-amd64.run install \
  --app-database appdb \
  --app-username app_user \
  --app-password '<APP_PASSWORD>' \
  -y
```

交付建议：

```text
root              -> 管理员，只用于运维
app_user          -> 业务账号，按库授权
mongodb_exporter  -> TODO：后续从 root 监控连接进一步拆为最小权限监控账号
mongodb_backup    -> TODO：Data Protection 阶段实现
```

---

## 网络与暴露策略

默认：

```text
externalAccess.enabled=false
service.type=ClusterIP
```

因此安装后 MongoDB 默认只通过 Kubernetes 内部网络访问，不默认创建 NodePort / LoadBalancer。

标准 ReplicaSet 连接种子类似：

```text
mongodb-cluster-0.mongodb-cluster-headless.aict.svc.cluster.local:27017
mongodb-cluster-1.mongodb-cluster-headless.aict.svc.cluster.local:27017
mongodb-cluster-2.mongodb-cluster-headless.aict.svc.cluster.local:27017
```

连接串示例：

```text
mongodb://root:<PASSWORD>@mongodb-cluster-0.mongodb-cluster-headless.aict.svc.cluster.local:27017,mongodb-cluster-1.mongodb-cluster-headless.aict.svc.cluster.local:27017,mongodb-cluster-2.mongodb-cluster-headless.aict.svc.cluster.local:27017/admin?replicaSet=rs0&authSource=admin
```

如果确实需要集群外访问，应单独设计 LoadBalancer / Gateway / VPN / ACL / NetworkPolicy，不建议把 NodePort 作为默认交付方式。

---

## 存储策略

### 新安装

Profile 默认值：

```text
lite      20Gi / data replica
standard  100Gi / data replica
large     500Gi / data replica
```

默认 standard 3 节点即至少申请：

```text
3 × 100Gi = 300Gi
```

### 已有 PVC 重跑 installer

PVC/StatefulSet 和 CPU/内存不同，不能把 `volumeClaimTemplates` 当成普通字段随意修改。

因此：

```text
已有 StatefulSet + 未显式传 --storage-size
    -> 保持原 volumeClaimTemplate 大小
```

即使新版 profile 默认是 100Gi，也不会偷偷把旧环境的 20Gi/50Gi PVC 改掉。

### 显式扩容

```bash
./mongodb-cluster-installer-amd64.run install \
  --storage-size 300Gi \
  -y
```

要求：

- 只能扩容，不能缩容；
- StorageClass 必须支持 `allowVolumeExpansion=true`；
- StorageClass 不能通过 reconcile 原地切换；
- 生产扩容前仍建议做数据保护和容量确认。

### 卸载

默认卸载 workload，但保留数据 PVC 和管理凭证：

```bash
./mongodb-cluster-installer-amd64.run uninstall -y
```

只有明确执行：

```bash
./mongodb-cluster-installer-amd64.run uninstall --delete-pvc -y
```

才删除数据 PVC，并同时删除 `Secret/mongodb-auth`。

---

## Probe 与优雅停机

MongoDB 主容器：

```text
startupProbe:
  periodSeconds: 10
  timeoutSeconds: 5
  failureThreshold: 60
```

约提供 10 分钟启动窗口，用于：

- 首次 ReplicaSet 初始化；
- 大 PVC 启动；
- WiredTiger recovery；
- 节点异常恢复；
- 升级后的启动过程。

同时：

```text
terminationGracePeriodSeconds=120
```

用于给 MongoDB 正常处理 SIGTERM、checkpoint 和 shutdown 留出时间。

Exporter 也开启 startupProbe。

---

## 安全基线

当前 chart 已具备并继续保留：

- MongoDB 非 root 运行；
- `allowPrivilegeEscalation=false`；
- Linux capabilities drop；
- `seccompProfile: RuntimeDefault`；
- Authentication 默认 ON；
- ExternalAccess 默认 OFF；
- PVC retention 默认 Retain；
- 不再提供固定 root password；
- 不再提供固定 replicaSetKey；
- 不再提供固定 registry 用户名/密码。

当前仍允许：

```text
networkPolicy.allowExternal=true
```

这是为了兼容不同项目 namespace。正式项目如果调用方 namespace/label 已知，应再叠加项目级 NetworkPolicy allow-list。

TLS 本轮不是默认开启项，后续应作为单独的证书生命周期和客户端兼容性工作处理。

---

## 监控与告警

Exporter：

```text
Percona mongodb_exporter 0.51.0
```

开启 compatibility mode，以降低现有 Dashboard/PromQL 迁移成本。

默认 collector：

- diagnostic data
- replica set status

默认不开高开销全量 collection/index stats collector。

ServiceMonitor 发现标签：

```yaml
monitoring.archinfra.io/stack: default
```

Grafana folder：

```text
Middleware/MongoDB
```

当前规则集：

| Alert | 级别 | 意义 |
| --- | --- | --- |
| `MongoDBExporterDown` | critical | exporter / MongoDB scrape 不可用 |
| `MongoDBReplicaSetMembersLow` | critical | 活跃成员少于期望值 |
| `MongoDBReplicaSetPrimaryMissing` | critical | 没有 PRIMARY |
| `MongoDBReplicationLagHigh` | warning | replication lag > 30s |
| `MongoDBReplicationLagCritical` | critical | replication lag > 120s |
| `MongoDBConnectionsHigh` | warning | 连接利用率 > 80% |
| `MongoDBConnectionsCritical` | critical | 连接利用率 > 95% |
| `MongoDBWiredTigerCacheHigh` | warning | WiredTiger cache > 85% |
| `MongoDBPVCUsageHigh` | warning | PVC > 80% |
| `MongoDBPVCUsageCritical` | critical | PVC > 90% |
| `MongoDBPodRestartHigh` | warning | 15 分钟内 MongoDB container 重启 > 3 次 |

其中 PVC/PodRestart 告警依赖中央 Prometheus 同时采集 kubelet / kube-state-metrics。

---

## 日志

MongoDB 容器日志按 Kubernetes 标准 stdout/stderr 采集。

推荐：

```text
MongoDB container logs
        -> node-level Fluent Bit / Vector
        -> Loki / Elasticsearch / centralized logging
```

不建议在 MongoDB Pod 内再维护一套长期日志归档 sidecar；长期留存、检索和告警交给统一日志平台。

常用查看：

```bash
kubectl logs -n aict mongodb-cluster-0 -c mongodb --tail=200
kubectl logs -n aict mongodb-cluster-1 -c mongodb --tail=200
```

---

## MongoDB 8.0.32 镜像供应链

本仓库不再使用：

```text
amd64 -> bitnamilegacy/mongodb:8.0.9
arm64 -> 第三方 MongoDB 8.0.9 成品镜像
```

改为统一构建：

```text
pinned Bitnami-compatible lifecycle source
        +
MongoDB official 8.0 apt repository
        +
MongoDB 8.0.32
        ->
Archinfra mongodb:8.0.32-archinfra1
```

构建脚本固定上游源码 commit，并在镜像生成后直接执行：

```text
mongod --version
```

只有产物真实报告 `8.0.32` 才继续打离线包。

Exporter 同样会验证运行时版本。

这意味着：

- amd64 / arm64 使用同一构建逻辑；
- target/offline 环境不需要联网构建；
- `.run` 内已经包含对应架构镜像 tar；
- 构建环境需要联网访问固定源码和软件包仓库。

---

## 8.0.9 -> 8.0.32 升级说明

这是 MongoDB 8.0 同一 major line 内的 patch 升级，但仍然属于有状态数据库升级。

正式环境建议：

1. 先确认当前 ReplicaSet 全部健康；
2. 确认 PRIMARY/SECONDARY 状态正常、复制延迟可接受；
3. 做数据库备份或底层快照；
4. 记录当前 root password / replicaSetKey；
5. 先在同版本测试数据/预生产环境验证；
6. 再执行 installer reconcile；
7. 升级后核对 ReplicaSet、FCV、业务读写、Exporter 和 Dashboard。

不要把 CI 的“镜像成功构建”理解成“客户现场数据升级已经自动验收”。最终上线仍需要真实 Kubernetes + PVC E2E。

---

## Help

```bash
./mongodb-cluster-installer-amd64.run help
./mongodb-cluster-installer-amd64.run help overview
./mongodb-cluster-installer-amd64.run help install
./mongodb-cluster-installer-amd64.run help params
./mongodb-cluster-installer-amd64.run help examples
./mongodb-cluster-installer-amd64.run help architecture
```

安装器 help 和本 README 使用同一套 `lite / standard / large` 交付口径。

---

## 状态检查

```bash
./mongodb-cluster-installer-amd64.run status -n aict
```

也可以直接：

```bash
kubectl get pods,sts,svc,pvc -n aict -l app.kubernetes.io/instance=mongodb-cluster
```

ReplicaSet：

```bash
kubectl exec -n aict mongodb-cluster-0 -c mongodb -- \
  mongosh --quiet \
  -u root \
  -p "$(kubectl get secret -n aict mongodb-auth -o jsonpath='{.data.mongodb-root-password}' | base64 -d)" \
  --authenticationDatabase admin \
  --eval 'rs.status()'
```

---

## 离线构建

```bash
./build.sh --arch amd64
./build.sh --arch arm64
./build.sh --arch all
```

构建机依赖：

```text
docker + buildx
git
helm
python3 / python
```

**不依赖 jq。**

生成：

```text
dist/mongodb-cluster-installer-amd64.run
dist/mongodb-cluster-installer-amd64.run.sha256

dist/mongodb-cluster-installer-arm64.run
dist/mongodb-cluster-installer-arm64.run.sha256
```

客户目标环境默认需要：

```text
kubectl
helm
docker（如果安装器需要导入/推送内置镜像）
```

如果镜像已经提前进入客户 registry，可以使用：

```bash
--skip-image-prepare
```

---

## CI 交付门禁

PR / main CI 会验证：

- shell syntax；
- MongoDB BOM 固定为 8.0.32；
- exporter BOM 固定；
- amd64 / arm64 image metadata；
- 不允许固定弱 root 密码 / replicaSetKey / registry 密码；
- `lite / standard / large` 是唯一资源 profile；
- ClusterIP-only 默认；
- startupProbe；
- 120 秒 termination grace；
- PVC Retain；
- Backup 默认关闭；
- ServiceMonitor / PrometheusRule / Dashboard；
- Helm lint / template；
- MongoDB runtime 实际版本验证；
- exporter runtime 实际版本验证；
- 双架构 `.run` 构建；
- installer help；
- SHA256 checksum。

---

## 后续 TODO

本轮先把 MongoDB 单集群交付基线收口，以下单独迭代：

- [ ] 给 exporter 创建最小权限 `mongodb_exporter` 用户，逐步取消 exporter 使用 root 凭证；
- [ ] 业务账号标准化：按应用创建 `app_user`，不让业务长期使用 root；
- [ ] Data Protection：定义 `mongodb_backup`、备份策略、恢复验收；
- [ ] TLS：证书生成/导入/轮换及客户端连接规范；
- [ ] 项目级 NetworkPolicy allow-list；
- [ ] 真实 Kubernetes/Sealos E2E：全新安装、故障转移、Pod 重建、PVC 保留、升级、扩容、卸载/重装；
- [ ] 独立验证 MongoDB 8.0.x patch rolling upgrade/rollback runbook。
