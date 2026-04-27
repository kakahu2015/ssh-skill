# Agent Autonomy Model

[中文](agent-autonomy.zh-CN.md) | [English](agent-autonomy.md)

This skill should not grow into a pile of fixed task scripts. Its purpose is to expose Linux operation primitives that an AI Agent can combine with its reasoning, system knowledge, and live observations.

The right abstraction is not:

```text
run this predefined repair script
```

It is:

```text
observe -> classify -> hypothesize -> choose primitive -> execute under guardrails -> verify -> continue, stop, or escalate
```

## Design Goal

The skill provides the operating surface. The Agent provides the reasoning.

The Agent should use its knowledge of Linux, networking, filesystems, systemd, package managers, common daemons, and failure patterns, but it must verify assumptions against live host observations before taking action.

Examples:

- Use knowledge that Caddy, nginx, and Apache are commonly managed by systemd, but verify with `service.sh status`, `sys.sh journal`, and `net.sh listen`.
- Use knowledge that Debian-like systems usually use `apt`, RHEL-like systems use `yum` or `dnf`, and Alpine uses `apk`, but verify with `pkg.sh detect`.
- Use knowledge that high disk usage can break logs, package managers, and TLS renewals, but verify with `sys.sh disk`, `file.sh list`, and bounded log inspection.
- Use knowledge that ports 80 and 443 are web entry points, but verify process ownership and listen state before changing services.

## What Belongs in the Skill

The skill should contain:

- Small, composable primitives
- Structured JSON outputs
- Guardrails and policy checks
- Redaction and audit logging
- Target selection and bounded batch execution
- Inventory validation
- Decision and action schemas that help the Agent reason consistently

The skill should avoid:

- Hard-coded business workflows
- Hidden deployment playbooks
- App-specific remediation scripts
- Large one-shot fix scripts
- Silent destructive actions
- Unbounded scanning or log dumping

## Autonomy Levels

Use autonomy levels to decide what an unattended Agent may do.

| Level | Name | Meaning | Typical allowance |
|---|---|---|---|
| L0 | Advisory | No remote execution | Explain, plan, ask for permission |
| L1 | Observe | Read-only execution | Facts, status, logs with limits, ports, disk, process list |
| L2 | Safe self-heal | Low-risk reversible actions | Reconnect ControlMaster, refresh facts, create backups, retry idempotent reads |
| L3 | Bounded change | Medium-risk changes with verification and rollback | Non-prod service restart, bounded config backup, package cache update |
| L4 | Privileged/destructive | High-risk or prod-impacting changes | Requires explicit confirmation or human approval |
| L5 | Forbidden | Actions the Agent must not perform unattended | Private key reads, destructive disk ops, broad deletes, firewall flush, credential exfiltration |

Default unattended mode should be **L1**. Raise to L2 or L3 only with explicit user configuration and strict guardrails.

## Unattended Decision Contract

Before any unattended action beyond read-only observation, the Agent should produce a structured decision record. This is not a chain-of-thought dump. It is a concise operational summary that can be audited.

Minimum fields:

```json
{
  "intent": "restore web service availability",
  "autonomy_level": "L2",
  "observations": ["caddy service is inactive", "port 443 is not listening"],
  "hypothesis": "service stopped or failed during reload",
  "risk": "medium",
  "action": {
    "primitive": "service.sh",
    "command": "status caddy"
  },
  "guardrails": {
    "requires_confirmation": false,
    "requires_lock": false,
    "rollback_available": false
  },
  "verification": ["check service status", "check port 443 listen state"],
  "stop_condition": "service active and port 443 listening, or policy blocks change",
  "confidence": "medium"
}
```

A JSON Schema is provided at:

```text
schemas/decision-record.schema.json
```

## Reasoning Rules for the Agent

### 1. Use knowledge, but verify it

The model may use Linux and ops knowledge to choose likely next observations. It must not treat prior knowledge as proof. Live evidence wins.

### 2. Prefer semantic primitives over raw shell

Use `sys.sh`, `file.sh`, `proc.sh`, `net.sh`, `pkg.sh`, and `service.sh` first. Use `exec.sh` only when no primitive fits.

### 3. Keep observations bounded

Unattended mode must avoid unbounded output. Prefer limits such as `tail -50`, `head -100`, or primitive limit arguments.

### 4. Separate diagnosis from mutation

Observation and diagnosis can be autonomous. Mutation requires autonomy-level checks, policy checks, and often explicit confirmation.

### 5. Verify every action

Every action that changes state must have a verification step. If verification fails, stop or escalate instead of trying random fixes.

### 6. Prefer reversible operations

Back up before changing files. Prefer reload before restart when appropriate. Prefer single-host canary before fleet action.

### 7. Escalate ambiguity

If evidence conflicts, risk is high, rollback is missing, or the target is production, the Agent should stop and ask for confirmation.

## Unattended Loop

A safe unattended Agent loop should look like this:

```text
1. Load inventory and target metadata
2. Observe facts and current state
3. Classify host, environment, service, and risk
4. Build a decision record
5. Check autonomy level and policy guard
6. Execute one primitive
7. Verify result
8. Update audit trail
9. Continue, stop, or escalate
```

The loop is controlled by the Agent. The skill only provides reliable tools and guardrails.

## Examples

### Example: read-only incident triage

Allowed at L1:

```bash
bash scripts/sys.sh edge-01 summary
bash scripts/service.sh edge-01 status caddy
bash scripts/sys.sh edge-01 journal caddy 100
bash scripts/net.sh edge-01 listen 443
```

The Agent can then summarize likely causes and propose next steps.

### Example: non-prod service restart

Potentially allowed at L3 if configured:

```text
preconditions:
  env != prod
  service is known
  recent logs indicate failed transient state
  restart policy allows this service
  verification is defined
```

Action:

```bash
bash scripts/service.sh dev-edge-01 restart caddy --confirm
```

Verification:

```bash
bash scripts/service.sh dev-edge-01 status caddy
bash scripts/net.sh dev-edge-01 listen 443
```

### Example: production service restart

Must escalate by default:

```text
env == prod
risk == medium
requires_confirmation == true
```

The Agent should produce a decision record and ask for approval instead of restarting unattended.

## Anti-Patterns

Do not turn this skill into:

- `fix_caddy.sh`
- `deploy_my_app.sh`
- `cleanup_all_servers.sh`
- `repair_everything.sh`
- a hidden playbook runner

If a workflow is useful, document it as an Agent reasoning pattern, not as a rigid script, unless it is a generic primitive.

## North Star

This project should become an **AI-native remote operations substrate**:

- The skill owns safe execution.
- The model owns reasoning and adaptation.
- Policy owns boundaries.
- Audit owns accountability.

That combination is what makes unattended operation possible without turning the project into brittle task automation.
