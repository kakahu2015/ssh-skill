# Agent Autonomy Model

[中文](agent-autonomy.zh-CN.md) | [English](agent-autonomy.md)

This skill should not grow into a pile of fixed task scripts. Its purpose is to expose Linux operation primitives that an AI Agent can combine with its reasoning, system knowledge, and live observations.

The right abstraction is not:

```text
run this predefined repair script
```

It is:

```text
observe -> classify -> hypothesize -> choose primitive -> gate -> execute -> verify -> continue, stop, or escalate
```

## Design Goal

The skill provides the operating surface. The Agent provides the reasoning.

The Agent should use its knowledge of Linux, networking, filesystems, service managers, package managers, daemons, and failure patterns, but it must verify assumptions against live host observations before taking action.

Generic examples:

- Use knowledge that many services are managed by a service manager, but verify with `service.sh status <service>`, bounded logs, process checks, and network checks.
- Use knowledge that different distributions use different package managers, but verify with `pkg.sh detect` before package operations.
- Use knowledge that high disk usage can affect many subsystems, but verify with `sys.sh disk`, `file.sh list`, and bounded log inspection.
- Use knowledge that a listening port may indicate service availability, but verify listen state and ownership before changing services.

## What Belongs in the Skill

The skill should contain:

- Small, composable primitives
- Structured JSON outputs
- Runtime autonomy gates
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

## Runtime Gate

`agent_gate.sh` turns the autonomy model into runtime enforcement. It is still generic: it does not know business services, deployment steps, or repair flows.

```bash
bash scripts/agent_gate.sh --decision examples/decision-record.observe.json --policy autonomy.example.yaml --dry-run
```

It performs these checks:

1. Parse and validate the decision record.
2. Read local autonomy policy if present.
3. Check autonomy level, risk, environment, host count, and primitive allowance.
4. Block raw `exec.sh` unless explicitly approved.
5. Execute one primitive action only when `--execute` is used.
6. Run executable verification actions when supplied.
7. Optionally run rollback actions after failed verification.
8. Write a redacted decision audit file.

## Unattended Decision Contract

Before any unattended action beyond read-only observation, the Agent should produce a structured decision record. This is not a chain-of-thought dump. It is a concise operational summary that can be audited.

Generic shape:

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

A JSON Schema is provided at:

```text
schemas/decision-record.schema.json
```

## Reasoning Rules for the Agent

### 1. Use knowledge, but verify it

The model may use Linux and ops knowledge to choose likely next observations. It must not treat prior knowledge as proof. Live evidence wins.

### 2. Prefer semantic primitives over raw shell

Use `sys.sh`, `file.sh`, `proc.sh`, `net.sh`, `pkg.sh`, and `service.sh` first. Use `exec.sh` only when no primitive fits, and prefer going through `agent_gate.sh` when a decision record exists.

### 3. Keep observations bounded

Unattended mode must avoid unbounded output. Prefer limits such as `tail -50`, `head -100`, or primitive limit arguments.

### 4. Separate diagnosis from mutation

Observation and diagnosis can be autonomous. Mutation requires autonomy-level checks, policy checks, and often explicit confirmation.

### 5. Verify every action

Every action that changes state must have a verification step. If verification fails, stop or escalate instead of trying random fixes.

### 6. Prefer reversible operations

Back up before changing files. Prefer the least disruptive operation that can satisfy the goal. Prefer single-host canary before fleet action.

### 7. Escalate ambiguity

If evidence conflicts, risk is high, rollback is missing, or the target is production, the Agent should stop and ask for confirmation.

## Unattended Loop

A safe unattended Agent loop should look like this:

```text
1. Load inventory and target metadata
2. Observe facts and current state
3. Classify host, environment, service, and risk
4. Build a decision record
5. Pass the decision through agent_gate.sh
6. Execute one primitive if allowed
7. Verify result
8. Update audit trail
9. Continue, stop, or escalate
```

The loop is controlled by the Agent. The skill only provides reliable tools and guardrails.

## Generic Examples

### Read-only incident triage

Allowed at L1:

```bash
bash scripts/sys.sh <host> summary
bash scripts/service.sh <host> status <service>
bash scripts/sys.sh <host> journal <service> 100
bash scripts/net.sh <host> listen <port>
```

The Agent can then summarize likely causes and propose next steps.

### Non-production bounded service restart

Potentially allowed at L3 if configured:

```text
preconditions:
  env != prod
  service is known
  recent bounded observations indicate a transient failed state
  restart policy allows this primitive
  verification is defined
```

Action through the gate:

```bash
bash scripts/agent_gate.sh --decision <decision.json> --policy <autonomy.yaml> --execute
```

The decision record, not a hard-coded script, names the primitive and its args.

### Production-impacting change

Must escalate by default:

```text
env == prod
risk >= medium
requires_confirmation == true
```

The Agent should produce a decision record and ask for approval instead of changing production unattended.

## Anti-Patterns

Do not turn this skill into:

- app-specific fix scripts
- app-specific deploy scripts
- one-shot cleanup scripts
- broad repair-all scripts
- a hidden playbook runner

If a workflow is useful, document it as an Agent reasoning pattern, not as a rigid script, unless it is a generic primitive.

## North Star

This project should become an **AI-native remote operations substrate**:

- The skill owns safe execution.
- The model owns reasoning and adaptation.
- Policy owns boundaries.
- Audit owns accountability.

That combination is what makes unattended operation possible without turning the project into brittle task automation.
