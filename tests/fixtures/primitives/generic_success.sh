#!/usr/bin/env bash
set -euo pipefail
printf '{"success":true,"primitive":"generic_success.sh","args":['
first=1
for arg in "$@"; do
  [[ "$first" -eq 0 ]] && printf ','
  printf '"%s"' "${arg//"/\"}"
  first=0
done
printf ']}\n'
