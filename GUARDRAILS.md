# AutomationProtocol — Guardrails Proposal

*Based on lessons from TheResearcher multi-agent build loop, 2026-02-19/20*
*For: AutomationProtocol repo — reusable patterns without a specific project*

---

## Design Principle

> **The script enforces invariants. The model executes tasks.**

Every failure we've hit came from the model making a decision that the script should have caught or prevented. Guardrails are not model instructions — they are code that runs before and after every agent call, validates inputs and outputs, and rejects anything that doesn't conform to schema.

The goal is **resilience to unexpected inputs**: step names with suffixes, missing fields, empty files, non-standard status strings, accumulated session context. None of these should cause silent failures or model hallucination. They should fail loud, early, and with a clear error message.

---

## G1 — Status Enum Validation (script-enforced)

**Problem:** Status values are freeform strings. `"reviewed"`, `"reviewed-step-11b"`, `"starting-step-20"`, `"verified-clean"` are all distinct strings with no enforcement. Any typo, suffix variation, or novel value causes silent routing failures.

**Proposal:**

Define a canonical status enum at the top of `review-loop.sh`:

```bash
VALID_STATUSES=(
  proposed revised
  approved revision-approved
  executed
  reviewed not-approved conditional needs-revision
  verified-clean verified
  starting-step-N  # templated, matched by prefix
)
```

After reading any flag or state file, validate the status field:

```bash
validate_status() {
  local s="$1"
  case "$s" in
    proposed|revised|approved|revision-approved|executed|reviewed|not-approved|conditional|needs-revision|verified-clean|verified|starting-step-*) return 0 ;;
    *) log "INVALID STATUS: '$s' is not a recognized value — rejecting"; return 1 ;;
  esac
}
```

Call this whenever status is read from a flag or state file. Reject anything outside the enum.

---

## G2 — Step Name Format Validation

**Problem:** Step names like `"11b"`, `"6.5"`, `"20"` are parsed differently in different places. `cut -d. -f1` on `"11b"` returns `"11b"`. `--argjson cs "11b"` fails jq. These are not caught until runtime.

**Proposal:**

Define a canonical step name format regex: `^[0-9]+(\.[0-9]+)?[a-z]?$`

Validate at the top of the script:

```bash
validate_step_name() {
  local step="$1"
  if ! echo "$step" | grep -qE '^[0-9]+(\.[0-9]+)?[a-z]?$'; then
    log "INVALID STEP NAME: '$step' — must match ^[0-9]+(\\.[0-9]+)?[a-z]?\$"
    return 1
  fi
}

# Safe integer extraction (works for "11b", "6.5", "20")
step_to_int() {
  echo "$1" | grep -o '^[0-9]*'
}
```

Use `step_to_int` everywhere an integer is needed. Never use `cut` or `awk` for step name parsing without first validating format.

---

## G3 — Routing Completeness Check

**Problem:** The `claude-code` routing block had no `reviewed → cr-fix` case. This was invisible — the script ran fine, just routed to the wrong prompt. There was no test or assertion that all status values had a handler.

**Proposal:**

Add a routing self-test function that runs on script startup:

```bash
assert_routing_coverage() {
  # For each known status, assert a routing case exists
  local statuses=("proposed" "revised" "approved" "revision-approved" "executed" "reviewed" "not-approved" "verified-clean")
  for s in "${statuses[@]}"; do
    # Dry-run the routing logic with this status
    local tag
    tag=$(resolve_phase_tag "$s")
    if [[ -z "$tag" ]]; then
      log "ROUTING GAP: status '$s' has no routing handler — fix review-loop.sh before running"
      exit 1
    fi
  done
}
```

Or more practically: extract the routing table to a dedicated `resolve_phase_tag()` function and unit-test it separately in a `test-routing.sh` script.

---

## G4 — Flag Schema Validation (pre-processing)

**Problem:** Agents can write `.agent-status.json` with missing or wrong fields. The script does some validation but not enough — it checks required keys exist but doesn't validate types or enum membership.

**Proposal:**

Extend `validate_flag()` to:
1. Check all required fields present (already done)
2. Validate `status` against enum (G1)
3. Validate `step` matches step name format (G2)
4. Validate `nextAgent` is one of `claude-code`, `codex`, `advance`, `archie`
5. Validate `timestamp` is a parseable ISO-8601 string
6. Validate `agent` matches the expected active agent from state (prevents rogue flags)

```bash
validate_flag_schema() {
  local flag="$1"
  local status step next_agent agent timestamp
  status=$(jq -r '.status' "$flag")
  step=$(jq -r '.step' "$flag")
  next_agent=$(jq -r '.nextAgent' "$flag")
  agent=$(jq -r '.agent' "$flag")
  timestamp=$(jq -r '.timestamp' "$flag")

  validate_status "$status" || return 1
  validate_step_name "$step" || return 1

  case "$next_agent" in
    claude-code|codex|advance|archie) ;;
    *) log "FLAG INVALID: unknown nextAgent '$next_agent'"; return 1 ;;
  esac

  # Validate ISO timestamp (basic check)
  echo "$timestamp" | grep -qE '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$' || {
    log "FLAG INVALID: bad timestamp '$timestamp'"; return 1
  }
}
```

---

## G5 — Watchdog Session Age Reset

**Problem:** Kimi's isolated session accumulates context across cron runs. After ~100k tokens of history, it starts hallucinating routing rules from its own prior outputs.

**Proposal:**

**Option A (simple):** Add a token count check to the watchdog. If session token count exceeds threshold (e.g., 80k), recreate the cron job (which drops the old session).

**Option B (structural):** Use `sessionTarget: "isolated"` with a per-run session key that includes a timestamp or run counter, forcing a fresh session every N runs.

**Option C (prompt-level):** Add to the watchdog prompt: *"You have N prior turns in context. Ignore all prior turns. The ONLY source of truth is the files on disk."* — this is already partially done but insufficient on its own.

**Recommended:** Option B (structural). Session isolation should be true isolation — each cron run gets a blank-slate model. The state files provide continuity, not session memory.

---

## G6 — Generic CR-Fix Prompt (never hardcode CRs)

**Problem:** The cr-fix prompt was written once for specific CRs and not updated when new CRs appeared. Claude Code was given conflicting guidance (prompt said "fix CR-180" but review comments had CR-181/182).

**Proposal:**

The cr-fix prompt template should be static and CR-agnostic:

```markdown
# Step N — CR Fix

You are Claude Code. Codex has reviewed the execution and found open CRs.

1. Read `ENG_REVIEW_COMMENTS.md` — this is the authoritative list of open issues.
2. Fix every CR marked `Status: open`. Do not fix CRs marked `Status: resolved`.
3. Follow Codex's proposed fix exactly where one is given. If no fix is given, use your judgment.
4. Run: npx tsc --noEmit && npx vitest run && npm run lint
5. All must pass before committing.
6. Commit: `git add -A && git commit -m "Review loop: Step N Round R — address CRs"`
7. Write flag: `{"agent":"claude-code","step":"N","status":"executed","nextAgent":"codex",...}`

Do not write the flag if tests or tsc fail.
```

The specific CRs, descriptions, and proposed fixes live in `ENG_REVIEW_COMMENTS.md` — written by Codex. The cr-fix prompt is an execution harness, not a knowledge document.

---

## G7 — Advance Pre-Flight Validation

**Problem:** The advance block runs `safe_state_update` which can fail silently (jq errors from invalid argjson input). The state gets stuck mid-advance with no recovery path.

**Proposal:**

Before running `safe_state_update` in the advance block:

```bash
advance_preflight() {
  local current_step="$1"
  local next_step="$2"

  # Validate current step format
  validate_step_name "$current_step" || return 1

  # Validate next step is a valid step number
  validate_step_name "$next_step" || return 1

  # Validate step_to_int works correctly
  local int_val
  int_val=$(step_to_int "$current_step")
  if [[ -z "$int_val" ]]; then
    log "ADVANCE PREFLIGHT FAIL: could not extract integer from step '$current_step'"
    return 1
  fi

  # Validate pending-steps.json if present
  local pending_file="$REPO/scripts/pending-steps.json"
  if [[ -f "$pending_file" ]]; then
    jq -e '.steps | type == "array"' "$pending_file" > /dev/null 2>&1 || {
      log "ADVANCE PREFLIGHT FAIL: pending-steps.json is malformed"
      return 1
    }
  fi

  return 0
}
```

Fail loud with a clear error before any state mutation.

---

## G8 — Smoke Test Script

**Problem:** Script bugs (routing gaps, parsing failures, invalid jq) are invisible until they trigger at runtime. By then, state may already be corrupted.

**Proposal:**

Create `scripts/test-loop.sh` — a dry-run validation suite:

```bash
#!/bin/bash
# Smoke test for review-loop.sh invariants

source scripts/review-loop-lib.sh  # extract pure functions to a sourced lib

echo "Testing status validation..."
for s in proposed reviewed approved executed verified-clean; do
  validate_status "$s" || { echo "FAIL: '$s' should be valid"; exit 1; }
done
validate_status "bad-value" && { echo "FAIL: 'bad-value' should be invalid"; exit 1; }

echo "Testing step name parsing..."
assert_eq "$(step_to_int '11b')" "11"
assert_eq "$(step_to_int '6.5')" "6"
assert_eq "$(step_to_int '20')" "20"

echo "Testing routing coverage..."
assert_routing_coverage

echo "All checks passed."
```

Run in CI (if present) and before any script change is committed.

---

## Summary Table

| Guardrail | What it catches | When |
|-----------|----------------|------|
| G1 — Status enum | Typos, novel status values, routing ambiguity | Flag/state read |
| G2 — Step format | Suffix parsing failures, jq argjson crashes | Step name used anywhere |
| G3 — Routing completeness | Missing branches in claude-code routing | Script startup / CI |
| G4 — Flag schema | Missing fields, bad types, rogue agent flags | Flag pickup |
| G5 — Session age reset | Watchdog context drift, hallucinated rules | Cron design |
| G6 — Generic cr-fix prompt | Stale CR IDs, conflicting guidance | Prompt authoring |
| G7 — Advance pre-flight | State stuck mid-advance, silent jq failures | Before advance runs |
| G8 — Smoke test | Script regressions caught before runtime | Pre-commit / CI |

---

*Written: 2026-02-20 by Archie*
*Related: [[Automation Issues & Hardening]]*
