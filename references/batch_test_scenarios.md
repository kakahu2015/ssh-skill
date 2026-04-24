# Batch Test Scenarios

These scenarios are designed to validate the Linux Ops skill across multiple VPS hosts.

All default smoke scenarios are **read-only**. They do not restart services, install packages, delete files, kill processes, or modify configs.

## 0. Select a safe target first

Start with 2-3 non-critical hosts:

```bash
bash scripts/select_hosts.sh --target "tag=staging" --csv
```

Or explicit hosts:

```bash
TEST_HOSTS="hk,us-west,google"
```

## 1. Full read-only smoke test

```bash
bash scripts/batch_smoke.sh \
  --hosts "$TEST_HOSTS" \
  --parallel 5 \
  --timeout 30 \
  --service caddy
```

For a target expression:

```bash
bash scripts/batch_smoke.sh \
  --target "tag=production,role=edge" \
  --parallel 20 \
  --timeout 30 \
  --service caddy
```

Output summary example:

```json
{
  "success": true,
  "run_id": "run_20260424T120000Z_12345",
  "scenario": "all",
  "target": "tag=production,role=edge",
  "service": "caddy",
  "total_scenarios": 7,
  "ok_scenarios": 7,
  "failed_scenarios": 0,
  "results_dir": ".runs/run_xxx/batch_smoke"
}
```

## 2. Connectivity scenario

Purpose: verify SSH, ControlMaster auto-connect, command execution, hostname, uptime.

```bash
bash scripts/batch_smoke.sh --hosts "$TEST_HOSTS" --scenario connectivity --parallel 10 --timeout 20
```

Expected: all hosts return hostname and uptime.

## 3. System scenario

Purpose: verify OS/kernel/load detection.

```bash
bash scripts/batch_smoke.sh --hosts "$TEST_HOSTS" --scenario system --parallel 10 --timeout 20
```

Expected: each host returns hostname, kernel, OS, load average.

## 4. Disk and memory scenario

Purpose: detect full root disk, missing `/tmp`, low memory visibility.

```bash
bash scripts/batch_smoke.sh --hosts "$TEST_HOSTS" --scenario disk --parallel 10 --timeout 20
```

Expected: each host returns `df -hP / /tmp` and `free -h`.

## 5. Network scenario

Purpose: verify listening ports and routes can be observed.

```bash
bash scripts/batch_smoke.sh --hosts "$TEST_HOSTS" --scenario network --parallel 10 --timeout 20
```

Expected: output from `ss` or `netstat`, plus route table.

## 6. Service scenario

Purpose: check a service state without restarting it.

```bash
bash scripts/batch_smoke.sh --hosts "$TEST_HOSTS" --scenario service --service caddy --parallel 10 --timeout 20
```

Expected: `systemctl is-active`, status head, and recent journal tail if available.

## 7. Files scenario

Purpose: verify basic file stat operations.

```bash
bash scripts/batch_smoke.sh --hosts "$TEST_HOSTS" --scenario files --parallel 10 --timeout 20
```

Expected: stats for `/etc/passwd`, `/etc/hosts`, and `/tmp`.

## 8. Package manager scenario

Purpose: detect package manager and whether common tools exist.

```bash
bash scripts/batch_smoke.sh --hosts "$TEST_HOSTS" --scenario pkg --parallel 10 --timeout 20
```

Expected: one of `apt`, `dnf`, `yum`, `apk`, `pacman`, or `unknown`.

## 9. Primitive-level spot checks

Run these against one safe host before fleet use:

```bash
bash scripts/sys.sh hk summary
bash scripts/file.sh hk exists /etc/passwd
bash scripts/file.sh hk tail /etc/hosts 20
bash scripts/proc.sh hk top 10
bash scripts/net.sh hk ports 30
bash scripts/pkg.sh hk detect
bash scripts/service.sh hk status caddy
```

## 10. Policy guard tests

These should be blocked unless confirmed:

```bash
bash scripts/exec.sh hk "sudo systemctl stop caddy"
bash scripts/file.sh hk remove /tmp/some-file
bash scripts/proc.sh hk kill 1234
bash scripts/pkg.sh hk install htop
```

Expected: `policy_blocked` or `confirm_required`.

With confirmation, only run on test hosts:

```bash
bash scripts/pkg.sh hk install htop --confirm
```

## 11. Lock tests

```bash
RUN_ID="test_lock_$(date +%s)"
bash scripts/lock.sh hk acquire --run-id "$RUN_ID" --timeout 5
bash scripts/lock.sh hk status
bash scripts/lock.sh hk release --run-id "$RUN_ID"
```

Expected: acquired -> locked -> released.

## 12. Runner failure behavior

Use a harmless failing command:

```bash
bash scripts/runner.sh --hosts "$TEST_HOSTS" --cmd "exit 7" --parallel 5 --timeout 10
```

Expected: summary has failed hosts, per-host JSON stored under `.runs/<run_id>/results/`.

## 13. Timeout behavior

```bash
bash scripts/runner.sh --hosts "$TEST_HOSTS" --cmd "sleep 10" --parallel 5 --timeout 2
```

Expected: timeout results with exit code 124 if GNU `timeout` exists locally.

## 14. Suggested rollout order

1. One test host.
2. Three mixed-provider hosts.
3. One non-critical tag group.
4. Production read-only smoke test.
5. Confirmed write operations only on one canary host.
6. Batch writes only after Agent summarizes prior results.

## Result locations

Batch smoke summaries:

```text
.runs/<run_id>/batch_smoke/summary.json
```

Each scenario summary:

```text
.runs/<run_id>/batch_smoke/<scenario>.json
```

Runner per-host results:

```text
.runs/<run_id>/results/<host>.json
```

Audit logs:

```text
.audit/<YYYY-MM-DD>/<run_id>.jsonl
```
