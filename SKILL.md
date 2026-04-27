---
name: linux-ops
version: 2.0.0
description: >
  Agent-native Linux operations skill over SSH. Use when an AI Agent needs to observe,
  reason about, and operate remote Linux servers using composable primitives. This is an
  AI-native operations substrate, not a task-script collection: the skill owns safe
  execution primitives, Python runtime gate enforcement, fail-closed semantic guard,
  JSON primitive rules, autonomy policy validation, path/risk guardrails, redaction,
  audit hashes, escalation events, and bounded testable execution; the model owns
  observation, reasoning, diagnosis, decision-making, verification, and escalation.
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
    - python3
    - sshpass       # optional, only for password auth
    - timeout       # optional, used by runner.sh per-host timeout when available
    - curl          # optional, only for webhook escalation integrations
---

# Linux Ops Skill v2.0

This is an **Agent-native Linux operations runtime over SSH**.

It is not an Ansible clone, not a hidden playbook runner, and not a pile of app-specific repair scripts. The Agent uses Linux and operations knowledge to reason from live observations; the skill provides bounded primitives, strict contracts, fail-closed runtime gates, policy validation, redaction, audit, and escalation.

Recommended loop:

```text
observe -> classify -> hypothesize -> write decision record -> validate decision/policy -> semantic gate -> execute one primitive -> verify -> rollback/escalate/stop
```

The model is responsible for diagnosis, sequencing, confidence assessment, and deciding the next action. The runtime is responsible for refusing unsafe or malformed action requests.

---

## v2.0 Runtime Model

Agent-owned unattended actions should flow through this chain:

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

`agent_gate.sh` is a thin compatibility wrapper. The runtime security boundary is `agent_gate.py`, which executes primitives with argv-style subprocess calls, not shell string evaluation.

---

## Core Files

- `scripts/agent_gate.py` — Python runtime gate and execution boundary.
- `scripts/agent_gate.sh` — thin wrapper around `agent_gate.py`.
- `scripts/primitive_rules.json` — fail-closed semantic rules for primitives, commands, risk, and unattended levels.
- `scripts/validate_decision.py` — strict dependency-free decision record validator.
- `scripts/validate_autonomy.py` — dependency-free autonomy policy validator.
- `scripts/composite.sh` — read-only composite observation primitive; Agent use should route through the gate.
- `scripts/sys.sh`, `file.sh`, `proc.sh`, `net.sh`, `pkg.sh`, `service.sh`, `lock.sh`, `scp_transfer.sh` — generic Linux primitives.
- `schemas/decision-record.schema.json` — decision contract.
- `schemas/audit-event.schema.json` — audit event contract.
- `schemas/gate-result.schema.json` — gate output contract.
- `schemas/run-summary.schema.json` — run summary contract.
- `schemas/escalation-event.schema.json` — escalation event contract.
- `tests/agent_gate_tests.sh` — no-SSH runtime gate regression matrix.

Prefer semantic primitives over raw shell. Do not add business-specific repair scripts.

---

## Non-Task-Script Rule

Do **not** add app-specific repair or deployment scripts such as:

```text
fix_<service>.sh
deploy_<app>.sh
repair_everything.sh
cleanup_all_servers.sh
```

Reusable behavior should be expressed as one of these:

- a generic primitive,
- a JSON primitive rule,
- an autonomy policy rule,
- a decision-record contract,
- a verification/rollback contract,
- a runtime gate check,
- a validator,
- a schema,
- or an Agent reasoning pattern in docs.

The runtime must stay business-agnostic.

---

## Autonomy Levels

Default unattended mode should be **L1 observe-only**.

| Level | Meaning | Default stance |
|---|---|---|
| L0 | Advisory only; no remote execution | Always safe |
| L1 | Bounded read-only observation | Default unattended mode |
| L2 | Low-risk reversible self-heal | Requires explicit local policy |
| L3 | Bounded non-prod change with verification | Requires policy and strict stop conditions |
| L4 | Privileged or production-impacting action | Requires explicit approval |
| L5 | Forbidden | Never execute unattended |

The Agent may propose an autonomy level in a decision record, but `agent_gate.py` enforces local policy, environment limits, primitive rules, risk rules, and guardrails. A model cannot grant itself extra authority by writing a higher level into JSON.

---

## Runtime Gate Behavior

`agent_gate.py` enforces:

1. valid decision record shape and OPSEC constraints,
2. valid autonomy policy shape,
3. fail-closed JSON primitive rules,
4. unknown primitive block unless `--test-mode` is used,
5. unknown primitive command block,
6. declared risk not lower than computed primitive/action risk,
7. autonomy level and environment max-level checks,
8. production L1 default unless explicitly confirmed,
9. host-count limit checks,
10. raw `exec.sh` block unless explicitly approved,
11. sensitive path block,
12. verification requirements for L2+ or non-low-risk execution,
13. single primitive execution per decision,
14. optional rollback after failed verification,
15. escalation event generation on gate blocks,
16. redacted audit containing decision, policy, and rules hashes.

`--test-mode` is for local mock primitive tests only. It must not be used for production operation.

---

## Composite Observations

`composite.sh` is a read-only primitive for common observation bundles. It does not mutate remote state and does not embed business workflows.

Supported actions:

```text
healthcheck, disk, memory, services, network, quick, journal, all
```

`services` requires explicit service names. No default business or platform service names are embedded.

`primitive_rules.json` allows lightweight composite observations at L1 and moves the larger `all` action to L2 because it may produce more output.

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

## Agent Workflow

Validate inputs:

```bash
python3 skills/ssh/scripts/validate_decision.py skills/ssh/examples/decision-record.observe.json --quiet
python3 skills/ssh/scripts/validate_autonomy.py skills/ssh/autonomy.example.yaml --quiet
python3 -m py_compile skills/ssh/scripts/agent_gate.py
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

Use `--allow-raw-exec` only when a semantic primitive cannot express the requested operation and the user explicitly approves raw shell execution.

---

## Security Rules

1. Never output credentials or infrastructure identifiers: IPs, usernames, passwords, key paths, `.secrets` paths, private hostnames, or key contents.
2. Never read private key contents.
3. Never modify `.secrets/` from Agent commands unless explicitly requested.
4. Observe before changing.
5. Use primitives first; raw `exec.sh` is not an unattended default.
6. Route Agent-owned unattended actions through `agent_gate.sh` / `agent_gate.py`.
7. Treat missing, corrupt, or incomplete runtime rules as a block condition.
8. Do not task-script the Agent with app-specific repair flows.
9. Every state-changing unattended action needs verification and stop conditions.
10. Escalate ambiguity, conflicting evidence, missing rollback, production targets, or high risk.

---

## Local Quality Checks

```bash
bash -n skills/ssh/scripts/*.sh skills/ssh/tests/*.sh
python3 -m py_compile skills/ssh/scripts/validate_decision.py skills/ssh/scripts/validate_autonomy.py skills/ssh/scripts/agent_gate.py skills/ssh/scripts/redact.py
bash skills/ssh/scripts/validate_hosts.sh skills/ssh/hosts.example.yaml
python3 skills/ssh/scripts/validate_autonomy.py skills/ssh/autonomy.example.yaml --quiet
python3 skills/ssh/scripts/validate_decision.py skills/ssh/examples/decision-record.observe.json --quiet
bash skills/ssh/scripts/agent_gate.sh --decision skills/ssh/examples/decision-record.observe.json --policy skills/ssh/autonomy.example.yaml --dry-run
bash skills/ssh/tests/agent_gate_tests.sh
```

The gate test matrix covers allow/block paths, raw exec block, production guard, host-count guard, OPSEC validation, unknown field block, invalid policy block, mock execute/verify/rollback, unknown primitive block, unknown command block, risk mismatch, path block, corrupt rules fail-closed behavior, composite L1 restriction, escalation file generation, and audit hash metadata.
