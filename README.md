# SSH/Linux Ops Skill (Agent-native)

OpenClaw 的通用 Linux 运维 skill，基于系统 `ssh` + ControlMaster，为 AI Agent 提供一组 **可组合、可审计、可批量执行的 Linux 操作 primitives**。

> 目标不是把 Ansible playbook 换成 bash playbook，而是给 Agent 一套安全的 Linux 操作积木：Agent 自己观察、推理、选择下一步；skill 负责连接、执行、批量、脱敏、策略拦截、审计和结果落盘。

## 设计原则

| 原则 | 说明 |
|------|------|
| Agent 自主组合 | 不内置僵硬流程，不强行规定“部署步骤” |
| Primitive-first | 提供观察、文件、进程、网络、包管理、服务、锁等通用操作 |
| SSH as syscall | `exec.sh` 是底层 syscall，其他脚本是更安全的 Linux primitives |
| 结构化结果 | 返回 JSON，方便 Agent 继续判断 |
| 批量安全 | `runner.sh` 提供并发、超时、失败率控制、结果落盘 |
| 最小护栏 | 高风险动作需确认；其余让 Agent 自主推理 |
| 不依赖远端 Agent | 远端只需要常见 Linux 命令，不要求 Python/Ansible |

## 核心能力

| 能力 | 脚本 |
|------|------|
| SSH 连接复用 | `connect.sh`, `disconnect.sh` |
| 自由命令执行 | `exec.sh` |
| 批量并发执行 | `runner.sh` |
| 主机选择 | `select_hosts.sh` |
| 系统观察 | `sys.sh`, `facts.sh`, `patrol.sh` |
| 文件操作 | `file.sh` |
| 进程操作 | `proc.sh` |
| 网络观察 | `net.sh` |
| 包管理 | `pkg.sh` |
| 服务管理 | `service.sh` |
| 文件传输 | `scp_transfer.sh` |
| 主机锁 | `lock.sh` |
| 公共能力 | `common.sh`：JSON、脱敏、策略、审计、配置读取 |

## 快速开始

```bash
# 列主机
bash scripts/list_hosts.sh

# 建立连接
bash scripts/connect.sh hk

# 自由命令，适合 Agent 临时探索
bash scripts/exec.sh hk "uptime"

# 批量命令，适合几十到上百台 VPS
bash scripts/runner.sh --target "tag=production" --cmd "uptime" --parallel 20 --timeout 30

# 按标签/字段选择目标
bash scripts/select_hosts.sh --target "tag=production,role=edge" --csv
```

## 通用 Linux primitives

### 系统观察

```bash
bash scripts/sys.sh hk summary
bash scripts/sys.sh hk disk
bash scripts/sys.sh hk memory
bash scripts/sys.sh hk load
bash scripts/sys.sh hk journal caddy 100
bash scripts/sys.sh hk dmesg 100
```

### 文件操作

```bash
bash scripts/file.sh hk exists /etc/caddy/Caddyfile
bash scripts/file.sh hk stat /etc/caddy/Caddyfile
bash scripts/file.sh hk tail /var/log/syslog 100
bash scripts/file.sh hk grep "error" /var/log/syslog 50
bash scripts/file.sh hk checksum /usr/bin/caddy
bash scripts/file.sh hk backup /etc/caddy/Caddyfile
bash scripts/file.sh hk mkdir /opt/app
bash scripts/file.sh hk remove /tmp/old-file --confirm
```

### 进程操作

```bash
bash scripts/proc.sh hk top 30
bash scripts/proc.sh hk mem 30
bash scripts/proc.sh hk find caddy
bash scripts/proc.sh hk tree 80
bash scripts/proc.sh hk kill 1234 --confirm
```

### 网络操作

```bash
bash scripts/net.sh hk ports 100
bash scripts/net.sh hk listen 443
bash scripts/net.sh hk curl http://127.0.0.1:2019/config/ 40
bash scripts/net.sh hk dns example.com
bash scripts/net.sh hk route
bash scripts/net.sh hk addr
```

### 包管理

```bash
bash scripts/pkg.sh hk detect
bash scripts/pkg.sh hk search nginx 30
bash scripts/pkg.sh hk installed curl
bash scripts/pkg.sh hk update-cache --confirm
bash scripts/pkg.sh hk install htop --confirm
```

### 服务管理

```bash
bash scripts/service.sh hk status caddy
bash scripts/service.sh hk logs caddy
bash scripts/service.sh hk restart caddy
bash scripts/service.sh hk stop caddy --confirm
```

### 主机锁

锁不是 workflow，只是给 Agent 协调并发写操作用：

```bash
bash scripts/lock.sh hk acquire --timeout 60 --run-id run_xxx
bash scripts/lock.sh hk status
bash scripts/lock.sh hk release --run-id run_xxx
```

## Agent 推荐工作方式

Agent 不需要死板执行 playbook。推荐循环是：

```text
observe -> reason -> choose primitive -> execute -> inspect result -> continue/stop
```

例子：排查某台机器 Caddy 异常：

```bash
bash scripts/sys.sh hk summary
bash scripts/service.sh hk status caddy
bash scripts/sys.sh hk journal caddy 100
bash scripts/net.sh hk listen 80
bash scripts/net.sh hk listen 443
bash scripts/file.sh hk stat /etc/caddy/Caddyfile
```

Agent 根据每一步 JSON 输出决定下一步，而不是照固定剧本执行。

## 批量入口

上百台 VPS 时，Agent 应优先用 `runner.sh`：

```bash
bash scripts/runner.sh \
  --target "tag=production,role=edge" \
  --cmd "systemctl status caddy --no-pager | head -20" \
  --parallel 20 \
  --timeout 30 \
  --fail-fast 20%
```

摘要会打印到 stdout，详情落盘：

```text
.runs/<run_id>/results/<host>.json
.audit/<date>/<run_id>.jsonl
```

## 目标选择

```bash
bash scripts/select_hosts.sh --tag production --csv
bash scripts/select_hosts.sh --field region=hk --field role=edge
bash scripts/select_hosts.sh --env prod --role caddy --csv
bash scripts/select_hosts.sh --target "tag=production,region=hk,role=edge" --csv
```

建议 `hosts.yaml` 增加可筛选元数据：

```yaml
hosts:
  hk-01:
    host: hk-01
    port: 22
    user: root
    auth: key
    key_path: /keys/hk-01
    default_workdir: /root
    provider: alibaba
    region: hk
    env: prod
    role: edge
    tags: [production, hk, caddy, edge]
```

## 策略拦截

保留最小护栏，不替 Agent 思考。

默认拦截高风险动作，例如：

- `rm -rf /`
- `mkfs`
- `dd if=`
- `shutdown` / `reboot`
- `iptables -F`
- `ufw disable`
- `killall`
- `fuser -k`
- `systemctl stop`
- `systemctl disable`

确认方式：

```bash
bash scripts/exec.sh hk "sudo systemctl stop caddy" --confirm
SSH_SKILL_CONFIRMED=yes bash scripts/exec.sh hk "sudo systemctl stop caddy"
```

中风险命令如果作用于超过 20 台主机，也需要确认，例如批量 `systemctl restart`。

## 与 Ansible 的区别

Ansible 是人类声明式配置管理：playbook、role、inventory、变量、模板。

这个 skill 是 Agent-native Linux 操作层：

- 不要求提前写 playbook
- 不把业务流程写死在工具里
- 给 Agent 通用 Linux primitives
- Agent 根据观测结果自主组合步骤
- 批量、审计、策略、脱敏由 skill 承担
- 远端不需要 Python/Ansible 环境

一句话：

> Ansible 管“期望状态”；这个 skill 给 Agent 提供“可安全调用的 Linux 操作系统接口”。

## 目录结构

```text
ssh-skill/
├── README.md
├── SKILL.md
├── _meta.json
├── hosts.yaml
├── scripts/
│   ├── common.sh        # 公共函数：配置、JSON、脱敏、策略、审计
│   ├── yaml.sh          # 轻量 YAML 解析
│   ├── connect.sh       # 建立 ControlMaster 连接
│   ├── disconnect.sh    # 断开连接
│   ├── exec.sh          # 自由命令执行
│   ├── runner.sh        # 并发批量执行入口
│   ├── select_hosts.sh  # 按 tag/字段选择主机
│   ├── sys.sh           # 系统观察 primitive
│   ├── file.sh          # 文件 primitive
│   ├── proc.sh          # 进程 primitive
│   ├── net.sh           # 网络 primitive
│   ├── pkg.sh           # 包管理 primitive
│   ├── service.sh       # 服务 primitive
│   ├── scp_transfer.sh  # 文件传输
│   ├── facts.sh         # 主机事实采集
│   ├── patrol.sh        # 轻量巡检
│   ├── lock.sh          # 主机锁
│   └── list_hosts.sh    # 列出主机
├── references/
├── .secrets/            # 真实凭据，本地存在，不提交
├── .runs/               # 执行结果，本地生成，不提交
├── .audit/              # 审计日志，本地生成，不提交
└── .state/              # 未来状态库，本地生成，不提交
```

## 安全说明

- `hosts.yaml` 不应包含真实 IP、真实密钥路径、密码或 token
- `.secrets/<host>.env` 保存真实连接信息，不提交 git
- 输出会自动脱敏 password/token/api_key/IPv4/key path
- 高风险命令有策略拦截
- 文件被占用时默认不自动杀进程，必须显式 `--force-release`
- 批量执行详情和审计记录只落本地 `.runs/.audit`，已加入 `.gitignore`

## 适用场景

- AI Agent 远程 Linux 操作
- 5-100+ 台 VPS 的轻量批量运维
- Agent 自动巡检、排障、修复建议、按需变更
- 文件、进程、网络、服务、包管理等通用操作
- 没有 Ansible 环境的快速运维

## 不适合场景

- 强声明式配置治理
- 复杂 role/playbook 模板体系
- 企业级 CMDB/审批/变更窗口
- 强合规生产环境的无人值守自动变更

这个 skill 适合作为 Agent 的 Linux 运维底座，而不是把 Agent 变成 Ansible 执行器。
