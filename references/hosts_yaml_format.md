# hosts.yaml Format Reference

## Basic Structure

```yaml
hosts:
  <hostname>:
    host: <placeholder>          # Real IP/domain in .secrets/<hostname>.env
    port: <port>                 # Default: 22
    user: <username>             # SSH user
    auth: key | password         # Authentication method
    key_path: /keys/<hostname>   # Placeholder, real path in .secrets/<hostname>.env
    default_workdir: <path>      # Optional, auto-cd before each command
    jump_host: <other-host>      # Optional, ProxyJump through another host

    # Recommended metadata for agent-scale selection
    provider: <provider>         # e.g. oci, alibaba, google, aws, hetzner
    region: <region>             # e.g. hk, jp, us-west, sjc
    env: <environment>           # e.g. prod, staging, dev
    role: <role>                 # e.g. edge, caddy, db, worker
    tags: [tag1, tag2]           # Optional labels for filtering
```

## Fields

| Field | Required | Default | Description |
|-------|----------|---------|-------------|
| host | Yes | - | Placeholder name; real IP/domain should live in `.secrets/` |
| port | No | 22 | SSH port |
| user | Yes | - | SSH username |
| auth | Yes | - | `key` or `password` |
| key_path | If auth=key | - | Placeholder path; real path should live in `.secrets/` |
| default_workdir | No | - | Auto-cd before commands |
| jump_host | No | - | ProxyJump host alias; must exist in same yaml |
| provider | Recommended | - | Cloud/provider metadata for selectors |
| region | Recommended | - | Region metadata for selectors |
| env | Recommended | - | Environment metadata for selectors |
| role | Recommended | - | Role metadata for selectors |
| tags | Recommended | - | Labels for filtering |

## Example for Agent Fleet Operations

```yaml
hosts:
  hk-edge-01:
    host: hk-edge-01
    port: 22
    user: root
    auth: key
    key_path: /keys/hk-edge-01
    default_workdir: /root
    provider: alibaba
    region: hk
    env: prod
    role: edge
    tags: [production, hk, caddy, edge]

  us-edge-01:
    host: us-edge-01
    port: 22
    user: root
    auth: key
    key_path: /keys/us-edge-01
    default_workdir: /root
    provider: oci
    region: us-west
    env: prod
    role: edge
    tags: [production, us-west, caddy, edge]
```

Then select hosts with:

```bash
bash scripts/select_hosts.sh --target "tag=production,role=edge" --csv
bash scripts/select_hosts.sh --env prod --region hk --csv
```

Run fleet commands with:

```bash
bash scripts/runner.sh --target "tag=production,role=edge" --cmd "uptime" --parallel 20 --timeout 30
```

## .secrets/<hostname>.env

Each host should have a corresponding `.secrets/<hostname>.env` file:

```bash
# Required for all hosts
HOST=<real-ip-or-domain>

# Required for key auth
KEY_PATH=<real-path-to-private-key>

# Required only for password auth
SSH_PASSWORD=<password>
```

Alias hosts are supported. If `hosts.yaml` contains:

```yaml
hosts:
  hk-vps:
    host: hk-vps
    user: root
    auth: key
    key_path: /keys/hk-vps

  hk:
    host: hk-vps
    user: root
    auth: key
    key_path: /keys/hk-vps
```

Scripts first try `.secrets/hk-vps.env`, then fall back to `.secrets/hk.env`.

## Security Notes

- `hosts.yaml` should contain no sensitive data.
- Real IPs/domains, key paths, and credentials belong in `.secrets/`.
- `.secrets/` is ignored by git, except the example file.
- Runtime results go to `.runs/` and audit logs go to `.audit/`; both are ignored by git.
- Prefer tags/fields and `runner.sh` for Agent batch work instead of long hard-coded host lists.
