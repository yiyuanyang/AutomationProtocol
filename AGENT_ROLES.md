# Agent Roles — Explicit Boundaries

## Claude Code (Implementation Engineer)

**Tool:** `claude -p --model claude-sonnet-4-5 --dangerously-skip-permissions`

**Allowed:**
- Read any file in the repo
- Write/edit source files, test files, documentation
- Run `tsc`, `lint`, `test` to validate work
- Write `.agent-status.json` flag when done
- Write `ENG_REVIEW_RESPONSE.md` (proposal or CR response)

**Never:**
- Edit `.review-loop-state.json` directly
- Edit `ENG_REVIEW_COMMENTS.md` (Codex-owned)
- Push to git (loop script handles all commits/pushes)
- Make product-scope decisions without `owner-mandates.json` authorization

## Codex (Engineering Reviewer)

**Tool:** `codex exec`

**Allowed:**
- Read any file in the repo
- Run `tsc`, `lint`, `test`
- Write `ENG_REVIEW_COMMENTS.md`
- Write `.agent-status.json` flag when done

**Never:**
- Edit source files (read-only on implementation)
- Edit `ENG_REVIEW_RESPONSE.md`
- Edit `.review-loop-state.json`
- Raise scope/plan CRs against owner-mandated steps (check `owner-mandates.json` first)

## Orchestrator (Archie / Human)

**Role:** Fix process and state only. Never implement.

**Allowed:**
- Edit any script in `scripts/`
- Edit prompt files in `scripts/prompts/`
- Use `scripts/inject-state.sh` to fix corrupted state (with documented reason)
- Roll back git commits that violate protocol
- Update `owner-mandates.json` per owner direction

**Never:**
- Write or edit source/implementation files
- Write proposals (`ENG_REVIEW_RESPONSE.md`)
- Write reviews (`ENG_REVIEW_COMMENTS.md`)
- Inject approval/verified-clean flags to skip agent work
- Implement CRs directly

## State File Ownership

| File | Owner | Others |
|------|-------|--------|
| `.review-loop-state.json` | Loop script only | Read-only |
| `.agent-status.json` | Active agent | Loop script deletes after reading |
| `ENG_REVIEW_COMMENTS.md` | Codex | Read-only |
| `ENG_REVIEW_RESPONSE.md` | Claude Code | Read-only |
| `owner-mandates.json` | Orchestrator/Owner | Read-only |
| `CODEBASE.md` | Orchestrator | Read-only during active loop |
