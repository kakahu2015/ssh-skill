# SSH/Linux Ops Skill v1.3.0 — Safety Hardening Update

This update hardens the SSH/Linux Ops Skill around inventory hygiene, command safety, sudo behavior, output redaction, and CI validation.

## Key Changes

### 1. Safer inventory handling

The repository no longer tracks real `hosts.yaml` inventory data. Instead, it now provides a safe example file:

```text
hosts.example.yaml
```

Users should copy it locally:

```bash
cp hosts.example.yaml hosts.yaml
```

Real host addresses, private key paths, passwords, and other sensitive connection details should be stored only under:

```text
.secrets/<host>.env
```

The local `hosts.yaml` and real `.secrets/` files are ignored by Git.

### 2. Inventory validation

A new validation script was added:

```bash
bash scripts/validate_hosts.sh hosts.example.yaml
bash scripts/validate_hosts.sh hosts.yaml --allow-real-hosts
```

It checks the inventory structure and catches common OPSEC mistakes, such as committing real IP addresses or real private key paths into the public inventory.

### 3. Stronger output redaction

The shared redaction layer in `common.sh` now covers more sensitive patterns, including:

- Passwords, tokens, API keys, and private-key style variables
- Private key block headers and footers
- IPv4 and common IPv6 addresses
- SSH-style `user@host` targets
- `.ssh` paths
- `.secrets` paths
- `/keys/...` placeholders
- Actual host, user, key path, and secrets path values loaded from the active host config

JSON output and audit logs now use safer redaction helpers where applicable.

### 4. Stronger policy guardrails

The command policy layer now detects more risky operations, including:

- Destructive filesystem commands
- Disk formatting and partitioning commands
- Firewall flush or disable operations
- Service stop, disable, and mask operations
- Dangerous Docker and Kubernetes actions
- Suspicious `bash -c` or `sh -c` patterns combined with downloaders or base64 decoding
- Attempts to read private keys, `/etc/shadow`, or `/etc/sudoers`

Medium-risk commands now require confirmation when they affect more than 20 hosts or when the target is marked as production through `env: prod`, `env: production`, or production-related tags.

### 5. Explicit sudo retry

`exec.sh` no longer automatically retries with `sudo` after a `Permission denied` error.

By default, it returns a structured JSON result such as:

```json
{
  "error": "permission_denied",
  "sudo_used": false
}
```

To explicitly allow sudo retry:

```bash
bash scripts/exec.sh <host> "cat /var/log/app.log | tail -50" --sudo
```

For batch runs:

```bash
bash scripts/runner.sh --target "tag=dev" --cmd "cat /var/log/app.log | tail -50" --sudo
```

The sudo retry path still passes through the policy guard before execution.

### 6. Safer SCP output

`scp_transfer.sh` now redacts `src`, `dst`, and stderr fields in its JSON output, reducing the risk of leaking local paths, remote paths, usernames, hostnames, or project-specific directory names.

### 7. CI added

A GitHub Actions workflow was added for basic quality checks:

```text
.github/workflows/shell-ci.yml
```

It runs:

```bash
bash -n scripts/*.sh
bash scripts/validate_hosts.sh hosts.example.yaml
```

It also runs ShellCheck in advisory mode.

## Recommended local setup

```bash
cp hosts.example.yaml hosts.yaml
mkdir -p .secrets
cp .secrets/host.env.example .secrets/demo-edge-01.env

bash scripts/validate_hosts.sh hosts.yaml --allow-real-hosts
```

Then connect and run commands:

```bash
bash scripts/list_hosts.sh
bash scripts/connect.sh demo-edge-01
bash scripts/exec.sh demo-edge-01 "uptime"
```

## Summary

Version `1.3.0` makes the skill safer for public reuse and production-like environments by separating real inventory from the repository, expanding redaction, tightening policy checks, requiring explicit sudo escalation, validating inventory files, and adding CI coverage.
