---
name: ssh
version: 1.1.0
description: >
  Agent-native SSH remote operations skill. Use when connecting to remote servers,
  executing remote commands, running batch operations across VPS fleets, collecting host facts,
  checking service health, uploading/downloading files, or managing remote processes/services.
  Host config is managed via hosts.yaml, while real IPs, key paths, and credentials are isolated in
  .secrets/<host>.env. Uses system ssh with ControlMaster for persistent connection reuse.
compatibility:
  tools:
    - exec
  system_deps:
    - ssh
    - scp
    - bash
    - awk
    - sed
    - sshpass       # optional, only for password auth
    - timeout       # optional, used by runner.sh per-host timeout when available
---

# SSH Skill

This is an **Agent-native SSH operations layer**, not a human-first Ansible clone.
It exposes safe, composable shell APIs that an AI Agent can call to operate VPS fleets.

Uses system `ssh` + ControlMaster for persistent connection reuse across multiple tool calls.
Host config lives in `hosts.yaml`; real IPs, key paths, and secrets live in `.secrets/<host>.env` and must not be committed.

---

## Preferred Agent Workflow

### 1. List available hosts

```bash
bash skills/ssh/scripts/list_hosts.sh
```

For real ControlMaster validation:

```bash
bash skills/ssh/scripts/list_hosts.sh --check
```

### 2. Select targets by tags or fields

Prefer selectors over hard-coded long host lists.

```bash
bash skills/ssh/scripts/select_hosts.sh --target "tag=production,role=edge" --csv
bash skills/ssh/scripts/select_hosts.sh --env prod --region hk --role caddy --csv
```

### 3. Use runner.sh for fleet operations

For multiple hosts or any operation that may touch many VPS, use `runner.sh` instead of manually looping over `exec.sh`.

```bash
bash skills/ssh/scripts/runner.sh \
  --target "tag=production,role=edge" \
  --cmd "uptime" \
  --parallel 20 \
  --timeout 30 \
  --fail-fast 20%
```

`runner.sh` prints a compact JSON summary and stores detailed per-host results under:

```text
.runs/<run_id>/results/<host>.json
```

Audit events are written to:

```text
.audit/<YYYY-MM-DD>/<run_id>.jsonl
```

### 4. Single-host commands

```bash
bash skills/ssh/scripts/connect.sh <host>
bash skills/ssh/scripts/exec.sh <host> "command here"
```

For multi-step operations, combine commands into one call:

```bash
bash skills/ssh/scripts/exec.sh prod "cd /app && git pull && npm install && pm2 restart app"
```

### 5. Service management

```bash
bash skills/ssh/scripts/service.sh hk status caddy
bash skills/ssh/scripts/service.sh hk logs caddy
bash skills/ssh/scripts/service.sh hk restart caddy
```

High-risk service operations such as stop/disable require explicit confirmation:

```bash
bash skills/ssh/scripts/service.sh hk stop caddy --confirm
```

### 6. File transfer

```bash
bash skills/ssh/scripts/scp_transfer.sh <host> upload /local/path /remote/path
bash skills/ssh/scripts/scp_transfer.sh <host> download /remote/path /local/path
```

If an upload target is busy, the script returns `target_busy` by default. Do not kill remote processes unless explicitly authorized:

```bash
bash skills/ssh/scripts/scp_transfer.sh hk upload ./caddy /usr/bin/caddy --force-release
```

### 7. Facts and patrol checks

Collect lightweight host facts:

```bash
bash skills/ssh/scripts/facts.sh --target "tag=production" --parallel 20 --timeout 30
```

Run a patrol health check for disk usage and service activity:

```bash
bash skills/ssh/scripts/patrol.sh --target "tag=production,role=edge" --service caddy --disk-threshold 85 --parallel 20
```

---

## Directory Structure

```text
openclaw/skills/ssh/
├── SKILL.md
├── README.md
├── _meta.json
├── hosts.yaml                ← Host config, placeholders only, safe for git
├── scripts/
│   ├── common.sh             ← Shared config, JSON, redaction, policy, audit helpers
│   ├── yaml.sh               ← Tiny hosts.yaml parser
│   ├── connect.sh            ← Establish ControlMaster background connection
│   ├── exec.sh               ← Execute commands via ControlMaster
│   ├── runner.sh             ← Concurrent fleet runner for Agent operations
│   ├── select_hosts.sh       ← Select hosts by tag/env/region/role/provider
│   ├── facts.sh              ← Collect lightweight host facts
│   ├── patrol.sh             ← Lightweight fleet health checks
│   ├── service.sh            ← Service management wrapper
│   ├── scp_transfer.sh       ← File upload/download
│   ├── disconnect.sh         ← Close ControlMaster socket
│   └── list_hosts.sh         ← List available hosts
├── references/
│   └── hosts_yaml_format.md
├── .secrets/                 ← Sensitive credentials, not committed
├── .runs/                    ← Runtime batch results, not committed
├── .audit/                   ← Runtime audit logs, not committed
└── .state/                   ← Future local state DB/cache, not committed
```

---

## Security Architecture

**Dual-layer config**:

- `hosts.yaml`: placeholders and non-secret metadata only — safe to share/commit
- `.secrets/<host>.env`: real IPs, key paths, credentials — must not be committed

Scripts read `hosts.yaml`, then override host and key path from `.secrets/<host>.env` or `.secrets/<alias-target>.env` when available.

**Output redaction**:

- `password=`, `passwd=`, `secret=`, `token=`, `api_key=` → `[REDACTED]`
- IPv4 addresses → `[REDACTED_IP]`
- common private-key paths → `[REDACTED_KEY_PATH]`

---

## Security Rules (MUST follow)

1. **Never output credentials**: IPs, usernames, passwords, key paths, key contents must not appear in conversation.
2. **Never read private key contents**: Reference keys by path only. Never `cat` or print private keys.
3. **Never modify `.secrets/` from Agent commands** unless the user explicitly asks.
4. **Prefer structured tools**: Use `service.sh`, `scp_transfer.sh`, `facts.sh`, `patrol.sh`, and `runner.sh` before free-form shell commands.
5. **Use runner for fleets**: For more than a few hosts, use `runner.sh` with `--parallel`, `--timeout`, and preferably `--fail-fast`.
6. **Confirm destructive commands**: High-risk commands require `--confirm` or `SSH_SKILL_CONFIRMED=yes`.
7. **No sudo passwords**: Do not embed sudo passwords in commands. Suggest NOPASSWD sudoers or manual operation.
8. **Truncate large outputs**: Add `head`, `tail`, or other limits to log/list commands.
9. **Do not auto-kill busy processes**: File upload busy-release requires `--force-release` or `SSH_SKILL_FORCE_RELEASE=yes`.
10. **Review summaries before follow-up actions**: After batch operations, inspect summary and failed hosts before remedial changes.

---

## Policy Guard

High-risk commands are blocked unless explicitly confirmed. Examples:

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

Use `tail -N` for logs and `head -N` for long lists. Keep N around 50-200.

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
| Command `exit_code != 0` | Return JSON result and summarize failed hosts |
