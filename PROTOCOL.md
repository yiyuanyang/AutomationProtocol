# Agent Coding Protocol

This document defines the rules for the AI build loop. All agents and orchestrators must follow it.

---

## 1. State Machine

The loop has one current step and moves through these phases in order:

```
propose → review → execute → verify → [advance to next step]
```

Valid transitions (script-enforced — any other transition triggers escalation):

| Current Phase | Flag Status | Next Phase | Next Agent |
|--------------|-------------|------------|------------|
| propose | proposed | review | codex |
| review | approved | execute | claude-code |
| review | reviewed (CRs) | review | claude-code |
| execute | executed | verify | codex |
| verify | verified-clean | advance | — |
| verify | reviewed (CRs) | verify | claude-code |

**No agent may write `.review-loop-state.json` directly.** All transitions go through the loop script.

---

## 2. Flag Protocol

When an agent completes its work it writes `.agent-status.json`:

```json
{
  "agent": "claude-code",
  "step": "5",
  "status": "proposed",
  "nextAgent": "codex",
  "timestamp": "2026-01-01T00:00:00Z"
}
```

**Flag validation (script-enforced):**
- All fields required
- `step` must match `currentStep` in state file
- `timestamp` must be within the last 30 minutes (stale flag = rejected)
- `status` must be valid for current phase
- `nextAgent` must be `claude-code` or `codex`

Rejected flags are deleted. Repeated rejections trigger escalation.

---

## 3. Owner Mandates

`owner-mandates.json` lists steps that are explicitly directed by the project owner:

```json
{
  "mandatedSteps": ["6.5", "11b"],
  "mandatedDecisions": [...]
}
```

**If a step is mandated:**
- Codex must NOT raise scope or plan-alignment CRs
- Technical correctness, safety, and test coverage CRs remain valid
- Claude Code must NOT defer or reinterpret the scope

Any agent that defers, skips, or redefines an owner-mandated step is in protocol violation.

---

## 4. Review Files

| File | Author | Format |
|------|--------|--------|
| `ENG_REVIEW_RESPONSE.md` | Claude Code | Proposal or CR response |
| `ENG_REVIEW_COMMENTS.md` | Codex | CRs in standard format |

**Before writing:** archive the previous version to `reviews/` with a timestamp suffix.

**CR format:**
```markdown
### CR-NNN: <title>
- **ID**: CR-NNN
- **Round**: N
- **Severity**: critical | high | medium | low
- **Category**: correctness | reliability | security | quality | test-coverage
- **File(s)**: path:line
- **Status**: open

<description and proposed fix>
```

---

## 5. CODEBASE.md

Every repo using this protocol must maintain `CODEBASE.md`:
- File map with key sections and line numbers
- Event/API catalog
- Per-step location index ("Step X touches file.ts:100-150")

**Agents must read `CODEBASE.md` before reading any source file.** Use the line numbers to target reads — never read a full large file from scratch.

---

## 6. Commits and Pushes

Only the loop script commits and pushes. Agents write files but do not run git.

Commit message format: `Review loop: Step <N> <action>`

---

## 7. Escalation

The script escalates (messages the owner) when:
- State is in an unknown/invalid transition
- Agent flag is rejected 3+ times in a row
- Lock is stale > 45 min with no active process
- Any agent directly modifies `.review-loop-state.json`
- `ENG_REVIEW_COMMENTS.md` is written by a non-Codex author

---

## 8. Quality Gates (per execution)

Before writing an `executed` flag, Claude Code must pass:
1. `tsc --noEmit` — 0 errors
2. `npm run lint` (or equivalent) — 0 errors
3. `npm test` (or equivalent) — all tests pass, no regressions

Codex must re-run these before writing `verified-clean`.
