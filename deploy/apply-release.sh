#!/usr/bin/env bash
# 在目标机（Linux arm64）执行：校验发布包、加载镜像、更新代码快照/可选 git 仓库，
# 然后复用 deploy.sh 完成候选容器预检、服务切换和失败回滚。
set -Eeuo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
RELEASE_DIR=${RELEASE_DIR:-$SCRIPT_DIR}
DEPLOY_DIR=${DEPLOY_DIR:-/data/wps-converter}
ENV_FILE=${ENV_FILE:-$DEPLOY_DIR/.env}
COMPOSE_SERVICE=${COMPOSE_SERVICE:-converter}
HOST_PORT=${HOST_PORT:-}
CODE_DIR=${CODE_DIR:-/opt/wps-converter}
SOURCE_ROOT=${SOURCE_ROOT:-$DEPLOY_DIR/source}
NO_DEPLOY=0
NO_CODE=0
FORCE_CODE=0

usage() {
    cat <<'EOF'
用法: ./apply-release.sh [选项]

在目标机加载离线发布包中的镜像，并切换到新版本。

选项:
  --release-dir DIR   发布包目录，默认脚本所在目录
  --deploy-dir DIR    compose 目录，默认 /data/wps-converter
  --env-file FILE     运行时环境文件，默认 <deploy-dir>/.env
  --code-dir DIR      服务端代码仓库/源码目录，默认 /opt/wps-converter
  --source-root DIR   版本化源码快照根目录，默认 <deploy-dir>/source
  --host-port PORT    宿主机端口；留空时由 deploy.sh 从 .env 读取
  --no-deploy         只加载镜像、更新代码，不切换服务
  --no-code           只加载镜像/部署，不更新代码
  --force-code        代码目录有未提交改动时强制覆盖
  -h, --help          显示帮助

环境变量:
  CODE_DIR            服务端已有 git 仓库路径；有 git/bundle 时自动 clone 创建
  SOURCE_ROOT         保存 <tag> 源码快照和 current 符号链接
EOF
}

fail() {
    echo "错误：$*" >&2
    exit 1
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --release-dir)
            [[ $# -ge 2 ]] || fail "$1 缺少参数"
            RELEASE_DIR=$2
            shift 2
            ;;
        --deploy-dir)
            [[ $# -ge 2 ]] || fail "$1 缺少参数"
            DEPLOY_DIR=$2
            ENV_FILE=${ENV_FILE:-$DEPLOY_DIR/.env}
            shift 2
            ;;
        --env-file)
            [[ $# -ge 2 ]] || fail "$1 缺少参数"
            ENV_FILE=$2
            shift 2
            ;;
        --code-dir)
            [[ $# -ge 2 ]] || fail "$1 缺少参数"
            CODE_DIR=$2
            shift 2
            ;;
        --source-root)
            [[ $# -ge 2 ]] || fail "$1 缺少参数"
            SOURCE_ROOT=$2
            shift 2
            ;;
        --host-port)
            [[ $# -ge 2 ]] || fail "$1 缺少参数"
            HOST_PORT=$2
            shift 2
            ;;
        --no-deploy)
            NO_DEPLOY=1
            shift
            ;;
        --no-code)
            NO_CODE=1
            shift
            ;;
        --force-code)
            FORCE_CODE=1
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

RELEASE_DIR=$(cd -- "$RELEASE_DIR" 2>/dev/null && pwd) \
    || fail "发布包目录不存在：$RELEASE_DIR"
cd "$RELEASE_DIR"

[[ -f release.env ]] || fail "缺少 release.env：$RELEASE_DIR/release.env"
[[ -f SHA256SUMS ]] || fail "缺少 SHA256SUMS"

echo "[..] 校验发布包"
if command -v sha256sum >/dev/null 2>&1; then
    sha256sum -c SHA256SUMS
else
    shasum -a 256 -c SHA256SUMS
fi

# shellcheck disable=SC1091
source ./release.env

: "${FORMAT_VERSION:?release.env 缺少 FORMAT_VERSION}"
: "${IMAGE:?release.env 缺少 IMAGE}"
: "${TAG:?release.env 缺少 TAG}"
: "${PLATFORM:?release.env 缺少 PLATFORM}"
: "${IMAGE_ARCHIVE:?release.env 缺少 IMAGE_ARCHIVE}"
: "${SOURCE_ARCHIVE:?release.env 缺少 SOURCE_ARCHIVE}"
: "${GIT_COMMIT:?release.env 缺少 GIT_COMMIT}"

[[ "$FORMAT_VERSION" == "1" ]] \
    || fail "不支持的发布包格式：$FORMAT_VERSION"
[[ "$PLATFORM" == "linux/arm64" ]] \
    || fail "发布包平台为 ${PLATFORM}，不是 linux/arm64"
[[ "$TAG" =~ ^[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}$ ]] \
    || fail "release.env 中的 TAG 非法：$TAG"
[[ -n "$IMAGE" && "$IMAGE" != *[[:space:]]* ]] \
    || fail "release.env 中的 IMAGE 非法：$IMAGE"
[[ -f "$IMAGE_ARCHIVE" ]] || fail "缺少镜像文件：$IMAGE_ARCHIVE"
[[ -f "$SOURCE_ARCHIVE" ]] || fail "缺少源码文件：$SOURCE_ARCHIVE"

TARGET_PLATFORM=$(docker info --format '{{.OSType}}/{{.Architecture}}' 2>/dev/null || true)
if [[ -z "$TARGET_PLATFORM" || "$TARGET_PLATFORM" == "/" ]]; then
    fail "无法读取目标机 Docker 平台，请确认 Docker 已启动。"
fi
[[ "$TARGET_PLATFORM" == "linux/arm64" || "$TARGET_PLATFORM" == "linux/aarch64" ]] \
    || fail "目标机 Docker 平台为 ${TARGET_PLATFORM}，需要 linux/arm64 或 linux/aarch64"

echo "[..] 加载镜像 $IMAGE:$TAG"
gunzip -c "$IMAGE_ARCHIVE" | docker load

ACTUAL_PLATFORM=$(docker image inspect "$IMAGE:$TAG" \
    --format '{{.Os}}/{{.Architecture}}' 2>/dev/null) \
    || fail "镜像加载后不存在：$IMAGE:$TAG"
[[ "$ACTUAL_PLATFORM" == "linux/arm64" || "$ACTUAL_PLATFORM" == "linux/aarch64" ]] \
    || fail "加载后的镜像平台为 ${ACTUAL_PLATFORM}，不是 linux/arm64"

IMAGE_REVISION=$(docker image inspect "$IMAGE:$TAG" \
    --format '{{index .Config.Labels "org.opencontainers.image.revision"}}' \
    2>/dev/null || true)
if [[ -n "$IMAGE_REVISION" && "$IMAGE_REVISION" != "$GIT_COMMIT" ]]; then
    fail "镜像 revision=$IMAGE_REVISION 与源码提交 $GIT_COMMIT 不一致。"
fi

if [[ "$NO_CODE" -eq 0 ]]; then
    echo "[..] 更新代码快照"
    SNAPSHOT_NAME=${TAG//\//-}
    mkdir -p "$SOURCE_ROOT"
    TMP_DIR=$(mktemp -d "$SOURCE_ROOT/.tmp.XXXXXX")
    cleanup_snapshot() {
        rm -rf "$TMP_DIR"
    }
    trap cleanup_snapshot EXIT

    tar -xzf "$SOURCE_ARCHIVE" -C "$TMP_DIR"
    [[ -f "$TMP_DIR/Dockerfile" ]] || fail "源码包结构异常：缺少 Dockerfile"

    rm -rf "$SOURCE_ROOT/$SNAPSHOT_NAME"
    mv "$TMP_DIR" "$SOURCE_ROOT/$SNAPSHOT_NAME"
    ln -sfn "$SNAPSHOT_NAME" "$SOURCE_ROOT/current"
    trap - EXIT
    echo "        快照: $SOURCE_ROOT/${SNAPSHOT_NAME}（current 已指向该版本）"

    if [[ -n "${CODE_DIR:-}" ]]; then
        if [[ -d "$CODE_DIR/.git" ]]; then
            command -v git >/dev/null 2>&1 \
                || fail "$CODE_DIR 是 git 仓库，但目标机未安装 git；请安装 git 或使用 --no-code。"
            if [[ -n "$(git -C "$CODE_DIR" status --porcelain)" && "$FORCE_CODE" -eq 0 ]]; then
                fail "$CODE_DIR 有未提交改动，未更新代码仓库。
请先提交/stash，或使用 --force-code 丢弃本地改动，或使用 --no-code 跳过代码更新。"
            fi
            [[ -n "${GIT_BUNDLE:-}" && -f "$GIT_BUNDLE" ]] \
                || fail "发布包缺少 git bundle，无法更新 ${CODE_DIR}；可使用 --no-code 跳过。"
            if [[ "$FORCE_CODE" -eq 1 && -n "$(git -C "$CODE_DIR" status --porcelain)" ]]; then
                echo "[WARN] --force-code：丢弃 $CODE_DIR 的本地改动" >&2
            fi
            git -C "$CODE_DIR" fetch --force "$RELEASE_DIR/$GIT_BUNDLE" \
                "+refs/heads/*:refs/remotes/release/*" \
                || git -C "$CODE_DIR" fetch --force "$RELEASE_DIR/$GIT_BUNDLE"
            if git -C "$CODE_DIR" rev-parse --verify HEAD >/dev/null 2>&1; then
                AHEAD=$(git -C "$CODE_DIR" rev-list --count "$GIT_COMMIT..HEAD" 2>/dev/null || echo 0)
                if [[ "$AHEAD" -gt 0 && "$FORCE_CODE" -eq 0 ]]; then
                    fail "$CODE_DIR 有 $AHEAD 个未包含在发布包中的本地提交。
请先推送/备份，或使用 --force-code 丢弃本地提交，或使用 --no-code 跳过代码更新。"
                fi
            fi
            git -C "$CODE_DIR" checkout -f -B "${GIT_BRANCH:-main}" "$GIT_COMMIT"
            echo "        仓库: $CODE_DIR @ $GIT_COMMIT"
        elif [[ ! -e "$CODE_DIR" || -z "$(ls -A "$CODE_DIR" 2>/dev/null)" ]]; then
            if [[ -n "${GIT_BUNDLE:-}" && -f "$GIT_BUNDLE" ]] \
                && command -v git >/dev/null 2>&1; then
                git clone "$RELEASE_DIR/$GIT_BUNDLE" "$CODE_DIR"
                git -C "$CODE_DIR" remote remove origin >/dev/null 2>&1 || true
                git -C "$CODE_DIR" checkout -f -B "${GIT_BRANCH:-main}" "$GIT_COMMIT"
                echo "        仓库: $CODE_DIR @ $GIT_COMMIT"
            else
                echo "[WARN] 目标机缺少 git 或发布包缺少 bundle，未创建 ${CODE_DIR}；最新源码见 $SOURCE_ROOT/current。" >&2
            fi
        else
            fail "$CODE_DIR 不是 git 仓库且非空，无法安全更新。
请把 CODE_DIR 指向 git 仓库、移走该目录，或使用 --no-code；最新代码快照见 $SOURCE_ROOT/current。"
        fi
    fi
fi

if [[ "$NO_DEPLOY" -eq 1 ]]; then
    echo "已跳过部署。镜像已加载：$IMAGE:$TAG"
    exit 0
fi

[[ -f "$RELEASE_DIR/deploy.sh" ]] || fail "缺少 deploy.sh：$RELEASE_DIR/deploy.sh"

echo "[..] 切换服务"
IMAGE="$IMAGE" \
TAG="$TAG" \
DEPLOY_DIR="$DEPLOY_DIR" \
ENV_FILE="$ENV_FILE" \
HOST_PORT="$HOST_PORT" \
COMPOSE_SERVICE="$COMPOSE_SERVICE" \
bash "$RELEASE_DIR/deploy.sh"

echo "部署完成：$IMAGE:$TAG"
