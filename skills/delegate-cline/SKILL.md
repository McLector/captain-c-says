---
name: delegate-cline
description: Delegate a code review or implementation task to Cline (the user's own coding agent CLI) and evaluate its output before trusting it. Use when the user asks to get something reviewed or implemented by Cline. On-demand only - never invoke without the user asking.
---

# Delegate to Cline

Two modes: **review** (Cline comments, never edits) and **implement** (Cline edits in an isolated worktree, nothing merges automatically).

## Review mode

1. Confirm the target directory is a git repo with a change to review.
2. Run:
   ```
   powershell -File <skill-dir>/scripts/review.ps1 -ProjectDir <path> -Description "<what changed and why>"
   ```
3. Read the printed output. If it says the diff was too large for inline review, do NOT re-run with a bypass - either review a subset of files, or tell the user the diff needs to be split.
4. Evaluate Cline's findings the way you evaluate any code review (per receiving-code-review) - verify before adopting, push back if wrong. Never apply a suggestion from this output automatically.

## Implement mode

1. Confirm the target directory is a git repo (required for `--worktree`).
2. Run:
   ```
   powershell -File <skill-dir>/scripts/implement.ps1 -ProjectDir <path> -TaskDescription "<the task>"
   ```
3. The script prints the full diff of everything Cline did, on an isolated worktree (the resulting commit is usually a detached HEAD, not a branch) - nothing has touched the user's real files.
4. Review that diff yourself before recommending the user merge it. Present it to the user the same way you'd present your own proposed change. Watch for build/verification artifacts (e.g. `__pycache__/*.pyc`) that Cline may include in the diff but shouldn't be merged as-is.
5. Only run the printed `git merge` command if the user agrees to keep the change. Otherwise run the printed `git worktree remove ... --force` command.

## Local model pre-flight (separate from Cline - for the direct-API local delegation path)

Before calling the local model directly:
```
powershell -File <skill-dir>/scripts/preflight-ram.ps1 -ModelSize 3b | ConvertFrom-Json
```
The script prints its result as a single JSON line (not a bare PowerShell
object) - piping the raw `-File` invocation through `ConvertFrom-Json` is
required to get a queryable object back. Capturing the plain object output
without JSON (e.g. `$r = powershell -File ... -ModelSize 3b`) truncates the
`Message` text and loses the object shape entirely, so don't do that.

If `Proceed` is `$false`, show the user the full `Message` and let them decide before continuing - never proceed silently past a warning.

## Constraints

- On-demand only. Offer, never auto-fire.
- Never run `cline auth <provider>` against the user's real `~/.cline` config to test something - it changes their active provider. Use `--data-dir` for isolated testing if a new provider ever needs registering.
- Every cline invocation in these scripts already includes an explicit timeout - do not remove it.
