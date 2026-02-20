#!/usr/bin/env bash
# review-loop.sh — Deterministic AI build loop.
#
# All routing decisions are made by this script. Agents execute tasks and write
# flags. This script reads flags, validates them, transitions state, and triggers
# the next agent. No model judgment in the control path.
#
# Flow: propose → review → execute → verify → advance
#
# Usage: bash scripts/review-loop.sh
#   Called by bash-watchdog.sh every N minutes.

set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
STATE="$REPO/.review-loop-state.json"
FLAG="$REPO/.agent-status.json"
LOCK="$REPO/.agent-trigger.lock"
PID_FILE="$REPO/.agent-pid"
LOG="$REPO/scripts/loop.log"
PROMPTS="$REPO/scripts/prompts"
REVIEWS_DIR="$REPO/reviews"
VALIDATE="$REPO/scripts/validate-flag.sh"
OWNER_MANDATES="$REPO/owner-mandates.json"

# ── Phase timeouts (seconds) ──────────────────────────────────────────────────
TIMEOUT_PROPOSE=600    # 10 min — proposal should be fast
TIMEOUT_REVIEW=900     # 15 min — review of proposal
TIMEOUT_EXECUTE=1500   # 25 min — implementation
TIMEOUT_VERIFY=1200    # 20 min — verification + tests

# ── Claude / Codex invocation ─────────────────────────────────────────────────
CLAUDE_MODEL="claude-sonnet-4-5"
CLAUDE_FLAGS="--dangerously-skip-permissions --output-format stream-json --verbose"
CODEX_FLAGS=""   # Add --full-auto or equivalent when stable

log() { echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] $*" | tee -a "$LOG"; }
die() { log "FATAL: $*"; exit 1; }

# ── Escalation ────────────────────────────────────────────────────────────────
escalate() {
  local msg="$1"
  log "ESCALATION: $msg"
  # Override with your notification mechanism (Telegram, Slack, etc.)
  # Example: message Steve on Telegram
  # curl -s "https://api.telegram.org/bot$BOT_TOKEN/sendMessage" \
  #   -d chat_id="$CHAT_ID" -d text="🚨 AutomationProtocol: $msg"
}

# ── State helpers ─────────────────────────────────────────────────────────────
get_state() { python3 -c "import json; d=json.load(open('$STATE')); print(d['$1'])"; }

update_state() {
  # update_state key=value key=value ...
  python3 << EOF
import json
from datetime import datetime, timezone
with open("$STATE") as f:
    d = json.load(f)
for kv in "$*".split():
    k, v = kv.split("=", 1)
    if k == "currentRound": d[k] = int(v)
    else: d[k] = v
d["lastUpdated"] = datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")
with open("$STATE", "w") as f:
    json.dump(d, f, indent=2)
EOF
}

# ── State machine ─────────────────────────────────────────────────────────────
# Maps (phase, status) → (next_phase, next_agent, prompt_tier)
# prompt_tier: the prefix used to look up step-specific prompts
# Lookup order: step-${STEP}-${tier}-claude.md → default-claude.md (or codex)
#
# Format: "next_phase:next_agent:prompt_tier"
declare -A TRANSITIONS
TRANSITIONS["propose:starting"]="propose:claude-code:p1"
TRANSITIONS["propose:proposed"]="review:codex:review"
TRANSITIONS["review:approved"]="execute:claude-code:p2"
TRANSITIONS["review:reviewed"]="review:claude-code:cr-fix"
TRANSITIONS["review:not-approved"]="review:claude-code:cr-fix"
TRANSITIONS["execute:executed"]="verify:codex:verify"
TRANSITIONS["verify:verified-clean"]="advance:advance:none"
TRANSITIONS["verify:reviewed"]="verify:claude-code:cr-fix"
TRANSITIONS["verify:not-approved"]="verify:claude-code:cr-fix"

# ── Prompt resolution ─────────────────────────────────────────────────────────
resolve_prompt() {
  local step="$1" tier="$2" agent="$3"
  local ext="claude"
  [[ "$agent" == "codex" ]] && ext="codex"

  # Look up: step-specific → default
  local candidates=(
    "$PROMPTS/step-${step}-${tier}-${ext}.md"
    "$PROMPTS/default-${ext}.md"
  )
  for f in "${candidates[@]}"; do
    if [[ -f "$f" ]]; then echo "$f"; return; fi
  done
  die "No prompt found for step=$step tier=$tier agent=$agent"
}

# ── Timeout for phase ─────────────────────────────────────────────────────────
phase_timeout() {
  case "$1" in
    propose) echo $TIMEOUT_PROPOSE ;;
    review)  echo $TIMEOUT_REVIEW  ;;
    execute) echo $TIMEOUT_EXECUTE ;;
    verify)  echo $TIMEOUT_VERIFY  ;;
    *)       echo 600              ;;
  esac
}

# ── Trigger agent ─────────────────────────────────────────────────────────────
trigger_claude() {
  local prompt_file="$1" timeout_secs="$2"
  log "Triggering Claude Code with $prompt_file (timeout=${timeout_secs}s)"

  # Write lock
  touch "$LOCK"

  # Launch detached with hard timeout; write PID for liveness tracking
  (
    ARCHIE_PROMPT="$prompt_file" ARCHIE_LOG="$LOG" \
    nohup bash -c \
      "timeout $timeout_secs claude -p \"\$(cat \"\$ARCHIE_PROMPT\")\" \
       --model $CLAUDE_MODEL $CLAUDE_FLAGS >> \"\$ARCHIE_LOG\" 2>&1" &
    echo $! > "$PID_FILE"
  )
}

trigger_codex() {
  local prompt_file="$1" timeout_secs="$2"
  log "Triggering Codex with $prompt_file (timeout=${timeout_secs}s)"

  touch "$LOCK"

  (
    ARCHIE_PROMPT="$prompt_file" ARCHIE_LOG="$LOG" \
    nohup bash -c \
      "timeout $timeout_secs codex exec \"\$(cat \"\$ARCHIE_PROMPT\")\" \
       >> \"\$ARCHIE_LOG\" 2>&1" &
    echo $! > "$PID_FILE"
  )
}

# ── Archive review file ───────────────────────────────────────────────────────
maybe_archive() {
  local file="$1"
  if [[ -f "$REPO/$file" ]]; then
    local ts; ts=$(date -u +%Y%m%dT%H%M%SZ)
    mkdir -p "$REVIEWS_DIR"
    cp "$REPO/$file" "$REVIEWS_DIR/${file%.md}-${ts}.md"
  fi
}

# ── Git commit helper ─────────────────────────────────────────────────────────
git_commit() {
  local msg="$1"
  cd "$REPO"
  git add -A
  git commit -m "$msg" --quiet
  git push --quiet
}

# =============================================================================
# MAIN
# =============================================================================

log "=== review-loop.sh fired ==="

# Validate state file
[[ -f "$STATE" ]] || die "state file missing"
python3 -m json.tool "$STATE" > /dev/null 2>&1 || die "state file invalid JSON"

STEP=$(get_state currentStep)
PHASE=$(get_state phase)
STATUS=$(get_state status)
ROUND=$(get_state currentRound)

log "State: step=$STEP phase=$PHASE status=$STATUS round=$ROUND"

# ── Section 1: Process flag if present ────────────────────────────────────────

if [[ -f "$FLAG" ]]; then
  log "Flag found."

  # Validate flag
  if ! bash "$VALIDATE" "$FLAG" "$STEP" 2>&1 | tee -a "$LOG" | grep -q "^OK$"; then
    log "FLAG REJECTED: invalid. Deleting."
    rm -f "$FLAG" "$LOCK" "$PID_FILE"
    exit 0
  fi

  FLAG_AGENT=$(python3 -c "import json; d=json.load(open('$FLAG')); print(d['agent'])")
  FLAG_STATUS=$(python3 -c "import json; d=json.load(open('$FLAG')); print(d['status'])")
  FLAG_NEXT=$(python3 -c "import json; d=json.load(open('$FLAG')); print(d['nextAgent'])")

  log "Flag validated: agent=$FLAG_AGENT status=$FLAG_STATUS next=$FLAG_NEXT"

  # Archive relevant review file before state transition
  if [[ "$FLAG_STATUS" == "proposed" || "$FLAG_STATUS" == "reviewed" || "$FLAG_STATUS" == "not-approved" ]]; then
    maybe_archive "ENG_REVIEW_RESPONSE.md"
    maybe_archive "ENG_REVIEW_COMMENTS.md"
  fi

  # Look up transition
  TRANSITION_KEY="${PHASE}:${FLAG_STATUS}"
  if [[ -z "${TRANSITIONS[$TRANSITION_KEY]+x}" ]]; then
    escalate "Unknown transition: phase=$PHASE flag_status=$FLAG_STATUS (step=$STEP round=$ROUND)"
    rm -f "$FLAG"
    exit 1
  fi

  IFS=: read -r NEXT_PHASE NEXT_AGENT PROMPT_TIER <<< "${TRANSITIONS[$TRANSITION_KEY]}"
  log "Transition: $PHASE/$STATUS → $NEXT_PHASE/$FLAG_STATUS → next=$NEXT_AGENT"

  # Handle advance (step complete)
  if [[ "$NEXT_PHASE" == "advance" ]]; then
    log "Step $STEP verified-clean. Advancing."
    NEXT_STEP=$(python3 -c "
import json
with open('$STATE') as f: d = json.load(f)
steps = d.get('stepsComplete', [])
steps.append(d['currentStep'])
d['stepsComplete'] = steps
import json
print(json.dumps(d))" || echo "")
    # Increment step (simple numeric; override for non-numeric steps)
    NEXT_STEP_NUM=$(python3 -c "
step = '$STEP'
try:
    print(str(int(step) + 1))
except:
    print(step + '-done')
")
    update_state "currentStep=$NEXT_STEP_NUM" "phase=propose" "status=starting" "currentRound=1" "activeAgent=claude-code"
    rm -f "$FLAG" "$LOCK" "$PID_FILE"
    git_commit "Review loop: Step $STEP verified-clean → advancing to $NEXT_STEP_NUM"
    log "Advanced to step $NEXT_STEP_NUM. Loop will trigger on next cycle."
    exit 0
  fi

  # Bump round on CR response
  NEW_ROUND=$ROUND
  if [[ "$FLAG_STATUS" == "reviewed" || "$FLAG_STATUS" == "not-approved" ]]; then
    NEW_ROUND=$(( ROUND + 1 ))
  fi

  # Update state
  update_state "phase=$NEXT_PHASE" "status=$FLAG_STATUS" "activeAgent=$NEXT_AGENT" "currentRound=$NEW_ROUND"
  rm -f "$FLAG" "$LOCK" "$PID_FILE"
  git_commit "Review loop: Step $STEP $FLAG_STATUS (round $NEW_ROUND)"
  log "State updated: $NEXT_PHASE/$FLAG_STATUS → next=$NEXT_AGENT round=$NEW_ROUND"

  # Trigger next agent
  PROMPT=$(resolve_prompt "$STEP" "$PROMPT_TIER" "$NEXT_AGENT")
  TIMEOUT=$(phase_timeout "$NEXT_PHASE")
  touch "$LOCK"
  if [[ "$NEXT_AGENT" == "claude-code" ]]; then
    trigger_claude "$PROMPT" "$TIMEOUT"
  elif [[ "$NEXT_AGENT" == "codex" ]]; then
    trigger_codex "$PROMPT" "$TIMEOUT"
  else
    escalate "Unknown next agent: $NEXT_AGENT"
    exit 1
  fi

  log "Next agent triggered. Exiting."
  exit 0
fi

# ── Section 2: No flag — check liveness ───────────────────────────────────────

if [[ -f "$LOCK" ]]; then
  LOCK_AGE=$(( $(date +%s) - $(stat -f %m "$LOCK" 2>/dev/null || stat -c %Y "$LOCK") ))

  # PID-based liveness
  if [[ -f "$PID_FILE" ]]; then
    PID=$(cat "$PID_FILE" 2>/dev/null || echo "")
    if [[ -n "$PID" ]] && kill -0 "$PID" 2>/dev/null; then
      log "Agent alive (PID $PID, lock ${LOCK_AGE}s) — waiting."
      exit 0
    else
      log "Agent dead (PID $PID gone, lock ${LOCK_AGE}s) — clearing and re-triggering."
      rm -f "$LOCK" "$PID_FILE"
      # Fall through to idle trigger below
    fi
  else
    # No PID file — lock-age fallback
    if [[ $LOCK_AGE -lt 2700 ]]; then
      log "Lock ${LOCK_AGE}s old (no PID) — waiting."
      exit 0
    else
      log "Lock stale (${LOCK_AGE}s) — clearing and re-triggering."
      rm -f "$LOCK"
      # Fall through to idle trigger below
    fi
  fi
fi

# ── Section 3: Idle — trigger current state ───────────────────────────────────

log "No flag, no active agent. State: $PHASE/$STATUS — triggering."

TRANSITION_KEY="${PHASE}:${STATUS}"
if [[ -z "${TRANSITIONS[$TRANSITION_KEY]+x}" ]]; then
  escalate "Idle state with no valid transition: phase=$PHASE status=$STATUS step=$STEP"
  exit 1
fi

IFS=: read -r NEXT_PHASE NEXT_AGENT PROMPT_TIER <<< "${TRANSITIONS[$TRANSITION_KEY]}"
PROMPT=$(resolve_prompt "$STEP" "$PROMPT_TIER" "$NEXT_AGENT")
TIMEOUT=$(phase_timeout "$PHASE")

if [[ "$NEXT_AGENT" == "claude-code" ]]; then
  trigger_claude "$PROMPT" "$TIMEOUT"
elif [[ "$NEXT_AGENT" == "codex" ]]; then
  trigger_codex "$PROMPT" "$TIMEOUT"
else
  escalate "Unknown agent for idle trigger: $NEXT_AGENT"
  exit 1
fi

log "Done."
