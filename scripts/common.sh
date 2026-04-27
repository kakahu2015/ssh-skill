#!/usr/bin/env bash
# OpenClaw SSH Skill - shared helpers
# shellcheck shell=bash

COMMON_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "$COMMON_DIR/.." && pwd)"
SCRIPTS_DIR="$COMMON_DIR"
HOSTS_YAML="${HOSTS_YAML:-$SKILL_DIR/hosts.yaml}"
SECRETS_DIR="${SECRETS_DIR:-$SKILL_DIR/.secrets}"
CTL_DIR="${CTL_DIR:-/tmp/ssh-ctl}"
RUNS_DIR="${RUNS_DIR:-$SKILL_DIR/.runs}"
AUDIT_DIR="${AUDIT_DIR:-$SKILL_DIR/.audit}"

# shellcheck source=/dev/null
source "$SCRIPTS_DIR/yaml.sh"

json_escape() {
    local input="${1-}"
    printf '%s' "$input" | awk 'BEGIN{ORS=""}{gsub(/\\/,"\\\\");gsub(/"/,"\\\"");gsub(/\t/,"\\t");gsub(/\r/,"\\r");if(NR>1)printf "\\n";printf "%s",$0}'
}

redact() {
    sed -E \
      -e 's/(password|passwd|secret|token|api[_-]?key|ssh_password|private[_-]?key)[[:space:]]*[=:][[:space:]]*[^[:space:]]+/\1=[REDACTED]/gi' \
      -e 's/-----BEGIN [A-Z0-9 ]*PRIVATE KEY-----/[REDACTED_PRIVATE_KEY]/g' \
      -e 's/-----END [A-Z0-9 ]*PRIVATE KEY-----/[REDACTED_PRIVATE_KEY]/g' \
      -e 's#(/[A-Za-z0-9._@+=,~-]+)*/\.ssh/[A-Za-z0-9._@+=,~/-]+#[REDACTED_KEY_PATH]#g' \
      -e 's#(/[A-Za-z0-9._@+=,~-]+)*/\.secrets/[A-Za-z0-9._@+=,~/-]+#[REDACTED_SECRETS_PATH]#g' \
      -e 's#(^|[[:space:]"=:/])/?keys/[A-Za-z0-9._@+=,~/-]+#\1[REDACTED_KEY_PATH]#g' \
      -e 's#(^|[[:space:]"=])(ssh://)?[A-Za-z0-9._%+-]+@([A-Za-z0-9.-]+|\[[0-9A-Fa-f:]+\])#\1\2[REDACTED_USER]@[REDACTED_HOST]#g' \
      -e 's/(^|[^0-9])([0-9]{1,3}\.){3}[0-9]{1,3}([^0-9]|$)/\1[REDACTED_IP]\3/g' \
      -e 's/(^|[^0-9A-Fa-f:])([0-9A-Fa-f]{1,4}:){2,7}[0-9A-Fa-f]{1,4}([^0-9A-Fa-f:]|$)/\1[REDACTED_IPV6]\3/g' \
      -e 's/(^|[^0-9A-Fa-f:])([0-9A-Fa-f]{1,4}:){1,7}:([0-9A-Fa-f]{1,4})?([^0-9A-Fa-f:]|$)/\1[REDACTED_IPV6]\4/g'
}

redact_string() {
    local text="${1-}" item label value
    text="$(printf '%s' "$text" | redact)"
    for item in "SSH_HOST:REDACTED_HOST" "SSH_USER:REDACTED_USER" "KEY_PATH:REDACTED_KEY_PATH" "SECRETS_ENV:REDACTED_SECRETS_PATH"; do
        label="${item%%:*}"; value="${!label-}"
        [[ -n "$value" ]] && text="${text//"$value"/[$(printf '%s' "${item#*:}")]}"
    done
    printf '%s' "$text"
}

safe_json_string() { json_escape "$(redact_string "${1-}")"; }
now_iso() { date -u +"%Y-%m-%dT%H:%M:%SZ"; }
make_run_id() { printf 'run_%s_%s' "$(date -u +%Y%m%dT%H%M%SZ)" "$$"; }

die_json() {
    local error="$1" message="$2" host="${3-}"
    printf '{\n  "success": false,\n'
    [[ -n "$host" ]] && printf '  "host": "%s",\n' "$(safe_json_string "$host")"
    printf '  "error": "%s",\n  "message": "%s"\n}\n' "$(safe_json_string "$error")" "$(safe_json_string "$message")"
    exit 1
}

require_hosts_yaml() {
    [[ -f "$HOSTS_YAML" ]] || die_json "config_not_found" "hosts.yaml 不存在: $HOSTS_YAML。复制 hosts.example.yaml 为 hosts.yaml，并把真实 HOST/KEY_PATH 放进 .secrets/<host>.env。"
}

get_env_value() {
    local file="$1" key="$2"
    [[ -f "$file" ]] || return 0
    grep -E "^${key}=" "$file" 2>/dev/null | tail -1 | cut -d= -f2- | tr -d '\r' | sed -E 's/^["'"'"']//; s/["'"'"']$//'
}

expand_path() {
    local p="${1-}"
    [[ "$p" == "~" ]] && { printf '%s' "$HOME"; return; }
    [[ "$p" == "~/"* ]] && { printf '%s/%s' "$HOME" "${p#~/}"; return; }
    printf '%s' "$p"
}

control_socket() { printf '%s/%s.sock' "$CTL_DIR" "$1"; }

load_host_config() {
    local host_name="$1"
    require_hosts_yaml
    SSH_HOST="$(read_yaml "$HOSTS_YAML" "$host_name" "host")"
    SSH_PORT="$(read_yaml "$HOSTS_YAML" "$host_name" "port")"; SSH_PORT="${SSH_PORT:-22}"
    SSH_USER="$(read_yaml "$HOSTS_YAML" "$host_name" "user")"
    AUTH_TYPE="$(read_yaml "$HOSTS_YAML" "$host_name" "auth")"
    KEY_PATH="$(read_yaml "$HOSTS_YAML" "$host_name" "key_path")"
    JUMP_HOST="$(read_yaml "$HOSTS_YAML" "$host_name" "jump_host")"
    DEFAULT_WORKDIR="$(read_yaml "$HOSTS_YAML" "$host_name" "default_workdir")"
    [[ -z "$SSH_HOST" || -z "$SSH_USER" || -z "$AUTH_TYPE" ]] && die_json "config_incomplete" "hosts.yaml 中 $host_name 缺少 host/user/auth 字段（或主机不存在）" "$host_name"
    REAL_HOST="$SSH_HOST"
    SECRETS_ENV="$SECRETS_DIR/${REAL_HOST}.env"
    [[ ! -f "$SECRETS_ENV" ]] && SECRETS_ENV="$SECRETS_DIR/${host_name}.env"
    if [[ -f "$SECRETS_ENV" ]]; then
        local secret_host secret_key
        secret_host="$(get_env_value "$SECRETS_ENV" "HOST")"
        secret_key="$(get_env_value "$SECRETS_ENV" "KEY_PATH")"
        [[ -n "$secret_host" ]] && SSH_HOST="$secret_host"
        [[ -n "$secret_key" ]] && KEY_PATH="$secret_key"
    fi
}

host_count_from_csv() { awk -F',' '{print NF}' <<< "$1"; }
_host_metadata_value() { [[ -f "$HOSTS_YAML" ]] && read_yaml "$HOSTS_YAML" "$1" "$2"; }

host_is_prod() {
    local env tags
    env="$(_host_metadata_value "$1" env | tr '[:upper:]' '[:lower:]')"
    tags="$(_host_metadata_value "$1" tags | tr '[:upper:]' '[:lower:]')"
    [[ "$env" == "prod" || "$env" == "production" || "$tags" =~ (^|[^a-z])(prod|production)([^a-z]|$) ]]
}

any_prod_host() {
    local h
    [[ -n "${1-}" ]] || return 1
    IFS=',' read -ra _SSH_SKILL_POLICY_HOSTS <<< "$1"
    for h in "${_SSH_SKILL_POLICY_HOSTS[@]}"; do
        h="$(echo "$h" | xargs)"
        [[ -n "$h" ]] && host_is_prod "$h" && return 0
    done
    return 1
}

policy_risk_for_command() {
    local cmd="$1"
    if echo "$cmd" | grep -Eiq '(^|[;&|[:space:]])(cat|less|more|tail|head|grep|awk|sed)[[:space:]].*(/etc/shadow|/etc/sudoers|/\.ssh/|id_rsa|id_ed25519|\.pem|\.key)([;&|[:space:]]|$)'; then echo high; return; fi
    if echo "$cmd" | grep -Eiq '(^|[;&|[:space:]])(rm[[:space:]].*(-r|-f|-[A-Za-z]*r[A-Za-z]*f|-[A-Za-z]*f[A-Za-z]*r)[[:space:]]+(/|/\*|/etc|/usr|/var|/home|/root)([[:space:];&|]|$)|mkfs|wipefs|fdisk|parted|sgdisk|shutdown|reboot|poweroff|halt|killall|fuser[[:space:]]+-k)([;&|[:space:]]|$)'; then echo high; return; fi
    if echo "$cmd" | grep -Eiq '(^|[;&|[:space:]])(dd[[:space:]].*(if=|of=/dev/)|iptables[[:space:]]+(-F|--flush)|ip6tables[[:space:]]+(-F|--flush)|nft[[:space:]]+flush|ufw[[:space:]]+disable|firewall-cmd[[:space:]].*(--panic-on|--complete-reload))([;&|[:space:]]|$)'; then echo high; return; fi
    if echo "$cmd" | grep -Eiq '(^|[;&|[:space:]])(systemctl[[:space:]]+(stop|disable|mask)|service[[:space:]][^[:space:]]+[[:space:]]+stop|docker[[:space:]]+(rm[[:space:]]+-f|system[[:space:]]+prune)|kubectl[[:space:]]+delete)([;&|[:space:]]|$)'; then echo high; return; fi
    if echo "$cmd" | grep -Eiq '(^|[;&|[:space:]])(bash|sh)[[:space:]]+-c[[:space:]].*(base64[[:space:]]+-d|curl|wget)'; then echo high; return; fi
    if echo "$cmd" | grep -Eiq '(^|[;&|[:space:]])(systemctl[[:space:]]+(restart|reload)|service[[:space:]][^[:space:]]+[[:space:]]+(restart|reload)|chmod[[:space:]]+(-R[[:space:]]+)?777|chown[[:space:]]+-R|rm[[:space:]].*(-r|-f)|apt(-get)?[[:space:]]+(install|remove|purge|upgrade|dist-upgrade)|yum[[:space:]]+(install|remove|update)|dnf[[:space:]]+(install|remove|upgrade)|apk[[:space:]]+(add|del|upgrade)|docker[[:space:]]+(restart|stop)|kubectl[[:space:]]+(rollout|scale|apply))([;&|[:space:]]|$)'; then echo medium; return; fi
    echo low
}

_policy_requires_confirm() {
    local risk="$1" host_count="$2" host_csv="${3-}"
    [[ "$risk" == high ]] && return 0
    [[ "$risk" == medium && "$host_count" -gt 20 ]] && return 0
    [[ "$risk" == medium ]] && any_prod_host "$host_csv" && return 0
    return 1
}

policy_check_command() {
    local cmd="$1" host_count="${2:-1}" confirm="${3:-}" host_csv="${4:-}" risk reason
    risk="$(policy_risk_for_command "$cmd")"
    if _policy_requires_confirm "$risk" "$host_count" "$host_csv"; then
        if [[ "${SSH_SKILL_CONFIRMED:-}" != yes && "$confirm" != --confirm ]]; then
            reason="risk=$risk hosts=$host_count"
            [[ "$risk" == medium && "$host_count" -le 20 ]] && reason="$reason prod_target=true"
            die_json "policy_blocked" "命令需要显式确认：设置 SSH_SKILL_CONFIRMED=yes 或追加 --confirm。$reason cmd=$(redact_string "$cmd")"
        fi
    fi
}

ensure_connected() {
    local host_name="$1" ctl_socket="$2" check
    mkdir -p "$CTL_DIR"
    if [[ ! -S "$ctl_socket" ]]; then
        echo "[ssh-skill] socket 不存在，尝试自动重连..." >&2
        bash "$SCRIPTS_DIR/connect.sh" "$host_name" >&2 || die_json "not_connected" "连接不存在且自动重连失败，请先运行 connect.sh $host_name" "$host_name"
    fi
    check=$(ssh -o "ControlPath=$ctl_socket" -O check placeholder 2>&1 || true)
    if ! echo "$check" | grep -q "Master running"; then
        echo "[ssh-skill] socket 已失效，尝试重连..." >&2
        rm -f "$ctl_socket"
        bash "$SCRIPTS_DIR/connect.sh" "$host_name" >&2 || die_json "reconnect_failed" "重连失败，请检查网络或主机状态" "$host_name"
    fi
}

write_audit_event() {
    local run_id="$1" host="$2" action="$3" success="$4" exit_code="$5" duration_ms="$6" command_text="${7-}" file
    mkdir -p "$AUDIT_DIR/$(date -u +%Y-%m-%d)"
    file="$AUDIT_DIR/$(date -u +%Y-%m-%d)/${run_id}.jsonl"
    printf '{"time":"%s","run_id":"%s","host":"%s","action":"%s","success":%s,"exit_code":%s,"duration_ms":%s,"command":"%s"}\n' \
      "$(now_iso)" "$(safe_json_string "$run_id")" "$(safe_json_string "$host")" "$(safe_json_string "$action")" "$success" "$exit_code" "$duration_ms" "$(safe_json_string "$command_text")" >> "$file"
}
