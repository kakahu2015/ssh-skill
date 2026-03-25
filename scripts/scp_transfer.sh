#!/usr/bin/env bash
# OpenClaw SSH Skill - SCP 文件传输（复用 ControlMaster）
# 用法:
#   bash scp_transfer.sh <host> upload   /local/path /remote/path
#   bash scp_transfer.sh <host> download /remote/path /local/path
set -euo pipefail

HOST_NAME="${1:?用法: scp_transfer.sh <host> <upload|download> <src> <dst>}"
DIRECTION="${2:?缺少方向: upload 或 download}"
SRC="${3:?缺少源路径}"
DST="${4:?缺少目标路径}"

SKILL_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPTS_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPTS_DIR/yaml.sh"

HOSTS_YAML="$SKILL_DIR/hosts.yaml"
CTL_SOCKET="/tmp/ssh-ctl/${HOST_NAME}.sock"

die() { echo "{\"success\":false,\"error\":\"$1\",\"message\":\"$2\"}"; exit 1; }

SSH_HOST=$(read_yaml "$HOSTS_YAML" "$HOST_NAME" "host")
SSH_PORT=$(read_yaml "$HOSTS_YAML" "$HOST_NAME" "port"); SSH_PORT="${SSH_PORT:-22}"
SSH_USER=$(read_yaml "$HOSTS_YAML" "$HOST_NAME" "user")

[[ ! -S "$CTL_SOCKET" ]] && die "not_connected" "未建立连接，请先运行 connect.sh $HOST_NAME"

SCP_OPTS=(
    -o "ControlPath=$CTL_SOCKET"
    -o "StrictHostKeyChecking=no"
    -P "$SSH_PORT"
)

case "$DIRECTION" in
  upload)
    [[ -e "$SRC" ]] || die "not_found" "本地文件不存在: $SRC"
    scp "${SCP_OPTS[@]}" "$SRC" "${SSH_USER}@${SSH_HOST}:${DST}"
    echo "{\"success\":true,\"host\":\"$HOST_NAME\",\"operation\":\"upload\",\"local\":\"$SRC\",\"remote\":\"$DST\"}"
    ;;
  download)
    scp "${SCP_OPTS[@]}" "${SSH_USER}@${SSH_HOST}:${SRC}" "$DST"
    echo "{\"success\":true,\"host\":\"$HOST_NAME\",\"operation\":\"download\",\"remote\":\"$SRC\",\"local\":\"$DST\"}"
    ;;
  *)
    die "invalid_direction" "方向必须是 upload 或 download，收到: $DIRECTION"
    ;;
esac
