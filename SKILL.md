---
name: linux-ops
version: 1.4.0
description: >
  Agent-native Linux operations skill over SSH. Use when an AI Agent needs to observe,
  reason about, and operate remote Linux servers using composable primitives. This skill
  is an AI-native operations substrate, not a task-script collection: the skill owns safe
  execution primitives and guardrails; the model owns observation, reasoning, diagnosis,
  decision-making, verification, and escalation. Supports ControlMaster reuse, target
  selection, batch execution, policy guardrails, redaction, audit logs, explicit sudo retry,
  inventory validation, autonomy levels, agent_gate runtime enforcement, and decision
  records for bounded unattended operation.
compatibility:
  tools:
    - exec
  system_deps:
    - ssh
    - scp
    - bash
    - awk
    - sed
    - grep
    - python3       # required by agent_gate.sh for JSON decision parsing
    - sshpass       # optional, only for password auth
    - timeout       # optional, used by runner.sh per-host timeout when available
---

# Linux Ops Skill

This is an **Agent-native Linux operations primitive layer over SSH**.

It is not an Ansible clone, not a hidden playbook runner, and not a growing pile of app-specific repair scripts. The Agent should use its Linux and operations knowledge to reason from live observations, then choose bounded primitives under policy guardrails.

Recommended loop:

```text
observe -> classify -> hypothesize -> choose primitive -> gate -> execute -> verify -> continue, stop, or escalate
```

The skill provides safe, composable Linux operation primitives. The Agent remains responsible for diagnosis, sequencing, confidence assessment, verification, and deciding the next action.

---

## Core Model

- `exec.sh` is the low-level SSH syscall.
- `agent_gate.sh` is the generic runtime gate for AI Agent decision records.
- `runner.sh` is the concurrent fleet executor.
- `select_hosts.sh` is the targeting layer.
- `sys.sh`, `file.sh`, `proc.sh`, `net.sh`, `pkg.sh`, `service.sh` are Linux operation primitives.
- `scp_transfer.sh` is the file transfer primitive.
- `lock.sh` is a coordination primitive for write operations.
- `validate_hosts.sh` validates local inventory shape and OPSEC hygiene.
- `common.sh` provides config loading, JSON output, redaction, policy checks, and audit logging.
- `autonomy.example.yaml` describes local autonomy boundaries.
- `schemas/decision-record.schema.json` defines concise auditable decision records.
- `examples/decision-record.observe.json` provides a generic dry-run example.

Prefer semantic primitives over raw shell when a primitive exists. Do not force a fixed workflow. Let the Agent combine primitives based on observations.

---

## Non-Task-Script Rule

Do **not** add app-specific repair scripts or hard-coded workflows such as:

```text
fix_<service>.sh
deploy_<app>.sh
repair_everything.sh
cleanup_all_servers.sh
```

If behavior is reusable, express it as:

- a generic primitive,
- an autonomy policy rule,
- a decision-record contract,
- a verification/rollback contract,
- or an Agent reasoning pattern in docs.

The runtime code must remain business-agnostic.

---

## Agent Reasoning Model

The Agent may use general knowledge of Linux, networking, filesystems, system managers, package managers, daemons, and failure modes. It must verify assumptions with live host observations before acting.

Generic examples:

- Know that many services are managed by a service manager, but verify with `service.sh status <service>`, bounded logs, and network/process primitives.
- Know that distributions use different package managers, but verify with `pkg.sh detect` before package operations.
- Know that disk pressure can affect many subsystems, but verify with `sys.sh disk` and bounded file/log primitives.
- Know that a listening port may indicate service availability, but verify listen state and ownership before changing services.

The model should not treat prior knowledge as proof. Live observations win.

---

## Autonomy and Unattended Operation

Unattended operation must be optimized through **autonomy levels, decision records, runtime gating, verification, and escalation**, not through fixed repair scripts.

Reference files:

```text
docs/agent-autonomy.md
docs/agent-autonomy.zh-CN.md
autonomy.example.yaml
schemas/decision-record.schema.json
examples/decision-record.observe.json
```

Default unattended mode should be **L1 observe-only**.

| Level | Meaning | Default stance |
|---|---|---|
| L0 | Advisory only; no remote execution | Always safe |
| L1 | Bounded read-only observation | Default unattended mode |
| L2 | Low-risk reversible self-heal | Requires explicit local autonomy policy |
| L3 | Bounded non-prod change with verification | Requires explicit local autonomy policy and strict stop conditions |
| L4 | Privileged or production-impacting action | Requires confirmation or approval |
| L5 | Forbidden | Never execute unattended |

Before any unattended action beyond read-only observation, the Agent should produce a concise decision record. This is not a chain-of-thought dump; it is an auditable operational summary.

Generic dry-run gate:

```bash
bash skills/ssh/scripts/agent_gate.sh \
  --decision skills/ssh/examples/decision-record.observe.json \
  --policy skills/ssh/autonomy.example.yaml \
  --dry-run
```

Generic decision record shape:

```json
{
  "intent": "collect bounded host or service evidence",
  "autonomy_level": "L1",
  "target_scope": { "hosts": ["<host>"], "environment": "<env>" },
  "observations": ["target selected from metadata", "requested operation is read-only"],
  "hypothesis": "bounded observation is needed before diagnosis or change",
  "risk": "low",
  "action": { "primitive": "service.sh", "args": ["<host>", "status", "<service>"] },
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

---

## Setup

The public repository ships safe examples only. Real inventory, autonomy policy, and secrets are local-only.

```bash
cp skills/ssh/hosts.example.yaml skills/ssh/hosts.yaml
cp skills/ssh/autonomy.example.yaml skills/ssh/autonomy.yaml
mkdir -p skills/ssh/.secrets
cp skills/ssh/.secrets/host.env.example skills/ssh/.secrets/<host>.env
bash skills/ssh/scripts/validate_hosts.sh skills/ssh/hosts.yaml --allow-real-hosts
```

Never commit real `hosts.yaml`, `autonomy.yaml`, or `.secrets/` content.

---

## Preferred Agent Workflow

### 1. List or select hosts

```bash
bash skills/ssh/scripts/list_hosts.sh
bash skills/ssh/scripts/list_hosts.sh --check
bash skills/ssh/scripts/select_hosts.sh --target "tag=<tag>,role=<role>" --csv
bash skills/ssh/scripts/select_hosts.sh --env <env> --region <region> --role <role> --csv
```

### 2. Observe first

Single host:

```bash
bash skills/ssh/scripts/sys.sh <host> summary
bash skills/ssh/scripts/sys.sh <host> disk
bash skills/ssh/scripts/proc.sh <host> top 30
bash skills/ssh/scripts/net.sh <host> ports 100
bash skills/ssh/scripts/service.sh <host> status <service>
```

Fleet read-only observation:

```bash
bash skills/ssh/scripts/runner.sh \
  --target "tag=<tag>" \
  --cmd "uptime" \
  --parallel 20 \
  --timeout 30 \
  --fail-fast 20%
```

### 3. Gate autonomous actions

For Agent-driven execution, wrap actions in `agent_gate.sh` whenever a decision record is available:

```bash
bash skills/ssh/scripts/agent_gate.sh --decision <decision.json> --policy <autonomy.yaml> --dry-run
bash skills/ssh/scripts/agent_gate.sh --decision <decision.json> --policy <autonomy.yaml> --execute
```

### 4. Verify and stop or escalate

Every state-changing action must define verification. If verification fails, evidence conflicts, rollback is missing, or production risk appears, stop and escalate.

---

## Linux Primitives

### System observation

```bash
bash skills/ssh/scripts/sys.sh <host> summary
bash skills/ssh/scripts/sys.sh <host> disk
bash skills/ssh/scripts/sys.sh <host> memory
bash skills/ssh/scripts/sys.sh <host> load
bash skills/ssh/scripts/sys.sh <host> journal [unit] [lines]
bash skills/ssh/scripts/sys.sh <host> dmesg [lines]
bash skills/ssh/scripts/sys.sh <host> users
```

### File operations

```bash
bash skills/ssh/scripts/file.sh <host> exists <path>
bash skills/ssh/scripts/file.sh <host> stat <path>
bash skills/ssh/scripts/file.sh <host> list <path> [limit]
bash skills/ssh/scripts/file.sh <host> head <path> [lines]
bash skills/ssh/scripts/file.sh <host> tail <path> [lines]
bash skills/ssh/scripts/file.sh <host> grep <pattern> <path> [limit]
bash skills/ssh/scripts/file.sh <host> checksum <path>
bash skills/ssh/scripts/file.sh <host> backup <path>
bash skills/ssh/scripts/file.sh <host> mkdir <path>
bash skills/ssh/scripts/file.sh <host> remove <path> --confirm
```

### Process operations

```bash
bash skills/ssh/scripts/proc.sh <host> top [limit]
bash skills/ssh/scripts/proc.sh <host> mem [limit]
bash skills/ssh/scripts/proc.sh <host> find <pattern> [limit]
bash skills/ssh/scripts/proc.sh <host> tree [limit]
bash skills/ssh/scripts/proc.sh <host> kill <pid> --confirm
```

### Network operations

```bash
bash skills/ssh/scripts/net.sh <host> ports [limit]
bash skills/ssh/scripts/net.sh <host> listen <port>
bash skills/ssh/scripts/net.sh <host> curl <url> [limit]
bash skills/ssh/scripts/net.sh <host> dns <name>
bash skills/ssh/scripts/net.sh <host> route
bash skills/ssh/scripts/net.sh <host> addr
```

### Package operations

```bash
bash skills/ssh/scripts/pkg.sh <host> detect
bash skills/ssh/scripts/pkg.sh <host> search <name> [limit]
bash skills/ssh/scripts/pkg.sh <host> installed <name>
bash skills/ssh/scripts/pkg.sh <host> update-cache --confirm
bash skills/ssh/scripts/pkg.sh <host> install <name> --confirm
```

### Service operations

```bash
bash skills/ssh/scripts/service.sh <host> status <service>
bash skills/ssh/scripts/service.sh <host> logs <service>
bash skills/ssh/scripts/service.sh <host> restart <service> --confirm
bash skills/ssh/scripts/service.sh <host> stop <service> --confirm
bash skills/ssh/scripts/service.sh <host> disable <service> --confirm
```

### File transfer

```bash
bash skills/ssh/scripts/scp_transfer.sh <host> upload /local/path /remote/path
bash skills/ssh/scripts/scp_transfer.sh <host> download /remote/path /local/path
```

---

## Security Rules (MUST follow)

1. **Never output credentials or infrastructure identifiers**: IPs, usernames, passwords, key paths, `.secrets` paths, private hostnames, and key contents must not appear in conversation.
2. **Never read private key contents**: reference keys by path only. Never `cat` private keys.
3. **Never modify `.secrets/` from Agent commands** unless the user explicitly requests it.
4. **Observe before changing**: for unclear problems, use observation primitives before applying changes.
5. **Use primitives first**: prefer semantic primitives over raw `exec.sh` when available.
6. **Use `agent_gate.sh` for Agent-owned unattended actions** when a decision record is available.
7. **Use runner for fleets** with `--parallel`, `--timeout`, and preferably `--fail-fast`.
8. **Use locks for write operations** when doing multi-step writes on a host.
9. **Confirm destructive commands**: high-risk operations require `--confirm` or `SSH_SKILL_CONFIRMED=yes`.
10. **Confirm prod-impacting medium-risk commands**: if `env` is `prod/production` or tags contain `prod/production`, restarts and package changes require confirmation.
11. **No implicit sudo**: do not rely on automatic sudo retry. Use `--sudo` only when the user intent requires it.
12. **No sudo passwords**: do not embed sudo passwords in commands.
13. **Truncate large outputs**: use primitive limits or bounded shell commands.
14. **Do not auto-kill busy processes**: file upload busy-release requires `--force-release` or `SSH_SKILL_FORCE_RELEASE=yes`.
15. **Do not task-script the Agent**: avoid fixed app-specific repair scripts.
16. **Unattended changes need verification**: every state-changing unattended action must define verification and stop conditions.
17. **Escalate ambiguity**: conflicting evidence, missing rollback, production targets, or high risk must stop autonomous execution and ask for confirmation.

---

## Policy Guard

High-risk examples:

- Reading private keys, `/etc/shadow`, or `/etc/sudoers`
- broad destructive deletion of system paths
- disk formatting, partitioning, or raw device writes
- shutdown/reboot/poweroff/halt
- firewall flush or disable operations
- process mass-kill operations
- service stop/disable/mask
- destructive container or orchestrator operations
- shell execution patterns that combine downloaders or base64 decoding

Medium-risk examples:

- service restart/reload
- broad chmod/chown
- package install/remove/upgrade commands
- container restart/stop
- orchestrator apply/rollout/scale

Medium risk requires confirmation when it affects more than 20 hosts or any production-tagged target.

Confirm explicitly:

```bash
bash skills/ssh/scripts/exec.sh <host> "sudo systemctl restart <service>" --confirm
SSH_SKILL_CONFIRMED=yes bash skills/ssh/scripts/exec.sh <host> "sudo systemctl restart <service>"
```

---

## sudo Retry

`exec.sh` does not automatically retry with sudo after `Permission denied`.

Default JSON result includes:

```json
{
  "error": "permission_denied",
  "sudo_used": false
}
```

Explicit sudo retry:

```bash
bash skills/ssh/scripts/exec.sh <host> "tail -50 <log-path>" --sudo
bash skills/ssh/scripts/runner.sh --target "tag=<tag>" --cmd "tail -50 <log-path>" --sudo
```

Environment opt-in:

```bash
SSH_SKILL_ALLOW_SUDO_RETRY=yes bash skills/ssh/scripts/exec.sh <host> "tail -50 <log-path>"
```

The sudo retry path still runs `policy_check_command` before execution.

---

## Inventory Format

```yaml
hosts:
  demo-host-01:
    host: demo-host-01                  # Placeholder, real IP/domain in .secrets/demo-host-01.env
    port: 22
    user: ubuntu
    auth: key
    key_path: /keys/demo-host-01        # Placeholder, real path in .secrets/demo-host-01.env
    default_workdir: /opt/workdir
    provider: demo-provider
    region: demo-region
    env: prod
    role: generic-role
    tags: [production, generic]
```

Corresponding `.secrets/demo-host-01.env`:

```bash
HOST=203.0.113.10
KEY_PATH=/path/to/private/key
# SSH_PASSWORD=your_password_here
```

Validate inventory:

```bash
bash skills/ssh/scripts/validate_hosts.sh skills/ssh/hosts.example.yaml
bash skills/ssh/scripts/validate_hosts.sh skills/ssh/hosts.yaml --allow-real-hosts
```

---

## Output Redaction

All user-visible JSON and audit command fields should flow through `safe_json_string` or `redact_string`.

Redaction covers:

- password/passwd/secret/token/api_key/ssh_password/private_key assignments
- private key block headers/footers
- IPv4 and common IPv6 forms
- `user@host` SSH targets
- `.ssh` paths
- `.secrets` paths
- `/keys/...` placeholders
- concrete `SSH_HOST`, `SSH_USER`, `KEY_PATH`, and `SECRETS_ENV` loaded from the active host config

---

## Local Quality Checks

```bash
bash -n skills/ssh/scripts/*.sh
bash skills/ssh/scripts/validate_hosts.sh skills/ssh/hosts.example.yaml
bash skills/ssh/scripts/agent_gate.sh --decision skills/ssh/examples/decision-record.observe.json --policy skills/ssh/autonomy.example.yaml --dry-run
```

GitHub Actions runs syntax checks, example inventory validation, generic agent gate dry-run, and advisory ShellCheck.
