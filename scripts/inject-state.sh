#!/usr/bin/env bash
# inject-state.sh — Archie's ONLY allowed state-correction tool.
#
# Use ONLY to fix corrupted state (wrong step, fabricated history, stale lock).
# NOT for advancing state, approving work, or skipping reviews.
#
# Usage:
#   inject-state.sh --step 11b --phase propose --status starting --reason "Prior agent fabricated step 20"
#   inject-state.sh --clear-lock --reason "Lock stale after crash"
#   inject-state.sh --clear-flag --reason "Stale flag from abandoned run"

set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
STATE="$REPO/.review-loop-state.json"
LOCK="$REPO/.agent-trigger.lock"
FLAG="$REPO/.agent-status.json"
PID_FILE="$REPO/.agent-pid"

STEP="" PHASE="" STATUS="" REASON="" CLEAR_LOCK=0 CLEAR_FLAG=0

# Parse args
while [[ $# -gt 0 ]]; do
  case "$1" in
    --step)      STEP="$2";   shift 2 ;;
    --phase)     PHASE="$2";  shift 2 ;;
    --status)    STATUS="$2"; shift 2 ;;
    --reason)    REASON="$2"; shift 2 ;;
    --clear-lock) CLEAR_LOCK=1; shift ;;
    --clear-flag) CLEAR_FLAG=1; shift ;;
    *) echo "Unknown arg: $1" >&2; exit 1 ;;
  esac
done

if [[ -z "$REASON" ]]; then
  echo "ERROR: --reason is required. Document why this injection is necessary." >&2
  exit 1
fi

echo "=== inject-state.sh ==="
echo "Reason: $REASON"
echo "Time:   $(date -u +%Y-%m-%dT%H:%M:%SZ)"

# Clear lock
if [[ $CLEAR_LOCK -eq 1 ]]; then
  if [[ -f "$LOCK" ]]; then
    rm -f "$LOCK" "$PID_FILE"
    echo "Cleared: .agent-trigger.lock"
  else
    echo "No lock to clear."
  fi
fi

# Clear flag
if [[ $CLEAR_FLAG -eq 1 ]]; then
  if [[ -f "$FLAG" ]]; then
    rm -f "$FLAG"
    echo "Cleared: .agent-status.json"
  else
    echo "No flag to clear."
  fi
fi

# Update state
if [[ -n "$STEP" || -n "$PHASE" || -n "$STATUS" ]]; then
  if [[ ! -f "$STATE" ]]; then
    echo "ERROR: state file not found." >&2
    exit 1
  fi

  python3 << EOF
import json, sys
from datetime import datetime, timezone

with open("$STATE") as f:
    d = json.load(f)

prev = {"step": d.get("currentStep"), "phase": d.get("phase"), "status": d.get("status")}

if "$STEP":  d["currentStep"] = "$STEP"
if "$PHASE": d["phase"] = "$PHASE"
if "$STATUS": d["status"] = "$STATUS"
d["lastUpdated"] = datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")
d["injectionNote"] = f"State corrected by inject-state.sh: {prev} → step={d['currentStep']} phase={d['phase']} status={d['status']}. Reason: $REASON"

with open("$STATE", "w") as f:
    json.dump(d, f, indent=2)

print(f"State updated: {prev['step']}/{prev['phase']}/{prev['status']} → {d['currentStep']}/{d['phase']}/{d['status']}")
EOF

  cd "$REPO"
  git add "$STATE"
  git commit -m "inject-state: $REASON" --quiet
  git push --quiet
  echo "Committed and pushed."
fi

echo "Done."
