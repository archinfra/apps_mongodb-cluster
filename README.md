# apps_mongodb-cluster

MongoDB 高可用副本集离线交付仓库。

这个仓库不是单独放一个 Helm chart，而是把下面几件事打成了一套完整的 `.run` 安装方案：

- 镜像准备
- Helm 安装
- 监控接入
- GitHub Actions 多架构构建
- 离线安装包交付

整体范式和我们之前的 MySQL、Redis、MinIO、Milvus、RabbitMQ 仓库保持一致，目标是让陌生使用者拿到安装包后，也能比较稳定地完成部署、升级、排障和监控接入。

## 这套安装器是怎么设计的

普通使用者可以把它理解成一个“MongoDB 副本集离线安装器”，核心只有 4 个动作：

- `install`
- `status`
- `uninstall`
- `help`

其中 `install` 会自动完成这些步骤：

1. 解包 `.run` 里的 chart、镜像元数据和镜像 tar
2. 按目标镜像仓库地址准备 MongoDB、exporter 和辅助镜像
3. 检查集群里是否支持 `ServiceMonitor`
4. 生成最终的 Helm 参数
5. 执行 `helm upgrade --install`
6. 输出 Pod、StatefulSet、Service、PVC、ServiceMonitor 状态

这意味着使用者通常不需要自己手动做这些事情：

- `docker load`
- `docker tag`
- `docker push`
- `helm dependency build`
- `kubectl apply ServiceMonitor`

安装器已经把这些流程编排好了。

## 默认值

下面是安装器当前的默认业务参数：

- namespace: `aict`
- release name: `mongodb-cluster`
- architecture: `replicaset`
- data replicas: `3`
- replica set name: `rs0`
- root user: `root`
- root password: `MongoDB@Passw0rd`
- replica set key: `ArchInfraMongoReplicaSetKey2026`
- authentication: `true`
- arbiter: `false`
- hidden replicas: `0`
- pod anti-affinity: `soft`
- volume permissions: `true`
- storage class: `nfs`
- storage size: `20Gi`
- metrics: `true`
- ServiceMonitor: `true`
- ServiceMonitor interval: `30s`
- registry repo: `sealos.hub:5000/kube4`
- image pull policy: `IfNotPresent`
- wait timeout: `10m`
- resource profile: `mid`

## Resource profile

Installer supports:

- `--resource-profile low`
- `--resource-profile mid`
- `--resource-profile midd`
- `--resource-profile high`

Default is `mid`. `midd` is accepted as an alias of `mid`.

Profile intent:

- `low`: demo, smoke test, or lightweight shared environment
- `mid`: normal shared environment, baseline for `500-1000` concurrency and around `10000` users
- `high`: higher write pressure, larger working set, or busier shared cluster

Per-profile baseline:

| Profile | MongoDB data pod | Exporter sidecar | volumePermissions init | Arbiter | Hidden replica |
| --- | --- | --- | --- | --- | --- |
| `low` | `300m / 768Mi` request, `500m / 1Gi` limit | `50m / 64Mi` request, `100m / 128Mi` limit | `20m / 32Mi` request, `100m / 64Mi` limit | `100m / 256Mi` request, `300m / 512Mi` limit | `300m / 768Mi` request, `500m / 1Gi` limit |
| `mid` | `500m / 1Gi` request, `1 / 2Gi` limit | `100m / 128Mi` request, `200m / 256Mi` limit | `50m / 64Mi` request, `200m / 128Mi` limit | `200m / 512Mi` request, `500m / 1Gi` limit | `500m / 1Gi` request, `1 / 2Gi` limit |
| `high` | `1 / 2Gi` request, `2 / 4Gi` limit | `200m / 256Mi` request, `500m / 512Mi` limit | `100m / 128Mi` request, `300m / 256Mi` limit | `500m / 1Gi` request, `1 / 2Gi` limit | `1 / 2Gi` request, `2 / 4Gi` limit |

这套默认值面向的是“标准三节点副本集 + 默认开启监控”的常见场景。

## 默认部署拓扑

如果直接执行：

```bash
./mongodb-cluster-installer-amd64.run install -y
```

默认会部署：

- 1 个 MongoDB StatefulSet
- 3 个数据节点，组成一个副本集
- 1 个 headless Service
- 1 个 metrics Service
- 3 个 PVC
- 每个数据节点 1 个 `mongodb-exporter` sidecar
- 1 个 `ServiceMonitor`

默认不会部署：

- arbiter
- hidden node
- 外部暴露 NodePort / LoadBalancer
- TLS
- 备份任务

也就是说，默认路径聚焦在“高可用副本集 + 集群内访问 + 默认监控接入”。

## 资源需求矩阵

这部分是给使用者和自动化系统做资源预估用的。

当前 chart 的资源主要来自 Bitnami `common.resources.preset` 预设：

- MongoDB 主容器：显式 `500m / 1Gi` request，`1 / 2Gi` limit
- exporter：显式 `100m / 128Mi` request，`200m / 256Mi` limit
- volumePermissions init 容器：显式 `50m / 64Mi` request，`200m / 128Mi` limit

对应的大致资源如下。

### 单个数据节点

MongoDB 主容器 `mid`：

- request: `500m CPU / 1Gi memory`
- limit: `1 CPU / 2Gi memory`

Exporter `mid`：

- request: `100m CPU / 128Mi memory`
- limit: `200m CPU / 256Mi memory`

所以一个默认数据节点的持续资源大致是：

- request: `600m CPU / 640Mi memory`
- limit: `900m CPU / 960Mi memory`

### 默认三节点副本集总资源

默认 `replicaCount=3` 且监控开启时，持续资源大致是：

| 项目 | 单节点 | 3 节点合计 |
| --- | --- | --- |
| CPU request | `600m` | `1800m` |
| Memory request | `1152Mi` | `3456Mi` |
| CPU limit | `1200m` | `3600m` |
| Memory limit | `2304Mi` | `6912Mi` |

### volumePermissions 额外启动开销

默认 `volumePermissions=true`，每个数据节点启动时还会额外跑一个显式 sizing 的 init 容器：

- request: `50m CPU / 64Mi memory`
- limit: `200m CPU / 128Mi memory`

它不是长期常驻容器，但在首次启动、重建 Pod 或重新挂载卷时会出现。

### 开启 arbiter 后的额外资源

如果启用：

```bash
--enable-arbiter
```

arbiter 在默认 `mid` 档位下大致额外增加：

- request: `200m CPU / 512Mi memory`
- limit: `500m CPU / 1Gi memory`

### 开启 hidden node 后的额外资源

如果通过：

```bash
--hidden-replica-count <num>
```

启用 hidden node，则每个 hidden 节点在默认 `mid` 档位下大致额外增加：

- request: `500m CPU / 1Gi memory`
- limit: `1 CPU / 2Gi memory`

### 存储需求

默认数据卷大小是：

- 每个数据节点 `20Gi`
- 默认 `3` 个数据节点

所以默认最低持久化存储需求是：

- `60Gi`

如果启用了 hidden node，安装器也会默认给 hidden 节点同样的存储大小，所以总存储需求会继续增加。

## 快速开始

### 1. 查看帮助

```bash
./mongodb-cluster-installer-amd64.run --help
./mongodb-cluster-installer-amd64.run help
```

### 2. 用默认参数安装高可用副本集

```bash
./mongodb-cluster-installer-amd64.run install -y
```

### 3. 查看状态

```bash
./mongodb-cluster-installer-amd64.run status
```

### 4. 卸载

```bash
./mongodb-cluster-installer-amd64.run uninstall -y
```

如果还需要把 PVC 一起清理掉：

```bash
./mongodb-cluster-installer-amd64.run uninstall --delete-pvc -y
```

## 常见使用场景

### 场景 1：标准三节点高可用副本集

```bash
./mongodb-cluster-installer-amd64.run install -y
```

### 场景 2：自定义 root 密码和副本集密钥

```bash
./mongodb-cluster-installer-amd64.run install \
  --root-password 'MongoDB@Passw0rd' \
  --replica-set-key 'ArchInfraMongoReplicaSetKey2026' \
  -y
```

### 场景 3：初始化一个业务库和业务用户

```bash
./mongodb-cluster-installer-amd64.run install \
  --app-database appdb \
  --app-username app \
  --app-password 'AppUser@2026' \
  -y
```

### 场景 4：镜像仓库里已经有镜像，不想重复推送

```bash
./mongodb-cluster-installer-amd64.run install \
  --registry sealos.hub:5000/kube4 \
  --skip-image-prepare \
  -y
```

### 场景 5：关闭监控

```bash
./mongodb-cluster-installer-amd64.run install \
  --disable-servicemonitor \
  --disable-metrics \
  -y
```

### 场景 6：做一个 2 数据节点 + 1 arbiter 的轻量副本集

```bash
./mongodb-cluster-installer-amd64.run install \
  --replica-count 2 \
  --enable-arbiter \
  -y
```

### 场景 7：需要更多 Helm 细粒度参数

```bash
./mongodb-cluster-installer-amd64.run install \
  --helm-args "--set externalAccess.enabled=true --set externalAccess.service.type=LoadBalancer" \
  -y
```

对于更复杂、包含空格或需要精确保留 shell 引号的 Helm 参数，建议用 `--` 透传：

```bash
./mongodb-cluster-installer-amd64.run install -y -- \
  --set hidden.enabled=true \
  --set hidden.replicaCount=2 \
  --set-string hidden.persistence.size=50Gi
```

## 监控是怎么处理的

MongoDB 这套安装器默认监控是开启的：

- `metrics.enabled=true`
- `metrics.serviceMonitor.enabled=true`

并且默认会打上平台统一标签：

- `monitoring.archinfra.io/stack=default`

这意味着如果你的 Prometheus Stack 采用了我们之前统一的发现策略，它会自动发现这个 MongoDB 的 `ServiceMonitor`。

如果集群里没有 `ServiceMonitor` CRD，安装器会自动降级：

- 保留 exporter sidecar
- 关闭 `ServiceMonitor` 资源创建

不会因为监控 CRD 缺失而导致整个 MongoDB 安装失败。

## 常用参数

### 核心参数

- `-n, --namespace <ns>`
- `--release-name <name>`
- `--architecture <replicaset|standalone>`
- `--replica-count <num>`
- `--replica-set-name <name>`
- `--root-user <name>`
- `--root-password <pwd>`
- `--replica-set-key <value>`
- `--enable-auth`
- `--disable-auth`
- `--app-database <name>`
- `--app-username <name>`
- `--app-password <pwd>`
- `--storage-class <name>`
- `--storage-size <size>`
- `--pod-anti-affinity <soft|hard|none>`
- `--enable-arbiter`
- `--disable-arbiter`
- `--hidden-replica-count <num>`
- `--enable-volume-permissions`
- `--disable-volume-permissions`

### 监控参数

- `--enable-metrics`
- `--disable-metrics`
- `--enable-servicemonitor`
- `--disable-servicemonitor`
- `--service-monitor-namespace <ns>`
- `--service-monitor-interval <value>`
- `--service-monitor-scrape-timeout <value>`

### 镜像和等待参数

- `--registry <repo-prefix>`
- `--registry-user <user>`
- `--registry-password <password>`
- `--image-pull-policy <policy>`
- `--skip-image-prepare`
- `--wait-timeout <duration>`

### 高级透传

- `--helm-args "<args>"`
- `-- <helm_args>`

## 如何进一步自定义

安装器提供了 3 层自定义能力。

### 第一层：直接使用安装器参数

这适合大多数通用场景，也是最推荐的方式。

### 第二层：用 `--helm-args`

适合那些安装器暂时没有单独暴露，但你又只想追加一两项 Helm 设置的场景。

例如：

```bash
./mongodb-cluster-installer-amd64.run install \
  --helm-args "--set tls.enabled=true --set externalAccess.enabled=true" \
  -y
```

### 第三层：用 `--` 做完整 Helm 透传

这适合复杂定制，例如：

- 外部访问
- TLS
- hidden node 的额外参数
- 节点亲和性
- tolerations
- 自定义资源 limits/requests
- PrometheusRule

示例：

```bash
./mongodb-cluster-installer-amd64.run install -y -- \
  --set externalAccess.enabled=true \
  --set externalAccess.service.type=NodePort \
  --set externalAccess.service.domain=mongodb.example.com \
  --set externalAccess.service.nodePorts[0]=30017 \
  --set externalAccess.service.nodePorts[1]=30018 \
  --set externalAccess.service.nodePorts[2]=30019
```

## 和其他组件怎么对接

MongoDB 默认不依赖这些组件启动：

- MySQL
- Redis
- Nacos

它和其他组件最常见的关系，是“被应用系统调用”而不是“依赖这些系统才能启动”。

### 应用如何连接 MongoDB

默认副本集内部连接地址形态大致是：

```text
mongodb-cluster-0.mongodb-cluster-headless.aict.svc.cluster.local:27017
mongodb-cluster-1.mongodb-cluster-headless.aict.svc.cluster.local:27017
mongodb-cluster-2.mongodb-cluster-headless.aict.svc.cluster.local:27017
```

如果默认启用了认证，常见连接串是：

```text
mongodb://root:<password>@mongodb-cluster-0.mongodb-cluster-headless.aict.svc.cluster.local:27017,mongodb-cluster-1.mongodb-cluster-headless.aict.svc.cluster.local:27017,mongodb-cluster-2.mongodb-cluster-headless.aict.svc.cluster.local:27017/admin?replicaSet=rs0&authSource=admin
```

### 和 Prometheus 对接

Prometheus 侧如果按我们统一方案配置了：

- 跨 namespace 发现
- 按 `monitoring.archinfra.io/stack=default` 选取 `ServiceMonitor`

那么 MongoDB 安装后会自动接入，不需要额外写监控对象。

## 使用前置条件与依赖

### 必要条件

- Kubernetes 集群可用
- `kubectl` 可访问目标集群
- `helm` 已安装
- 目标命名空间允许创建 StatefulSet、PVC、Secret、Service
- 至少存在一个可用的 StorageClass

### 镜像相关条件

- 如果不带 `--skip-image-prepare`，执行机器需要有 `docker`
- 如果带 `--skip-image-prepare`，目标仓库里必须已经有安装器所需镜像

### 监控相关条件

- 如果集群里有 `ServiceMonitor` CRD，就会创建 `ServiceMonitor`
- 如果没有，安装器会自动降级，不会因此失败

## 镜像来源说明

这个仓库支持 `amd64` 和 `arm64` 多架构，但 MongoDB 主镜像的来源是按架构分开的：

- `amd64`：`bitnamilegacy/mongodb:8.0.9`
- `arm64`：`dlavrenuek/bitnami-mongodb-arm:8.0.9`

辅助镜像采用多架构公共源：

- `bitnamilegacy/mongodb-exporter:0.47.0-debian-12-r1`
- `bitnamilegacy/kubectl:1.33.4-debian-12-r0`
- `bitnamilegacy/os-shell:12-debian-12-r51`
- `bitnamilegacy/nginx:1.29.1-debian-12-r0`

也正因为我们会把公共镜像重新打到目标内网仓库，安装器和 chart 默认都开启了：

- `global.security.allowInsecureImages=true`

这是离线交付场景下的预期行为，不是异常。

## 给 AI 或自动化系统使用时，还需要知道什么

如果你计划把安装包放到服务器上，让大模型自行参考文档完成部署，我建议把下面这些规则也一并告诉它。

### 默认优先策略

如果没有额外约束，优先采用：

- `replicaset`
- `3` 个数据节点
- 开启认证
- 开启 metrics
- 开启 `ServiceMonitor`
- `storageClass=nfs`
- `storageSize=20Gi`

### 什么时候要主动改参数

- 集群资源紧张：考虑降低 `--replica-count`
- 想要 2 数据节点 + 1 仲裁：使用 `--replica-count 2 --enable-arbiter`
- 需要业务库和业务用户：补 `--app-database --app-username --app-password`
- 需要外部访问：优先通过 `--helm-args` 或 `--` 透传 `externalAccess.*`
- 需要 TLS：通过 `--helm-args` 或 `--` 透传 `tls.*`

### 成功标准

AI 或自动化系统可以把下面这些作为安装成功信号：

- Helm release 状态正常
- MongoDB StatefulSet Pod 全部 `Running`
- `kubectl get pvc` 绑定成功
- 如果启用了监控，metrics Service 存在
- 如果集群支持 CRD，`ServiceMonitor` 已创建
- 在副本集模式下，业务可通过副本集连接串访问

### 常见失败信号

- PVC 一直 `Pending`
- Pod `CrashLoopBackOff`
- Volume permission 相关报错
- 认证参数不完整导致启动失败
- 开启 `ServiceMonitor` 但集群没有对应 CRD
- 开启 `externalAccess` 但没有配对应的 LB/NodePort 参数

## 常见排障思路

### 1. 看 release 状态

```bash
./mongodb-cluster-installer-amd64.run status
```

### 2. 看 Pod 和 PVC

```bash
kubectl get pods,pvc -n aict
```

### 3. 看某个 MongoDB Pod 的日志

```bash
kubectl logs -n aict mongodb-cluster-0
```

### 4. 看 exporter 是否起来

```bash
kubectl get svc -n aict | grep metrics
kubectl get servicemonitor -A | grep mongodb-cluster
```

### 5. 看副本集是否已经选主

```bash
kubectl exec -it -n aict mongodb-cluster-0 -- mongosh admin -u root -p 'MongoDB@Passw0rd' --eval 'rs.status()'
```

## 仓库结构

- `build.sh`
  负责构建多架构 `.run` 离线安装包
- `install.sh`
  安装器入口，负责解包、镜像准备、Helm 安装、状态输出
- `images/image.json`
  按架构声明构建所需镜像
- `charts/mongodb`
  vendor 进仓库的 MongoDB Helm chart
- `.github/workflows/build-offline-installer.yml`
  GitHub Actions 多架构构建和 release 发布流程

## 本地构建

如果你在本地手工构建，需要这些工具：

- `jq`
- `docker`
- `helm`

示例：

```bash
./build.sh --arch amd64
./build.sh --arch arm64
./build.sh --arch all
```

产物会在：

- `dist/mongodb-cluster-installer-amd64.run`
- `dist/mongodb-cluster-installer-amd64.run.sha256`
- `dist/mongodb-cluster-installer-arm64.run`
- `dist/mongodb-cluster-installer-arm64.run.sha256`

## GitHub Actions 发布

仓库的默认发布方式是 GitHub Actions：

- `push main/master`：构建 `amd64` / `arm64` 安装包
- `push v* tag`：额外发布 GitHub Release
- `workflow_dispatch`：手工触发构建

如果本地环境拉不到镜像，推荐直接依赖 GitHub Actions 进行正式产包。
## Built-in Monitoring, Alerts, And Dashboards

Default install now enables:

- `metrics.enabled=true`
- `metrics.serviceMonitor.enabled=true`
- `metrics.prometheusRule.enabled=true`

Default monitoring resources:

- `ServiceMonitor`
- `PrometheusRule`
- Grafana dashboard `ConfigMap`

Grafana auto-import contract:

- dashboard label: `grafana_dashboard=1`
- platform label: `monitoring.archinfra.io/stack=default`
- folder annotation: `grafana_folder=Middleware/MongoDB`

Built-in alerts:

- `MongoDBExporterDown`
- `MongoDBReplicaSetMembersLow`
- `MongoDBConnectionsHigh`

Built-in dashboard panels:

- Healthy Members
- Current Connections
- Resident Memory
- Ops / Sec
- Connections
- Operation Rate
