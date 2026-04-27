#!/usr/bin/env bash
# OpenClaw SSH Skill - thin compat wrapper around agent_gate.py
# All gate logic lives in the Python implementation.
set -euo pipefail

SCRIPTS_DIR="$(cd "$(dirname "$0")" && pwd)"
SKILL_DIR="$(cd "$SCRIPTS_DIR/.." && pwd)"

# Forward all args to the Python implementation
exec python3 "$SCRIPTS_DIR/agent_gate.py" "$@"
