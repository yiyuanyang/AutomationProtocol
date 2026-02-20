#!/usr/bin/env bash
# validate-flag.sh — Strict flag schema validation
#
# Usage: validate-flag.sh <flag-file> <expected-step>
# Exit 0 = valid. Exit 1 = invalid (reason printed to stderr).

set -euo pipefail

FLAG="${1:-}"
EXPECTED_STEP="${2:-}"
MAX_AGE_SECS=1800  # 30 min — reject flags older than this

if [[ -z "$FLAG" || ! -f "$FLAG" ]]; then
  echo "ERROR: flag file not found: $FLAG" >&2
  exit 1
fi

if ! python3 -m json.tool "$FLAG" > /dev/null 2>&1; then
  echo "ERROR: flag is not valid JSON" >&2
  exit 1
fi

python3 << EOF
import json, sys, time

with open("$FLAG") as f:
    d = json.load(f)

errors = []

# Required fields
for field in ("agent", "step", "status", "nextAgent", "timestamp"):
    if field not in d or not d[field]:
        errors.append(f"missing required field: {field}")

# Step match
if "$EXPECTED_STEP" and d.get("step") != "$EXPECTED_STEP":
    errors.append(f"step mismatch: flag={d.get('step')} expected=$EXPECTED_STEP")

# Timestamp freshness
try:
    from datetime import datetime, timezone
    ts = datetime.fromisoformat(d["timestamp"].replace("Z", "+00:00"))
    age = (datetime.now(timezone.utc) - ts).total_seconds()
    if age > $MAX_AGE_SECS:
        errors.append(f"flag is stale: age={int(age)}s max=$MAX_AGE_SECS s")
except Exception as e:
    errors.append(f"invalid timestamp: {e}")

# Valid status values
valid_statuses = {"proposed", "approved", "reviewed", "executed", "verified-clean", "not-approved"}
if d.get("status") not in valid_statuses:
    errors.append(f"unknown status: {d.get('status')}")

# Valid next agent
valid_agents = {"claude-code", "codex", "archie", "advance"}
if d.get("nextAgent") not in valid_agents:
    errors.append(f"unknown nextAgent: {d.get('nextAgent')}")

if errors:
    for e in errors:
        print(f"ERROR: {e}", file=sys.stderr)
    sys.exit(1)
else:
    print("OK")
EOF
