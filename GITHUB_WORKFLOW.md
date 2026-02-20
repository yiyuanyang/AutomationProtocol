# AutomationProtocol — GitHub-Native Workflow Design

*Proposed evolution from MD-file reviews to GitHub Issues + PRs*
*Draft: 2026-02-20*

---

## Core Idea

Replace the current review loop (`ENG_REVIEW_COMMENTS.md` ↔ `ENG_REVIEW_RESPONSE.md`) with native GitHub primitives:
- **GitHub Issues** = Step tracking with acceptance criteria as task lists
- **Pull Requests** = Implementation + review
- **PR Comments** = Change requests (CRs) with threaded discussion
- **PR Approval/Rejection** = Review decision
- **Issue/PR State** = Loop state machine

---

## Workflow Overview

### Phase 1: Proposal

```bash
# Script creates GitHub issue for the step
gh issue create \
  --title "Step 22 — Settings Page (Model Selection + API Key)" \
  --body-file scripts/prompts/step-22-issue-template.md \
  --label "step,proposed" \
  --assignee "@me"
```

**Issue body template includes:**
```markdown
## Step 22 — Settings Page

### Acceptance Criteria
- [ ] Model picker UI with Claude + Kimi options
- [ ] Per-provider API key input (Anthropic, Moonshot)
- [ ] Settings persist across sessions
- [ ] Runtime API key override in claude client
- [ ] Full test coverage (mocked, no real API calls)

### Dependencies
- Step 12 (UI framework)
- Step 16 (IPC patterns)

### Quality Gates
- [ ] TypeScript compiles with 0 errors
- [ ] All tests pass (100% or documented exception)
- [ ] ESLint clean
- [ ] No real API calls in tests

---
*This issue tracks Step 22 implementation. Claude Code will create a PR with the proposal.*
```

### Phase 2: Implementation → PR

```bash
# Claude Code: view issue, create branch, implement
gh issue view $ISSUE_NUMBER --json title,body

# Create feature branch
git checkout -b step-22-settings-page

# Implement... then create PR
gh pr create \
  --title "Step 22: Settings Page (Model Selection + API Key)" \
  --body-file PROPOSAL.md \
  --label "step-22,proposal" \
  --reviewer "codex"  # Codex will review
```

**PR body includes:**
```markdown
## Proposal

Closes #XXX (the step issue)

### Design Summary
[Architecture overview]

### Files Changed
- `src/components/settings/SettingsPanel.tsx` — UI
- `electron/settings/store.ts` — persistence
- ...

### Quality Gates
- [x] TypeScript compiles
- [x] Tests pass
- [x] ESLint clean

### Checklist
- [ ] Reviewed by Codex
- [ ] All CRs addressed
- [ ] Ready for merge
```

### Phase 3: Review (Codex)

Codex reviews via PR diff:

```bash
# Codex: fetch PR diff
gh pr diff $PR_NUMBER

# Review with inline comments
cat > review-comments.json << 'EOF'
[
  {
    "path": "electron/settings/store.ts",
    "line": 42,
    "body": "CR-1 (high): API key stored in plaintext. Use electron-store encryption.",
    "side": "RIGHT"
  },
  {
    "path": "src/components/settings/SettingsPanel.tsx",
    "line": 89,
    "body": "CR-2 (medium): Handle Moonshot API errors gracefully.",
    "side": "RIGHT"
  }
]
EOF

gh api repos/{owner}/{repo}/pulls/$PR_NUMBER/comments \
  --input review-comments.json
```

**Codex decision:**
```bash
# If approved:
gh pr review $PR_NUMBER --approve --body "Approved for execution. Quality gates pass."

# If changes needed:
gh pr review $PR_NUMBER --request-changes --body "See inline CRs. Address and re-request."
```

### Phase 4: Address CRs (Claude Code)

```bash
# View unresolved review comments
gh pr view $PR_NUMBER --json reviewDecision,reviewRequests

# Address CRs...
git add .
git commit --amend --no-edit  # Or new commit
git push --force-with-lease

# Re-request review
gh pr ready $PR_NUMBER
```

**Discussion threads auto-resolve** when Claude Code pushes new commits addressing the line.

### Phase 5: Merge = Approval

```bash
# Script detects PR approval
PR_STATUS=$(gh pr view $PR_NUMBER --json reviewDecision -q '.reviewDecision')

if [[ "$PR_STATUS" == "APPROVED" ]]; then
  # Update issue: mark acceptance criteria checkboxes
  gh issue edit $ISSUE_NUMBER --body-file updated-with-checkboxes.md
  
  # Merge PR
  gh pr merge $PR_NUMBER --squash --subject "Step 22: Settings Page"
  
  # Close issue (or move to Phase 2: Execution)
  gh issue close $ISSUE_NUMBER --comment "Phase 1 approved. Moving to execution."
fi
```

### Phase 6: Execution

Same flow, but issue/PR labels change:
- Issue label: `phase:execute` (was `phase:propose`)
- PR title: "Step 22: Settings Page (Implementation)"
- Codex reviews the actual code diff, not proposal

---

## Automation Mapping

| Current State | GitHub Equivalent |
|---------------|-------------------|
| `.review-loop-state.json` | GitHub Issue state + labels |
| `currentStep: "22"` | Issue title contains "Step 22" |
| `phase: propose` | Issue label `phase:propose` |
| `phase: review` | PR open, awaiting review |
| `phase: execute` | Issue label `phase:execute` + new PR |
| `status: proposed` | PR created, not yet reviewed |
| `status: approved` | PR approved by Codex |
| `status: reviewed` | PR has requested changes |
| `ENG_REVIEW_COMMENTS.md` | PR review comments (inline) |
| `ENG_REVIEW_RESPONSE.md` | PR description + commit messages |
| Archive to `reviews/` | PR history + issue timeline |

---

## API Capabilities Checklist

| Feature | GitHub CLI | GitHub REST API | Notes |
|---------|-----------|-----------------|-------|
| Create issue with task list | ✅ `gh issue create` | ✅ | Body includes `- [ ]` syntax |
| Update issue checkboxes | ✅ `gh issue edit` | ✅ | Edit body to toggle `[x]` |
| Create PR | ✅ `gh pr create` | ✅ | |
| Get PR diff | ✅ `gh pr diff` | ✅ `diff` media type | |
| Post review comments | ✅ `gh pr review` | ✅ | Inline comments on specific lines |
| Approve/request changes | ✅ `gh pr review --approve` | ✅ | |
| Check review status | ✅ `gh pr view --json reviewDecision` | ✅ | |
| Re-request review | ✅ `gh pr ready` | ✅ | |
| Merge PR | ✅ `gh pr merge` | ✅ | Squash or regular merge |
| Close issue | ✅ `gh issue close` | ✅ | With comment |
| List PR comments | ✅ `gh pr view --comments` | ✅ | For Codex to read feedback |

**All required operations are supported.**

---

## Advantages Over Current Model

### 1. **Native CR Resolution**
PR comments auto-resolve when the line they reference changes. No manual `Status: resolved` tracking.

### 2. **Diff-Based Review**
Codex sees `git diff`, not full file contents. Review scope is naturally isolated to what changed.

### 3. **Threaded Discussion**
Each CR can have back-and-forth on the specific line, not flat MD files.

### 4. **Visual Quality Gates**
Issue checkboxes show at-a-glance what's done vs pending.

### 5. **No CR Accumulation**
Resolved comments disappear from "unresolved" view. Only active feedback remains visible.

### 6. **Built-in State Machine**
Issue open/closed + PR open/merged/review status tracks loop state without custom files.

### 7. **Human-Friendly UI**
Steve can open GitHub and see the same state the agents see.

---

## Implementation Considerations

### Authentication
```bash
# GitHub CLI needs auth
git config --global credential.helper osxkeychain
gh auth login --web
```

### Rate Limiting
- GitHub API: 5000 requests/hour
- Our usage: ~50 requests per full loop cycle
- Well within limits

### Error Handling
```bash
# Wrap gh commands with retry logic
gh_with_retry() {
  local retries=3
  while [[ $retries -gt 0 ]]; do
    gh "$@" && return 0
    retries=$((retries - 1))
    sleep 5
  done
  log "ERROR: gh command failed after retries"
  return 1
}
```

### Migration from Current System
1. Create GitHub issues for current step and pending steps
2. Port active `ENG_REVIEW_COMMENTS.md` to PR comments (one-time)
3. Archive old MD files to `reviews/legacy/`
4. Switch script to GitHub-native commands

---

## Open Questions

1. **Private repo considerations?** (All operations work on private repos with proper auth)
2. **Branch protection rules?** (Can enforce "requires review" before merge)
3. **Multiple steps in flight?** (Each step = separate issue + PR, works fine)

---

## Recommendation

**Yes, implement this.** The GitHub-native workflow is superior to the MD-file protocol in every dimension:
- Better UX for humans and agents
- Built-in CR resolution
- Diff-based review
- No accumulation problems
- Industry-standard workflow

The transition is straightforward since all required APIs are available.

---

*Draft: 2026-02-20*
*See also: [[AutomationProtocol — Architecture Vision]], [[AutomationProtocol — Guardrails Proposal]]*
