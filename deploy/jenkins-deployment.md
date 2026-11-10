# wps-converter Jenkins 部署方案

> 2026-11-04 定稿。已拍板：
> - 固定部署到测试转换机 `CHANGE_ME_WPS_TARGET_IP`（`/data/wps-converter`，宿主端口 `8028`）；该地址与测试后端 `WPS_CONVERTER_URL` 一致。
> - Jenkins（`CHANGE_ME_JENKINS_IP:8085`）为宿主机 systemd 运行，有外网，可直接拉基础镜像与 PyPI/apt 镜像源。
> - 目标机 `CHANGE_ME_WPS_TARGET_IP` 以 **root 直连**（测试服务器；Jenkins→目标机免密通道需先验证）。
> - 镜像 `docker save` 直传（不建 registry）；镜像 tag = git 短哈希（8 位），每次构建对应一次可回滚的版本。
> - 目标机沿用现有 compose 管理方式：候选容器预检 → 替换 `wps-converter:local` → `/health/ready` 健康门禁 → 失败自动回滚。
>
> 本方案产物：`deploy/Jenkinsfile`（流水线）、`deploy/deploy.sh`（目标机部署/回滚脚本）、本文档。**两者需提交并推送到要部署的分支后 Jenkins 才能使用。**

## 0. 拓扑与流程

```text
┌─────────────────── CHANGE_ME_JENKINS_IP（Jenkins 机，有外网）───────────────────┐
│  Git 服务 :8089（devops/backendgroup/rd202605/wps-converter）           │
│  Jenkins :8085（宿主机 systemd，docker 命令直接可用）                    │
│                                                                        │
│  ① git checkout <部署分支>                                              │
│  ② 容器内 uv sync + pytest（门禁）        ── python:3.13-slim-bookworm  │
│  ③ DOCKER_BUILDKIT=1 docker build（Dockerfile 的 RUN --mount 需要 BuildKit）│
└──────────────┬─────────────────────────────────────────────────────────┘
               │ ④ docker save | gzip | ssh root@CHANGE_ME_WPS_TARGET_IP "gunzip | docker load"
               ▼
┌─────────────────── CHANGE_ME_WPS_TARGET_IP（目标机，root）─────────────────────────┐
│  ⑤ deploy/deploy.sh：隔离候选容器探活 → compose 替换 → /health/ready 门禁 │
│     候选失败不切换；切换后失败自动回滚；保留最近 5 个版本镜像            │
│  运行时配置：/data/wps-converter/.env（人工管理）                        │
│  端口映射：0.0.0.0:8028 → 容器 8000                                     │
└─────────────────────────────────────────────────────────────────────────┘
```

- `disableConcurrentBuilds()` 保证同一时间只有一个部署，避免目标机上容器替换竞态。
- 触发方式：手动 Build Now（当前）。可选自动化见 §8。
- 目标机当前容器名为 `wps-converter-converter-1`（compose 项目名 `wps-converter` + 服务名 `converter`）。

## 1. 一次性配置

### 1.1 目标机 CHANGE_ME_WPS_TARGET_IP（root）

```bash
ssh root@CHANGE_ME_WPS_TARGET_IP

# ① 确认部署目录、compose 和 .env 已存在（当前测试机已有）
cd /data/wps-converter
test -f .env && test -f docker-compose.yml
docker compose config --quiet

# ② 确认 8028 由本服务占用
ss -lntp | grep 8028

# ③ 确认 Docker / Compose 可用
docker version >/dev/null && docker compose version
```

`.env` 重点核对键（其余键按 `.env.example` 默认即可）：

| 键 | 部署要点 |
| --- | --- |
| `CONVERTER_API_KEY` | 必填；必须与后端 `WPS_CONVERTER_API_KEY` **同值**，否则转换接口 401 |
| `CONVERTER_PORT` | **`8028`**（宿主机端口；容器内固定 8000。deploy.sh 未显式传 `HOST_PORT` 时会从这里读取） |
| `MAX_FILE_SIZE_MB` | `50`（与后端 `WPS_CONVERTER_MAX_FILE_SIZE` 对齐） |
| `MAX_CONCURRENCY` | `4`（按目标机 CPU/内存调整） |
| `CONVERSION_TIMEOUT_SECONDS` | `120`（与后端 `WPS_CONVERTER_TIMEOUT_MS` 对齐） |
| `SOFFICE_PATH` | `/usr/bin/soffice` |
| `OFD_CONVERTER_PATH` | `ofd2pdf`；当前目标机 compose 未显式传该变量，镜像内默认值可直接工作。如需覆盖，请在 `docker-compose.yml` 的 `environment` 中补充 |
| `LOG_LEVEL` | `INFO` |

> 当前目标机的 `docker-compose.yml` 是旧版本 checkout 留下的文件，只用于容器编排；流水线只更新镜像，不更新该文件。不要手动执行 `docker compose up --build`（会用目标机旧源码构建并覆盖镜像）；发布统一走 Jenkins。若后续新增环境变量或调整 tmpfs/端口，请人工同步 compose 和 `.env`，再触发构建。

### 1.2 Jenkins 机 → 目标机免密通道

以 Jenkins 运行用户（apt/systemd 安装时为 `jenkins`）验证：

```bash
sudo -u jenkins ssh root@CHANGE_ME_WPS_TARGET_IP 'docker version >/dev/null && docker compose version && echo OK'
```

若该通道不属于 `jenkins` 系统用户（挂在其他运维账号下），把 `deploy/Jenkinsfile` 里的 `DEPLOY_HOST` 改成对应账号，其余不变。若 Jenkins 无法直达 `.17`，需要先开通免密或改用可直达的部署机。

### 1.3 Jenkins job（Pipeline from SCM）

新建 Item → **Pipeline**，名称建议 `wps-converter`：

| 配置项 | 值 |
| --- | --- |
| Definition | Pipeline script from SCM |
| SCM | Git |
| Repository URL | `http://CHANGE_ME_JENKINS_IP:8089/devops/backendgroup/rd202605/wps-converter` |
| Credentials | 新建「Username with password」：有该仓库读权限的 Git 账号 + access token |
| Branch Specifier | `*/main`（或本次要部署的分支，如 `*/feature/ofd-support`） |
| Script Path | `deploy/Jenkinsfile` |
| Lightweight checkout | 勾选 |

插件要求：仅 Git + Pipeline（apt 安装的 Jenkins 默认自带）。ssh 走宿主机既有免密通道，不依赖 sshagent 插件。

**目标机地址不再写入仓库**：`deploy/Jenkinsfile` 使用 `credentials('wps-converter-deploy-host')`。
在 Jenkins 的 `Manage Jenkins → Credentials → System → Global credentials` 新建：

- Kind：`Secret text`
- ID：`wps-converter-deploy-host`
- Secret：`root@<目标机IP>`
- Description：`wps-converter 目标机 SSH`（可选）

范围选 `Global`。真实 IP 只保存在 Jenkins 凭据中，构建日志会自动打码。

**前置**：`deploy/Jenkinsfile`、`deploy/deploy.sh` 已提交并推送到对应分支，然后点 Build Now。

## 2. 流水线阶段（Jenkinsfile）

| 阶段 | 内容 | 说明 |
| --- | --- | --- |
| 单测门禁 | 容器内 `uv sync --locked --dev && uv run --no-sync pytest` | Python 3.13；挂 `jwai-wps-uv-cache` 卷加速依赖安装 |
| 构建镜像 | `DOCKER_BUILDKIT=1 docker build -t wps-converter:<sha8> .` | Dockerfile 使用 `RUN --mount`，legacy builder 不支持，必须 BuildKit |
| 传输镜像 | `docker save \| gzip \| ssh … "gunzip \| docker load"` | 内网点对点，无需 registry；镜像较大，首次传输时间较长 |
| 部署 | `ssh root@CHANGE_ME_WPS_TARGET_IP bash -s < deploy/deploy.sh` | 行为见 §3 |

首次构建需要 Jenkins 能访问 Docker Hub、Debian 包源、PyPI、Maven Central 和华为毕昇 JDK/JRE 镜像。当前已配置以下国内加速：

| 来源 | 当前配置 | 说明 |
| --- | --- | --- |
| Debian apt | `mirrors.aliyun.com` | 最终镜像阶段固定阿里云；`ofd-build` 阶段可用 Jenkinsfile 的 `DEBIAN_MIRROR` 覆盖为清华/中科大源 |
| PyPI（uv 二进制） | `pypi.tuna.tsinghua.edu.cn` | Jenkinsfile 的 `PYPI_INDEX_URL`；`uv sync` 仍按 `uv.lock` 走 `pypi.org`，因为 `--locked` 不允许换源 |
| Maven | `maven.aliyun.com/repository/public` | 见 `ofd-converter/settings.xml`；依赖缺失时改回 Maven Central |
| 朱雀仿宋字体 | 仓库内置 `docker/fonts/ZhuqueFangsong-Regular.ttf` | 构建时直接 `COPY`，不访问 GitHub；SHA256 和许可证见 `docker/fonts/README.md` |
| Docker 基础镜像 | Docker Hub | 如拉取慢，在 Jenkins 的 Docker daemon 配置 `registry-mirrors`，不在仓库内改 |

如果 Jenkins 不能直连这些源，需要提前预热构建缓存或改用内部镜像源；否则构建阶段会失败。镜像包含 LibreOffice、JRE 和字体，体积较大，Jenkins 的 Docker 数据盘建议预留至少 10 GB，并在首次构建前确认 `df -h /var/lib/docker` 空间充足。

## 3. 部署脚本行为（deploy/deploy.sh）

- **隔离预检**：新镜像先在 `--network none`、不开放端口的临时容器内启动，用镜像自带的 `/health/ready` 健康检查轮询；`/health/ready` 会检查容器内 `soffice` 和 `ofd2pdf` 是否可执行。候选失败时直接退出，旧容器保持运行。
- **切换方式**：沿用目标机 compose。当前镜像先标记为 `wps-converter:previous`，新镜像标记为 compose 使用的 `wps-converter:local`，然后执行 `docker compose up -d --no-build --pull never converter`。`--no-build` 确保不会在目标机重新构建，`--pull never` 确保不访问镜像仓库。
- **健康门禁**：替换后轮询正式容器的 health 状态，默认 180 秒。检查的是 `/health/ready`，不是仅进程存活的 `/health/live`。
- **失败处理**：健康检查失败时打印最近 50 行 compose 日志；若存在上一版本镜像，自动把 `wps-converter:previous` 标记回 `wps-converter:local` 并重建容器，再次健康检查。任一环失败即退出非零，Jenkins 构建标红。
- **镜像保留**：目标机只留最近 5 个版本（按创建时间），保证回滚窗口。
- **注意**：`docker compose up` 会重建容器，**中断正在执行的转换请求**。服务无状态，调用方负责重试；建议选没有批量转换任务的窗口部署。
- **不覆盖目标机配置**：`.env`、`docker-compose.yml` 均由目标机人工管理，流水线不写入、不覆盖。
- **健康检查边界**：`/health/ready` 只验证 `soffice` / `ofd2pdf` 是否存在且可执行，不验证实际转换效果。部署后应使用脱敏样本回归 `.doc`、`.wps`、`.xls`、`.et`、`.ofd`，重点关注 LibreOffice 版式差异和 OFD 字体/印章失真。

## 4. 回滚

一条命令（镜像还在目标机保留窗口内即可）：

```bash
ssh root@CHANGE_ME_WPS_TARGET_IP IMAGE=wps-converter TAG=<要回退到的短哈希> \
  DEPLOY_DIR=/data/wps-converter ENV_FILE=/data/wps-converter/.env \
  HOST_PORT=8028 COMPOSE_SERVICE=converter \
  bash -s < deploy/deploy.sh
```

查历史版本短哈希：

```bash
ssh root@CHANGE_ME_WPS_TARGET_IP 'docker images wps-converter'
```

tag 即构建时的 git 短哈希，可与 `git log` 对上。

手动回滚（不经过预检，直接切 `previous`）：

```bash
ssh root@CHANGE_ME_WPS_TARGET_IP \
  'cd /data/wps-converter && docker tag wps-converter:previous wps-converter:local && docker compose up -d --no-build --pull never converter'
```

## 5. 日常运维命令速查（在 .17 上）

```bash
docker logs -f wps-converter-converter-1              # 跟踪日志（排障首选）
docker exec -it wps-converter-converter-1 bash        # 进容器（read-only 根，仅 tmpfs 可写）
curl http://CHANGE_ME_WPS_TARGET_IP:8028/health/ready            # 健康检查（含 soffice / ofd2pdf）
docker inspect wps-converter-converter-1 --format '{{.Config.Image}}'   # 当前版本
docker stats --no-stream wps-converter-converter-1    # 资源占用
```

若目标机 compose 项目名或服务名调整，容器名会变化，以 `docker compose ps` 为准。

## 6. 安全说明

- `.env` 只存在于 `/data/wps-converter/.env`，不进镜像、不进流水线；建议 `chmod 600`。
- 容器安全参数沿用 compose：非 root 用户 `converter`、`read_only`、`cap_drop: ALL`、`no-new-privileges`、`/tmp` tmpfs。不要为了调试方便去掉这些限制。
- 8028 是带 `X-API-Key` 鉴权的服务端口，绑定 `0.0.0.0` 是因为同网段后端需要访问；如网内存在不可信访问方，建议用防火墙限制来源。
- 不要在 Jenkinsfile、构建日志或本文档中写入 `CONVERTER_API_KEY` / `WPS_CONVERTER_API_KEY` 的真实值。
- Jenkins 以 root 直连目标机并拥有 docker 全权，是测试环境的已接受取舍；生产化时再换专用账号 + sudoers 白名单。

## 7. 目标切换与差异说明

### 7.1 切换目标机

默认目标是测试转换机 `CHANGE_ME_WPS_TARGET_IP`。如需切换，修改 `deploy/Jenkinsfile` 的 `environment`：

| 变量 | 说明 |
| --- | --- |
| `DEPLOY_HOST` | SSH 目标，如 `root@CHANGE_ME_WPS_TARGET_IP_ALT` |
| `DEPLOY_DIR` | 目标机 compose 所在目录，如 `/data/webapp/wps-converter` |
| `ENV_FILE` | 目标机 `.env` 路径 |
| `HOST_PORT` | 目标机宿主机端口；也可留空让 deploy.sh 从 `.env` 的 `CONVERTER_PORT` 读取 |

切换前确认目标机已有 Docker、Compose、`.env` 和 `docker-compose.yml`，且架构与 Jenkins 构建机一致。注意 `.9` 的 `8028` 已被 nginx 占用，若部署到 `.9` 需另选端口并同步修改后端 `WPS_CONVERTER_URL`。

### 7.2 与 Agent 的 Jenkinsfile 差异

- **与 Agent 的 Jenkinsfile 差异**：Agent 用 `docker run` 直接管理单容器；wps-converter 沿用目标机已有的 compose（`/data/wps-converter`），因此部署脚本会调用 `docker compose up`，并保留 `wps-converter:local` / `wps-converter:previous` 两个标签。
- **BuildKit 是硬要求**：Dockerfile 的 `RUN --mount=type=cache` 是 BuildKit 语法；Jenkinsfile 已显式设置 `DOCKER_BUILDKIT=1`。若 Jenkins 的 Docker 版本过旧，需要升级 Docker 或改用带 buildx 的构建方式。
- **架构必须匹配**：目标机 `.17` 为 x86_64；Jenkins 构建机需与目标机架构一致。可在 Jenkins 上执行 `docker version --format '{{.Server.Arch}}'` 与目标机对比。若目标机是 arm64（如生产 `.214`），不能在 x86 Jenkins 上直接构建后传输；需在 arm64 机器构建，或给流水线增加 `buildx --platform linux/arm64` 与 QEMU，当前方案不包含这部分。
- **arm64 离线目标**：使用 `deploy/package-release.sh` 在联网的 arm64 构建机生成镜像 + 源码发布包，目标机用 `deploy/apply-release.sh` 加载并复用 `deploy/deploy.sh` 完成预检、切换和回滚。步骤见 [`docs/offline-deployment.md`](../docs/offline-deployment.md#交付预构建镜像推荐用于-ofd-等依赖变更)。
- **目标机源码不更新**：流水线只更新镜像，不更新 `/data/wps-converter` 的源码 checkout。compose、`.env` 或系统依赖变化时，仍需人工在目标机处理。

## 8. 后续可选增强（当前不做）

- **push 自动构建**：GitLab 侧配 webhook 到 Jenkins（需 GitLab 插件），或先用零插件的 Poll SCM（`H/5 * * * *`）过渡。
- **多实例/蓝绿**：当前单实例 + 秒级替换 + 自动回滚已满足测试环境需要，不引入额外复杂度。
- **生产流水线**：生产目标为 arm64，需单独设计构建机与发布窗口，不与本测试流水线共用。
