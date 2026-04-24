# hosts.yaml Format Reference

## Basic Structure

```yaml
hosts:
  <hostname>:
    host: <placeholder>          # Real IP in .secrets/<hostname>.env
    port: <port>                 # Default: 22
    user: <username>             # SSH user
    auth: key | password         # Authentication method
    key_path: /keys/<hostname>   # Placeholder, real path in .secrets/<hostname>.env
    default_workdir: <path>      # Optional, auto-cd before each command
    jump_host: <other-host>      # Optional, ProxyJump through another host
    tags: [tag1, tag2]           # Optional, for filtering/labeling
```

## Fields

| Field | Required | Default | Description |
|-------|----------|---------|-------------|
| host | Yes | - | Placeholder name (real IP in .secrets/) |
| port | No | 22 | SSH port |
| user | Yes | - | SSH username |
| auth | Yes | - | `key` or `password` |
| key_path | If auth=key | - | Placeholder path (real path in .secrets/) |
| default_workdir | No | - | Auto-cd before commands |
| jump_host | No | - | ProxyJump host name (must exist in same yaml) |
| tags | No | - | Labels for filtering |

## .secrets/<hostname>.env

Each host needs a corresponding `.secrets/<hostname>.env` file:

```bash
# Required for all hosts
HOST=<real-ip-or-domain>

# Required for key auth
KEY_PATH=<real-path-to-private-key>

# Required for password auth
SSH_PASSWORD=<password>
```

## Security Notes

- `hosts.yaml` contains NO sensitive data — safe for git
- `.secrets/` contains real IPs and credentials — **NOT in git**
- Scripts auto-override hosts.yaml values with .secrets values
- If .secrets file is missing, hosts.yaml values are used as-is
