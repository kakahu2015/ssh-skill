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
  inventory validation, autonomy levels, and decision records for unattended operation.
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
    - sshpass       # optional, only for password auth
    - timeout       # optional, used by runner.sh per-host timeout when available
---

# Linux Ops Skill

This is an **Agent-native Linux operations primitive layer over SSH**.

It is not an Ansible clone, not a hidden playbook runner, and not a growing pile of one-off repair scripts. The Agent should use its Linux and operations knowledge to reason from live observations, then choose bounded primitives under policy guardrails.

Recommended loop:

```text
observe -> classify -> hypothesize -> choose primitive -> execute under guardrails -> verify -> continue, stop, or escalate
```

The skill provides safe, composable Linux operation primitives. The Agent remains responsible for diagnosis, sequencing, confidence assessment, verification, and deciding the next action.

---

## Core Model

- `exec.sh` is the low-level SSH syscall.
- `runner.sh` is the concurrent fleet executor.
- `select_hosts.sh` is the targeting layer.
- `sys.sh`, `file.sh`, `proc.sh`, `net.sh`, `pkg.sh`, `service.sh` are Linux operation primitives.
- `scp_transfer.sh` is the file transfer primitive.
- `lock.sh` is a coordination primitive for write operations.
- `validate_hosts.sh` validates local inventory shape and OPSEC hygiene.
- `common.sh` provides config loading, JSON output, redaction, policy checks, and audit logging.
- `autonomy.example.yaml` describes local autonomy boundaries.
- `schemas/decision-record.schema.json` defines concise auditable decision records.

Prefer primitives over free-form shell when a primitive exists, but do not force a fixed workflow. Let the Agent combine primitives based on observations.

---

## Agent Reasoning Model

The Agent may use general knowledge of Linux, networking, filesystems, systemd, package managers, common daemons, and failure modes. It must verify assumptions with live host observations before acting.

Examples:

- Know that Caddy/nginx/Apache are commonly systemd services, but verify with `service.sh status`, `sys.sh journal`, and `net.sh listen`.
- Know that Debian-like systems often use `apt`, RHEL-like systems use `yum` or `dnf`, and Alpine uses `apk`, but verify with `pkg.sh detect`.
- Know that disk pressure can break logs, package managers, and certificate renewal, but verify with `sys.sh disk` and bounded file/log primitives.
- Know that 80/443 are typical web ports, but verify listen state and service ownership before making changes.

The model should not treat prior knowledge as proof. Live observations win.

---

## Autonomy and Unattended Operation

Unattended operation must be optimized through **autonomy levels, decision records, verification, and escalation**, not through fixed repair scripts.

Reference docs:

```text
docs/agent-autonomy.md
docs/agent-autonomy.zh-CN.md
autonomy.example.yaml
schemas/decision-record.schema.json
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

Minimum decision record fields:

```json
{
  "intent": "restore web service availability",
  "autonomy_level": "L2",
  "observations": ["caddy service is inactive", "port 443 is not listening"],
  "hypothesis": "service stopped or failed during reload",
  "risk": "medium",
  "action": { "primitive": "service.sh", "command": "status caddy" },
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

### 1. List hosts

```bash
bash skills/ssh/scripts/list_hosts.sh
bash skills/ssh/scripts/list_hosts.sh --check
```

### 2. Select target hosts

```bash
bash skills/ssh/scripts/select_hosts.sh --target "tag=production,role=edge" --csv
bash skills/ssh/scripts/select_hosts.sh --env prod --region hk --role caddy --csv
```

### 3. Observe first

Single host:

```bash
bash skills/ssh/scripts/sys.sh <host> summary
bash skills/ssh/scripts/sys.sh <host> disk
bash skills/ssh/scripts/proc.sh <host> top 30
bash skills/ssh/scripts/net.sh <host> ports 100
bash skills/ssh/scripts/service.sh <host> status caddy
```

Fleet:

```bash
bash skills/ssh/scripts/runner.sh \
  --target "tag=production" \
  --cmd "uptime" \
  --parallel 20 \
  --timeout 30 \
  --fail-fast 20%
```

### 4. Reason from JSON results

Read the compact summary first. For fleet runs, inspect failed hosts from:

```text
.runs/<run_id>/results/<host>.json
```

Audit logs are written to:

```text
.audit/<YYYY-MM-DD>/<run_id>.jsonl
```

### 5. Use write locks for coordinated changes

For write operations that may overlap with other tasks:

```bash
bash skills/ssh/scripts/lock.sh <host> acquire --timeout 60 --run-id <run_id>
# perform operation
bash skills/ssh/scripts/lock.sh <host> release --run-id <run_id>
```

Do not make lock usage a rigid workflow for read-only operations.

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

If a target file is busy, default behavior is to return `target_busy`. Only release busy processes with explicit authorization:

```bash
bash skills/ssh/scripts/scp_transfer.sh <host> upload /local/file /remote/file --force-release
```

---

## Security Rules (MUST follow)

1. **Never output credentials or infrastructure identifiers**: IPs, usernames, passwords, key paths, `.secrets` paths, private hostnames, and key contents must not appear in conversation.
2. **Never read private key contents**: reference keys by path only. Never `cat` private keys.
3. **Never modify `.secrets/` from Agent commands** unless the user explicitly requests it.
4. **Observe before changing**: for unclear problems, use `sys.sh`, `file.sh`, `proc.sh`, `net.sh`, and `service.sh status/logs` before applying changes.
5. **Use primitives first**: prefer `file.sh`, `proc.sh`, `net.sh`, `pkg.sh`, `service.sh` over raw `exec.sh` when available.
6. **Use runner for fleets**: for more than a few hosts, use `runner.sh` with `--parallel`, `--timeout`, and preferably `--fail-fast`.
7. **Use locks for write operations**: when doing multi-step writes on a host, use `lock.sh acquire/release`.
8. **Confirm destructive commands**: high-risk operations require `--confirm` or `SSH_SKILL_CONFIRMED=yes`.
9. **Confirm prod-impacting medium-risk commands**: if `env` is `prod/production` or tags contain `prod/production`, restarts and package changes require confirmation.
10. **No implicit sudo**: do not rely on automatic sudo retry. Use `--sudo` only when the user intent requires it.
11. **No sudo passwords**: do not embed sudo passwords in commands. Suggest NOPASSWD sudoers or manual operation.
12. **Truncate large outputs**: use limits in primitives or add `head`/`tail` to raw commands.
13. **Do not auto-kill busy processes**: file upload busy-release requires `--force-release` or `SSH_SKILL_FORCE_RELEASE=yes`.
14. **Review summaries before follow-up actions**: for batch runs, inspect failed hosts before remediation.
15. **Do not task-script the Agent**: avoid fixed app-specific repair scripts. Capture reusable behavior as primitives, autonomy policy, or Agent reasoning patterns.
16. **Unattended changes need verification**: every state-changing unattended action must define verification and stop conditions.
17. **Escalate ambiguity**: conflicting evidence, missing rollback, production targets, or high risk must stop autonomous execution and ask for confirmation.

---

## Policy Guard

High-risk examples:

- Reading private keys, `/etc/shadow`, or `/etc/sudoers`
- `rm -rf /`, `rm -rf /etc`, `rm -rf /usr`, `rm -rf /home`, `rm -rf /root`
- `mkfs`, `wipefs`, `fdisk`, `parted`, `sgdisk`
- `dd ... of=/dev/...`
- `shutdown`, `reboot`, `poweroff`, `halt`
- `iptables -F`, `ip6tables -F`, `nft flush`, `ufw disable`
- `killall`, `fuser -k`
- `systemctl stop`, `systemctl disable`, `systemctl mask`
- `docker rm -f`, `docker system prune`
- `kubectl delete`
- `bash -c` / `sh -c` mixed with `base64 -d`, `curl`, or `wget`

Medium-risk examples:

- `systemctl restart/reload`
- `service <name> restart/reload`
- `chmod 777`, `chown -R`
- package install/remove/upgrade commands
- `docker restart/stop`
- `kubectl apply/rollout/scale`

Medium risk requires confirmation when it affects more than 20 hosts or any production-tagged target.

Confirm explicitly:

```bash
bash skills/ssh/scripts/exec.sh <host> "sudo systemctl restart caddy" --confirm
SSH_SKILL_CONFIRMED=yes bash skills/ssh/scripts/exec.sh <host> "sudo systemctl restart caddy"
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
bash skills/ssh/scripts/exec.sh <host> "cat /var/log/app.log | tail -50" --sudo
bash skills/ssh/scripts/runner.sh --target "tag=dev" --cmd "cat /var/log/app.log | tail -50" --sudo
```

Environment opt-in:

```bash
SSH_SKILL_ALLOW_SUDO_RETRY=yes bash skills/ssh/scripts/exec.sh <host> "cat /var/log/app.log | tail -50"
```

The sudo retry path still runs `policy_check_command` before execution.

---

## Inventory Format

```yaml
hosts:
  prod-edge-01:
    host: prod-edge-01                  # Placeholder, real IP/domain in .secrets/prod-edge-01.env
    port: 22
    user: ubuntu
    auth: key
    key_path: /keys/prod-edge-01        # Placeholder, real path in .secrets/prod-edge-01.env
    default_workdir: /opt/myapp
    provider: oci
    region: us-west
    env: prod
    role: edge
    tags: [production, us-west, caddy, edge]
```

Corresponding `.secrets/prod-edge-01.env`:

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

## Output Truncation

Commands that may output a lot of text must be truncated by the caller:

```bash
dmesg | tail -50
journalctl --since today | head -100
cat /var/log/syslog | tail -200
find / -name "*.log" | head -30
ps aux | head -50
```

Use primitive limits where possible.

---

## Error Handling

| Error | Action |
|-------|--------|
| `hosts.yaml` not found | Copy `hosts.example.yaml` to `hosts.yaml`, then add real values under `.secrets/` |
| Host not in yaml | List existing hosts and ask user to add the host |
| `sshpass` not installed | Suggest installing `sshpass` or switching to key auth |
| Connection timeout | Check host/port/firewall and retry later |
| Auth failed | Check `.secrets/` config; do not output credentials |
| ControlMaster socket expired | Auto re-run `connect.sh`, then retry |
| `policy_blocked` | Ask for explicit confirmation before continuing |
| `permission_denied` | Ask whether to retry with `--sudo`; do not auto-sudo |
| `target_busy` | Ask whether to retry with `--force-release` |
| `lock_owned_by_other` | Wait, inspect lock status, or ask before force unlock |
| Command `exit_code != 0` | Return JSON result and summarize failed hosts |

---

## Local Quality Checks

```bash
bash -n skills/ssh/scripts/*.sh
bash skills/ssh/scripts/validate_hosts.sh skills/ssh/hosts.example.yaml
```

GitHub Actions runs syntax checks, example inventory validation, and advisory ShellCheck.
