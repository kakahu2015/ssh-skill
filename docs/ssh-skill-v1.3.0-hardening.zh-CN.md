# SSH/Linux Ops Skill v1.3.0 — 安全加固更新

[中文](ssh-skill-v1.3.0-hardening.zh-CN.md) | [English](ssh-skill-v1.3.0-hardening.md)

本次更新围绕 inventory 隔离、命令安全、sudo 行为、输出脱敏和 CI 校验，对 SSH/Linux Ops Skill 做了一轮安全加固。

## 主要变化

### 1. 更安全的 inventory 管理

仓库不再跟踪真实 `hosts.yaml`。公开仓库只保留安全示例：

```text
hosts.example.yaml
```

本地使用时复制一份：

```bash
cp hosts.example.yaml hosts.yaml
```

真实主机地址、私钥路径、密码和其他敏感连接信息只放在：

```text
.secrets/<host>.env
```

本地 `hosts.yaml` 和真实 `.secrets/` 文件已加入 Git 忽略规则。

### 2. Inventory 校验

新增校验脚本：

```bash
bash scripts/validate_hosts.sh hosts.example.yaml
bash scripts/validate_hosts.sh hosts.yaml --allow-real-hosts
```

它会检查 inventory 结构，并发现常见 OPSEC 问题，例如把真实 IP 或真实私钥路径写入公开 inventory。

### 3. 更强的输出脱敏

`common.sh` 的脱敏层现在覆盖更多敏感模式，包括：

- password、token、API key、private-key 风格变量
- private key block 的 header/footer
- IPv4 和常见 IPv6 地址
- SSH 风格的 `user@host` 目标
- `.ssh` 路径
- `.secrets` 路径
- `/keys/...` 占位路径
- 当前 host config 加载到的真实 host、user、key path 和 secrets path

JSON 输出和审计日志在适用位置会使用更安全的脱敏 helper。

### 4. 更强的策略拦截

命令策略层现在能识别更多风险操作，包括：

- 破坏性文件系统命令
- 磁盘格式化和分区命令
- 防火墙 flush 或 disable 操作
- 服务 stop、disable、mask 操作
- 危险 Docker 和 Kubernetes 操作
- 可疑的 `bash -c` 或 `sh -c`，尤其是和 downloader 或 base64 解码组合时
- 读取私钥、`/etc/shadow` 或 `/etc/sudoers` 的尝试

中风险命令在影响超过 20 台主机，或者目标通过 `env: prod`、`env: production` 或生产相关 tags 标记为生产环境时，需要显式确认。

### 5. 显式 sudo 重试

`exec.sh` 不再在 `Permission denied` 后自动用 `sudo` 重试。

默认返回结构化 JSON，例如：

```json
{
  "error": "permission_denied",
  "sudo_used": false
}
```

显式允许 sudo 重试：

```bash
bash scripts/exec.sh <host> "cat /var/log/app.log | tail -50" --sudo
```

批量执行时：

```bash
bash scripts/runner.sh --target "tag=dev" --cmd "cat /var/log/app.log | tail -50" --sudo
```

sudo 重试路径在执行前仍然会经过 policy guard。

### 6. 更安全的 SCP 输出

`scp_transfer.sh` 现在会对 JSON 输出中的 `src`、`dst` 和 stderr 字段做脱敏，降低泄漏本地路径、远端路径、用户名、主机名或项目目录名的风险。

### 7. 新增 CI

新增 GitHub Actions 工作流：

```text
.github/workflows/shell-ci.yml
```

它会运行：

```bash
bash -n scripts/*.sh
bash scripts/validate_hosts.sh hosts.example.yaml
```

同时以 advisory 模式运行 ShellCheck。

## 推荐本地初始化

```bash
cp hosts.example.yaml hosts.yaml
mkdir -p .secrets
cp .secrets/host.env.example .secrets/demo-edge-01.env

bash scripts/validate_hosts.sh hosts.yaml --allow-real-hosts
```

然后连接和执行命令：

```bash
bash scripts/list_hosts.sh
bash scripts/connect.sh demo-edge-01
bash scripts/exec.sh demo-edge-01 "uptime"
```

## 总结

`1.3.0` 版本通过隔离真实 inventory、增强脱敏、强化策略拦截、要求显式 sudo 提权、增加 inventory 校验和 CI 覆盖，让这个 skill 更适合公开复用和类生产环境使用。
