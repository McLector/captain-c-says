param(
    [Parameter(Mandatory)]
    [string]$ProjectDir,

    [Parameter(Mandatory)]
    [string]$TaskDescription,

    [int]$TimeoutSeconds = 300
)

$ErrorActionPreference = 'Stop'

. "$PSScriptRoot\parse-cline-json.ps1"
. "$PSScriptRoot\log-event.ps1"
$stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
$clineIncomplete = $false

# VERIFIED 2026-08-31 (final fix wave, Finding 4): under
# $ErrorActionPreference = 'Stop', a native command's stderr output is wrapped
# into a terminating NativeCommandError - `git rev-parse` on a non-repo writes
# to stderr, so this crashed with a raw PowerShell stack trace BEFORE the
# intended `if ($LASTEXITCODE -ne 0)` check below was ever reached, even with
# `2>$null` present (redirecting stderr doesn't stop PowerShell from treating
# the underlying error record as terminating). Confirmed live by running this
# probe against a non-git directory: it threw instead of printing the intended
# message. Scoping $ErrorActionPreference to 'Continue' for just this call lets
# the LASTEXITCODE check below actually run.
$prevEAP = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
$null = & git -C $ProjectDir rev-parse --is-inside-work-tree 2>$null
$ErrorActionPreference = $prevEAP
if ($LASTEXITCODE -ne 0) {
    Write-Error "ProjectDir '$ProjectDir' is not a git repository - --worktree requires a git repo."
    exit 1
}

$providersPath = "$HOME\.cline\data\settings\providers.json"
$activeProvider = "unknown"
if (Test-Path $providersPath) {
    $activeProvider = (Get-Content $providersPath -Raw | ConvertFrom-Json).lastUsedProvider
}
Write-Host "This task will be sent to cline's active provider ('$activeProvider') and will make real file edits in an isolated worktree - your real files are not touched." -ForegroundColor Yellow

# NOTE: Windows PowerShell 5.1's native-command argument marshalling mishandles
# embedded double quotes when a splatted array is passed to `cline` (an
# npm-generated .ps1 shim that re-splats its own $args into a nested `node`
# invocation). Unescaped quotes shift the command-line quoting boundaries and
# either get silently dropped or cause the single prompt argument to fragment
# into multiple argv tokens (cline then errors with "Unknown command or
# unquoted prompt"). Escaping embedded quotes keeps the prompt intact as one
# argument. Confirmed by live testing against this machine's installed cline
# 3.0.60 CLI (see task-2-report.md / review.ps1); $TaskDescription is a free-form
# string here too, so it carries the same risk if it happens to contain a `"`.
#
# VERIFIED 2026-08-31 (final fix wave, Finding 1): the naive
# `.Replace('"', '\"')` only escapes the quote itself and does NOT double any
# backslashes already immediately preceding it (CommandLineToArgvW rule: N
# backslashes immediately before a quote must become 2N+1 backslashes to
# preserve N literal backslashes plus one literal quote through parsing). This
# same bug affects both the `cline` call AND the `git commit -m` call below,
# which reuses $promptText. Reproduced and fixed identically to review.ps1 -
# see that file for the live round-trip test via a node echo-argv harness
# (confirmed `--json`/`-t`/`300` survive as separate argv tokens after this
# escaping, where the naive version collapsed them into the prompt token).
$promptText = ($TaskDescription -replace '(\\*)"', '$1$1\"') -replace '(\\+)$', '$1$1'

$outFile = Join-Path $env:TEMP "cline-implement-$(Get-Date -Format 'yyyyMMddHHmmss').json"
$argsList = @($promptText, '--json', '-c', $ProjectDir, '--worktree', '--auto-approve', 'true', '-t', $TimeoutSeconds)

# VERIFIED 2026-08-31 (final fix wave, Finding 3): replaces the previous
# regex-based search over the raw --json output for a
# `...\.cline\worktrees\...` path. That regex needed two live-debugged
# corrections during Task 4 (missing path segment, JSON-doubled backslashes)
# and still had two known weaknesses: no trailing boundary assertion after the
# captured path, and a hardcoded `...\Users\...` assumption that breaks for
# any profile not under that path or a CLINE_DIR-relocated config. Snapshotting
# `git worktree list --porcelain` on $ProjectDir before and after invoking
# cline, then diffing, is robust regardless of username, profile location, or
# path depth, and needs no assumption about cline's JSON shape at all - git
# itself is the source of truth for what worktree now exists.
function Get-WorktreePaths([string]$Dir) {
    $lines = & git -C $Dir worktree list --porcelain
    $paths = @()
    foreach ($line in $lines) {
        if ($line -match '^worktree\s+(.+)$') { $paths += $matches[1] }
    }
    return $paths
}

$worktreesBefore = Get-WorktreePaths -Dir $ProjectDir

# Same $ErrorActionPreference scoping as review.ps1 around its `& cline
# @argsList` call, and for the same reason: a CLI-flag-parser-level stderr
# failure from cline.exe would otherwise become a terminating
# NativeCommandError under 'Stop', masking the intended red failure-message
# handling below (backported from Phase 2's agy scripts, which hit this
# live).
$prevEAP = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
& cline @argsList *> $outFile
$exitCode = $LASTEXITCODE
$ErrorActionPreference = $prevEAP

$result = Get-ClineResult -OutputFile $outFile

$worktreesAfter = Get-WorktreePaths -Dir $ProjectDir
$newWorktrees = $worktreesAfter | Where-Object { $worktreesBefore -notcontains $_ }
# Handle both separators - `git worktree list --porcelain` emits forward
# slashes on this machine (confirmed live), but match backslash too in case
# that ever varies by git version/config.
$worktreePath = $newWorktrees | Where-Object { $_ -match '\.cline[\\/]worktrees' } | Select-Object -First 1

if (-not $worktreePath) {
    Write-DelegationEvent -Skill 'delegate-cline' -Mode 'implement' -ProjectDir $ProjectDir -Model $activeProvider `
        -TaskDescription $TaskDescription -Outcome 'failed' -Reason 'could not locate a new cline worktree via git worktree list' `
        -DurationSeconds $stopwatch.Elapsed.TotalSeconds
    Write-Host "Could not locate a new cline worktree via 'git worktree list' - cannot safely show what changed." -ForegroundColor Red
    Write-Host "--- raw output ---"
    Write-Host $result.RawOutput
    exit 1
}

# Normalize to backslashes so downstream `git -C $worktreePath` and printed
# paths look like normal Windows paths regardless of which separator git used.
$worktreePath = $worktreePath -replace '/', '\'

if ($exitCode -ne 0 -or -not $result.Success) {
    $clineIncomplete = $true
    Write-Host "Cline implement task did not complete cleanly (exit $exitCode, reason: $($result.Reason))" -ForegroundColor Red
}

# Ensure whatever cline did is committed in the worktree, so the diff/merge
# steps below are accurate regardless of whether cline commits its own work.
#
# VERIFIED 2026-08-31 (Task 4, isolated non-live check): the same class of
# Windows native-argument-marshalling problem documented above for the cline
# shim also bites plain git.exe here - passing a string containing an
# embedded `"` as a `-m` argument via PowerShell 5.1 silently DROPS the quote
# characters rather than preserving or erroring (confirmed: an unescaped
# TaskDescription of `...the word "hello"` was committed as
# `...the word hello` with the quotes gone). Reusing $promptText (already
# escaped above) instead of raw $TaskDescription fixes this the same way it
# fixes the cline prompt.
#
# VERIFIED 2026-08-31 (final fix wave, Finding 1 follow-up): re-verified this
# specifically for the CORRECTED escaping algorithm (the original note above
# predates the Finding-1 fix and was checked against the naive
# `.Replace('"', '\"')`, not this regex). In a throwaway git repo, committed
# with `-m "delegate-cline implement: $promptText"` where $promptText was
# produced by the new regex from a TaskDescription containing both an escaped
# `\"hi\"` sequence and a trailing backslash
# (`x = "she said \"hi\" to me" and trailing\`); `git log -1 --format=%s`
# came back byte-for-byte equal to the original unescaped TaskDescription
# (backslashes not doubled, quotes intact) - confirming the commit-message
# call site round-trips correctly, not just the cline-prompt call site.
# VERIFIED 2026-08-31 (final fix wave, Finding 2, part 3): neither `add` nor
# `commit` had its exit code checked. A failed commit for any reason (e.g. no
# user.name/user.email configured in a fresh worktree, disk issue, hook
# failure) would leave the worktree's HEAD unchanged, which - like the unguarded
# empty $mergeBase below - produces the "empty diff presented as complete"
# symptom via a second route: the diff against $mergeBase would show nothing
# because nothing new was actually committed, but the script would proceed as
# if it had. Fail loudly instead of silently continuing.
$worktreeStatus = & git -C $worktreePath status --porcelain
if ($worktreeStatus) {
    & git -C $worktreePath add -A
    if ($LASTEXITCODE -ne 0) {
        Write-DelegationEvent -Skill 'delegate-cline' -Mode 'implement' -ProjectDir $ProjectDir -Model $activeProvider `
            -TaskDescription $TaskDescription -Outcome 'failed' -Reason "git add -A failed in the worktree (exit $LASTEXITCODE)" `
            -DurationSeconds $stopwatch.Elapsed.TotalSeconds
        Write-Host "git add -A failed in the worktree (exit $LASTEXITCODE) - refusing to present a diff that may not reflect all of cline's changes." -ForegroundColor Red
        exit 1
    }
    & git -C $worktreePath commit -m "delegate-cline implement: $promptText" | Out-Null
    if ($LASTEXITCODE -ne 0) {
        Write-DelegationEvent -Skill 'delegate-cline' -Mode 'implement' -ProjectDir $ProjectDir -Model $activeProvider `
            -TaskDescription $TaskDescription -Outcome 'failed' -Reason "git commit failed in the worktree (exit $LASTEXITCODE)" `
            -DurationSeconds $stopwatch.Elapsed.TotalSeconds
        Write-Host "git commit failed in the worktree (exit $LASTEXITCODE) - refusing to present a diff/merge instructions for a change that was never actually committed." -ForegroundColor Red
        exit 1
    }
}

# VERIFIED 2026-08-31 (Task 4, live run): cline's --worktree creates a
# DETACHED HEAD worktree (matches cline --help's own wording: "Auto-create a
# detached git worktree"), not a new branch. `git branch --show-current`
# therefore prints NOTHING in the worktree, confirmed live (`git status`
# there reported "Not currently on any branch" and `git worktree list` in
# $ProjectDir showed it as "(detached HEAD)"). Two consequences fixed below:
#   (a) PowerShell captures a native command's empty output as $null, not "" -
#       calling .Trim() directly on that null throws "You cannot call a
#       method on a null-valued expression" (hit live). Coercing through
#       `-join ''` first turns $null into "" safely before .Trim().
#   (b) Falling back to the commit SHA when there's no branch keeps the
#       printed merge/diff instructions correct either way - `git merge
#       --no-ff <sha>` works on a bare commit exactly like it does on a
#       branch name.
$branchName = ((& git -C $worktreePath branch --show-current) -join '').Trim()
$headSha = ((& git -C $worktreePath rev-parse HEAD) -join '').Trim()
$mergeRef = if ($branchName) { $branchName } else { $headSha }
$refLabel = if ($branchName) { "branch '$branchName'" } else { "commit $headSha (detached HEAD)" }

$baseBranch = ((& git -C $ProjectDir branch --show-current) -join '').Trim()

# VERIFIED 2026-08-31 (final fix wave, Finding 2, parts 1-2): if the real
# project ($ProjectDir - not the cline-created worktree) is itself on a
# detached HEAD (e.g. after `git checkout <sha>`, mid-bisect, mid-rebase),
# `git branch --show-current` returns empty, and `git merge-base HEAD
# $baseBranch` (called with an empty second argument) fails - reproduced live
# by checking out test-projects/cline-delegation-smoke to a detached HEAD and
# running this script: `git merge-base HEAD ""` errored (nonzero exit,
# nothing on stdout) and left $mergeBase empty. Left unguarded,
# `git diff "$mergeBase..HEAD"` on the next line becomes `git diff "..HEAD"`,
# which git silently resolves the omitted left side to HEAD and returns a
# ZERO-LINE diff at exit code 0 - the script would then print "Full diff of
# everything cline did" over an empty diff and offer a merge command for a
# change the user was never actually shown. Fix: fall back to $ProjectDir's
# own current commit (the exact commit cline's worktree was created from) as
# the base reference when $baseBranch is empty or merge-base fails/is empty;
# if that also can't be resolved, refuse to print a diff at all rather than
# risk showing an empty one. The merge-base call itself is also guarded
# against the same NativeCommandError-under-Stop problem as Finding 4 (a
# failed merge-base writes to stderr, which would otherwise crash the script
# before this fallback ever runs).
$prevEAP = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
$mergeBase = if ($baseBranch) { ((& git -C $worktreePath merge-base HEAD $baseBranch 2>$null) -join '').Trim() } else { '' }
$ErrorActionPreference = $prevEAP

if (-not $mergeBase) {
    # VERIFIED 2026-09-02: plain `git rev-parse HEAD` on a repo with no
    # commits (unborn HEAD) does not fail silently - it echoes the literal
    # argument "HEAD" back to stdout while writing the real error to stderr
    # (confirmed live: exit 128, stdout is the 4-character string "HEAD").
    # The old code here only checked truthiness, so that literal string
    # passed as non-empty and got used as a real base ref two lines below -
    # a git-quirk route to the same "empty diff presented as complete"
    # failure class every other guard in this project exists to prevent,
    # just reached via `git diff "HEAD..HEAD"` instead of an unresolved
    # $mergeBase. `--verify` fails cleanly instead of echoing the argument.
    # Also scoped like the merge-base call above: under this script's
    # $ErrorActionPreference = 'Stop', a failing native command's stderr
    # write would otherwise become a terminating NativeCommandError here,
    # for the same reason documented elsewhere in this file (Finding 4).
    $prevEAPBase = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    $mergeBase = ((& git -C $ProjectDir rev-parse --verify HEAD 2>$null) -join '').Trim()
    $ErrorActionPreference = $prevEAPBase
}

if (-not $mergeBase) {
    Write-DelegationEvent -Skill 'delegate-cline' -Mode 'implement' -ProjectDir $ProjectDir -Model $activeProvider `
        -TaskDescription $TaskDescription -Outcome 'failed' -Guard 'unresolvable_base' `
        -Reason 'could not resolve any base commit to diff against' -DurationSeconds $stopwatch.Elapsed.TotalSeconds
    Write-Host "Could not resolve any base commit to diff against (the real project has no resolvable branch or HEAD) - refusing to print a diff, since an unguarded empty base would silently present zero changes as a complete, safe-to-merge task." -ForegroundColor Red
    exit 1
}

Write-Host "--- Cline's summary ---" -ForegroundColor Green
Write-Host $result.Text

# NOTE: git output is captured as a PowerShell array (one element per line).
# Interpolating/echoing an array directly can collapse newlines depending on
# context (via $OFS on string interpolation); Write-Host on a raw array also
# doesn't guarantee newline-per-line the way a joined string does. Explicitly
# -join "`n" so the full multi-line diff renders with real line breaks.
$diffOutput = (& git -C $worktreePath diff "$mergeBase..HEAD") -join "`n"

# A resolvable base is not the same as a non-empty diff: cline can report a
# completed finishReason with a plausible-sounding summary while touching no
# files (nothing to commit, so the commit fallback above never ran, so
# worktree HEAD == $mergeBase). Left unguarded, that silently presents a
# no-op $refLabel with merge instructions as if it were a completed task -
# the same failure class the detached-HEAD/empty-base guards above exist to
# prevent, reached by a different route (backported from Phase 2's agy
# scripts, which added this proactively and verified it live in both
# directions). Refuse to offer merge instructions for an empty diff; cline's
# own summary (printed above) still reaches the user either way.
if (-not ($diffOutput -and $diffOutput.Trim())) {
    Write-DelegationEvent -Skill 'delegate-cline' -Mode 'implement' -ProjectDir $ProjectDir -Model $activeProvider `
        -TaskDescription $TaskDescription -Outcome 'failed' -Guard 'empty_diff' `
        -Reason "cline reported completion but the worktree diff against $mergeBase is empty" -DurationSeconds $stopwatch.Elapsed.TotalSeconds
    Write-Host "Cline reported completion but the worktree diff against $mergeBase is EMPTY - no files were actually changed. Refusing to print merge instructions for a no-op $refLabel." -ForegroundColor Red
    Write-Host "The worktree at '$worktreePath' still exists. To discard it:"
    Write-Host "  git -C `"$ProjectDir`" worktree remove `"$worktreePath`" --force"
    exit 1
}

$finalReason = if ($clineIncomplete) { 'cline reported an incomplete/non-clean finish but a non-empty diff was produced - review carefully' } else { 'completed' }
Write-DelegationEvent -Skill 'delegate-cline' -Mode 'implement' -ProjectDir $ProjectDir -Model $activeProvider `
    -TaskDescription $TaskDescription -Outcome 'success' -Reason $finalReason -DurationSeconds $stopwatch.Elapsed.TotalSeconds

Write-Host "`n--- Full diff of everything cline did on $refLabel ---" -ForegroundColor Cyan
Write-Host $diffOutput

Write-Host "`nNothing has been merged into '$ProjectDir'. To keep this change:"
Write-Host "  git -C `"$ProjectDir`" merge --no-ff $mergeRef"
Write-Host "To discard it:"
Write-Host "  git -C `"$ProjectDir`" worktree remove `"$worktreePath`" --force"
