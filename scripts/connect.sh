#!/usr/bin/env bash
# OpenClaw SSH Skill - 建立 ControlMaster 后台连接
# 用法: bash connect.sh <host>
set -euo pipefail

HOST_NAME="${1:?用法: connect.sh <host>}"

SKILL_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPTS_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPTS_DIR/yaml.sh"

HOSTS_YAML="$SKILL_DIR/hosts.yaml"
SECRETS_DIR="$SKILL_DIR/.secrets"
CTL_DIR="/tmp/ssh-ctl"
CTL_SOCKET="$CTL_DIR/${HOST_NAME}.sock"

die() { echo "{\"success\":false,\"error\":\"$1\",\"message\":\"$2\"}"; exit 1; }
require_cmd() { command -v "$1" &>/dev/null || die "missing_dep" "需要安装: $1"; }

# 检查 hosts.yaml 存在
[[ -f "$HOSTS_YAML" ]] || die "config_not_found" "hosts.yaml 不存在: $HOSTS_YAML"

# 读取主机配置
SSH_HOST=$(read_yaml "$HOSTS_YAML" "$HOST_NAME" "host")
SSH_PORT=$(read_yaml "$HOSTS_YAML" "$HOST_NAME" "port"); SSH_PORT="${SSH_PORT:-22}"
SSH_USER=$(read_yaml "$HOSTS_YAML" "$HOST_NAME" "user")
AUTH_TYPE=$(read_yaml "$HOSTS_YAML" "$HOST_NAME" "auth")
KEY_PATH=$(read_yaml "$HOSTS_YAML" "$HOST_NAME" "key_path")
JUMP_HOST=$(read_yaml "$HOSTS_YAML" "$HOST_NAME" "jump_host")

[[ -z "$SSH_HOST" || -z "$SSH_USER" || -z "$AUTH_TYPE" ]] && \
    die "config_incomplete" "hosts.yaml 中 $HOST_NAME 缺少 host/user/auth 字段（或主机不存在）"

# ── ControlMaster 检查：如果已有活跃连接则直接返回 ──
mkdir -p "$CTL_DIR"
if [[ -S "$CTL_SOCKET" ]]; then
    CHECK=$(ssh -o ControlPath="$CTL_SOCKET" -O check placeholder 2>&1 || true)
    if echo "$CHECK" | grep -q "Master running"; then
        echo "{\"success\":true,\"host\":\"$HOST_NAME\",\"status\":\"already_connected\",\"socket\":\"$CTL_SOCKET\"}"
        exit 0
    fi
    rm -f "$CTL_SOCKET"
fi

# ── 构建 SSH 基础参数 ──
SSH_OPTS=(
    -o "ControlMaster=yes"
    -o "ControlPath=$CTL_SOCKET"
    -o "ControlPersist=10m"
    -o "StrictHostKeyChecking=no"
    -o "BatchMode=no"
    -o "ConnectTimeout=15"
    -p "$SSH_PORT"
)

# 跳板机
if [[ -n "$JUMP_HOST" ]]; then
    JUMP_SSH_HOST=$(read_yaml "$HOSTS_YAML" "$JUMP_HOST" "host")
    JUMP_SSH_USER=$(read_yaml "$HOSTS_YAML" "$JUMP_HOST" "user")
    JUMP_SSH_PORT=$(read_yaml "$HOSTS_YAML" "$JUMP_HOST" "port"); JUMP_SSH_PORT="${JUMP_SSH_PORT:-22}"
    if [[ -n "$JUMP_SSH_HOST" && -n "$JUMP_SSH_USER" ]]; then
        SSH_OPTS+=(-o "ProxyJump=${JUMP_SSH_USER}@${JUMP_SSH_HOST}:${JUMP_SSH_PORT}")
    fi
fi

# ── 认证方式 ──
case "$AUTH_TYPE" in
  key)
    [[ -z "$KEY_PATH" ]] && die "config_error" "auth: key 时必须设置 key_path"
    KEY_PATH_EXP="${KEY_PATH/#\~/$HOME}"
    [[ -f "$KEY_PATH_EXP" ]] || die "key_not_found" "私钥文件不存在: $KEY_PATH_EXP"
    SSH_OPTS+=(-i "$KEY_PATH_EXP" -o "IdentitiesOnly=yes")
    ssh "${SSH_OPTS[@]}" -N -f "${SSH_USER}@${SSH_HOST}" 2>/tmp/ssh-connect-err && RC=0 || RC=$?
    ;;
  password)
    require_cmd sshpass
    SECRETS_FILE="$SECRETS_DIR/${HOST_NAME}.env"
    [[ -f "$SECRETS_FILE" ]] || die "secrets_not_found" "密码文件不存在: $SECRETS_FILE"
    SSH_PASSWORD=$(grep -E '^SSH_PASSWORD=' "$SECRETS_FILE" | cut -d= -f2- | tr -d "'\"\r")
    [[ -z "$SSH_PASSWORD" ]] && die "config_error" "SSH_PASSWORD 为空: $SECRETS_FILE"
    sshpass -p "$SSH_PASSWORD" ssh "${SSH_OPTS[@]}" -N -f "${SSH_USER}@${SSH_HOST}" 2>/tmp/ssh-connect-err && RC=0 || RC=$?
    unset SSH_PASSWORD
    ;;
  *)
    die "config_error" "不支持的 auth 类型: $AUTH_TYPE（有效值: key | password）"
    ;;
esac

# ── 结果输出 ──
if [[ "${RC:-0}" -eq 0 ]] && [[ -S "$CTL_SOCKET" ]]; then
    echo "{\"success\":true,\"host\":\"$HOST_NAME\",\"status\":\"connected\",\"socket\":\"$CTL_SOCKET\"}"
else
    ERR=$(cat /tmp/ssh-connect-err 2>/dev/null | head -3 | tr '\n' ' ')
    echo "{\"success\":false,\"host\":\"$HOST_NAME\",\"error\":\"connect_failed\",\"detail\":\"$(echo "$ERR" | sed 's/"/\\"/g')\"}"
    exit 1
fi
