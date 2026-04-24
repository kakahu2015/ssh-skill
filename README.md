# SSH Skill (Agent-native 增强版)

OpenClaw 的 SSH 运维技能包，基于系统 `ssh` + ControlMaster，专为 AI Agent 远程操作和小规模/中规模 VPS 运维设计。

> 这个项目不是传统 Ansible 克隆，而是 **Agent-native SSH 运维执行层**：让 Agent 通过稳定脚本 API 做连接、执行、批量调度、服务管理、文件传输、策略拦截和审计记录。

## 核心能力

| 能力 | 说明 |
|------|------|
| ControlMaster 复用 | `connect.sh` 建立持久连接，后续命令免重复认证 |
| 安全分层配置 | `hosts.yaml` 放占位符，真实 IP/密钥路径放 `.secrets/<host>.env` |
| 结构化输出 | 主要脚本返回 JSON，方便 Agent 继续决策 |
| 批量并发 | `runner.sh` 支持 `--parallel`、`--timeout`、`--fail-fast` |
| 目标选择 | `select_hosts.sh` 支持按 `tag/env/region/role/provider` 筛选 |
| 策略拦截 | 高风险命令默认阻断，需要 `--confirm` 或 `SSH_SKILL_CONFIRMED=yes` |
| 审计记录 | 执行事件写入 `.audit/YYYY-MM-DD/<run_id>.jsonl` |
| 结果落盘 | 批量执行详情写入 `.runs/<run_id>/results/` |
| 文件传输保护 | 被占用文件不再默认 kill，需要显式 `--force-release` |

## 快速开始

```bash
# 1. 列出可用主机
bash scripts/list_hosts.sh

# 2. 验证 ControlMaster socket 是否真实可用
bash scripts/list_hosts.sh --check

# 3. 建立连接
bash scripts/connect.sh hk

# 4. 单主机执行命令
bash scripts/exec.sh hk "uptime"

# 5. 多主机兼容执行
bash scripts/exec.sh "hk,us-west,google" "uptime"

# 6. 按标签/字段选择主机
bash scripts/select_hosts.sh --target "tag=production" --csv

# 7. 并发批量执行，适合几十到上百台 VPS
bash scripts/runner.sh --target "tag=production" --cmd "uptime" --parallel 20 --timeout 30

# 8. 管理服务
bash scripts/service.sh hk status caddy
bash scripts/service.sh hk restart caddy

# 9. 高风险动作需要确认
bash scripts/service.sh hk stop caddy --confirm
# 或者
SSH_SKILL_CONFIRMED=yes bash scripts/exec.sh hk "sudo systemctl stop caddy"

# 10. 上传文件；如目标文件被占用，默认报错，不自动杀进程
bash scripts/scp_transfer.sh hk upload ./caddy /usr/bin/caddy
# 显式允许释放占用进程
bash scripts/scp_transfer.sh hk upload ./caddy /usr/bin/caddy --force-release
```

## Agent 批量运维入口

推荐让 Agent 优先使用 `runner.sh`，而不是手动循环调用 `exec.sh`。

```bash
bash scripts/runner.sh \
  --target "tag=production,role=edge" \
  --cmd "systemctl status caddy --no-pager | head -20" \
  --parallel 20 \
  --timeout 30 \
  --fail-fast 20%
```

返回摘要 JSON：

```json
{
  "success": true,
  "run_id": "run_20260424T120000Z_12345",
  "target": "tag=production,role=edge",
  "risk": "low",
  "total": 120,
  "ok": 118,
  "failed": 2,
  "skipped": 0,
  "parallel": 20,
  "timeout_sec": 30,
  "results_dir": ".runs/run_xxx/results",
  "audit_dir": ".audit/2026-04-24"
}
```

每台机器的完整 stdout/stderr 会落盘到：

```text
.runs/<run_id>/results/<host>.json
```

审计记录会落盘到：

```text
.audit/<date>/<run_id>.jsonl
```

## 目标选择

`select_hosts.sh` 支持两类筛选：

```bash
# 按 tag
bash scripts/select_hosts.sh --tag production --csv

# 按字段
bash scripts/select_hosts.sh --field region=hk --field role=edge

# 简写
bash scripts/select_hosts.sh --env prod --role caddy --csv

# 组合表达式
bash scripts/select_hosts.sh --target "tag=production,region=hk,role=edge" --csv
```

建议把 `hosts.yaml` 扩展为更适合批量运维的结构：

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

默认会拦截高风险命令，例如：

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

高风险命令必须显式确认：

```bash
bash scripts/exec.sh hk "sudo systemctl stop caddy" --confirm
```

或：

```bash
SSH_SKILL_CONFIRMED=yes bash scripts/exec.sh hk "sudo systemctl stop caddy"
```

中风险命令如果作用于超过 20 台主机，也需要确认，例如批量 `systemctl restart`。

## 与 Ansible 的区别

Ansible 适合人类编写 playbook、role、inventory，并进行声明式配置管理。

ssh-skill 面向 AI Agent：

- 不要求提前编写 playbook
- 不要求远端 Python/Ansible 环境
- 每个操作都是可组合脚本 API
- 输出结构化 JSON，方便 Agent 继续决策
- 通过 ControlMaster 复用 SSH 连接
- 支持并发、超时、失败率、审计和结果落盘

因此，ssh-skill 不是传统意义上的 Ansible 克隆，而是 **Agent-native 的远程运维执行层**。

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
│   ├── exec.sh          # 执行远程命令
│   ├── runner.sh        # 并发批量执行入口
│   ├── select_hosts.sh  # 按 tag/字段选择主机
│   ├── scp_transfer.sh  # 文件传输
│   ├── service.sh       # 服务管理
│   ├── disconnect.sh    # 断开连接
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

- AI Agent 远程执行命令
- 5-100+ 台 VPS 的轻量批量运维
- 文件分发、服务重启、状态检查
- 没有 Ansible 环境的快速运维
- Agent 自动巡检/排障/部署的底层 SSH 执行层

## 不适合场景

- 大规模声明式配置管理
- 复杂 role/playbook 模板体系
- 强幂等配置治理
- 需要企业级 CMDB/权限审批/变更窗口的场景

这些场景可以继续用 Ansible、Terraform、SaltStack 或专门的运维平台。ssh-skill 更适合做 Agent 的安全执行层。
