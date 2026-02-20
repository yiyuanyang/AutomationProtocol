#!/usr/bin/env bash
# bash-watchdog.sh — Pure bash loop watchdog (no AI, no session, no hallucination)
#
# Replaces the Kimi AI watchdog. Deterministic: checks state, decides action,
# runs review-loop.sh. Zero model judgment in the control path.
#
# Usage: Call this on a cron schedule (e.g., every 3 min).
#   */3 * * * * /path/to/bash-watchdog.sh >> /path/to/watchdog.log 2>&1
#
# Or via OpenClaw cron as a systemEvent that triggers:
#   bash /path/to/bash-watchdog.sh

set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
LOOP_SCRIPT="$REPO/scripts/review-loop.sh"
STATE="$REPO/.review-loop-state.json"
FLAG="$REPO/.agent-status.json"
LOCK="$REPO/.agent-trigger.lock"
PID_FILE="$REPO/.agent-pid"
LOG="$REPO/scripts/watchdog.log"

STALE_LOCK_SECS=2700   # 45 min — clear stale lock + re-trigger
STALE_PID_SECS=900     # 15 min — if PID dead and no flag, agent crashed

log() { echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] $*" | tee -a "$LOG"; }

# ── State validation ─────────────────────────────────────────────────────────

if [[ ! -f "$STATE" ]]; then
  log "ERROR: state file missing — cannot proceed. Fix manually."
  exit 1
fi

if ! python3 -m json.tool "$STATE" > /dev/null 2>&1; then
  log "ERROR: state file is not valid JSON — cannot proceed. Fix with inject-state.sh."
  exit 1
fi

STEP=$(python3 -c "import json; d=json.load(open('$STATE')); print(d['currentStep'])")
PHASE=$(python3 -c "import json; d=json.load(open('$STATE')); print(d['phase'])")
STATUS=$(python3 -c "import json; d=json.load(open('$STATE')); print(d['status'])")

log "State: step=$STEP phase=$PHASE status=$STATUS"

# ── Flag check ───────────────────────────────────────────────────────────────

if [[ -f "$FLAG" ]]; then
  log "Flag found — running loop to process it."
  bash "$LOOP_SCRIPT"
  exit 0
fi

# ── Lock / PID check ─────────────────────────────────────────────────────────

if [[ -f "$LOCK" ]]; then
  LOCK_AGE=$(( $(date +%s) - $(stat -f %m "$LOCK" 2>/dev/null || stat -c %Y "$LOCK") ))

  # Check PID liveness if we have one
  if [[ -f "$PID_FILE" ]]; then
    PID=$(cat "$PID_FILE" 2>/dev/null || echo "")
    if [[ -n "$PID" ]] && kill -0 "$PID" 2>/dev/null; then
      log "Agent alive (PID $PID, lock ${LOCK_AGE}s old) — waiting."
      exit 0
    else
      log "Agent dead (PID $PID gone, lock ${LOCK_AGE}s old) — clearing and re-triggering."
      rm -f "$LOCK" "$PID_FILE"
      bash "$LOOP_SCRIPT"
      exit 0
    fi
  fi

  # No PID file — fall back to lock age
  if [[ $LOCK_AGE -lt $STALE_LOCK_SECS ]]; then
    log "Lock ${LOCK_AGE}s old (no PID file) — waiting."
    exit 0
  else
    log "Lock stale (${LOCK_AGE}s, no PID file) — clearing and re-triggering."
    rm -f "$LOCK"
    bash "$LOOP_SCRIPT"
    exit 0
  fi
fi

# ── Idle — trigger ───────────────────────────────────────────────────────────

log "No flag, no lock — idle. Triggering loop."
bash "$LOOP_SCRIPT"
