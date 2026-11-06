#!/usr/bin/env bash
# 在联网的 arm64 构建机上执行：构建 linux/arm64 镜像，生成可离线交付的发布包。
#
# 发布包包含：镜像 tar.gz、源码 tar.gz、git bundle、目标机部署脚本、校验文件。
# 目标机不构建、不联网，只加载镜像并切换服务。
set -Eeuo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
REPO=$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel 2>/dev/null) || {
    echo "错误：请在 wps-converter Git 仓库内运行。" >&2
    exit 1
}

IMAGE=${IMAGE:-wps-converter}
SHORT_COMMIT=$(git -C "$REPO" rev-parse --short=8 HEAD)
TAG=${TAG:-arm64-$SHORT_COMMIT}
OUTPUT_DIR=${OUTPUT_DIR:-$HOME/gov-llm-releases}
SKIP_BUILD=0
SKIP_SMOKE=0
MAKE_TRANSFER_ARCHIVE=1

usage() {
    cat <<'EOF'
用法: deploy/package-release.sh [选项]

在 arm64 构建机上构建 linux/arm64 镜像，并打包为可离线交付的发布目录。

选项:
  --image NAME            镜像名，默认 wps-converter
  --tag TAG               镜像 tag，默认 arm64-<git 短哈希>
  --output DIR            输出根目录，默认 ~/gov-llm-releases
  --skip-build            复用已存在的镜像，不重新构建
  --skip-smoke            跳过镜像内运行时组件检查
  --no-transfer-archive   不生成外层单文件 tar
  -h, --help              显示帮助

环境变量:
  DEBIAN_MIRROR           传给 Dockerfile 的 Debian 镜像源，例如 deb.debian.org
  PYPI_INDEX_URL          传给 Dockerfile 的 PyPI 镜像源（仅用于安装 uv 二进制）

示例:
  DEBIAN_MIRROR=deb.debian.org deploy/package-release.sh
  deploy/package-release.sh --skip-build --tag arm64-62ea08ac
EOF
}

fail() {
    echo "错误：$*" >&2
    exit 1
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --image)
            [[ $# -ge 2 ]] || fail "$1 缺少参数"
            IMAGE=$2
            shift 2
            ;;
        --tag)
            [[ $# -ge 2 ]] || fail "$1 缺少参数"
            TAG=$2
            shift 2
            ;;
        --output)
            [[ $# -ge 2 ]] || fail "$1 缺少参数"
            OUTPUT_DIR=$2
            shift 2
            ;;
        --skip-build)
            SKIP_BUILD=1
            shift
            ;;
        --skip-smoke)
            SKIP_SMOKE=1
            shift
            ;;
        --no-transfer-archive)
            MAKE_TRANSFER_ARCHIVE=0
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            usage >&2
            fail "未知参数：$1"
            ;;
    esac
done

cd "$REPO"

[[ "$TAG" =~ ^[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}$ ]] \
    || fail "非法 tag：$TAG"
[[ -n "$IMAGE" && "$IMAGE" != *[[:space:]]* ]] \
    || fail "非法镜像名：$IMAGE"

COMMIT=$(git rev-parse HEAD)
SHORT_COMMIT=$(git rev-parse --short=8 HEAD)
BRANCH=$(git branch --show-current)
[[ -n "$BRANCH" ]] || BRANCH=main
CREATED_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)

if [[ -n "$(git -c core.autocrlf=true status --porcelain)" ]]; then
    echo "错误：工作区有未提交改动。" >&2
    echo "镜像会包含工作区内容，而源码包来自 HEAD，两者会不一致。" >&2
    echo "请先提交或 stash 后重试：" >&2
    git status --short >&2
    exit 1
fi

[[ -f Dockerfile ]] || fail "缺少 Dockerfile"
[[ -f pyproject.toml && -f uv.lock ]] || fail "缺少 pyproject.toml 或 uv.lock"
command -v docker >/dev/null 2>&1 || fail "未找到 docker"
command -v git >/dev/null 2>&1 || fail "未找到 git"

BUILD_PLATFORM=$(docker info --format '{{.OSType}}/{{.Architecture}}' 2>/dev/null || true)
if [[ -z "$BUILD_PLATFORM" || "$BUILD_PLATFORM" == "/" ]]; then
    fail "无法读取 Docker 平台，请确认 Docker Desktop/daemon 已启动。"
fi
if [[ "$BUILD_PLATFORM" != "linux/arm64" && "$BUILD_PLATFORM" != "linux/aarch64" ]]; then
    fail "构建机 Docker 平台为 ${BUILD_PLATFORM}，需要 linux/arm64 或 linux/aarch64。
请在 Apple Silicon Mac 或 arm64 Linux 构建机上执行；x86 构建机需要 buildx/QEMU，本脚本不处理。"
fi

if [[ "$SKIP_BUILD" -eq 0 ]]; then
    BUILD_ARGS=()
    if [[ -n "${DEBIAN_MIRROR:-}" ]]; then
        BUILD_ARGS+=(--build-arg "DEBIAN_MIRROR=$DEBIAN_MIRROR")
    fi
    if [[ -n "${PYPI_INDEX_URL:-}" ]]; then
        BUILD_ARGS+=(--build-arg "PYPI_INDEX_URL=$PYPI_INDEX_URL")
    fi
    echo "[..] 构建 $IMAGE:$TAG (linux/arm64)"
    DOCKER_BUILDKIT=1 docker build \
        --platform linux/arm64 \
        ${BUILD_ARGS[@]+"${BUILD_ARGS[@]}"} \
        --label "org.opencontainers.image.revision=$COMMIT" \
        --label "org.opencontainers.image.version=$TAG" \
        --label "org.opencontainers.image.created=$CREATED_AT" \
        -t "$IMAGE:$TAG" \
        "$REPO"
else
    echo "[..] 跳过构建，复用 $IMAGE:$TAG"
    docker image inspect "$IMAGE:$TAG" >/dev/null 2>&1 \
        || fail "镜像不存在：$IMAGE:$TAG"
    IMAGE_REVISION=$(docker image inspect "$IMAGE:$TAG" \
        --format '{{index .Config.Labels "org.opencontainers.image.revision"}}' \
        2>/dev/null || true)
    if [[ -n "$IMAGE_REVISION" && "$IMAGE_REVISION" != "$COMMIT" ]]; then
        fail "镜像 revision=$IMAGE_REVISION 与当前提交 $COMMIT 不一致，不能复用。"
    fi
    if [[ -z "$IMAGE_REVISION" ]]; then
        echo "[WARN] 镜像缺少 org.opencontainers.image.revision 标签，无法校验它与当前提交是否一致。" >&2
    fi
fi

ACTUAL_PLATFORM=$(docker image inspect "$IMAGE:$TAG" --format '{{.Os}}/{{.Architecture}}')
[[ "$ACTUAL_PLATFORM" == "linux/arm64" || "$ACTUAL_PLATFORM" == "linux/aarch64" ]] \
    || fail "镜像平台为 ${ACTUAL_PLATFORM}，不是 linux/arm64"

if [[ "$SKIP_SMOKE" -eq 0 ]]; then
    echo "[..] 检查镜像内 LibreOffice / 毕昇 JRE / ofd2pdf / Python 依赖"
    docker run --rm --entrypoint sh "$IMAGE:$TAG" -c '
        set -e
        command -v soffice >/dev/null
        /opt/bisheng-jre/bin/java -version >/dev/null 2>&1
        ( /usr/local/bin/ofd2pdf 2>&1 || true ) | grep -q "usage: ofd2pdf"
        python -c "import pypdf, fastapi"
    '
fi

RELEASE_NAME="$IMAGE-$TAG"
RELEASE_NAME=${RELEASE_NAME//\//-}
RELEASE_DIR="$OUTPUT_DIR/$RELEASE_NAME"
IMAGE_ARCHIVE="$RELEASE_NAME-image.tar.gz"
SOURCE_ARCHIVE="$RELEASE_NAME-src.tar.gz"
GIT_BUNDLE="$RELEASE_NAME.bundle"
README_FILE="README.txt"

rm -rf "$RELEASE_DIR"
mkdir -p "$RELEASE_DIR"

echo "[..] 导出镜像 $IMAGE:$TAG"
docker save "$IMAGE:$TAG" | gzip -1 > "$RELEASE_DIR/$IMAGE_ARCHIVE"

echo "[..] 导出源码 $COMMIT"
git archive --format=tar.gz --output "$RELEASE_DIR/$SOURCE_ARCHIVE" "$COMMIT"

BUNDLE_VALUE=""
if git bundle create "$RELEASE_DIR/$GIT_BUNDLE" --all >/dev/null 2>&1; then
    BUNDLE_VALUE="$GIT_BUNDLE"
else
    rm -f "$RELEASE_DIR/$GIT_BUNDLE"
    echo "[WARN] 当前仓库无法生成 git bundle（可能是浅克隆），发布包将只包含源码 tar。" >&2
fi

cp -p "$SCRIPT_DIR/deploy.sh" "$RELEASE_DIR/deploy.sh"
cp -p "$SCRIPT_DIR/apply-release.sh" "$RELEASE_DIR/apply-release.sh"
chmod 0755 "$RELEASE_DIR/deploy.sh" "$RELEASE_DIR/apply-release.sh"

cat > "$RELEASE_DIR/release.env" <<EOF
FORMAT_VERSION=1
IMAGE=$IMAGE
TAG=$TAG
PLATFORM=linux/arm64
GIT_COMMIT=$COMMIT
GIT_BRANCH=$BRANCH
IMAGE_ARCHIVE=$IMAGE_ARCHIVE
SOURCE_ARCHIVE=$SOURCE_ARCHIVE
GIT_BUNDLE=$BUNDLE_VALUE
CREATED_AT=$CREATED_AT
EOF

cat > "$RELEASE_DIR/$README_FILE" <<EOF
wps-converter arm64 离线发布包
================================
镜像: $IMAGE:$TAG
平台: linux/arm64
提交: $COMMIT
分支: $BRANCH
构建时间: $CREATED_AT

文件:
  $IMAGE_ARCHIVE    Docker 镜像（gzip）
  $SOURCE_ARCHIVE   与镜像对应的源码快照
  ${BUNDLE_VALUE:-（无 git bundle）}
  deploy.sh         目标机镜像切换/回滚脚本
  apply-release.sh  目标机一键加载 + 更新代码 + 部署
  release.env       发布元数据
  SHA256SUMS        校验文件

目标机执行:
  sha256sum -c SHA256SUMS
  ./apply-release.sh

可选环境变量:
  DEPLOY_DIR=/data/wps-converter
  ENV_FILE=/data/wps-converter/.env
  CODE_DIR=/opt/wps-converter
  SOURCE_ROOT=/data/wps-converter/source
  HOST_PORT=8028
  COMPOSE_SERVICE=converter

只加载镜像/更新代码、不切换服务:
  ./apply-release.sh --no-deploy

不更新代码:
  ./apply-release.sh --no-code

代码目录有本地改动/本地提交、确认丢弃后强制更新:
  ./apply-release.sh --force-code

注意:
  - 目标机必须是 Linux arm64，Docker 平台显示为 linux/arm64 或 linux/aarch64。
  - .env 和 docker-compose.yml 由目标机维护，发布包不会覆盖。
  - 不要使用 docker compose up --build；部署脚本使用 --no-build --pull never。
EOF

echo "[..] 生成 SHA256SUMS"
(
    cd "$RELEASE_DIR"
    FILES=(
        "$IMAGE_ARCHIVE"
        "$SOURCE_ARCHIVE"
        "$README_FILE"
        "apply-release.sh"
        "deploy.sh"
        "release.env"
    )
    if [[ -n "$BUNDLE_VALUE" ]]; then
        FILES+=("$BUNDLE_VALUE")
    fi
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "${FILES[@]}" > SHA256SUMS
    else
        shasum -a 256 "${FILES[@]}" > SHA256SUMS
    fi
)

TRANSFER_ARCHIVE=""
if [[ "$MAKE_TRANSFER_ARCHIVE" -eq 1 ]]; then
    TRANSFER_ARCHIVE="$OUTPUT_DIR/$RELEASE_NAME.tar"
    echo "[..] 生成单文件传输包 $TRANSFER_ARCHIVE"
    tar -C "$OUTPUT_DIR" -cf "$TRANSFER_ARCHIVE" "$RELEASE_NAME"
    (
        cd "$OUTPUT_DIR"
        if command -v sha256sum >/dev/null 2>&1; then
            sha256sum "$(basename "$TRANSFER_ARCHIVE")" \
                > "$(basename "$TRANSFER_ARCHIVE").sha256"
        else
            shasum -a 256 "$(basename "$TRANSFER_ARCHIVE")" \
                > "$(basename "$TRANSFER_ARCHIVE").sha256"
        fi
    )
fi

echo
echo "[ OK ] 发布包目录: $RELEASE_DIR"
echo "        镜像: $IMAGE:$TAG ($ACTUAL_PLATFORM)"
echo "        源码: $SOURCE_ARCHIVE"
if [[ -n "$TRANSFER_ARCHIVE" ]]; then
    echo "        单文件: $TRANSFER_ARCHIVE"
fi
echo
echo "目标机步骤:"
if [[ -n "$TRANSFER_ARCHIVE" ]]; then
    echo "  scp $(basename "$TRANSFER_ARCHIVE") $(basename "$TRANSFER_ARCHIVE").sha256 root@<目标机>:/data/"
    echo "  ssh root@<目标机> 'cd /data && sha256sum -c $(basename "$TRANSFER_ARCHIVE").sha256 && tar -xf $(basename "$TRANSFER_ARCHIVE")'"
    echo "  ssh root@<目标机> 'cd /data/$RELEASE_NAME && ./apply-release.sh'"
else
    echo "  scp -r $RELEASE_DIR root@<目标机>:/data/"
    echo "  ssh root@<目标机> 'cd /data/$RELEASE_NAME && sha256sum -c SHA256SUMS && ./apply-release.sh'"
fi
