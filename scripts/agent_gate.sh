#!/usr/bin/env bash
# OpenClaw SSH Skill - runtime gate for AI Agent decisions
#
# Generic autonomy gate. It validates a decision record, checks autonomy
# boundaries, executes exactly one primitive action, and optionally executes
# verification/rollback actions from the decision record.
#
# It must not contain app-specific or business-specific workflows.
set -euo pipefail

SCRIPTS_DIR="$(cd "$(dirname "$0")" && pwd)"
SKILL_DIR="$(cd "$SCRIPTS_DIR/.." && pwd)"
# shellcheck source=/dev/null
source "$SCRIPTS_DIR/common.sh"

DECISION_FILE=""
POLICY_FILE="${AUTONOMY_YAML:-$SKILL_DIR/autonomy.yaml}"
MODE="dry-run"
GATE_CONFIRMED=0
ROLLBACK_ON_FAILED_VERIFICATION=0
ALLOW_RAW_EXEC=0

usage() {
    cat <<'USAGE'
Usage: agent_gate.sh --decision <decision.json> [options]

Options:
  --decision <file>                 Decision record JSON file
  --policy <file>                   Autonomy policy file, default: autonomy.yaml if present
  --dry-run                         Validate and print planned action without executing, default
  --execute                         Execute action after gate checks
  --confirm                         Allow confirmation-gated L4/high-risk actions
  --rollback-on-failed-verification Run rollback_actions if verification fails
  --allow-raw-exec                  Permit exec.sh when explicitly approved
  -h, --help                        Show help

This gate does not contain app-specific workflows. It only enforces autonomy,
policy, decision-record, verification, and rollback contracts around primitives.
USAGE
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --decision)
            DECISION_FILE="${2:?--decision requires a file}"; shift 2 ;;
        --policy)
            POLICY_FILE="${2:?--policy requires a file}"; shift 2 ;;
        --dry-run)
            MODE="dry-run"; shift ;;
        --execute)
            MODE="execute"; shift ;;
        --confirm)
            GATE_CONFIRMED=1; shift ;;
        --rollback-on-failed-verification)
            ROLLBACK_ON_FAILED_VERIFICATION=1; shift ;;
        --allow-raw-exec)
            ALLOW_RAW_EXEC=1; shift ;;
        -h|--help)
            usage; exit 0 ;;
        *)
            if [[ -z "$DECISION_FILE" && -f "$1" ]]; then
                DECISION_FILE="$1"; shift
            else
                die_json "invalid_arg" "Unknown argument: $1"
            fi
            ;;
    esac
done

[[ -n "$DECISION_FILE" ]] || die_json "missing_arg" "--decision is required"
[[ -f "$DECISION_FILE" ]] || die_json "not_found" "Decision file not found: $DECISION_FILE"
[[ "$MODE" == "dry-run" || "$MODE" == "execute" ]] || die_json "invalid_arg" "Invalid mode: $MODE"

require_python3() {
    command -v python3 >/dev/null 2>&1 || die_json "missing_dependency" "agent_gate.sh requires local python3 for JSON decision parsing"
}

json_array() {
    local first=1 item
    printf '['
    for item in "$@"; do
        [[ "$first" -eq 0 ]] && printf ', '
        printf '"%s"' "$(safe_json_string "$item")"
        first=0
    done
    printf ']'
}

level_num() {
    case "$1" in
        L0) echo 0 ;;
        L1) echo 1 ;;
        L2) echo 2 ;;
        L3) echo 3 ;;
        L4) echo 4 ;;
        L5) echo 5 ;;
        *) echo 99 ;;
    esac
}

risk_num() {
    case "$1" in
        low) echo 1 ;;
        medium) echo 2 ;;
        high) echo 3 ;;
        forbidden) echo 99 ;;
        *) echo 99 ;;
    esac
}

level_risk_limit() {
    case "$1" in
        L0) echo 0 ;;
        L1|L2) echo 1 ;;
        L3) echo 2 ;;
        L4) echo 3 ;;
        L5) echo 0 ;;
        *) echo 0 ;;
    esac
}

primitive_action_key() {
    local primitive="$1"
    shift || true
    local op="${2-}"
    case "$primitive" in
        service.sh|file.sh|proc.sh|net.sh|pkg.sh|sys.sh|lock.sh)
            printf '%s:%s' "$primitive" "$op" ;;
        facts.sh|patrol.sh|connect.sh|disconnect.sh|runner.sh|exec.sh|scp_transfer.sh)
            printf '%s:*' "$primitive" ;;
        *)
            printf '%s:*' "$primitive" ;;
    esac
}

is_allowed_without_confirmation() {
    local level="$1" primitive="$2" key
    shift 2 || true
    key="$(primitive_action_key "$primitive" "$@")"

    case "$level" in
        L0)
            return 1 ;;
        L1)
            case "$key" in
                sys.sh:*|facts.sh:*|patrol.sh:*|file.sh:exists|file.sh:stat|file.sh:list|file.sh:head|file.sh:tail|file.sh:grep|file.sh:checksum|proc.sh:top|proc.sh:mem|proc.sh:find|proc.sh:tree|net.sh:ports|net.sh:listen|net.sh:dns|net.sh:route|net.sh:addr|pkg.sh:detect|pkg.sh:installed|pkg.sh:search|service.sh:status|service.sh:logs)
                    return 0 ;;
                *) return 1 ;;
            esac ;;
        L2)
            is_allowed_without_confirmation L1 "$primitive" "$@" && return 0
            case "$key" in
                lock.sh:status|file.sh:backup|connect.sh:*|disconnect.sh:*) return 0 ;;
                *) return 1 ;;
            esac ;;
        L3)
            is_allowed_without_confirmation L2 "$primitive" "$@" && return 0
            case "$key" in
                service.sh:restart|service.sh:reload|pkg.sh:update-cache|file.sh:mkdir) return 0 ;;
                *) return 1 ;;
            esac ;;
        L4|L5)
            return 1 ;;
        *)
            return 1 ;;
    esac
}

validate_primitive_name() {
    local primitive="$1"
    [[ "$primitive" =~ ^[A-Za-z0-9_.-]+\.sh$ ]] || die_json "invalid_primitive" "Invalid primitive name: $primitive"
    [[ "$primitive" != *"/"* ]] || die_json "invalid_primitive" "Primitive must not contain path separators: $primitive"
    [[ -f "$SCRIPTS_DIR/$primitive" ]] || die_json "unknown_primitive" "Primitive not found: $primitive"
}

run_primitive_action() {
    local label="$1" primitive="$2" rc
    shift 2
    validate_primitive_name "$primitive"
    echo "[agent-gate] $label: $primitive $*" >&2
    set +e
    bash "$SCRIPTS_DIR/$primitive" "$@"
    rc=$?
    set -e
    return "$rc"
}

require_python3
ENV_FILE="$(mktemp)"
trap 'rm -f "$ENV_FILE"' EXIT

python3 - "$DECISION_FILE" "$POLICY_FILE" "$ENV_FILE" <<'PY'
import json
import re
import shlex
import sys
from pathlib import Path

decision_path = Path(sys.argv[1])
policy_path = Path(sys.argv[2])
env_path = Path(sys.argv[3])

try:
    decision = json.loads(decision_path.read_text())
except Exception as exc:
    raise SystemExit(f"invalid decision JSON: {exc}")

required = [
    "intent", "autonomy_level", "observations", "hypothesis", "risk",
    "action", "guardrails", "verification", "stop_condition", "confidence"
]
missing = [key for key in required if key not in decision]
if missing:
    raise SystemExit("missing required decision fields: " + ", ".join(missing))

levels = {"L0", "L1", "L2", "L3", "L4", "L5"}
risks = {"low", "medium", "high", "forbidden"}
confidences = {"low", "medium", "high"}
if decision["autonomy_level"] not in levels:
    raise SystemExit("invalid autonomy_level")
if decision["risk"] not in risks:
    raise SystemExit("invalid risk")
if decision["confidence"] not in confidences:
    raise SystemExit("invalid confidence")
if not isinstance(decision["observations"], list) or not decision["observations"]:
    raise SystemExit("observations must be a non-empty array")
if not isinstance(decision["verification"], list) or not decision["verification"]:
    raise SystemExit("verification must be a non-empty array")

action = decision["action"]
if not isinstance(action, dict) or not action.get("primitive"):
    raise SystemExit("action.primitive is required")
args = action.get("args", [])
if args is None:
    args = []
if not isinstance(args, list) or not all(isinstance(x, str) for x in args):
    raise SystemExit("action.args must be an array of strings")

guardrails = decision["guardrails"]
if not isinstance(guardrails, dict):
    raise SystemExit("guardrails must be an object")
for key in ("requires_confirmation", "requires_lock", "rollback_available"):
    if key not in guardrails or not isinstance(guardrails[key], bool):
        raise SystemExit(f"guardrails.{key} must be a boolean")

target_scope = decision.get("target_scope") or {}
if not isinstance(target_scope, dict):
    raise SystemExit("target_scope must be an object")
hosts = target_scope.get("hosts") or []
if not isinstance(hosts, list) or not all(isinstance(x, str) for x in hosts):
    raise SystemExit("target_scope.hosts must be an array of strings")
environment = str(target_scope.get("environment") or "unknown").lower()

verification_actions = decision.get("verification_actions") or []
rollback_actions = decision.get("rollback_actions") or []
for group_name, group in (("verification_actions", verification_actions), ("rollback_actions", rollback_actions)):
    if not isinstance(group, list):
        raise SystemExit(f"{group_name} must be an array")
    for item in group:
        if not isinstance(item, dict) or not item.get("primitive"):
            raise SystemExit(f"{group_name} entries require primitive")
        item_args = item.get("args", [])
        if not isinstance(item_args, list) or not all(isinstance(x, str) for x in item_args):
            raise SystemExit(f"{group_name}.args must be an array of strings")

policy_default_level = "L1"
policy_env_max_level = "L1"
policy_max_hosts = 1
policy_require_verification = True
policy_file_found = policy_path.exists()

if policy_file_found:
    text = policy_path.read_text()
    m = re.search(r"(?m)^default_level:\s*(L[0-5])\s*$", text)
    if m:
        policy_default_level = m.group(1)
        policy_env_max_level = policy_default_level

    m = re.search(r"(?m)^\s*max_hosts:\s*([0-9]+)\s*$", text)
    if m:
        policy_max_hosts = int(m.group(1))

    def read_bool(name, default):
        mm = re.search(rf"(?m)^\s*{re.escape(name)}:\s*(true|false)\s*$", text, re.I)
        if not mm:
            return default
        return mm.group(1).lower() == "true"

    policy_require_verification = read_bool("require_post_action_verification", policy_require_verification)

    env_match = re.search(r"(?ms)^environments:\s*\n(?P<body>.*?)(?:\n[^\s#][^\n]*:|\Z)", text)
    if env_match and environment != "unknown":
        body = env_match.group("body")
        block_match = re.search(rf"(?ms)^\s{{2}}{re.escape(environment)}:\s*\n(?P<block>.*?)(?=^\s{{2}}[A-Za-z0-9_.-]+:\s*$|\Z)", body)
        if block_match:
            level_match = re.search(r"(?m)^\s+max_unattended_level:\s*(L[0-5])\s*$", block_match.group("block"))
            if level_match:
                policy_env_max_level = level_match.group(1)


def q(value):
    return shlex.quote(str(value))

def arr(name, values):
    return f"{name}=(" + " ".join(q(v) for v in values) + ")"

lines = []
lines.append(f"DECISION_INTENT={q(decision['intent'])}")
lines.append(f"DECISION_LEVEL={q(decision['autonomy_level'])}")
lines.append(f"DECISION_RISK={q(decision['risk'])}")
lines.append(f"DECISION_CONFIDENCE={q(decision['confidence'])}")
lines.append(f"DECISION_ENV={q(environment)}")
lines.append(f"DECISION_PRIMITIVE={q(action['primitive'])}")
lines.append(arr("DECISION_ARGS", args))
lines.append(arr("DECISION_HOSTS", hosts))
lines.append(f"DECISION_REQUIRES_CONFIRMATION={q(str(guardrails['requires_confirmation']).lower())}")
lines.append(f"DECISION_REQUIRES_LOCK={q(str(guardrails['requires_lock']).lower())}")
lines.append(f"DECISION_ROLLBACK_AVAILABLE={q(str(guardrails['rollback_available']).lower())}")
lines.append(f"DECISION_GUARDRAIL_MAX_HOSTS={q(str(guardrails.get('max_hosts', '')))}")
lines.append(f"POLICY_FILE_FOUND={q(str(policy_file_found).lower())}")
lines.append(f"POLICY_DEFAULT_LEVEL={q(policy_default_level)}")
lines.append(f"POLICY_ENV_MAX_LEVEL={q(policy_env_max_level)}")
lines.append(f"POLICY_MAX_HOSTS={q(str(policy_max_hosts))}")
lines.append(f"POLICY_REQUIRE_VERIFICATION={q(str(policy_require_verification).lower())}")
lines.append(f"VERIFICATION_ACTION_COUNT={q(str(len(verification_actions)))}")
for idx, item in enumerate(verification_actions):
    lines.append(f"VERIFY_{idx}_PRIMITIVE={q(item['primitive'])}")
    lines.append(arr(f"VERIFY_{idx}_ARGS", item.get("args", [])))
lines.append(f"ROLLBACK_ACTION_COUNT={q(str(len(rollback_actions)))}")
for idx, item in enumerate(rollback_actions):
    lines.append(f"ROLLBACK_{idx}_PRIMITIVE={q(item['primitive'])}")
    lines.append(arr(f"ROLLBACK_{idx}_ARGS", item.get("args", [])))

env_path.write_text("\n".join(lines) + "\n")
PY

# shellcheck source=/dev/null
source "$ENV_FILE"

HOST_COUNT=${#DECISION_HOSTS[@]}
if [[ "$HOST_COUNT" -eq 0 && "${#DECISION_ARGS[@]}" -gt 0 ]]; then
    HOST_COUNT=1
fi
EFFECTIVE_MAX_HOSTS="$POLICY_MAX_HOSTS"
if [[ -n "$DECISION_GUARDRAIL_MAX_HOSTS" ]]; then
    EFFECTIVE_MAX_HOSTS="$DECISION_GUARDRAIL_MAX_HOSTS"
fi

DECISION_LEVEL_NUM="$(level_num "$DECISION_LEVEL")"
POLICY_LEVEL_NUM="$(level_num "$POLICY_ENV_MAX_LEVEL")"
DECISION_RISK_NUM="$(risk_num "$DECISION_RISK")"
LEVEL_RISK_NUM="$(level_risk_limit "$DECISION_LEVEL")"

[[ "$DECISION_LEVEL" != "L5" ]] || die_json "autonomy_forbidden" "L5 actions are forbidden and cannot be executed"
[[ "$DECISION_RISK" != "forbidden" ]] || die_json "autonomy_forbidden" "Forbidden-risk actions cannot be executed by agent_gate"

if [[ "$MODE" == "execute" && "$DECISION_LEVEL" == "L0" ]]; then
    die_json "autonomy_blocked" "L0 is advisory-only and does not allow remote execution"
fi

if [[ "$DECISION_LEVEL_NUM" -gt "$POLICY_LEVEL_NUM" && "$GATE_CONFIRMED" -ne 1 ]]; then
    die_json "autonomy_blocked" "Decision autonomy level $DECISION_LEVEL exceeds policy max $POLICY_ENV_MAX_LEVEL for env=$DECISION_ENV."
fi

if [[ "$DECISION_RISK_NUM" -gt "$LEVEL_RISK_NUM" && "$GATE_CONFIRMED" -ne 1 ]]; then
    die_json "autonomy_blocked" "Risk $DECISION_RISK exceeds allowed risk for $DECISION_LEVEL."
fi

if [[ "$DECISION_REQUIRES_CONFIRMATION" == "true" && "$GATE_CONFIRMED" -ne 1 ]]; then
    die_json "confirmation_required" "Decision guardrails require explicit confirmation."
fi

if [[ "$HOST_COUNT" -gt "$EFFECTIVE_MAX_HOSTS" && "$GATE_CONFIRMED" -ne 1 ]]; then
    die_json "autonomy_blocked" "Host count $HOST_COUNT exceeds max_hosts $EFFECTIVE_MAX_HOSTS."
fi

if [[ "$DECISION_ENV" == "prod" || "$DECISION_ENV" == "production" ]]; then
    if [[ "$DECISION_LEVEL_NUM" -gt 1 && "$GATE_CONFIRMED" -ne 1 ]]; then
        die_json "prod_guard" "Production targets default to L1 observe-only unless explicitly confirmed."
    fi
fi

validate_primitive_name "$DECISION_PRIMITIVE"

if [[ "$DECISION_PRIMITIVE" == "exec.sh" && "$ALLOW_RAW_EXEC" -ne 1 && "$GATE_CONFIRMED" -ne 1 ]]; then
    die_json "raw_exec_blocked" "exec.sh is blocked by agent_gate unless --allow-raw-exec or --confirm is provided. Prefer semantic primitives."
fi

if ! is_allowed_without_confirmation "$DECISION_LEVEL" "$DECISION_PRIMITIVE" "${DECISION_ARGS[@]}"; then
    if [[ "$GATE_CONFIRMED" -ne 1 ]]; then
        die_json "autonomy_blocked" "Primitive/action $(primitive_action_key "$DECISION_PRIMITIVE" "${DECISION_ARGS[@]}") is not allowed unattended at $DECISION_LEVEL."
    fi
fi

if [[ "$POLICY_REQUIRE_VERIFICATION" == "true" && "$MODE" == "execute" ]]; then
    if [[ "$DECISION_LEVEL_NUM" -ge 2 || "$DECISION_RISK" != "low" ]]; then
        [[ "$VERIFICATION_ACTION_COUNT" -gt 0 ]] || die_json "verification_required" "Executable verification_actions are required for L2+ or non-low-risk execution."
    fi
fi

RUN_ID="${SSH_SKILL_RUN_ID:-$(make_run_id)}"
AUDIT_DAY_DIR="$AUDIT_DIR/$(date -u +%Y-%m-%d)"
mkdir -p "$AUDIT_DAY_DIR"
DECISION_AUDIT_FILE="$AUDIT_DAY_DIR/${RUN_ID}.decision.json"
redact_string "$(cat "$DECISION_FILE")" > "$DECISION_AUDIT_FILE"

if [[ "$MODE" == "dry-run" ]]; then
    cat <<JSON
{
  "success": true,
  "mode": "dry-run",
  "run_id": "$(safe_json_string "$RUN_ID")",
  "decision_file": "$(safe_json_string "$DECISION_FILE")",
  "policy_file": "$(safe_json_string "$POLICY_FILE")",
  "policy_file_found": $([[ "$POLICY_FILE_FOUND" == "true" ]] && echo true || echo false),
  "autonomy_level": "$(safe_json_string "$DECISION_LEVEL")",
  "policy_max_level": "$(safe_json_string "$POLICY_ENV_MAX_LEVEL")",
  "risk": "$(safe_json_string "$DECISION_RISK")",
  "environment": "$(safe_json_string "$DECISION_ENV")",
  "host_count": $HOST_COUNT,
  "max_hosts": $EFFECTIVE_MAX_HOSTS,
  "action": {
    "primitive": "$(safe_json_string "$DECISION_PRIMITIVE")",
    "args": $(json_array "${DECISION_ARGS[@]}")
  },
  "verification_action_count": $VERIFICATION_ACTION_COUNT,
  "rollback_action_count": $ROLLBACK_ACTION_COUNT,
  "audit_decision_file": "$(safe_json_string "$DECISION_AUDIT_FILE")"
}
JSON
    exit 0
fi

ACTION_RC=0
run_primitive_action "execute" "$DECISION_PRIMITIVE" "${DECISION_ARGS[@]}" || ACTION_RC=$?
write_audit_event "$RUN_ID" "agent_gate" "execute:$DECISION_PRIMITIVE" "$([[ "$ACTION_RC" -eq 0 ]] && echo true || echo false)" "$ACTION_RC" 0 "$DECISION_PRIMITIVE ${DECISION_ARGS[*]-}"

if [[ "$ACTION_RC" -ne 0 ]]; then
    die_json "action_failed" "Primary action failed with exit_code=$ACTION_RC"
fi

VERIFY_FAILED=0
if [[ "$VERIFICATION_ACTION_COUNT" -gt 0 ]]; then
    for ((i=0; i<VERIFICATION_ACTION_COUNT; i++)); do
        eval "VERIFY_PRIMITIVE=\${VERIFY_${i}_PRIMITIVE}"
        eval "VERIFY_ARGS=(\"\${VERIFY_${i}_ARGS[@]}\")"
        VERIFY_RC=0
        run_primitive_action "verify[$i]" "$VERIFY_PRIMITIVE" "${VERIFY_ARGS[@]}" || VERIFY_RC=$?
        write_audit_event "$RUN_ID" "agent_gate" "verify:$VERIFY_PRIMITIVE" "$([[ "$VERIFY_RC" -eq 0 ]] && echo true || echo false)" "$VERIFY_RC" 0 "$VERIFY_PRIMITIVE ${VERIFY_ARGS[*]-}"
        if [[ "$VERIFY_RC" -ne 0 ]]; then
            VERIFY_FAILED=1
            break
        fi
    done
fi

ROLLBACK_ATTEMPTED=false
if [[ "$VERIFY_FAILED" -ne 0 ]]; then
    if [[ "$ROLLBACK_ON_FAILED_VERIFICATION" -eq 1 && "$ROLLBACK_ACTION_COUNT" -gt 0 ]]; then
        ROLLBACK_ATTEMPTED=true
        for ((i=0; i<ROLLBACK_ACTION_COUNT; i++)); do
            eval "ROLLBACK_PRIMITIVE=\${ROLLBACK_${i}_PRIMITIVE}"
            eval "ROLLBACK_ARGS=(\"\${ROLLBACK_${i}_ARGS[@]}\")"
            ROLLBACK_RC=0
            run_primitive_action "rollback[$i]" "$ROLLBACK_PRIMITIVE" "${ROLLBACK_ARGS[@]}" || ROLLBACK_RC=$?
            write_audit_event "$RUN_ID" "agent_gate" "rollback:$ROLLBACK_PRIMITIVE" "$([[ "$ROLLBACK_RC" -eq 0 ]] && echo true || echo false)" "$ROLLBACK_RC" 0 "$ROLLBACK_PRIMITIVE ${ROLLBACK_ARGS[*]-}"
        done
    fi
    cat <<JSON
{
  "success": false,
  "run_id": "$(safe_json_string "$RUN_ID")",
  "error": "verification_failed",
  "rollback_attempted": $ROLLBACK_ATTEMPTED,
  "audit_decision_file": "$(safe_json_string "$DECISION_AUDIT_FILE")"
}
JSON
    exit 1
fi

cat <<JSON
{
  "success": true,
  "mode": "execute",
  "run_id": "$(safe_json_string "$RUN_ID")",
  "action": {
    "primitive": "$(safe_json_string "$DECISION_PRIMITIVE")",
    "args": $(json_array "${DECISION_ARGS[@]}")
  },
  "verification_action_count": $VERIFICATION_ACTION_COUNT,
  "audit_decision_file": "$(safe_json_string "$DECISION_AUDIT_FILE")"
}
JSON
