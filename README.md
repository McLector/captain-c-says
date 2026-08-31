# Captain C Says

Claude Code skills that delegate code review and implementation work to other coding-agent CLIs — Claude Code stays the orchestrator you talk to, while these skills hand off concrete work to a second tool and evaluate what comes back before trusting it.

Two skills are included, one per target CLI:

| Skill | Target | Modes |
|---|---|---|
| [`delegate-cline`](skills/delegate-cline) | [Cline](https://cline.bot) CLI | review, implement |
| [`delegate-agy`](skills/delegate-agy) | Agy ([Antigravity](https://antigravity.google)) CLI | review, implement |

## What they do

Both skills work the same way:

- **Review mode** — sends your diff to the target CLI for comments. It never edits anything; Claude Code evaluates the findings like any other code review before adopting them.
- **Implement mode** — hands the target CLI a task description. It makes real edits, but always in an isolated git worktree. Nothing merges automatically: you get the full diff and copy-pasteable commands to either merge it or discard the worktree.

Both are **on-demand only** — Claude Code will offer to delegate, but never fires either skill without you asking first.

Both scripts are defended against the same failure class: a target CLI reporting success while silently doing nothing (an empty response, an empty diff, or a diff that can't be resolved against a real base commit) is always treated as a failure, never presented as a completed task.

## Requirements

- [Claude Code](https://claude.com/claude-code) (or another agent harness that reads Claude Code-style skills)
- Windows + PowerShell (the scripts are `.ps1` — no other platform is supported yet)
- The relevant CLI installed and authenticated:
  - [`cline`](https://github.com/cline/cline) for `delegate-cline`
  - `agy` for `delegate-agy` (no local/on-device model option — every call sends content to Agy's hosted Google backend; the skill discloses this before every send)

## Install

Copy (or symlink) whichever skill(s) you want into your Claude Code skills directory:

```powershell
Copy-Item -Recurse skills\delegate-cline $HOME\.claude\skills\delegate-cline
Copy-Item -Recurse skills\delegate-agy   $HOME\.claude\skills\delegate-agy
```

Claude Code picks up skills from `~/.claude/skills/` automatically — restart your session if it was already running.

## Usage

Just ask, in any project:

- *"Get this diff reviewed by Cline"*
- *"Have Agy implement this function"*

Claude Code reads the relevant `SKILL.md`, runs the matching script, and walks you through what came back.

## Design notes

- Every prompt/description sent to a target CLI is passed as a PowerShell argument-array element (never interpolated into a single command string), with Windows-argv quote-escaping applied — a naive `.Replace('"', '\"')` is not enough on Windows and will corrupt embedded quotes.
- Implement mode never touches your real working tree directly. `cline`'s own `--worktree` flag handles isolation for `delegate-cline`; `agy` has no equivalent flag, so `delegate-agy`'s `implement.ps1` creates and manages its own worktree.
- Both skills refuse to print a diff or merge instructions when the base commit can't be resolved, or when the resulting diff is empty — silent no-ops are always surfaced as failures.

## License

[MIT](LICENSE)
