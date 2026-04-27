#!/usr/bin/env bash
# Generic runtime gate tests. No SSH connections are opened.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

export AUDIT_DIR="$TMP_DIR/audit"
export HOSTS_YAML="$ROOT/hosts.example.yaml"

pass_count=0

log() { printf '[agent-gate-test] %s\n' "$*"; }

pass() {
  pass_count=$((pass_count + 1))
  log "PASS: $1"
}

expect_success() {
  local name="$1"; shift
  if "$@" >"$TMP_DIR/out.log" 2>"$TMP_DIR/err.log"; then
    pass "$name"
  else
    cat "$TMP_DIR/out.log" >&2 || true
    cat "$TMP_DIR/err.log" >&2 || true
    echo "FAIL: $name" >&2
    exit 1
  fi
}

expect_failure_contains() {
  local name="$1" expected="$2"; shift 2
  if "$@" >"$TMP_DIR/out.log" 2>"$TMP_DIR/err.log"; then
    cat "$TMP_DIR/out.log" >&2 || true
    cat "$TMP_DIR/err.log" >&2 || true
    echo "FAIL: $name unexpectedly succeeded" >&2
    exit 1
  fi
  if grep -q "$expected" "$TMP_DIR/out.log" "$TMP_DIR/err.log" 2>/dev/null; then
    pass "$name"
  else
    cat "$TMP_DIR/out.log" >&2 || true
    cat "$TMP_DIR/err.log" >&2 || true
    echo "FAIL: $name did not contain expected marker: $expected" >&2
    exit 1
  fi
}

write_decision() {
  local path="$1" level="$2" risk="$3" env="$4" primitive="$5" args_json="$6" max_hosts="$7" requires_confirmation="$8" hosts_json="$9"
  cat >"$path" <<JSON
{
  "intent": "generic gate test",
  "autonomy_level": "$level",
  "target_scope": {
    "hosts": $hosts_json,
    "environment": "$env"
  },
  "observations": ["bounded generic test observation"],
  "hypothesis": "generic gate behavior is being validated",
  "risk": "$risk",
  "action": {
    "primitive": "$primitive",
    "args": $args_json,
    "command": "$primitive generic args",
    "expected_effect": "dry-run validation only"
  },
  "guardrails": {
    "requires_confirmation": $requires_confirmation,
    "requires_lock": false,
    "rollback_available": false,
    "policy_risk": "$risk",
    "max_hosts": $max_hosts,
    "timeout_sec": 30,
    "output_limit": "bounded"
  },
  "verification": ["gate returns expected allow/block result"],
  "verification_actions": [],
  "rollback": [],
  "rollback_actions": [],
  "stop_condition": "dry-run completes or blocks as expected",
  "confidence": "high"
}
JSON
}

VALID_DECISION="$TMP_DIR/valid-observe.json"
cp "$ROOT/examples/decision-record.observe.json" "$VALID_DECISION"

expect_success \
  "validate generic observe decision" \
  python3 "$ROOT/scripts/validate_decision.py" "$VALID_DECISION" --quiet

expect_success \
  "agent_gate allows L1 observe dry-run" \
  bash "$ROOT/scripts/agent_gate.sh" --decision "$VALID_DECISION" --policy "$ROOT/autonomy.example.yaml" --dry-run

RAW_EXEC_DECISION="$TMP_DIR/raw-exec.json"
write_decision "$RAW_EXEC_DECISION" "L1" "low" "dev" "exec.sh" '["demo-host-01", "uptime"]' 1 false '["demo-host-01"]'
expect_failure_contains \
  "agent_gate blocks raw exec without explicit approval" \
  "raw_exec_blocked" \
  bash "$ROOT/scripts/agent_gate.sh" --decision "$RAW_EXEC_DECISION" --policy "$ROOT/autonomy.example.yaml" --dry-run

PROD_L3_DECISION="$TMP_DIR/prod-l3.json"
write_decision "$PROD_L3_DECISION" "L3" "medium" "prod" "service.sh" '["demo-host-01", "restart", "generic-service"]' 1 false '["demo-host-01"]'
expect_failure_contains \
  "agent_gate blocks production L3 without confirmation" \
  "autonomy_blocked" \
  bash "$ROOT/scripts/agent_gate.sh" --decision "$PROD_L3_DECISION" --policy "$ROOT/autonomy.example.yaml" --dry-run

HOST_LIMIT_DECISION="$TMP_DIR/host-limit.json"
write_decision "$HOST_LIMIT_DECISION" "L1" "low" "dev" "sys.sh" '["demo-host-01", "summary"]' 1 false '["demo-host-01", "demo-host-02"]'
expect_failure_contains \
  "agent_gate blocks host count above max_hosts" \
  "exceeds max_hosts" \
  bash "$ROOT/scripts/agent_gate.sh" --decision "$HOST_LIMIT_DECISION" --policy "$ROOT/autonomy.example.yaml" --dry-run

SENSITIVE_DECISION="$TMP_DIR/sensitive.json"
write_decision "$SENSITIVE_DECISION" "L1" "low" "dev" "sys.sh" '["demo-host-01", "summary"]' 1 false '["demo-host-01"]'
python3 - "$SENSITIVE_DECISION" <<'PY'
import json, sys
p = sys.argv[1]
data = json.load(open(p))
data["observations"].append("observed ssh target admin@example.internal")
json.dump(data, open(p, "w"), indent=2)
PY
expect_failure_contains \
  "validate_decision blocks sensitive-looking targets" \
  "sensitive-looking" \
  python3 "$ROOT/scripts/validate_decision.py" "$SENSITIVE_DECISION" --quiet

UNKNOWN_KEY_DECISION="$TMP_DIR/unknown-key.json"
cp "$VALID_DECISION" "$UNKNOWN_KEY_DECISION"
python3 - "$UNKNOWN_KEY_DECISION" <<'PY'
import json, sys
p = sys.argv[1]
data = json.load(open(p))
data["unexpected_field"] = True
json.dump(data, open(p, "w"), indent=2)
PY
expect_failure_contains \
  "validate_decision blocks unknown top-level keys" \
  "unknown top-level keys" \
  python3 "$ROOT/scripts/validate_decision.py" "$UNKNOWN_KEY_DECISION" --quiet

log "Completed $pass_count generic agent gate tests"
