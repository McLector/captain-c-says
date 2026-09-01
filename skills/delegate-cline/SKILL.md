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
4. Evaluate Cline's findings the way you evaluate any code review (per receiving-code-review) - verify before adopting, push back if wrong. Never apply a suggestion from this output automatically. Also check whether the review looks truncated or incomplete relative to the diff it was given, not only whether it's non-empty - cline has no confirmed token-usage signal, so this is a judgment call, not something the script can catch for you.
5. Every run of `review.ps1` appends one line to `~/.claude/delegation-log/events.jsonl`. While reading the output in steps 3-4, glance at that line and confirm it's consistent with what you actually saw (outcome/guard match the real result) - flag a mismatch immediately rather than trusting the log blindly.

## Implement mode

1. Confirm the target directory is a git repo (required for `--worktree`).
2. Run:
   ```
   powershell -File <skill-dir>/scripts/implement.ps1 -ProjectDir <path> -TaskDescription "<the task>"
   ```
3. The script prints the full diff of everything Cline did, on an isolated worktree (the resulting commit is usually a detached HEAD, not a branch) - nothing has touched the user's real files.
4. Review that diff yourself before recommending the user merge it. Present it to the user the same way you'd present your own proposed change. Watch for build/verification artifacts (e.g. `__pycache__/*.pyc`) that Cline may include in the diff but shouldn't be merged as-is, and for signs the task was left incomplete or truncated partway through - cline has no confirmed token-usage signal, so this is a judgment call, not something the script enforces.
5. Only run the printed `git merge` command if the user agrees to keep the change. Otherwise run the printed `git worktree remove ... --force` command.
6. Every run of `implement.ps1` appends one line to `~/.claude/delegation-log/events.jsonl`. While reviewing the diff in step 4, glance at that line and confirm it's consistent with what you actually saw - flag a mismatch immediately rather than trusting the log blindly.

## Local model (direct API, no CLI middleman - separate from Cline)

The local Ollama path bypasses `cline` entirely - it's a direct HTTP call
to Ollama, invoked through three scripts:

1. RAM preflight:
   ```
   powershell -File <skill-dir>/scripts/preflight-ram.ps1 -ModelSize 3b -ProjectDir <path> | ConvertFrom-Json
   ```
2. Token-budget preflight (put the prompt text in a temp file first - never pass it as a CLI argument):
   ```
   powershell -File <skill-dir>/scripts/preflight-tokens.ps1 -PromptFile <path> -ModelSize 3b -ProjectDir <path> | ConvertFrom-Json
   ```
   Both preflights print their result as a single JSON line (not a bare
   PowerShell object) - piping the raw `-File` invocation through
   `ConvertFrom-Json` is required to get a queryable object back. Capturing
   the plain object output without JSON truncates the `Message` text and
   loses the object shape entirely, so don't do that.

   If either preflight's `Proceed` is `$false`, show the user the full
   `Message` and let them decide before continuing - never proceed
   silently past a warning, and never auto-switch model size or target on
   your own.

3. Only once both preflights say `Proceed: true` (or the user explicitly
   overrides), make the actual call:
   ```
   powershell -File <skill-dir>/scripts/invoke-ollama.ps1 -PromptFile <path> -ModelSize 3b -ProjectDir <path> | ConvertFrom-Json
   ```
   This script checks the response's `done_reason` for you: `"length"`
   means the response was cut off partway through, and the script already
   treats that as a failure (`Success: false`) - never presented as a
   usable result. This is a hard, code-enforced check, unlike cline/agy
   where truncation can only be judged by hand.

Every one of these three scripts appends one line to
`~/.claude/delegation-log/events.jsonl`, including on a preflight block or
a truncation failure - not only on success.

## Log audit

When the user asks to check the delegation log
(`~/.claude/delegation-log/events.jsonl`), read the recent lines and check
for: a line that isn't valid JSON (this project has hit real
encoding/quote-escaping bugs before, so a corrupted line is a real
possibility, not hypothetical); a line missing an expected field;
timestamps out of order; and a target repeatedly hitting the same guard,
which is worth surfacing as a pattern even if each individual line looks
fine. Don't try to re-verify old entries against git state - a finished
or discarded task's worktree is usually already gone by the time an audit
is requested, so this is about the log's own integrity, not re-litigating
history that's no longer inspectable.

This file is append-only and self-recreates on next use if missing - never
delete it, truncate it, or treat it as disposable test output while
verifying a change to these scripts.

## Constraints

- On-demand only. Offer, never auto-fire.
- Never run `cline auth <provider>` against the user's real `~/.cline` config to test something - it changes their active provider. Use `--data-dir` for isolated testing if a new provider ever needs registering.
- Every cline invocation in these scripts already includes an explicit timeout - do not remove it.
