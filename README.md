# AutomationProtocol

A reusable, project-agnostic AI build loop for shipping software with Claude Code (implementation) and Codex (review), orchestrated entirely by deterministic shell scripts.

## Core Thesis

> The loop is deterministic machinery. AI agents are workers, not orchestrators.

Every routing decision, state transition, and validation is made by scripts. Models execute bounded tasks (write a proposal, review code, fix CRs) and write a flag when done. Scripts read flags and advance state. No AI judgment in the control path.

## Quick Start

1. Copy this repo into your project (or use as a submodule)
2. Fill out `CODEBASE.md` with your project's file map
3. Write your step descriptions into `EXECUTION_PLAN.md`
4. Set up the bash watchdog cron (see `scripts/bash-watchdog.sh`)
5. Start the loop: `bash scripts/review-loop.sh`

## Agent Roles

| Agent | Tool | Role |
|-------|------|------|
| **Claude Code** | `claude -p` | Proposes designs, writes code, fixes CRs |
| **Codex** | `codex exec` | Reviews proposals, verifies implementations |
| **Archie / Orchestrator** | You or OpenClaw | Fixes process/state only — never implements |

See `AGENT_ROLES.md` for explicit boundaries.

## Loop Flow

```
[propose] → Claude Code writes proposal → flag(proposed)
[review]  → Codex reviews proposal     → flag(approved | reviewed+CRs)
           ↳ if reviewed: Claude Code addresses CRs → loop
[execute] → Claude Code implements     → flag(executed)
[verify]  → Codex verifies + tests     → flag(verified-clean | reviewed+CRs)
           ↳ if reviewed: Claude Code fixes CRs → loop
[advance] → Script advances to next step
```

## Key Design Decisions

- **Bash watchdog, not AI watchdog** — eliminates session-context hallucination
- **PID tracking** — instant liveness detection, no lock-age guessing
- **Hard timeouts** — agents are killed after phase-appropriate limits
- **Strict flag validation** — schema check, timestamp freshness, step match
- **State machine table** — all transitions explicit in script, unknown states escalate
- **Fresh agents** — every invocation is a new `claude -p` / `codex exec` process
- **CODEBASE.md** — agents read the index first; no full-file exploration
