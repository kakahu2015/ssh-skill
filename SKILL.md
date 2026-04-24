---
name: ssh
version: 1.1.0
description: >
  SSH remote login and interactive session skill. Use when connecting to remote servers,
  executing multiple remote commands, maintaining session state (working directory, environment),
  uploading/downloading files (SCP), or managing remote processes/services.
  Host config managed via hosts.yaml, sensitive credentials isolated in .secrets/<host>.env.
  Uses system ssh with ControlMaster for persistent connection reuse across tool calls.
compatibility:
  tools:
    - exec
  system_deps:
    - ssh
    - scp
    - sshpass       # optional, only for password auth
---

# SSH Skill

Uses system `ssh` + ControlMaster for persistent connection reuse across multiple tool calls.
Host config in `hosts.yaml`, sensitive fields in `.secrets/<host>.env` (not in git).

---

## Directory Structure

```
openclaw/skills/ssh/
├── SKILL.md
├── hosts.yaml                ← Host config (placeholders only, safe for git)
├── hosts.yaml.bak            ← Original config backup
├── scripts/
│   ├── connect.sh            ← Establish ControlMaster background connection
│   ├── exec.sh               ← Execute commands via ControlMaster
│   ├── disconnect.sh         ← Close ControlMaster socket
│   ├── scp_transfer.sh       ← File upload/download
│   └── list_hosts.sh         ← List available hosts
├── references/
│   └── hosts_yaml_format.md  ← hosts.yaml format reference
└── .secrets/                 ← Sensitive credentials (add to .gitignore)
    ├── .gitignore
    ├── <host>.env            ← Real IP + key path per host
    └── <host>.env.example    ← Password/passphrase template
```

## Security Architecture

**Dual-layer config**:
- `hosts.yaml`: placeholders only (hostname, port, user) — safe to share/commit
- `.secrets/<host>.env`: real IPs, key paths — **not in git**

Scripts read hosts.yaml, then override with `HOST` and `KEY_PATH` from `.secrets/<host>.env`.
If .secrets file is missing, scripts fall back to raw hosts.yaml values.

**Output redaction**:
- `exec.sh` has a built-in `redact()` function that automatically filters:
  - `password=`, `passwd=`, `secret=`, `token=`, `api_key=` → `[REDACTED]`
  - IPv4 addresses → `[REDACTED_IP]`
- `list_hosts.sh` outputs only host aliases / metadata and does not print host or user fields

---

## Workflow

### Step 1: List and confirm hosts

```bash
bash skills/ssh/scripts/list_hosts.sh
```

If user hasn't specified a host, show the list for selection.

### Step 2: Connect (ControlMaster)

```bash
bash skills/ssh/scripts/connect.sh <host>
```

- Reads host config from `hosts.yaml`
- If `auth: password`, loads `SSH_PASSWORD` from `.secrets/<host>.env` via `sshpass`
- Creates ControlMaster socket in `/tmp/ssh-ctl/`
- Background persistent connection (`-N -f -o ControlMaster=yes`)
- Outputs connection status JSON

**After connection succeeds**, all subsequent commands reuse this socket without re-authentication.

### Step 3: Execute commands (interactive session)

```bash
bash skills/ssh/scripts/exec.sh <host> "command here"
```

**State persistence strategy**: Each ssh invocation is a separate process, working directory does not persist. Two approaches:

- **Method A (recommended)**: Set `default_workdir` in `hosts.yaml`, exec.sh auto-cds before each command
- **Method B**: Explicitly include path in command, e.g. `cd /app && git pull`

For multi-step operations, combine into one call:
```bash
bash skills/ssh/scripts/exec.sh prod "cd /app && git pull && npm install && pm2 restart app"
```

### Step 4: File transfer

```bash
# Upload
bash skills/ssh/scripts/scp_transfer.sh <host> upload /local/path /remote/path

# Download
bash skills/ssh/scripts/scp_transfer.sh <host> download /remote/path /local/path
```

SCP reuses the same ControlMaster socket, no re-authentication needed.

### Step 5: Disconnect

```bash
bash skills/ssh/scripts/disconnect.sh <host>
```

Execute when user says "exit", "disconnect", "close", "done".

---

## Security Rules (MUST follow)

1. **Never output credentials**: IPs, usernames, passwords, key paths, key contents — must not appear in conversation
2. **Never read private key contents**: Reference by path only (`ssh -i /path/to/key`), never `cat` or `read` key files
3. **Never modify config files**: hosts.yaml and .secrets/ are read-only
4. **Confirm destructive commands**: Before executing `rm -rf`, `dd`, `systemctl stop`, `DROP TABLE`, `> /dev/sda`, etc., explicitly confirm with user
5. **Output redaction**: exec.sh has built-in redact() for password/token/IP; manually add `[REDACTED]` for anything missed
6. **No sudo passwords**: Do not embed sudo passwords in commands; suggest `NOPASSWD` config or manual operation
7. **Missing hosts.yaml**: Show format guide and prompt user to create

---

## hosts.yaml Format

```yaml
hosts:
  prod:
    host: prod                          # Placeholder, real IP in .secrets/prod.env
    port: 22
    user: ubuntu
    auth: key
    key_path: /keys/prod                # Placeholder, real path in .secrets/prod.env
    default_workdir: /opt/myapp
    tags: [production]
```

Corresponding `.secrets/prod.env`:
```bash
HOST=1.2.3.4
KEY_PATH=/root/.ssh/id_ed25519
```

For password auth, `.secrets/<host>.env` also needs:
```bash
SSH_PASSWORD=your_password
```

---

## 输出截断

执行可能输出大量内容的命令时，**必须自行加管道截断**，避免撑爆 agent context：

```bash
dmesg | tail -50
journalctl --since today | head -100
cat /var/log/syslog | tail -200
find / -name "*.log" | head -30
ps aux | head -50
```

通用原则：日志类用 `tail -N`，列表类用 `head -N`，N 控制在 50-200。

## Error Handling

| Error | Action |
|-------|--------|
| `hosts.yaml` not found | Show format guide, prompt user to create |
| Host not in yaml | List existing hosts, ask to add new |
| `sshpass` not installed | Suggest `apt install sshpass` or switch to key auth |
| Connection timeout | Check host/port/firewall, ask to retry |
| Auth failed | Check .secrets/ config, do not output credentials |
| ControlMaster socket expired | Auto re-run connect.sh then retry |
| Command exit_code != 0 | Return exit_code + stderr, ask if troubleshooting needed |
