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

# yaml.sh intentionally stays tiny and dependency-free.
# shellcheck source=/dev/null
source "$SCRIPTS_DIR/yaml.sh"

json_escape() {
    local input="${1-}"
    printf '%s' "$input" | awk '
    BEGIN { ORS="" }
    {
        gsub(/\\/, "\\\\")
        gsub(/"/, "\\\"")
        gsub(/\t/, "\\t")
        gsub(/\r/, "\\r")
        if (NR > 1) printf "\\n"
        printf "%s", $0
    }'
}

redact() {
    sed -E \
        -e 's/(password|passwd|secret|token|api[_-]?key)[[:space:]]*[=:][[:space:]]*[^[:space:]]+/\1=[REDACTED]/gi' \
        -e 's/([0-9]{1,3}\.){3}[0-9]{1,3}/[REDACTED_IP]/g' \
        -e 's#(/[[:alnum:]_.-]+)*\.ssh/[[:alnum:]_.-]+#[REDACTED_KEY_PATH]#g'
}

redact_string() {
    printf '%s' "${1-}" | redact
}

now_iso() {
    date -u +"%Y-%m-%dT%H:%M:%SZ"
}

make_run_id() {
    printf 'run_%s_%s' "$(date -u +%Y%m%dT%H%M%SZ)" "$$"
}

die_json() {
    local error="$1" message="$2" host="${3-}"
    printf '{\n'
    printf '  "success": false,\n'
    [[ -n "$host" ]] && printf '  "host": "%s",\n' "$(json_escape "$host")"
    printf '  "error": "%s",\n' "$(json_escape "$error")"
    printf '  "message": "%s"\n' "$(json_escape "$(redact_string "$message")")"
    printf '}\n'
    exit 1
}

require_hosts_yaml() {
    [[ -f "$HOSTS_YAML" ]] || die_json "config_not_found" "hosts.yaml 不存在: $HOSTS_YAML"
}

get_env_value() {
    local file="$1" key="$2"
    [[ -f "$file" ]] || return 0
    grep -E "^${key}=" "$file" 2>/dev/null | tail -1 | cut -d= -f2- | tr -d '\r' | sed -E 's/^['"'"'\"]//; s/['"'"'\"]$//'
}

expand_path() {
    local p="${1-}"
    if [[ "$p" == "~" ]]; then
        printf '%s' "$HOME"
    elif [[ "$p" == "~/"* ]]; then
        printf '%s/%s' "$HOME" "${p#~/}"
    else
        printf '%s' "$p"
    fi
}

control_socket() {
    local host="$1"
    printf '%s/%s.sock' "$CTL_DIR" "$host"
}

# Loads host settings into global variables:
# SSH_HOST SSH_PORT SSH_USER AUTH_TYPE KEY_PATH JUMP_HOST DEFAULT_WORKDIR SECRETS_ENV REAL_HOST
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

    [[ -z "$SSH_HOST" || -z "$SSH_USER" || -z "$AUTH_TYPE" ]] && \
        die_json "config_incomplete" "hosts.yaml 中 $host_name 缺少 host/user/auth 字段（或主机不存在）" "$host_name"

    REAL_HOST="$SSH_HOST"
    SECRETS_ENV="$SECRETS_DIR/${REAL_HOST}.env"
    if [[ ! -f "$SECRETS_ENV" ]]; then
        SECRETS_ENV="$SECRETS_DIR/${host_name}.env"
    fi

    if [[ -f "$SECRETS_ENV" ]]; then
        local secret_host secret_key
        secret_host="$(get_env_value "$SECRETS_ENV" "HOST")"
        secret_key="$(get_env_value "$SECRETS_ENV" "KEY_PATH")"
        [[ -n "$secret_host" ]] && SSH_HOST="$secret_host"
        [[ -n "$secret_key" ]] && KEY_PATH="$secret_key"
    fi
}

host_count_from_csv() {
    local csv="$1"
    awk -F',' '{print NF}' <<< "$csv"
}

policy_risk_for_command() {
    local cmd="$1"
    if echo "$cmd" | grep -Eiq '(^|[;&|[:space:]])(rm[[:space:]]+-rf[[:space:]]+/|mkfs|dd[[:space:]]+if=|shutdown|reboot|iptables[[:space:]]+-F|ufw[[:space:]]+disable|killall|fuser[[:space:]]+-k)([;&|[:space:]]|$)'; then
        echo "high"
    elif echo "$cmd" | grep -Eiq 'systemctl[[:space:]]+(stop|disable)|service[[:space:]][^[:space:]]+[[:space:]]+stop'; then
        echo "high"
    elif echo "$cmd" | grep -Eiq 'systemctl[[:space:]]+restart|service[[:space:]][^[:space:]]+[[:space:]]+restart|chmod[[:space:]]+777|chown[[:space:]]+-R'; then
        echo "medium"
    else
        echo "low"
    fi
}

policy_check_command() {
    local cmd="$1" host_count="${2:-1}" confirm="${3:-}"
    local risk
    risk="$(policy_risk_for_command "$cmd")"

    if [[ "$risk" == "high" ]]; then
        if [[ "${SSH_SKILL_CONFIRMED:-}" != "yes" && "$confirm" != "--confirm" ]]; then
            die_json "policy_blocked" "高风险命令需要显式确认：设置 SSH_SKILL_CONFIRMED=yes 或追加 --confirm。risk=high hosts=$host_count cmd=$(redact_string "$cmd")"
        fi
    fi

    if [[ "$risk" == "medium" && "$host_count" -gt 20 ]]; then
        if [[ "${SSH_SKILL_CONFIRMED:-}" != "yes" && "$confirm" != "--confirm" ]]; then
            die_json "policy_blocked" "中风险命令作用于超过 20 台主机，需要显式确认：设置 SSH_SKILL_CONFIRMED=yes 或追加 --confirm。risk=medium hosts=$host_count cmd=$(redact_string "$cmd")"
        fi
    fi
}

ensure_connected() {
    local host_name="$1" ctl_socket="$2"
    mkdir -p "$CTL_DIR"
    if [[ ! -S "$ctl_socket" ]]; then
        echo "[ssh-skill] socket 不存在，尝试自动重连..." >&2
        bash "$SCRIPTS_DIR/connect.sh" "$host_name" >&2 || \
            die_json "not_connected" "连接不存在且自动重连失败，请先运行 connect.sh $host_name" "$host_name"
    fi

    local check
    check=$(ssh -o "ControlPath=$ctl_socket" -O check placeholder 2>&1 || true)
    if ! echo "$check" | grep -q "Master running"; then
        echo "[ssh-skill] socket 已失效，尝试重连..." >&2
        rm -f "$ctl_socket"
        bash "$SCRIPTS_DIR/connect.sh" "$host_name" >&2 || \
            die_json "reconnect_failed" "重连失败，请检查网络或主机状态" "$host_name"
    fi
}

write_audit_event() {
    local run_id="$1" host="$2" action="$3" success="$4" exit_code="$5" duration_ms="$6" command_text="${7-}"
    mkdir -p "$AUDIT_DIR/$(date -u +%Y-%m-%d)"
    local file="$AUDIT_DIR/$(date -u +%Y-%m-%d)/${run_id}.jsonl"
    printf '{"time":"%s","run_id":"%s","host":"%s","action":"%s","success":%s,"exit_code":%s,"duration_ms":%s,"command":"%s"}\n' \
        "$(now_iso)" \
        "$(json_escape "$run_id")" \
        "$(json_escape "$host")" \
        "$(json_escape "$action")" \
        "$success" \
        "$exit_code" \
        "$duration_ms" \
        "$(json_escape "$(redact_string "$command_text")")" >> "$file"
}
