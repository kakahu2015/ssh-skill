# SSH Skill (增强版)

OpenClaw 的 SSH 运维技能包，基于系统 ssh + ControlMaster，专为 AI Agent 远程操作设计。

> 原版基础上做了实战改进：**自动权限适配、文件锁处理、批量执行、服务管理、连接重试**。

## 核心改进

| 功能 | 原版 | 改进版 |
|------|------|--------|
| 权限不足 | 直接失败 | 自动加 `sudo` 重试 |
| 文件被占用 | 报错 `Text file busy` | 上传前自动释放占用进程 |
| 多主机执行 | 逐个手动执行 | `exec.sh "hk,us-west" "cmd"` 一行搞定 |
| 服务管理 | 无 | 新增 `service.sh` 封装 start/stop/status/logs |
| 连接稳定性 | 一次失败就挂 | 自动重试 3 次，ControlPersist 延长至 30 分钟 |

## 快速开始

```bash
# 1. 列出可用主机
bash skills/ssh/scripts/list_hosts.sh

# 2. 连接（自动持久化）
bash skills/ssh/scripts/connect.sh hk

# 3. 执行命令（支持多主机逗号分隔）
bash skills/ssh/scripts/exec.sh "hk,us-west,google" "uptime"

# 4. 上传文件（自动处理占用）
bash skills/ssh/scripts/scp_transfer.sh hk upload /local/file /remote/path

# 5. 管理服务（新增）
bash skills/ssh/scripts/service.sh hk status caddy
```

## 目录结构

```
ssh-skill/
├── README.md
├── SKILL.md            # OpenClaw 技能描述（agent 读这个）
├── hosts.yaml          # 主机配置（仅占位符，安全提交）
├── .secrets/           # 敏感信息（不提交，已加入 .gitignore）
├── scripts/
│   ├── connect.sh      # 建立 ControlMaster 连接（含重试）
│   ├── exec.sh         # 执行远程命令（自动 sudo）
│   ├── scp_transfer.sh # 文件传输（自动释放占用）
│   ├── service.sh      # 服务管理（新增）
│   ├── disconnect.sh   # 断开连接
│   └── list_hosts.sh  # 列出主机
└── references/         # 格式参考
```

## 为什么不用 Ansible？

| 场景 | 推荐 |
|------|------|
| 5-20 台机器，Agent 自动化运维 | **这个 ssh skill** |
| 几百台机器，复杂配置管理 | Ansible |

Ansible 是重型工业标准，但对你现在这个场景（OpenClaw agent 自动操作、少量服务器）来说，这个轻量改进的 ssh skill 更顺手。

## 安全

- `hosts.yaml` 只放占位符（主机名、端口、用户），可安全提交
- 真实 IP、密钥路径放 `.secrets/<host>.env`，已被 `.gitignore` 排除
- `exec.sh` 内置脱敏：自动过滤 password/token/IP
- 敏感操作（rm -rf、systemctl stop）需显式确认

## 适用场景

- ✅ AI Agent 远程执行命令
- ✅ 批量服务器运维（5-50 台）
- ✅ 文件分发、服务重启
- ✅ 没有 Ansible 环境的轻量运维

---

**实测**：5 台服务器批量替换 caddy 二进制 + 重启，全程自动化，比原版省心太多。
