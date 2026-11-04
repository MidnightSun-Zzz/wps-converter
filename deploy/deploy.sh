#!/usr/bin/env bash
# 在目标机（默认 CHANGE_ME_WPS_TARGET_IP）上执行：候选容器探活 → compose 替换 → 健康门禁 → 失败自动回滚。
# 由 Jenkinsfile 通过 ssh root@CHANGE_ME_WPS_TARGET_IP IMAGE=… TAG=… bash -s < deploy/deploy.sh 调用，
# 也可手动执行用于回滚：IMAGE=wps-converter TAG=<旧版本短哈希> ./deploy.sh
#
# 目标机沿用现有 compose 管理方式（目录 /data/wps-converter，服务名 converter）：
#   1) 新镜像先在无端口、无网络的隔离容器内跑同一 /health/ready 检查；
#   2) 候选健康后把当前镜像标记为 wps-converter:previous，把新镜像标记为 compose 使用的
#      wps-converter:local，再 docker compose up -d --no-build 替换容器；
#   3) 正式容器健康检查失败时自动回滚到 previous。
# 运行时配置（.env）和 compose 文件由目标机人工管理，不随镜像/流水线覆盖。
set -Eeuo pipefail

IMAGE="${IMAGE:-wps-converter}"
TAG="${TAG:?必须通过环境变量指定要部署的 TAG}"
DEPLOY_DIR="${DEPLOY_DIR:-/data/wps-converter}"
ENV_FILE="${ENV_FILE:-$DEPLOY_DIR/.env}"
COMPOSE_SERVICE="${COMPOSE_SERVICE:-converter}"
HOST_BIND_IP="${HOST_BIND_IP:-0.0.0.0}"
HOST_PORT="${HOST_PORT:-}"
HEALTH_TIMEOUT="${HEALTH_TIMEOUT:-180}"
PREFLIGHT_TIMEOUT="${PREFLIGHT_TIMEOUT:-90}"

REF="$IMAGE:$TAG"

wait_healthy() {
    local name="$1" timeout="$2"
    local deadline=$((SECONDS + timeout))
    local status running
    while (( SECONDS < deadline )); do
        running="$(docker inspect --format '{{.State.Running}}' "$name" 2>/dev/null || echo false)"
        if [[ "$running" != "true" ]]; then
            return 1
        fi
        status="$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$name" 2>/dev/null || echo none)"
        case "$status" in
            healthy) return 0 ;;
            unhealthy) return 1 ;;
        esac
        sleep 3
    done
    return 1
}

[[ -f "$ENV_FILE" ]] || { echo "错误：缺少 $ENV_FILE，首次部署请先按 deploy/jenkins-deployment.md 配置。" >&2; exit 1; }
[[ -f "$DEPLOY_DIR/docker-compose.yml" ]] || { echo "错误：缺少 $DEPLOY_DIR/docker-compose.yml，目标机需先准备 compose 文件。" >&2; exit 1; }
docker image inspect "$REF" >/dev/null 2>&1 || { echo "错误：镜像不存在 $REF（先 docker load）。" >&2; exit 1; }

cd "$DEPLOY_DIR"
docker compose --env-file "$ENV_FILE" config --quiet

COMPOSE_IMAGE="${COMPOSE_IMAGE:-$(docker compose --env-file "$ENV_FILE" config --images "$COMPOSE_SERVICE" | head -n1)}"
COMPOSE_IMAGE="${COMPOSE_IMAGE:-wps-converter:local}"

# 未显式指定宿主机端口时，从 .env 的 CONVERTER_PORT 读取，避免健康检查端口与 compose 映射不一致。
if [[ -z "$HOST_PORT" ]]; then
    HOST_PORT="$(sed -n 's/^[[:space:]]*CONVERTER_PORT[[:space:]]*=[[:space:]]*//p' "$ENV_FILE" | tail -n1 | tr -d '\r"' | tr -d "'")"
fi
[[ "$HOST_PORT" =~ ^[0-9]+$ ]] || { echo "错误：无法从 $ENV_FILE 读取 CONVERTER_PORT，请显式传入 HOST_PORT。" >&2; exit 1; }

CONTAINER_ID="$(docker compose --env-file "$ENV_FILE" ps -q -a "$COMPOSE_SERVICE" 2>/dev/null | head -n1 || true)"
PREV_REF=""
if [[ -n "$CONTAINER_ID" ]]; then
    PREV_REF="$(docker inspect --format '{{.Config.Image}}' "$CONTAINER_ID" 2>/dev/null || true)"
fi

if [[ -n "$PREV_REF" && "$PREV_REF" != "$REF" ]]; then
    echo "上一版本：$PREV_REF（新版本健康检查失败时自动回滚到它）"
fi

# 先在不开放端口、无网络的候选容器内运行同一 /health/ready 检查。
# 候选版本不健康时直接退出，旧容器保持运行，避免健康门禁超时和无效回滚。
PREFLIGHT_NAME="${IMAGE}-preflight-$$"
cleanup_preflight() { docker rm -f "$PREFLIGHT_NAME" >/dev/null 2>&1 || true; }
docker rm -f "$PREFLIGHT_NAME" >/dev/null 2>&1 || true
trap cleanup_preflight EXIT
docker run -d \
    --name "$PREFLIGHT_NAME" \
    --network none \
    --init \
    --read-only \
    --cap-drop ALL \
    --security-opt no-new-privileges \
    --tmpfs /tmp:rw,noexec,nosuid,nodev,size=512m,mode=1777 \
    --env-file "$ENV_FILE" \
    "$REF" >/dev/null

if ! wait_healthy "$PREFLIGHT_NAME" "$PREFLIGHT_TIMEOUT"; then
    echo "候选容器健康检查失败，现有服务未切换。容器日志：" >&2
    docker logs --tail 50 "$PREFLIGHT_NAME" >&2 || true
    exit 1
fi
cleanup_preflight
trap - EXIT

if [[ -n "$PREV_REF" && "$PREV_REF" != "$REF" ]]; then
    docker tag "$PREV_REF" "$IMAGE:previous"
fi
docker tag "$REF" "$COMPOSE_IMAGE"
docker compose --env-file "$ENV_FILE" up -d --no-build --pull never "$COMPOSE_SERVICE"

CONTAINER_ID="$(docker compose --env-file "$ENV_FILE" ps -q "$COMPOSE_SERVICE" | head -n1 || true)"
if [[ -z "$CONTAINER_ID" ]]; then
    echo "错误：compose 未启动 $COMPOSE_SERVICE 容器。" >&2
    exit 1
fi

if wait_healthy "$CONTAINER_ID" "$HEALTH_TIMEOUT"; then
    echo "部署成功：$REF → http://${HOST_BIND_IP}:${HOST_PORT}/health/ready"
    # 本机只保留最近 5 个版本镜像，超出回滚窗口的旧版本清掉
    docker images "$IMAGE" -q | tail -n +6 | xargs -r docker rmi >/dev/null 2>&1 || true
    exit 0
fi

echo "健康检查超时（${HEALTH_TIMEOUT}s），容器最近日志：" >&2
docker compose --env-file "$ENV_FILE" logs --tail 50 "$COMPOSE_SERVICE" >&2 || true

if [[ -n "$PREV_REF" && "$PREV_REF" != "$REF" ]] && docker image inspect "$IMAGE:previous" >/dev/null 2>&1; then
    echo "自动回滚：$PREV_REF" >&2
    docker tag "$IMAGE:previous" "$COMPOSE_IMAGE"
    docker compose --env-file "$ENV_FILE" up -d --no-build --pull never "$COMPOSE_SERVICE"
    CONTAINER_ID="$(docker compose --env-file "$ENV_FILE" ps -q "$COMPOSE_SERVICE" | head -n1 || true)"
    if [[ -n "$CONTAINER_ID" ]] && wait_healthy "$CONTAINER_ID" "$HEALTH_TIMEOUT"; then
        echo "已回滚到 $PREV_REF" >&2
    else
        echo "回滚后健康检查仍未通过，请查看 docker compose logs $COMPOSE_SERVICE。" >&2
        exit 1
    fi
else
    echo "无可回滚的上一版本（首次部署或旧镜像已被清理）。" >&2
fi
exit 1
