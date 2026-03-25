#!/usr/bin/env bash
# OpenClaw SSH Skill - 列出 hosts.yaml 中所有主机
set -euo pipefail

SKILL_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPTS_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPTS_DIR/yaml.sh"

HOSTS_YAML="$SKILL_DIR/hosts.yaml"
CTL_DIR="/tmp/ssh-ctl"

[[ -f "$HOSTS_YAML" ]] || { echo '{"error":"hosts.yaml 不存在","path":"'"$HOSTS_YAML"'"}'; exit 1; }

HOSTS=$(list_hosts "$HOSTS_YAML")
COUNT=0

echo "{"
echo "  \"hosts\": ["

for HOST_NAME in $HOSTS; do
    HOST=$(read_yaml "$HOSTS_YAML" "$HOST_NAME" "host")
    USER=$(read_yaml "$HOSTS_YAML" "$HOST_NAME" "user")
    AUTH=$(read_yaml "$HOSTS_YAML" "$HOST_NAME" "auth")
    JUMP=$(read_yaml "$HOSTS_YAML" "$HOST_NAME" "jump_host")
    SOCKET="$CTL_DIR/${HOST_NAME}.sock"
    CONNECTED=$([ -S "$SOCKET" ] && echo true || echo false)

    [ $COUNT -gt 0 ] && echo ","

    echo "    {"
    echo "      \"name\": \"$HOST_NAME\","
    echo "      \"host\": \"$HOST\","
    echo "      \"user\": \"$USER\","
    echo "      \"auth\": \"$AUTH\","
    echo "      \"jump_host\": \"${JUMP:-}\","
    echo "      \"connected\": $CONNECTED"
    printf "    }"

    COUNT=$((COUNT + 1))
done

echo ""
echo "  ],"
echo "  \"count\": $COUNT"
echo "}"
