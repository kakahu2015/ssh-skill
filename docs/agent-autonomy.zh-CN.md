# Agent 自治模型

[中文](agent-autonomy.zh-CN.md) | [English](agent-autonomy.md)

这个 skill 不应该继续膨胀成一堆固定任务脚本。它的目标是暴露 Linux 操作 primitives，让 AI Agent 结合自身推理能力、系统知识储备和实时观测结果，自主组合下一步操作。

正确抽象不是：

```text
运行某个预定义修复脚本
```

而是：

```text
观察 -> 分类 -> 假设 -> 选择 primitive -> 进入门禁 -> 执行 -> 验证 -> 继续、停止或升级给人
```

## 设计目标

skill 提供操作面，Agent 提供推理。

Agent 可以使用自己对 Linux、网络、文件系统、服务管理器、包管理器、daemon 和故障模式的知识，但必须先用真实主机观测验证假设，不能把知识储备当成事实。

泛化例子：

- Agent 可以知道很多服务由服务管理器托管，但要用 `service.sh status <service>`、有限日志、进程和网络 primitive 验证。
- Agent 可以知道不同发行版使用不同包管理器，但要用 `pkg.sh detect` 验证。
- Agent 可以知道磁盘压力会影响很多子系统，但要用 `sys.sh disk`、`file.sh list` 和有限日志查看验证。
- Agent 可以知道端口监听可能代表服务可用，但修改服务前必须确认监听状态和归属。

## 什么应该放进 skill

skill 应该包含：

- 小而可组合的 primitives
- 结构化 JSON 输出
- runtime autonomy gate
- 策略护栏和 policy 检查
- 脱敏和审计日志
- 目标选择和有边界的批量执行
- inventory 校验
- 帮助 Agent 稳定推理的决策和动作 schema

skill 应该避免：

- 写死业务流程
- 隐藏式部署 playbook
- 特定应用的一键修复脚本
- 大型一次性 fix 脚本
- 静默破坏性操作
- 无边界扫描或日志 dump

## 自治等级

用自治等级决定无人值守 Agent 可以做什么。

| Level | 名称 | 含义 | 典型允许范围 |
|---|---|---|---|
| L0 | 建议模式 | 不远程执行 | 解释、规划、请求授权 |
| L1 | 观察模式 | 只读执行 | facts、status、有限日志、端口、磁盘、进程列表 |
| L2 | 安全自愈 | 低风险可逆动作 | 重连 ControlMaster、刷新 facts、创建备份、重试幂等读操作 |
| L3 | 有边界变更 | 带验证和回滚的中风险动作 | 非生产服务 restart、有限配置备份、包缓存更新 |
| L4 | 特权/破坏性 | 高风险或生产影响动作 | 必须显式确认或人工审批 |
| L5 | 禁止 | Agent 不得无人值守执行 | 读私钥、磁盘破坏、广泛删除、防火墙 flush、凭据外传 |

默认无人值守模式应该是 **L1**。只有在用户显式配置并有严格护栏时，才能提升到 L2 或 L3。

## Runtime Gate

`agent_gate.sh` 把自治模型变成运行时门禁。它仍然是通用组件：不知道业务服务、部署步骤或修复流程。

```bash
bash scripts/agent_gate.sh --decision examples/decision-record.observe.json --policy autonomy.example.yaml --dry-run
```

它负责：

1. 解析并校验 decision record。
2. 读取本地 autonomy policy。
3. 检查自治等级、风险、环境、主机数量和 primitive 允许范围。
4. 默认阻断 raw `exec.sh`，除非显式授权。
5. 只有在 `--execute` 时才执行一个 primitive。
6. 如果提供了 executable verification actions，则执行验证。
7. 验证失败后可以按配置执行 rollback actions。
8. 写入脱敏后的 decision audit 文件。

## 无人值守决策契约

在执行任何超出只读观察的无人值守动作前，Agent 应该生成结构化 decision record。这不是暴露长篇推理链，而是一份可审计的操作摘要。

泛化形态：

```json
{
  "intent": "collect bounded service health evidence",
  "autonomy_level": "L1",
  "target_scope": { "hosts": ["<host>"], "environment": "<env>" },
  "observations": ["target selected from metadata", "requested operation is read-only"],
  "hypothesis": "bounded observation is needed before diagnosis or change",
  "risk": "low",
  "action": {
    "primitive": "service.sh",
    "args": ["<host>", "status", "<service>"]
  },
  "guardrails": {
    "requires_confirmation": false,
    "requires_lock": false,
    "rollback_available": false,
    "max_hosts": 1
  },
  "verification": ["gate validates autonomy level, risk, primitive, and policy boundary"],
  "verification_actions": [],
  "rollback": [],
  "rollback_actions": [],
  "stop_condition": "gate succeeds or reports an autonomy/policy/schema error",
  "confidence": "high"
}
```

对应 JSON Schema：

```text
schemas/decision-record.schema.json
```

## Agent 推理规则

### 1. 可以使用知识，但必须验证

模型可以使用 Linux 和运维知识来选择下一步观察，但不能把先验知识当成证据。实时观测优先。

### 2. 优先使用语义 primitive

优先用 `sys.sh`、`file.sh`、`proc.sh`、`net.sh`、`pkg.sh`、`service.sh`。只有没有合适 primitive 时再用 `exec.sh`；如果存在 decision record，应优先经过 `agent_gate.sh`。

### 3. 观察必须有边界

无人值守模式禁止无边界输出。使用 `tail -50`、`head -100` 或 primitive 的 limit 参数。

### 4. 区分诊断和变更

观察和诊断可以更自治。变更必须经过自治等级、policy 检查，很多情况下还需要显式确认。

### 5. 每个动作都要验证

任何改变状态的动作都必须有验证步骤。如果验证失败，停止或升级，不要随机尝试更多修复。

### 6. 优先可逆操作

改文件前备份。选择能达成目标的最小扰动操作。批量变更前先单机 canary。

### 7. 歧义时升级

如果证据冲突、风险较高、缺少回滚或目标是生产环境，Agent 应该停止并请求确认。

## 无人值守循环

安全的无人值守 Agent 循环应该是：

```text
1. 加载 inventory 和目标元数据
2. 观察 facts 和当前状态
3. 分类主机、环境、服务和风险
4. 构造 decision record
5. 通过 agent_gate.sh 门禁
6. 如果允许，执行一个 primitive
7. 验证结果
8. 更新审计轨迹
9. 继续、停止或升级
```

循环由 Agent 控制。skill 只提供可靠工具和边界。

## 泛化示例

### 示例：只读故障分诊

L1 允许：

```bash
bash scripts/sys.sh <host> summary
bash scripts/service.sh <host> status <service>
bash scripts/sys.sh <host> journal <service> 100
bash scripts/net.sh <host> listen <port>
```

Agent 可以据此总结可能原因并提出下一步。

### 示例：非生产服务重启

在配置允许时，L3 可能允许：

```text
preconditions:
  env != prod
  service is known
  recent bounded observations indicate a transient failed state
  restart policy allows this primitive
  verification is defined
```

通过 gate 执行动作：

```bash
bash scripts/agent_gate.sh --decision <decision.json> --policy <autonomy.yaml> --execute
```

具体 primitive 和 args 由 decision record 指定，而不是写死在脚本里。

### 示例：生产影响变更

默认必须升级给人：

```text
env == prod
risk >= medium
requires_confirmation == true
```

Agent 应该生成 decision record 并请求批准，而不是无人值守修改生产环境。

## 反模式

不要把这个 skill 做成：

- 特定应用修复脚本
- 特定应用部署脚本
- 一次性清理脚本
- 广义 repair-all 脚本
- 隐藏 playbook runner

如果某个 workflow 有价值，应把它写成 Agent 推理模式，而不是写成僵硬脚本；除非它确实是通用 primitive。

## 北极星

这个项目应该成为 **AI-native remote operations substrate**：

- skill 负责安全执行
- 模型负责推理和适应
- policy 负责边界
- audit 负责问责

这才是无人值守操作的基础，而不是把项目做成脆弱的任务自动化脚本集合。
