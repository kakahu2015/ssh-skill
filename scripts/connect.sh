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

# .secrets/<host>.env 覆盖（IP/密钥路径不走 YAML）
# 解析 alias：如果 hosts.yaml 里 host 字段指向另一个主机名，用那个名字找 secrets
REAL_HOST="$SSH_HOST"
SECRETS_ENV="$SECRETS_DIR/${REAL_HOST}.env"
if [[ ! -f "$SECRETS_ENV" ]]; then
    SECRETS_ENV="$SECRETS_DIR/${HOST_NAME}.env"
fi
if [[ -f "$SECRETS_ENV" ]]; then
    _H=$(grep -E '^HOST=' "$SECRETS_ENV" | cut -d= -f2-)
    _K=$(grep -E '^KEY_PATH=' "$SECRETS_ENV" | cut -d= -f2-)
    [[ -n "$_H" ]] && SSH_HOST="$_H"
    [[ -n "$_K" ]] && KEY_PATH="$_K"
fi

[[ -z "$SSH_HOST" || -z "$SSH_USER" || -z "$AUTH_TYPE" ]] && \
    die "config_incomplete" "hosts.yaml 中 $HOST_NAME 缺少 host/user/auth 字段（或主机不存在）"

# 不做 ping 预检查，直接依赖 ssh 的 ConnectTimeout。
# 原因：部分环境没有 ping，之前会把“本地缺命令”误报成“远端超时”。

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
    -o "ControlPersist=30m"
    -o "StrictHostKeyChecking=accept-new"
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
    _ERR=$(mktemp)
    MAX_RETRY=3
    RC=1
    for i in $(seq 1 $MAX_RETRY); do
        echo "[ssh-skill] 连接尝试 $i/$MAX_RETRY..." >&2
        ssh "${SSH_OPTS[@]}" -N -f "${SSH_USER}@${SSH_HOST}" 2>"$_ERR" && RC=0 && break
        sleep 2
    done
    ;;
  password)
    require_cmd sshpass
    SECRETS_FILE="$SECRETS_DIR/${HOST_NAME}.env"
    [[ -f "$SECRETS_FILE" ]] || die "secrets_not_found" "密码文件不存在: $SECRETS_FILE"
    SSH_PASSWORD=$(grep -E '^SSH_PASSWORD=' "$SECRETS_FILE" | cut -d= -f2- | tr -d "'\"\r")
    [[ -z "$SSH_PASSWORD" ]] && die "config_error" "SSH_PASSWORD 为空: $SECRETS_FILE"
    _ERR=$(mktemp)
    export SSHPASS="$SSH_PASSWORD"
    sshpass -e ssh "${SSH_OPTS[@]}" -N -f "${SSH_USER}@${SSH_HOST}" 2>"$_ERR" && RC=0 || RC=$?
    unset SSHPASS SSH_PASSWORD
    ;;
  *)
    die "config_error" "不支持的 auth 类型: $AUTH_TYPE（有效值: key | password）"
    ;;
esac

# ── 结果输出 ──
if [[ "${RC:-0}" -eq 0 ]] && [[ -S "$CTL_SOCKET" ]]; then
    rm -f "$_ERR"
    echo "{\"success\":true,\"host\":\"$HOST_NAME\",\"status\":\"connected\",\"socket\":\"$CTL_SOCKET\"}"
else
    ERR=$(cat "$_ERR" 2>/dev/null | head -3 | tr '\n' ' ')
    rm -f "$_ERR"
    echo "{\"success\":false,\"host\":\"$HOST_NAME\",\"error\":\"connect_failed\",\"detail\":\"$(echo "$ERR" | sed 's/"/\\"/g')\"}"
    exit 1
fi
