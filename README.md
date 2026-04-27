# SSH/Linux Ops Skill (Agent-native)

[中文 v1.3.0 安全加固说明](docs/ssh-skill-v1.3.0-hardening.zh-CN.md) | [English v1.3.0 Safety Hardening Notes](docs/ssh-skill-v1.3.0-hardening.md)

OpenClaw 的通用 Linux 运维 skill，基于系统 `ssh` + ControlMaster，为 AI Agent 提供一组 **可组合、可审计、可批量执行的 Linux 操作 primitives**。

目标不是把 Ansible playbook 换成 bash playbook，而是给 Agent 一套安全的 Linux 操作积木：Agent 自己观察、推理、选择下一步；skill 负责连接、执行、批量、脱敏、策略拦截、审计和结果落盘。

## 设计原则

| 原则 | 说明 |
|------|------|
| Agent 自主组合 | 不内置僵硬流程，不强行规定“部署步骤” |
| Primitive-first | 提供观察、文件、进程、网络、包管理、服务、锁等通用操作 |
| SSH as syscall | `exec.sh` 是底层 syscall，其他脚本是更安全的 Linux primitives |
| 结构化结果 | 返回 JSON，方便 Agent 继续判断 |
| 批量安全 | `runner.sh` 提供并发、超时、失败率控制、结果落盘 |
| 显式提权 | `Permission denied` 后不会默认 sudo；必须 `--sudo` 或显式环境变量授权 |
| 配置隔离 | `hosts.example.yaml` 可提交；真实 `hosts.yaml` 和 `.secrets/` 不提交 |

## 快速开始

```bash
# 1. 准备本地 inventory。hosts.yaml 已加入 .gitignore。
cp hosts.example.yaml hosts.yaml

# 2. 准备真实连接信息。真实 IP/domain/key path 只放 .secrets/。
mkdir -p .secrets
cp .secrets/host.env.example .secrets/demo-edge-01.env

# 3. 校验 inventory。
bash scripts/validate_hosts.sh hosts.yaml --allow-real-hosts

# 4. 连接和观察。
bash scripts/list_hosts.sh
bash scripts/connect.sh demo-edge-01
bash scripts/exec.sh demo-edge-01 "uptime"
```

批量执行：

```bash
bash scripts/runner.sh --target "tag=production" --cmd "uptime" --parallel 20 --timeout 30 --fail-fast 20%
```

需要显式 sudo 重试时：

```bash
bash scripts/exec.sh demo-edge-01 "cat /var/log/app.log | tail -50" --sudo
bash scripts/runner.sh --target "tag=dev" --cmd "cat /var/log/app.log | tail -50" --sudo
```

## 核心脚本

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
| Inventory 校验 | `validate_hosts.sh` |
| 公共能力 | `common.sh`：JSON、脱敏、策略、审计、配置读取 |

## Agent 推荐工作方式

Agent 不需要死板执行 playbook。推荐循环是：

```text
observe -> reason -> choose primitive -> execute -> inspect result -> continue/stop
```

例子：排查某台机器 Caddy 异常：

```bash
bash scripts/sys.sh demo-edge-01 summary
bash scripts/service.sh demo-edge-01 status caddy
bash scripts/sys.sh demo-edge-01 journal caddy 100
bash scripts/net.sh demo-edge-01 listen 80
bash scripts/net.sh demo-edge-01 listen 443
bash scripts/file.sh demo-edge-01 stat /etc/caddy/Caddyfile
```

Agent 根据每一步 JSON 输出决定下一步，而不是照固定剧本执行。

## Inventory 和 secrets

公开仓库只保留示例 inventory：

```text
hosts.example.yaml
.secrets/host.env.example
```

本地真实文件不提交：

```text
hosts.yaml
.secrets/<host>.env
```

示例 `hosts.yaml`：

```yaml
hosts:
  prod-edge-01:
    host: prod-edge-01                  # placeholder；真实 HOST 放 .secrets/prod-edge-01.env
    port: 22
    user: ubuntu
    auth: key
    key_path: /keys/prod-edge-01        # placeholder；真实 KEY_PATH 放 .secrets/prod-edge-01.env
    default_workdir: /opt/myapp
    provider: oci
    region: us-west
    env: prod
    role: edge
    tags: [production, us-west, caddy, edge]
```

对应 `.secrets/prod-edge-01.env`：

```bash
HOST=203.0.113.10
KEY_PATH=/path/to/private/key
# SSH_PASSWORD=your_password_here
```

校验：

```bash
bash scripts/validate_hosts.sh hosts.example.yaml
bash scripts/validate_hosts.sh hosts.yaml --allow-real-hosts
```

## 策略拦截

高风险动作必须显式确认：

- 读取私钥、`/etc/shadow`、`/etc/sudoers`
- `rm -rf /`、`rm -rf /etc`、`rm -rf /usr`、`rm -rf /home`、`rm -rf /root`
- `mkfs`、`wipefs`、`fdisk`、`parted`、`sgdisk`
- `dd ... of=/dev/...`
- `shutdown`、`reboot`、`poweroff`、`halt`
- `iptables -F`、`ip6tables -F`、`nft flush`、`ufw disable`
- `killall`、`fuser -k`
- `systemctl stop/disable/mask`
- `docker rm -f`、`docker system prune`
- `kubectl delete`
- `bash -c` / `sh -c` 中组合 `base64 -d`、`curl`、`wget`

中风险动作在超过 20 台主机或命中生产目标时需要确认。生产目标判断来自 `env: prod/production` 或 `tags` 包含 `prod/production`。

确认方式：

```bash
bash scripts/exec.sh prod-edge-01 "sudo systemctl restart caddy" --confirm
SSH_SKILL_CONFIRMED=yes bash scripts/exec.sh prod-edge-01 "sudo systemctl restart caddy"
```

## sudo 行为

`exec.sh` 不再在 `Permission denied` 后自动 sudo。默认返回 JSON，包含：

```json
{
  "error": "permission_denied",
  "sudo_used": false
}
```

显式授权才重试：

```bash
bash scripts/exec.sh demo-edge-01 "cat /var/log/app.log | tail -50" --sudo
SSH_SKILL_ALLOW_SUDO_RETRY=yes bash scripts/exec.sh demo-edge-01 "cat /var/log/app.log | tail -50"
```

sudo 重试前仍会重新走 policy guard。

## 输出脱敏

所有 JSON 输出和审计命令字段应走 `safe_json_string` 或 `redact_string`。当前覆盖：

- password/passwd/secret/token/api_key/ssh_password/private_key 赋值
- private key block header/footer
- IPv4、常见 IPv6
- `user@host` SSH target
- `.ssh` 路径、`.secrets` 路径、`/keys/...` placeholder
- 当前 host config 中加载到的真实 host、user、key path、secrets path

## 批量执行结果

`runner.sh` 摘要打印到 stdout，详情落盘：

```text
.runs/<run_id>/results/<host>.json
.audit/<date>/<run_id>.jsonl
```

建议 fleet 操作总是带：

```bash
--parallel <n> --timeout <sec> --fail-fast <percent>
```

## CI / 本地检查

```bash
bash -n scripts/*.sh
bash scripts/validate_hosts.sh hosts.example.yaml
```

GitHub Actions 会运行语法检查、示例 inventory 校验，以及非阻断的 ShellCheck advisory。

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
