# SSH/Linux Ops Skill v2.0 (Agent-native)

[Agent 自治模型](docs/agent-autonomy.zh-CN.md) | [Agent Autonomy Model](docs/agent-autonomy.md)  
[中文 v1.3.0 安全加固说明](docs/ssh-skill-v1.3.0-hardening.zh-CN.md) | [English v1.3.0 Safety Hardening Notes](docs/ssh-skill-v1.3.0-hardening.md)

OpenClaw 的通用 Linux 运维 skill，基于系统 `ssh` + ControlMaster，为 AI Agent 提供一组 **可组合、可审计、可批量执行、可被运行时门禁约束的 Linux 操作 primitives**。

目标不是把 Ansible playbook 换成 bash playbook，也不是堆固定任务脚本。这个项目的目标是给大模型一个安全、结构化、可审计的远程 Linux 操作面：**Agent 负责观察、推理、决策和验证；skill 负责安全执行、运行时门禁、语义规则、脱敏审计和升级通知。**

## v2.0 Runtime Model

v2.0 的核心变化是：`agent_gate.sh` 只保留为兼容 wrapper，真正的安全边界迁移到 Python runtime：

```text
decision-record.json
  -> validate_decision.py
  -> validate_autonomy.py
  -> agent_gate.sh
  -> agent_gate.py
  -> primitive_rules.json
  -> autonomy/risk/env/host-count checks
  -> semantic guard
  -> path guard
  -> raw exec guard
  -> execute exactly one primitive
  -> verification_actions
  -> rollback_actions when requested
  -> redacted audit with decision/policy/rules hashes
  -> escalation event on gate block
```

关键能力：

| 能力 | v2.0 行为 |
|---|---|
| Python runtime gate | `agent_gate.py` 使用 argv-style subprocess 调用 primitive，不使用 shell 字符串执行模型输入 |
| Fail-closed semantic guard | `primitive_rules.json` 加载失败、未知 primitive、未知 command 默认阻断 |
| Risk mismatch guard | decision 声明的 risk 不能低于 primitive/action 规则计算出的 risk |
| Path guard | 敏感路径如 `.ssh`、`.secrets`、`/etc/shadow`、Kubernetes/Docker 私密路径默认阻断 |
| Raw exec guard | `exec.sh` 不是 unattended default，必须显式审批/允许 |
| Composite observations | `composite.sh` 是只读 primitive；Agent 使用时应通过 gate |
| Escalation event | gate block 会写 `.escalation.json`，可选 webhook |
| Audit hash | decision/policy/rules hash 写入 decision audit 便于复盘 |
| Test mode | `--test-mode` 只用于 mock primitive 测试，不用于生产 |

## 设计原则

| 原则 | 说明 |
|------|------|
| Agent 自主组合 | 不内置僵硬流程，不强行规定“部署步骤” |
| Primitive-first | 提供观察、文件、进程、网络、包管理、服务、锁、组合观察等通用操作 |
| AI reasoning first | 让模型使用 Linux/运维知识推理，但必须用实时观测验证假设 |
| SSH as syscall | `exec.sh` 是底层 syscall，其他脚本是更安全的 Linux primitives |
| Python gate as runtime boundary | Agent-owned unattended action 必须经过 `agent_gate.py` |
| Fail-closed by default | 缺规则、坏规则、未知 primitive、未知 command 都阻断 |
| 结构化结果 | 返回 JSON，方便 Agent 继续判断 |
| 有界无人值守 | 受 autonomy level、policy、semantic rules、verification、rollback、escalation 约束 |
| 配置隔离 | `hosts.example.yaml` 可提交；真实 `hosts.yaml`、`autonomy.yaml` 和 `.secrets/` 不提交 |

## 快速开始

```bash
cp hosts.example.yaml hosts.yaml
mkdir -p .secrets
cp .secrets/host.env.example .secrets/demo-host-01.env
bash scripts/validate_hosts.sh hosts.yaml --allow-real-hosts
```

只读观察：

```bash
bash scripts/sys.sh demo-host-01 summary
bash scripts/composite.sh demo-host-01 quick
```

Agent-owned 操作建议先生成 decision record 并走 gate：

```bash
python3 scripts/validate_decision.py examples/decision-record.observe.json --quiet
python3 scripts/validate_autonomy.py autonomy.example.yaml --quiet
bash scripts/agent_gate.sh --decision examples/decision-record.observe.json --policy autonomy.example.yaml --dry-run
```

## 核心脚本与规则

| 能力 | 文件 |
|------|------|
| Python runtime gate | `scripts/agent_gate.py` |
| Gate wrapper | `scripts/agent_gate.sh` |
| Semantic rules | `scripts/primitive_rules.json` |
| Decision validation | `scripts/validate_decision.py` |
| Autonomy policy validation | `scripts/validate_autonomy.py` |
| SSH 连接复用 | `connect.sh`, `disconnect.sh` |
| Raw syscall | `exec.sh` |
| Batch execution | `runner.sh` |
| 主机选择 | `select_hosts.sh` |
| 系统观察 | `sys.sh`, `facts.sh`, `patrol.sh` |
| 文件操作 | `file.sh` |
| 进程操作 | `proc.sh` |
| 网络观察 | `net.sh` |
| 包管理 | `pkg.sh` |
| 服务管理 | `service.sh` |
| 只读组合观察 | `composite.sh` |
| 文件传输 | `scp_transfer.sh` |
| 主机锁 | `lock.sh` |
| Inventory 校验 | `validate_hosts.sh` |

## Agent 推荐工作方式

Agent 不需要死板执行 playbook。推荐循环是：

```text
observe -> classify -> hypothesize -> choose primitive -> write decision record -> validate -> gate -> execute -> verify -> continue/stop/escalate
```

泛化示例：排查某台机器上的某个服务异常：

```bash
bash scripts/composite.sh <host> services <service>
bash scripts/service.sh <host> status <service>
bash scripts/sys.sh <host> journal <service> 100
bash scripts/net.sh <host> listen <port>
bash scripts/file.sh <host> stat <config-path>
```

Agent 可以使用自己对 Linux、systemd、网络、文件系统、包管理器和服务运行机制的知识来选择下一步，但必须用实时 JSON 输出验证假设，而不是照固定剧本执行。

## AI 自治与无人值守

无人值守不是无限自动化。正确做法是把 skill 保持为 primitives，让 Agent 结合大模型知识和实时观测自主推理，同时由本地策略和 runtime gate 约束边界。

相关文件：

```text
docs/agent-autonomy.zh-CN.md
docs/agent-autonomy.md
autonomy.example.yaml
scripts/primitive_rules.json
schemas/decision-record.schema.json
schemas/gate-result.schema.json
schemas/run-summary.schema.json
schemas/escalation-event.schema.json
examples/decision-record.observe.json
```

默认无人值守等级建议是 **L1 观察模式**：只允许 bounded read-only primitives。L2/L3 必须通过本地 `autonomy.yaml` 显式配置，并且需要 decision record、verification 和 policy guard。

自治等级：

| Level | 名称 | 含义 |
|---|---|---|
| L0 | Advisory | 不远程执行，只解释和规划 |
| L1 | Observe | 只读观察，有限日志和状态检查 |
| L2 | Safe self-heal | 低风险可逆动作，例如重连、刷新 facts、备份 |
| L3 | Bounded change | 非生产、有验证、有边界的中风险变更 |
| L4 | Privileged/prod-impacting | 特权或生产影响动作，必须显式确认 |
| L5 | Forbidden | 禁止无人值守执行 |

Agent 在执行超出只读观察的动作前，应生成 concise decision record，而不是暴露长篇推理链。decision record 是操作凭证，不是 chain-of-thought。

```bash
bash scripts/agent_gate.sh --decision examples/decision-record.observe.json --policy autonomy.example.yaml --dry-run
```

## Composite Observations

`composite.sh` 是只读组合观察 primitive，不执行写操作，不内置业务修复流程。

```bash
bash scripts/composite.sh <host> quick
bash scripts/composite.sh <host> services <service1> <service2>
bash scripts/composite.sh <host> network
```

`services` 必须显式传服务名，不再默认任何服务。`primitive_rules.json` 允许 lightweight composite actions 在 L1 运行；`all` 因输出较大，默认提升到 L2。

## Inventory 和 secrets

公开仓库只保留示例 inventory：

```text
hosts.example.yaml
.secrets/host.env.example
```

本地真实文件不提交：

```text
hosts.yaml
autonomy.yaml
.secrets/<host>.env
```

校验：

```bash
bash scripts/validate_hosts.sh hosts.example.yaml
bash scripts/validate_hosts.sh hosts.yaml --allow-real-hosts
```

## Safety and Audit

v2.0 audit 会记录红acted decision，并附带：

```text
decision_hash
policy_hash
rules_hash
```

这些 hash 用于复盘“当时是哪份 decision、哪份 policy、哪份 primitive rules 让 gate 做出允许/阻断判断”。

相关 schema：

```text
schemas/audit-event.schema.json
schemas/gate-result.schema.json
schemas/run-summary.schema.json
schemas/escalation-event.schema.json
```

## CI / 本地检查

```bash
bash -n scripts/*.sh tests/*.sh
python3 -m py_compile scripts/validate_decision.py scripts/validate_autonomy.py scripts/agent_gate.py scripts/redact.py
bash scripts/validate_hosts.sh hosts.example.yaml
python3 scripts/validate_autonomy.py autonomy.example.yaml --quiet
python3 scripts/validate_decision.py examples/decision-record.observe.json --quiet
bash scripts/agent_gate.sh --decision examples/decision-record.observe.json --policy autonomy.example.yaml --dry-run
bash tests/agent_gate_tests.sh
```

GitHub Actions 会运行语法检查、Python compile、inventory validation、autonomy policy validation、decision validation、generic agent gate dry-run、generic gate test matrix，以及非阻断 ShellCheck advisory。

当前 gate test matrix 覆盖：

```text
L1 observe allow
raw exec block
production L3 block
host-count block
OPSEC leakage block
unknown field block
invalid autonomy policy block
execute success + verification success
verification failure + rollback
action failure stop
unknown primitive -> semantic_blocked
unknown command -> semantic_blocked
risk mismatch -> risk_mismatch
sensitive path -> path_blocked
corrupt primitive_rules.json -> rules_load_failed
composite all at L1 -> semantic_blocked
escalation file generation
audit hash metadata
```

## 与 Ansible 的区别

Ansible 是人类声明式配置管理：playbook、role、inventory、变量、模板。

这个 skill 是 Agent-native Linux 操作 runtime：

- 不要求提前写 playbook
- 不把业务流程写死在工具里
- 给 Agent 通用 Linux primitives
- Agent 根据观测结果自主组合步骤
- runtime gate 负责安全边界
- semantic rules、audit、redaction、escalation 由 skill 承担
- 远端不需要 Python/Ansible 环境

一句话：

> Ansible 管“期望状态”；这个 skill 给 Agent 提供“可安全调用的 Linux 操作系统接口”。
