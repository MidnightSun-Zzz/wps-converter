# 无互联网环境部署与更新

本文适用于以下场景：目标服务器只有一个特定 CPU 架构，部署后无法访问互联网，
但仍需要频繁修改本服务代码并重新执行 `docker compose build`。

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
