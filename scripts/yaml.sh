#!/usr/bin/env bash
# YAML 解析工具函数（纯 bash，无 python 依赖）
# 仅适用于 hosts.yaml 这种 2 级缩进结构
# 用法: source yaml.sh; read_yaml <hosts.yaml> <hostname> <field>

read_yaml() {
    local file="$1" host="$2" field="$3"
    awk -v host="$host" -v field="$field" '
    BEGIN { in_hosts=0; in_host=0 }
    /^[a-zA-Z]/ && !/^hosts:/ { in_hosts=0; in_host=0; next }
    /^hosts:/ { in_hosts=1; next }
    in_hosts && /^  [a-zA-Z0-9_-]+:/ {
        gsub(/^  /, ""); gsub(/:.*$/, "")
        in_host = ($1 == host) ? 1 : 0
        next
    }
    in_host && /^    [a-zA-Z0-9_-]+:/ {
        line = $0
        gsub(/^    /, "", line)
        sub(/[[:space:]]*#.*$/, "", line)
        split(line, parts, /:[[:space:]]*/)
        key = parts[1]
        if (key == field) {
            val = ""
            for (i=2; i<=length(parts); i++) {
                if (i > 2) val = val ": "
                val = val parts[i]
            }
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", val)
            gsub(/^["\x27]|["\x27]$/, "", val)
            print val
            exit
        }
    }
    ' "$file"
}

list_hosts() {
    local file="$1"
    awk '
    /^[a-zA-Z]/ && !/^hosts:/ { in_hosts=0; next }
    /^hosts:/ { in_hosts=1; next }
    in_hosts && /^  [a-zA-Z0-9_-]+:/ {
        gsub(/^  /, ""); gsub(/:.*$/, "")
        print
    }
    ' "$file"
}
