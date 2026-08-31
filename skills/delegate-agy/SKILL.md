---
name: delegate-agy
description: Delegate a code review or implementation task to Agy (Antigravity, the user's own coding agent CLI) and evaluate its output before trusting it. Use when the user asks to get something reviewed or implemented by Agy. On-demand only - never invoke without the user asking.
---

# Delegate to Agy

Two modes: **review** (Agy comments, never edits) and **implement** (Agy edits in a worktree this skill creates and manages itself, nothing merges automatically).

Agy has no local/on-device model option - every call sends content to Agy's hosted (Google) backend. Always tell the user this before sending.

## Review mode

1. Confirm the target directory is a git repo root (not a subdirectory of one) with a change to review.
2. Run:
   ```
   powershell -File <skill-dir>/scripts/review.ps1 -ProjectDir <path> -Description "<what changed and why>"
   ```
3. Read the printed output. If it says the diff was too large for inline review, do NOT re-run with a bypass - either review a subset of files, or tell the user the diff needs to be split. In practice an oversized diff falls back to a summary-only prompt that makes Agy reach for a tool headless mode auto-denies, so `review.ps1` fails outright (red `FAILED`, exit 1) rather than returning a partial/chunked review - expect that hard failure and treat it as a signal to review a smaller sub-scope, not as a script bug.
4. Evaluate Agy's findings the way you evaluate any code review (per receiving-code-review) - verify before adopting, push back if wrong. Never apply a suggestion from this output automatically.
5. Optionally pass `-Model <model-id>` to pick a specific Agy-hosted model (Gemini 3.x tiers, Claude 4.6, or the open `gpt-oss-120b`) instead of Agy's default.

## Implement mode

1. Confirm the target directory is a git repo root (not a subdirectory of one).
2. Run:
   ```
   powershell -File <skill-dir>/scripts/implement.ps1 -ProjectDir <path> -TaskDescription "<the task>"
   ```
3. Unlike Cline (which creates its own isolated worktree), this script creates and manages the worktree itself under `%TEMP%\agy-worktrees\`. On success, it prints the full diff of everything Agy did there - nothing has touched the user's real files. It does not always reach that point: if the diff against the base branch is empty (Agy reported completion but changed nothing), or if a failure occurs after the worktree was created (e.g. a failed `git add`/`commit` in the worktree, or no resolvable base commit), the script prints no diff and no merge command - only worktree/branch discard instructions, since there is nothing to merge.
4. When a diff is printed, review it yourself before recommending the user merge it. Present it to the user the same way you'd present your own proposed change. Watch for build/verification artifacts that shouldn't be merged as-is.
5. When there is a diff, run the printed `git merge` command only if the user agrees to keep the change, then run the printed post-merge cleanup commands (worktree remove, then branch delete) afterward. Otherwise - including on any path where no diff was printed - run the printed discard commands, which remove both the worktree and its branch.

## Constraints

- On-demand only. Offer, never auto-fire.
- Every agy invocation in these scripts already includes an explicit `--print-timeout` - do not remove it.
- baicode (a third CLI target) is not part of this skill - it was scoped out during development (blocked on an account/billing issue with its hosted default model, not a code problem) and never implemented here.
