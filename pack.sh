#!/usr/bin/env bash
# ============================================================
# 打上线包：把本地已提交代码打包为 wps-converter-src-<8位短哈希>.tar.gz
# 用法: ./pack.sh [commit/分支/tag，默认 HEAD] [输出目录，默认 ~/gov-llm-releases，可用 ARCHIVE_DIR 覆盖]
# 说明: git archive 只打【已提交】内容；.venv/.env/.git 等不入包
# 发布: 把产物交给 deploy-wps-converter.sh（先测试后生产）:
#   cd 部署文档/scripts_dev  && ./deploy-wps-converter.sh <产物路径>/wps-converter-src-<短哈希>.tar.gz
#   cd 部署文档/scripts_prod && ./deploy-wps-converter.sh <产物路径>/wps-converter-src-<短哈希>.tar.gz
#   （断网环境加 --offline，且需未改 pyproject.toml / Dockerfile）
# ============================================================
set -euo pipefail

REPO=$(git rev-parse --show-toplevel) || { echo "[FAIL] 请在 wps-converter 仓库内运行"; exit 1; }
REF=${1:-HEAD}
OUT_DIR=${2:-${ARCHIVE_DIR:-$HOME/gov-llm-releases}}

HASH8=$(git -C "$REPO" rev-parse --short=8 "$REF" 2>/dev/null) \
  || { echo "[FAIL] 引用不存在: $REF"; exit 1; }

# 与 Windows(CRLF)/WSL(LF) 混用环境对齐行尾比较，避免整仓误报为改动
DIRTY=$(git -C "$REPO" -c core.autocrlf=true status --porcelain)
if [[ -n "$DIRTY" ]]; then
  echo "[WARN] 以下未提交/未跟踪改动不会打进包内（确认无需上线可忽略）："
  echo "$DIRTY" | sed 's/^/    /'
fi

mkdir -p "$OUT_DIR"
OUT="$OUT_DIR/wps-converter-src-$HASH8.tar.gz"
git -C "$REPO" archive --format=tar.gz -o "$OUT" "$REF"

echo "[ OK ] 已打包: $OUT（$(du -h "$OUT" | cut -f1)）"
echo "       版本: $HASH8  $(git -C "$REPO" log -1 --format='%s' "$HASH8")"
echo "后续发布（先测试后生产）:"
echo "  cd 部署文档/scripts_dev  && ./deploy-wps-converter.sh $OUT"
echo "  cd 部署文档/scripts_prod && ./deploy-wps-converter.sh $OUT"
