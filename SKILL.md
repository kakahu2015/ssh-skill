---
name: linux-ops
version: 1.2.0
description: >
  Agent-native Linux operations skill over SSH. Use when an AI Agent needs to observe,
  reason about, and operate remote Linux servers using composable primitives: system,
  file, process, network, package, service, transfer, locks, and free-form commands.
  Supports ControlMaster connection reuse, target selection, concurrent batch execution,
  policy guardrails, output redaction, audit logs, and per-run result storage.
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

It is not an Ansible clone and should not be used like a rigid playbook runner. The Agent should:

```text
observe -> reason -> choose primitive -> execute -> inspect result -> continue or stop
```

The skill provides safe, composable Linux operation primitives. The Agent remains responsible for diagnosis, sequencing, and deciding the next action.

---

## Core Model

- `exec.sh` is the low-level SSH syscall.
- `runner.sh` is the concurrent fleet executor.
- `select_hosts.sh` is the targeting layer.
- `sys.sh`, `file.sh`, `proc.sh`, `net.sh`, `pkg.sh`, `service.sh` are Linux operation primitives.
- `lock.sh` is a coordination primitive for write operations.
- `common.sh` provides config loading, JSON output, redaction, policy checks, and audit logging.

Prefer primitives over free-form shell when a primitive exists, but do not force a fixed workflow. Let the Agent combine primitives based on observations.

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
bash skills/ssh/scripts/sys.sh hk summary
bash skills/ssh/scripts/sys.sh hk disk
bash skills/ssh/scripts/proc.sh hk top 30
bash skills/ssh/scripts/net.sh hk ports 100
bash skills/ssh/scripts/service.sh hk status caddy
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
bash skills/ssh/scripts/lock.sh hk acquire --timeout 60 --run-id <run_id>
# perform operation
bash skills/ssh/scripts/lock.sh hk release --run-id <run_id>
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
bash skills/ssh/scripts/service.sh <host> restart <service>
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

1. **Never output credentials**: IPs, usernames, passwords, key paths, and key contents must not appear in conversation.
2. **Never read private key contents**: reference keys by path only. Never `cat` private keys.
3. **Never modify `.secrets/` from Agent commands** unless the user explicitly requests it.
4. **Observe before changing**: for unclear problems, use `sys.sh`, `file.sh`, `proc.sh`, `net.sh`, and `service.sh status/logs` before applying changes.
5. **Use primitives first**: prefer `file.sh`, `proc.sh`, `net.sh`, `pkg.sh`, `service.sh` over raw `exec.sh` when available.
6. **Use runner for fleets**: for more than a few hosts, use `runner.sh` with `--parallel`, `--timeout`, and preferably `--fail-fast`.
7. **Use locks for write operations**: when doing multi-step writes on a host, use `lock.sh acquire/release`.
8. **Confirm destructive commands**: high-risk operations require `--confirm` or `SSH_SKILL_CONFIRMED=yes`.
9. **No sudo passwords**: do not embed sudo passwords in commands. Suggest NOPASSWD sudoers or manual operation.
10. **Truncate large outputs**: use limits in primitives or add `head`/`tail` to raw commands.
11. **Do not auto-kill busy processes**: file upload busy-release requires `--force-release` or `SSH_SKILL_FORCE_RELEASE=yes`.
12. **Review summaries before follow-up actions**: for batch runs, inspect failed hosts before remediation.

---

## Policy Guard

The skill keeps guardrails minimal so Agent autonomy is preserved. It blocks only clearly risky operations unless explicitly confirmed.

High-risk examples:

- `rm -rf /`
- `mkfs`
- `dd if=`
- `shutdown` / `reboot`
- `iptables -F`
- `ufw disable`
- `killall`
- `fuser -k`
- `systemctl stop`
- `systemctl disable`

Medium-risk commands, such as broad service restarts, require confirmation when they affect more than 20 hosts.

Confirm explicitly:

```bash
bash skills/ssh/scripts/exec.sh hk "sudo systemctl stop caddy" --confirm
```

or:

```bash
SSH_SKILL_CONFIRMED=yes bash skills/ssh/scripts/exec.sh hk "sudo systemctl stop caddy"
```

---

## hosts.yaml Format

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
HOST=1.2.3.4
KEY_PATH=/root/.ssh/id_ed25519
```

For password auth:

```bash
SSH_PASSWORD=your_password
```

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
| `hosts.yaml` not found | Show format guide and ask user to create it |
| Host not in yaml | List existing hosts and ask user to add the host |
| `sshpass` not installed | Suggest installing `sshpass` or switching to key auth |
| Connection timeout | Check host/port/firewall and retry later |
| Auth failed | Check `.secrets/` config; do not output credentials |
| ControlMaster socket expired | Auto re-run `connect.sh`, then retry |
| `policy_blocked` | Ask for explicit confirmation before continuing |
| `target_busy` | Ask whether to retry with `--force-release` |
| `lock_owned_by_other` | Wait, inspect lock status, or ask before force unlock |
| Command `exit_code != 0` | Return JSON result and summarize failed hosts |
