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
SECRETS_DIR="$SKILL_DIR/.secrets"
CTL_SOCKET="/tmp/ssh-ctl/${HOST_NAME}.sock"

die() { echo "{\"success\":false,\"error\":\"$1\",\"message\":\"$2\"}"; exit 1; }

SSH_HOST=$(read_yaml "$HOSTS_YAML" "$HOST_NAME" "host")
SSH_PORT=$(read_yaml "$HOSTS_YAML" "$HOST_NAME" "port"); SSH_PORT="${SSH_PORT:-22}"
SSH_USER=$(read_yaml "$HOSTS_YAML" "$HOST_NAME" "user")

# .secrets/<host>.env 覆盖（IP 不走 YAML）
SECRETS_ENV="$SECRETS_DIR/${HOST_NAME}.env"
if [[ -f "$SECRETS_ENV" ]]; then
    _H=$(grep -E '^HOST=' "$SECRETS_ENV" | cut -d= -f2-)
    [[ -n "$_H" ]] && SSH_HOST="$_H"
fi

[[ ! -S "$CTL_SOCKET" ]] && die "not_connected" "未建立连接，请先运行 connect.sh $HOST_NAME"

# 上传前检查并释放被占用的目标文件
check_and_release_file() {
    local remote_file="$1"
    # 检查文件是否存在且被占用
    local check_cmd="if [ -f '$remote_file' ]; then if fuser '$remote_file' >/dev/null 2>&1; then echo 'BUSY'; else echo 'FREE'; fi; else echo 'NOT_EXIST'; fi"
    local status
    status=$(ssh -o "ControlPath=$CTL_SOCKET" -p "$SSH_PORT" "${SSH_USER}@${SSH_HOST}" "$check_cmd" 2>/dev/null || echo "ERROR")
    if echo "$status" | grep -q "BUSY"; then
        echo "[ssh-skill] 检测到目标文件被占用，尝试释放..." >&2
        # 尝试停掉常见服务（按文件名判断）
        if echo "$remote_file" | grep -q "caddy"; then
            ssh -o "ControlPath=$CTL_SOCKET" -p "$SSH_PORT" "${SSH_USER}@${SSH_HOST}" "sudo systemctl stop caddy 2>/dev/null; sudo killall -9 caddy 2>/dev/null; sleep 1" || true
        fi
        # 通用：强制杀掉占用进程
        ssh -o "ControlPath=$CTL_SOCKET" -p "$SSH_PORT" "${SSH_USER}@${SSH_HOST}" "sudo fuser -k '$remote_file' 2>/dev/null; sleep 1" || true
    fi
}

SCP_OPTS=(
    -o "ControlPath=$CTL_SOCKET"
    -o "StrictHostKeyChecking=accept-new"
    -P "$SSH_PORT"
)

case "$DIRECTION" in
  upload)
    [[ -e "$SRC" ]] || die "not_found" "本地文件不存在: $SRC"
    # 上传前检查并释放目标文件占用
    check_and_release_file "$DST"
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
