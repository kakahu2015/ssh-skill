---
name: ssh
version: 1.0.0
description: >
  SSH 远程登录与交互式会话技能。当用户需要连接到远程服务器、持续执行多条远程命令、
  维持会话状态（工作目录、环境变量）、上传/下载文件（SCP）、管理远程进程或服务时使用。
  主机配置从 hosts.yaml 集中管理，敏感凭据通过独立 .secrets/<host>.env 隔离存储。
  调用系统 ssh 命令（ControlMaster 复用连接实现伪交互式会话）。
  触发关键词：ssh、登录服务器、远程执行、连接到、部署到、在服务器上、scp、
  "去 vps 看看"、"在 prod 上跑"、远程主机、跳板机。
compatibility:
  tools:
    - bash_tool
  system_deps:
    - ssh
    - scp
    - sshpass       # 仅密码登录时需要，可选
---

# SSH Skill

使用系统 `ssh` + ControlMaster 实现跨多次 bash_tool 调用的持久连接复用。
主机配置集中在 `hosts.yaml`，密码等敏感字段存于 `.secrets/<host>.env`（不入 git）。

---

## 目录结构

```
openclaw/skills/ssh/
├── SKILL.md
├── hosts.yaml                ← 所有主机配置（无敏感信息，可入 git）
├── scripts/
│   ├── connect.sh            ← 建立 ControlMaster 后台连接
│   ├── exec.sh               ← 复用连接执行命令
│   ├── disconnect.sh         ← 关闭 ControlMaster socket
│   ├── scp_transfer.sh       ← 文件上传/下载
│   └── list_hosts.sh         ← 列出可用主机
├── references/
│   └── hosts_yaml_format.md  ← hosts.yaml 格式说明
└── .secrets/                 ← 敏感凭据目录（整体加入 .gitignore）
    ├── .gitignore
    └── <host>.env.example    ← 密码/passphrase 模板
```

---

## 工作流程

### Step 1：列出并确认主机

```bash
bash skills/ssh/scripts/list_hosts.sh
```

如果用户未明确指定主机名，展示列表让用户选择。

### Step 2：建立连接（ControlMaster）

```bash
bash skills/ssh/scripts/connect.sh <host>
```

- 读取 `hosts.yaml` 中该主机的配置
- 若 `auth: password`，从 `.secrets/<host>.env` 加载 `SSH_PASSWORD`，通过 `sshpass` 传入
- 在 `/tmp/ssh-ctl/` 下创建 ControlMaster socket
- 后台保持连接（`-N -f -o ControlMaster=yes`）
- 输出连接状态 JSON

**连接成功后**，后续所有命令复用此 socket，无需重复认证。

### Step 3：执行命令（交互式会话）

```bash
bash skills/ssh/scripts/exec.sh <host> "command here"
```

**状态保持策略**：ssh 每次是独立进程，工作目录不跨调用持久。有两种方式处理：

- **方式 A（推荐）**：在 `hosts.yaml` 设置 `default_workdir`，exec.sh 自动 `cd` 到该目录再执行
- **方式 B**：用户在命令中显式写路径，如 `cd /app && git pull`

需要维持状态时（如多步部署），将多条命令合并为一次调用：
```bash
bash skills/ssh/scripts/exec.sh prod "cd /app && git pull && npm install && pm2 restart app"
```

### Step 4：文件传输

```bash
# 上传
bash skills/ssh/scripts/scp_transfer.sh <host> upload /local/path /remote/path

# 下载
bash skills/ssh/scripts/scp_transfer.sh <host> download /remote/path /local/path
```

SCP 同样通过 ControlMaster socket 复用，无需重复认证。

### Step 5：关闭连接

```bash
bash skills/ssh/scripts/disconnect.sh <host>
```

用户说"退出"、"断开"、"关闭连接"、"不用了"时执行。

---

## 安全规则（必须遵守）

1. **不输出凭据**：IP、用户名、密码、私钥路径、私钥内容，一律不在对话中显示
2. **不修改配置文件**：hosts.yaml 和 .secrets/ 只读，不写入
3. **破坏性命令需确认**：执行 `rm -rf`、`dd`、`systemctl stop`、`DROP TABLE`、`> /dev/sda` 等前，必须向用户明确确认
4. **输出脱敏**：命令输出中出现 `password=`、`token=`、`secret=`、`key=` 等字样，替换为 `[REDACTED]` 后展示
5. **sudo 密码**：不在命令中嵌入 sudo 密码；如需 sudo，提示用户配置 `NOPASSWD` 或手动操作
6. **hosts.yaml 不存在时**：展示下方格式说明，引导用户创建

---

## hosts.yaml 格式

```yaml
hosts:
  prod:
    host: 1.2.3.4
    port: 22
    user: ubuntu
    auth: key                        # key | password
    key_path: ~/.ssh/id_ed25519      # auth: key 时必填
    default_workdir: /opt/myapp      # 可选，每次执行自动 cd
    tags: [production]

  dev-server:
    host: 192.168.1.50
    port: 2222
    user: admin
    auth: password                   # 密码从 .secrets/dev-server.env 读取
    default_workdir: ~
    tags: [dev, internal]

  bastion-jump:
    host: jump.example.com
    port: 22
    user: ec2-user
    auth: key
    key_path: ~/.ssh/jump.pem
    tags: [jump]

  prod-internal:
    host: 10.0.0.5
    port: 22
    user: ubuntu
    auth: key
    key_path: ~/.ssh/id_ed25519
    jump_host: bastion-jump          # ProxyJump，引用上面的主机名
    default_workdir: /srv/app
    tags: [production, internal]
```

---

## 错误处理

| 错误 | 处理 |
|------|------|
| `hosts.yaml` 不存在 | 展示格式说明，引导用户创建 |
| 主机名不在 yaml 中 | 列出已有主机，询问是否新增 |
| `sshpass` 未安装 | 提示 `apt install sshpass` 或改用私钥认证 |
| 连接超时 | 提示检查 host/port/防火墙，询问是否重试 |
| 认证失败 | 提示检查 .secrets/ 配置，不输出具体凭据 |
| ControlMaster socket 已过期 | 自动重新执行 connect.sh 后重试 |
| 命令 exit_code != 0 | 展示 stderr，询问是否需要排查 |
