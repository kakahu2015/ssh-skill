---
name: linux-ops
version: 1.5.0
description: >
  Agent-native Linux operations skill over SSH. Use when an AI Agent needs to observe,
  reason about, and operate remote Linux servers using composable primitives. This is an
  AI-native operations substrate, not a task-script collection: the skill owns safe
  execution primitives, guardrails, runtime gate validation, redaction, and audit; the
  model owns observation, reasoning, diagnosis, decision-making, verification, and
  escalation. Supports ControlMaster reuse, target selection, batch execution, policy
  guardrails, explicit sudo retry, inventory validation, autonomy levels, decision
  records, strict decision validation, and generic gate tests for bounded unattended
  operation.
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
    - python3       # required by agent_gate.sh and validate_decision.py
    - sshpass       # optional, only for password auth
    - timeout       # optional, used by runner.sh per-host timeout when available
---

# Linux Ops Skill

This is an **Agent-native Linux operations primitive layer over SSH**.

It is not an Ansible clone, not a hidden playbook runner, and not a growing pile of app-specific repair scripts. The Agent should use Linux and operations knowledge to reason from live observations, then choose bounded primitives under policy guardrails.

Recommended loop:

```text
observe -> classify -> hypothesize -> choose primitive -> validate decision -> gate -> execute -> verify -> continue, stop, or escalate
```

The skill provides safe, composable Linux operation primitives. The Agent remains responsible for diagnosis, sequencing, confidence assessment, verification, and deciding the next action.

---

## Core Model

- `exec.sh` is the low-level SSH syscall.
- `agent_gate.sh` is the generic runtime gate for AI Agent decision records.
- `validate_decision.py` is the strict, dependency-free decision record validator.
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
- `tests/agent_gate_tests.sh` verifies generic gate allow/block behavior without SSH.

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

If behavior is reusable, express it as one of these instead:

- a generic primitive,
- an autonomy policy rule,
- a decision-record contract,
- a verification/rollback contract,
- a runtime gate check,
- or an Agent reasoning pattern in docs.

The runtime code must remain business-agnostic.

---

## Agent Reasoning Model

The Agent may use general knowledge of Linux, networking, filesystems, service managers, package managers, daemons, and failure modes. It must verify assumptions with live host observations before acting.

Generic examples:

- Know that many services are managed by a service manager, but verify with `service.sh status <service>`, bounded logs, process checks, and network checks.
- Know that distributions use different package managers, but verify with `pkg.sh detect` before package operations.
- Know that disk pressure can affect many subsystems, but verify with `sys.sh disk` and bounded file/log primitives.
- Know that a listening port may indicate service availability, but verify listen state and ownership before changing services.

The model should not treat prior knowledge as proof. Live observations win.

---

## Autonomy and Unattended Operation

Unattended operation must be optimized through **autonomy levels, decision records, runtime validation, runtime gating, verification, and escalation**, not through fixed repair scripts.

Reference files:

```text
docs/agent-autonomy.md
docs/agent-autonomy.zh-CN.md
autonomy.example.yaml
schemas/decision-record.schema.json
examples/decision-record.observe.json
scripts/validate_decision.py
scripts/agent_gate.sh
tests/agent_gate_tests.sh
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

Validate a decision record:

```bash
python3 skills/ssh/scripts/validate_decision.py skills/ssh/examples/decision-record.observe.json --quiet
```

Dry-run the runtime gate:

```bash
bash skills/ssh/scripts/agent_gate.sh \
  --decision skills/ssh/examples/decision-record.observe.json \
  --policy skills/ssh/autonomy.example.yaml \
  --dry-run
```

Execute only after the gate allows the action:

```bash
bash skills/ssh/scripts/agent_gate.sh --decision <decision.json> --policy <autonomy.yaml> --execute
```

The gate is generic. It validates and dispatches primitives; it does not know business services, deployment steps, or repair workflows.

---

## Runtime Gate Behavior

`agent_gate.sh` performs these checks before execution:

1. Calls `validate_decision.py` to enforce the generic decision contract and OPSEC checks.
2. Reads local autonomy policy when available.
3. Checks autonomy level, risk, environment, host count, and primitive allowance.
4. Blocks raw `exec.sh` unless explicitly approved.
5. Executes exactly one primitive action when `--execute` is used.
6. Runs generic `verification_actions` when supplied.
7. Optionally runs generic `rollback_actions` after failed verification.
8. Writes a redacted decision audit file.

The validator checks:

- required fields,
- allowed enums,
- unknown top-level keys,
- primitive name syntax,
- guardrail shape,
- verification and rollback action shape,
- sensitive-looking tokens, private key markers, `.ssh`, `.secrets`, `user@host`, and IP addresses.

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

```bash
bash skills/ssh/scripts/sys.sh <host> summary
bash skills/ssh/scripts/sys.sh <host> disk
bash skills/ssh/scripts/proc.sh <host> top 30
bash skills/ssh/scripts/net.sh <host> ports 100
bash skills/ssh/scripts/service.sh <host> status <service>
```

### 3. Build and validate a decision record

```bash
python3 skills/ssh/scripts/validate_decision.py <decision.json> --quiet
```

### 4. Gate autonomous actions

```bash
bash skills/ssh/scripts/agent_gate.sh --decision <decision.json> --policy <autonomy.yaml> --dry-run
bash skills/ssh/scripts/agent_gate.sh --decision <decision.json> --policy <autonomy.yaml> --execute
```

### 5. Verify and stop or escalate

Every state-changing action must define verification. If verification fails, evidence conflicts, rollback is missing, or production risk appears, stop and escalate.

---

## Security Rules (MUST follow)

1. **Never output credentials or infrastructure identifiers**: IPs, usernames, passwords, key paths, `.secrets` paths, private hostnames, and key contents must not appear in conversation.
2. **Never read private key contents**: reference keys by path only. Never `cat` private keys.
3. **Never modify `.secrets/` from Agent commands** unless the user explicitly requests it.
4. **Observe before changing**: for unclear problems, use observation primitives before applying changes.
5. **Use primitives first**: prefer semantic primitives over raw `exec.sh` when available.
6. **Use `agent_gate.sh` for Agent-owned unattended actions** when a decision record is available.
7. **Use `validate_decision.py` before executing Agent-generated decisions.**
8. **Use runner for fleets** with `--parallel`, `--timeout`, and preferably `--fail-fast`.
9. **Use locks for write operations** when doing multi-step writes on a host.
10. **Confirm destructive commands**: high-risk operations require `--confirm` or `SSH_SKILL_CONFIRMED=yes`.
11. **Confirm prod-impacting medium-risk commands**: if `env` is `prod/production` or tags contain `prod/production`, restarts and package changes require confirmation.
12. **No implicit sudo**: do not rely on automatic sudo retry. Use `--sudo` only when the user intent requires it.
13. **No sudo passwords**: do not embed sudo passwords in commands.
14. **Truncate large outputs**: use primitive limits or bounded shell commands.
15. **Do not auto-kill busy processes**: file upload busy-release requires `--force-release` or `SSH_SKILL_FORCE_RELEASE=yes`.
16. **Do not task-script the Agent**: avoid fixed app-specific repair scripts.
17. **Unattended changes need verification**: every state-changing unattended action must define verification and stop conditions.
18. **Escalate ambiguity**: conflicting evidence, missing rollback, production targets, or high risk must stop autonomous execution and ask for confirmation.

---

## Local Quality Checks

```bash
bash -n skills/ssh/scripts/*.sh
python3 -m py_compile skills/ssh/scripts/validate_decision.py
bash skills/ssh/scripts/validate_hosts.sh skills/ssh/hosts.example.yaml
python3 skills/ssh/scripts/validate_decision.py skills/ssh/examples/decision-record.observe.json --quiet
bash skills/ssh/scripts/agent_gate.sh --decision skills/ssh/examples/decision-record.observe.json --policy skills/ssh/autonomy.example.yaml --dry-run
bash skills/ssh/tests/agent_gate_tests.sh
```

GitHub Actions runs syntax checks, example inventory validation, decision validation, generic agent gate dry-run, the generic gate test matrix, and advisory ShellCheck.
