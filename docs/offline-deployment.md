# 无互联网环境部署与更新

本文适用于以下场景：目标服务器只有一个特定 CPU 架构，部署后无法访问互联网，
但仍需要更新本服务。目标机保留构建缓存时可以离线重建；涉及新系统依赖或 arm64
交付时，推荐直接加载预构建镜像。

## 构建设计

Dockerfile 将构建分成三段：

1. uv 阶段：在 Python 基础镜像中安装固定版本的 `uv`。
2. OFD 构建阶段：使用毕昇 JDK 21 和 Maven 构建 `ofd-converter`，产出
   `ofd2pdf.jar`。
3. 运行阶段：复制 `pyproject.toml`、`uv.lock` 和 `README.md`，使用锁文件执行
   `uv sync --locked --no-dev --no-install-project` 安装 Python 依赖；再复制
   `src/` 源码和 OFD 构建产物。

因此，只修改 `src/` 时，Python 依赖、LibreOffice、毕昇运行时和 OFD 转换器所在层
仍可复用；只有源码层重新构建。`uv.lock` 是依赖安装的依据，修改 `pyproject.toml`
后必须同步更新并提交它。

依赖安装使用 BuildKit 的 uv 缓存挂载，OFD 构建使用 Maven 本地仓库缓存挂载。
缓存由本机 builder 保存，代码层重建不会触发依赖下载；依赖层需要重建时，
`UV_OFFLINE=1` 会强制 uv 只使用本机缓存。

Compose 的 `build.pull: false` 禁止构建时主动拉取 `FROM` 镜像。它不会把缺失的
基础镜像、系统软件包或 Python 包变成可用的离线资源；这些资源必须在进入隔离环境前
准备好。

## 交付预构建镜像（推荐用于 OFD 等依赖变更）

新增 OFD 转换后，目标机离线构建不再是最省事的路径：镜像新增了毕昇 JRE、
OFDRW/Maven 依赖、LibreOffice/字体等 Debian 包和 arm64 基础镜像。更可靠的方式是在
一台联网的 arm64 构建机上生成完整镜像，再把镜像和源码一起带进隔离环境。

### 1. 在 arm64 构建机生成发布包

构建机需要 Docker，并且 Docker 平台必须是 Linux arm64。不同 Docker 版本可能把架构
显示为 `arm64` 或 `aarch64`，脚本两者都接受：

```bash
docker info --format '{{.OSType}}/{{.Architecture}}'
# linux/arm64 或 linux/aarch64

docker version --format '{{.Server.Os}}/{{.Server.Arch}}'
# linux/arm64
```

在仓库根目录执行：

```bash
DEBIAN_MIRROR=deb.debian.org deploy/package-release.sh
```

脚本会：

- 检查工作区是否干净；有未提交改动时直接失败，避免镜像和源码包不一致；
- 以 `--platform linux/arm64` 构建镜像；
- 检查镜像内 `soffice`、毕昇 JRE、`ofd2pdf` 和 Python 依赖；
- 导出镜像、源码 tar、git bundle、服务端脚本和 `SHA256SUMS`；
- 镜像 tag 默认直接使用 git 短哈希，例如 `wps-converter:62ea08ac`；
- 默认输出到 `~/gov-llm-releases/wps-converter-<短哈希>/`，并生成同名 `.tar`
  单文件传输包。

当前离线单机交付用 hash 作为 tag 即可。如果以后把同一 commit 的 x86_64 和 arm64
镜像推到同一个 registry，tag 会冲突，这时再用 `--tag <短哈希>-arm64` 区分。

常用选项：

```bash
# 复用已经构建好的镜像
deploy/package-release.sh --skip-build --tag <短哈希>

# 指定输出目录
deploy/package-release.sh --output /data/releases

# 不生成外层单文件 tar，改为直接传发布目录
deploy/package-release.sh --no-transfer-archive
```

发布包内容：

```text
wps-converter-<短哈希>/
  wps-converter-<短哈希>-image.tar.gz
  wps-converter-<短哈希>-src.tar.gz
  wps-converter-<短哈希>.bundle
  deploy.sh
  apply-release.sh
  release.env
  README.txt
  SHA256SUMS
```

### 2. 传到目标机并校验

```bash
scp wps-converter-<短哈希>.tar \
    wps-converter-<短哈希>.tar.sha256 \
    root@<目标机>:/data/

ssh root@<目标机> \
  'cd /data && sha256sum -c wps-converter-<短哈希>.tar.sha256'
```

解包后还会校验包内每个文件：

```bash
cd /data
tar -xf wps-converter-<短哈希>.tar
cd wps-converter-<短哈希>
sha256sum -c SHA256SUMS
```

### 3. 目标机一键加载、更新代码并切换

```bash
cd /data/wps-converter-<短哈希>
./apply-release.sh
```

`apply-release.sh` 会依次完成：

1. 校验发布包文件；
2. 确认目标机 Docker 平台为 `linux/arm64` 或 `linux/aarch64`；
3. `docker load` 镜像并再次检查镜像架构；
4. 把源码解压到 `<deploy-dir>/source/<tag>`，并更新 `current` 符号链接；
5. 如果 `CODE_DIR` 是 git 仓库，用发布包里的 bundle 更新到发布提交；
6. 调用同目录的 `deploy.sh`：候选容器预检 → 切换 `wps-converter:local` →
   `/health/ready` 健康门禁 → 失败自动回滚。

默认路径：

| 变量 | 默认值 | 说明 |
| --- | --- | --- |
| `DEPLOY_DIR` | `/data/wps-converter` | compose 和 `.env` 所在目录 |
| `ENV_FILE` | `<DEPLOY_DIR>/.env` | 运行时环境文件 |
| `CODE_DIR` | `/opt/wps-converter` | 服务端代码仓库；有 git/bundle 时自动 clone/更新 |
| `SOURCE_ROOT` | `<DEPLOY_DIR>/source` | 版本化源码快照目录 |
| `HOST_PORT` | 空 | 留空时由 `deploy.sh` 从 `.env` 的 `CONVERTER_PORT` 读取 |
| `COMPOSE_SERVICE` | `converter` | compose 服务名 |

按目标机实际路径覆盖：

```bash
DEPLOY_DIR=/data/wps-converter \
ENV_FILE=/data/wps-converter/.env \
CODE_DIR=/opt/wps-converter \
SOURCE_ROOT=/data/wps-converter/source \
HOST_PORT=8028 \
COMPOSE_SERVICE=converter \
./apply-release.sh
```

只加载镜像和更新代码，不切换服务：

```bash
./apply-release.sh --no-deploy
```

只切换镜像，不更新代码：

```bash
./apply-release.sh --no-code
```

`CODE_DIR` 有未提交改动或未包含在发布包中的本地提交时，默认拒绝更新；确认可以丢弃后
再加 `--force-code`。如果 `CODE_DIR` 不是 git 仓库且非空，脚本会中止，避免覆盖未知
内容；可改用 `--no-code` 或移走该目录。缺少 git/bundle 时不会创建 `CODE_DIR`，但最新
源码始终在 `SOURCE_ROOT/current`。

不要把 `CODE_DIR` 直接指向 `DEPLOY_DIR`（通常包含目标机的 `.env` 和
`docker-compose.yml`），否则 git 切换代码时可能覆盖这些人工维护的文件。

### 4. 代码快照与仓库同步

- 每个发布版本都会在 `SOURCE_ROOT/<tag>` 保留一份代码快照，`current` 指向最新版本；
  快照来自与镜像相同的 git 提交，便于排查和后续构建。
- `CODE_DIR` 是 git 仓库时，`apply-release.sh` 会从发布包的 git bundle 更新到同一提交。
  如果目录不存在或为空，有 git/bundle 时会 `git clone` bundle 创建仓库；没有 git 或
  bundle 时不创建 `CODE_DIR`，只保留源码快照。
- `.env`、`docker-compose.yml` 由目标机人工维护，发布包不会覆盖。

### 5. 回滚

`deploy.sh` 在健康检查失败时会自动回滚到切换前的镜像。手动回滚：

```bash
cd /data/wps-converter
docker tag wps-converter:previous wps-converter:local
docker compose up -d --no-build --pull never converter
```

### 6. 验收

```bash
curl -fsS http://127.0.0.1:8028/health/ready
# 应返回 soffice=true、ofdConverter=true
```

再用真实 `.ofd` 样本调用一次 `/api/v1/convert`，确认返回 `%PDF-` 开头且可解析的
PDF。OFD 字体替换、电子签章和印章可能失真，仍需业务侧按真实样本验收。

目标机注意事项：

- Docker 建议 20.10 及以上；平台必须是 Linux arm64（显示为 `linux/arm64` 或
  `linux/aarch64` 均可）。
- 镜像约 1.5 GB，确认 `/var/lib/docker` 和 `/data` 空间充足。
- 目标 compose 必须保留可写 `/tmp`（当前 compose 使用 tmpfs）；OFD 转换需要临时文件。
- 旧 compose 如果显式设置了 `OFD_CONVERTER_PATH`，确认是 `ofd2pdf` 或删除该变量。
- 不要在目标机执行 `docker compose up --build`；部署脚本使用 `--no-build --pull never`。

### 7. 为什么不传依赖包

OFD 升级涉及 apt、Maven、PyPI 和 JDK/JRE 四类资源，还要匹配 arm64 和 Debian
bookworm。只传“依赖包”通常需要改 Dockerfile、准备本地 apt/Maven/PyPI 源和完整缓存，
漏掉一个传递依赖就会在构建后半段失败。镜像方式把运行时依赖封成一个已验证的镜像，
目标机只负责加载和切换，回滚也更简单。

如果安全制度禁止导入镜像、必须目标机自行构建，建议维护一个预装好工具链和依赖的
内部 `builder` 基础镜像，而不是每次手工拼依赖包。

### 8. 构建机常见问题

- **架构显示不一致**：部分 Docker 版本在 `docker info` 中显示 `linux/aarch64`，
  而 `docker version` 和镜像元数据显示 `linux/arm64`。发布脚本两者都接受。
- **apt 镜像不可达**：构建机若使用 HTTP 代理，Docker 构建容器可能无法访问默认的
  Debian 镜像源。可设置 `DEBIAN_MIRROR=deb.debian.org`，或在 Docker Desktop 中
  配置构建代理后再试。
- **毕昇 JDK/JRE 下载断流**：Dockerfile 已加下载重试和超时；仍失败时换网络或
  预热本地镜像。
- **macOS Bash 3.2**：脚本中变量后紧跟中文时使用 `${VAR}` 形式，避免 Bash 3.2
  把中文字节并入变量名。
- **工作区不干净**：发布脚本会拒绝构建，因为镜像来自工作区而源码包来自 HEAD，
  两者可能不一致。先提交或 stash 再打包。

## 一次性准备

应在目标服务器仍可联网时完成以下步骤。由于镜像内包含 LibreOffice 和可能带有
CPU/平台相关 wheel 的 Python 依赖，最好直接在目标服务器上完成第一次构建：

```bash
docker info --format '{{.OSType}}/{{.Architecture}}'
docker pull python:3.13-slim-bookworm
UV_OFFLINE=0 docker compose build --pull
docker image inspect wps-converter:local --format '{{.Os}}/{{.Architecture}}'
```

第一次构建会访问 Docker 基础镜像、Dockerfile 中配置的 Debian 镜像源、Python
包索引、Maven Central 和华为毕昇 JDK 镜像站。朱雀仿宋字体已内置在仓库
`docker/fonts/`，构建时不需要访问 GitHub。构建成功后保留以下内容，不要执行会
清理它们的命令：

- `wps-converter:local` 镜像；
- `python:3.13-slim-bookworm` 本地镜像；
- Docker builder 的构建缓存、uv 缓存挂载和 Maven 本地仓库缓存挂载。

如果目标环境不能访问上述站点，需要在第一次联网构建时完成并导出镜像，或者把
毕昇 JDK/JRE 和 Maven 依赖提前放入本地缓存或内部镜像源。

如果目标服务器从未联网，则必须通过受控介质导入匹配目标架构的基础镜像和依赖包；
没有这些输入，离线构建无法凭空安装新依赖。

## 只更新代码

只修改 `src/` 时，在目标服务器执行：

```bash
UV_OFFLINE=1 docker compose up -d --build --pull never
docker compose ps
```

不要加 `--no-cache`，也不要清理 builder 缓存。Compose 中的 `build.pull: false`
保证构建不主动拉取基础镜像，`UV_OFFLINE=1` 保证 uv 不访问包索引，`--pull never`
保证启动阶段不拉取。只要基础镜像、依赖层、uv 缓存和 Maven 缓存仍在本机，这个
流程不需要互联网。uv 安装层和 OFD 构建层也被缓存；如果它们被重建，需要本机已有
对应的 PyPI/Maven 资源。

## 修改或新增 Python 依赖

修改 `pyproject.toml` 后，应在目标机仍可联网或可访问内部 Python 源时更新锁文件：

```bash
uv lock
uv lock --check
```

然后执行：

```bash
UV_OFFLINE=1 docker compose build --pull=false
```

如果新版本的 wheel 已在本机 uv 缓存中，构建可以离线完成；否则构建会失败，不会联网。
必须先在目标机联网时预热缓存，或把新依赖的 wheel、uv 缓存或可访问的内部 PyPI 镜像
带入隔离环境。对于 `pydantic-core`、`httptools`、
`uvloop` 等包含原生代码的依赖，wheel 必须匹配目标操作系统、Python 3.13 和 CPU 架构。

修改 LibreOffice、字体、毕昇 JDK/JRE、OFDRW 版本或其他 Debian 软件包时同理：
需要本地 Debian 镜像、对应的 `.deb`/归档文件、Maven 依赖，或在目标服务器重新联网
构建基础层。代码层缓存不能替代这些外部构建输入。

## 版本与回滚

更新前保留当前镜像标签，构建新版本后再启动：

```bash
docker tag wps-converter:local wps-converter:previous
UV_OFFLINE=1 docker compose build --pull=false
docker compose up -d --no-build --pull never
```

如果新版本失败，可将 `previous` 重新标记为 `local` 后再次启动。也可以在隔离前
导出镜像，在目标服务器使用 `docker load` 导入：

```bash
docker save -o wps-converter.tar wps-converter:local
docker load -i wps-converter.tar
```

## 常见边界

- 代码更新不需要新系统包或 Python 包时，可以长期离线构建。
- 新依赖不是代码，必须额外提供对应的离线安装介质或内部软件源。
- 完全离线时不能在目标机凭空生成新依赖的锁文件；应在联网准备阶段生成并带入
  `pyproject.toml` 与 `uv.lock`。
- 不同 CPU 架构的镜像不能直接替代目标镜像；目标架构的基础镜像和二进制依赖必须
  单独准备。
