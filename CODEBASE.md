# CODEBASE.md — Agent Reference Index (Template)

> **Instructions:** Fill this out before starting the build loop. Keep it updated as files are added or refactored. Agents read this before touching any source file — it replaces exploratory grep/read passes.

Last updated: <!-- date -->

---

## File Map

<!-- For each significant file, list: path, line count, purpose, key sections with line numbers -->

### `src/example/core.ts` (NNN lines)
Brief description of what this file does.

Key sections:
- **Lines 1–50**: Imports, types, constants
- **Lines 51–150**: Main class / primary export
- **Lines 151–200**: Helper utilities

Key exports: `MainClass`, `helperFn`

---

## Key Patterns

<!-- Document recurring patterns agents need to know -->

### Error handling pattern
```ts
// example
```

### Dependency injection pattern
```ts
// example
```

---

## API / Event Catalog

<!-- List all events, IPC channels, or API endpoints -->

| Name | Payload | Description |
|------|---------|-------------|
| `example:event` | `{ id: string }` | Fires when X happens |

---

## Step Index

<!-- For each remaining step, list exact file+line ranges to read -->

### Step N — <Step Name>
**Files:** `src/file.ts:100-150`, `src/other.ts:20-40`

What to look for: brief description of what the agent needs to find

---

## Prompt Guidance

**Do:** Read this file first. Use line offsets (`Read file_path offset=N limit=50`) to target reads.

**Don't:** Read entire large files. Use the line numbers above.

**For proposals:** The audit in this file is ground truth. Don't re-run grep sweeps to confirm what's listed here.
