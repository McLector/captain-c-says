param(
    [Parameter(Mandatory)]
    [string]$ProjectDir,

    [Parameter(Mandatory)]
    [string]$TaskDescription,

    [int]$TimeoutSeconds = 300,

    [string]$Model
)

$ErrorActionPreference = 'Stop'

. "$PSScriptRoot\parse-agy-json.ps1"
. "$PSScriptRoot\log-event.ps1"
$stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
$agyIncomplete = $false
$agyModel = if ($Model) { $Model } else { 'default' }

# Prints the two commands (in the order they must be run - removing the
# worktree before deleting the branch, since a branch still checked out into a
# worktree can't be deleted) needed to fully clean up a worktree created by
# this script. Used on every post-worktree-creation exit path so a
# delegate-agy-<timestamp> branch never gets left behind when only the
# worktree is cleaned up.
function Write-DiscardInstructions {
    param(
        [Parameter(Mandatory)][string]$ProjectDir,
        [Parameter(Mandatory)][string]$WorktreePath,
        [Parameter(Mandatory)][string]$BranchName
    )
    Write-Host "  git -C `"$ProjectDir`" worktree remove `"$WorktreePath`" --force"
    Write-Host "  git -C `"$ProjectDir`" branch -D $BranchName"
}

# Same $ErrorActionPreference scoping trick as review.ps1/delegate-cline's
# implement.ps1: under 'Stop', a native command's stderr output becomes a
# terminating NativeCommandError, which would otherwise crash the script here
# before the intended $LASTEXITCODE check runs.
$prevEAP = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
$null = & git -C $ProjectDir rev-parse --is-inside-work-tree 2>$null
$ErrorActionPreference = $prevEAP
if ($LASTEXITCODE -ne 0) {
    Write-Error "ProjectDir '$ProjectDir' is not a git repository."
    exit 1
}

# `--is-inside-work-tree` only confirms $ProjectDir is somewhere inside a repo,
# not that it IS the repo root - a monorepo subdirectory passes it too. That
# matters here because `git worktree add` below is run with `-C $ProjectDir`:
# if $ProjectDir is a subdirectory, git silently operates on the whole
# ancestor repo at its root instead of the intended subdirectory, and every
# merge/discard instruction this script prints ends up targeting the wrong
# repo. Resolve the actual root and require it to equal $ProjectDir.
$prevEAP = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
$repoRoot = ((& git -C $ProjectDir rev-parse --show-toplevel 2>$null) -join '').Trim()
$ErrorActionPreference = $prevEAP
if ($LASTEXITCODE -ne 0 -or -not $repoRoot) {
    Write-Error "Could not resolve the git repo root for '$ProjectDir'."
    exit 1
}
# `--show-toplevel` always returns forward-slash paths (even on Windows) and
# never a trailing separator; $ProjectDir as typed may differ on both counts.
# Resolve-Path + trimming a trailing separator normalizes both sides before
# comparing so a valid root isn't rejected on formatting alone.
$resolvedProjectDir = (Resolve-Path -LiteralPath $ProjectDir).Path.TrimEnd('\', '/')
$resolvedRepoRoot = (Resolve-Path -LiteralPath $repoRoot).Path.TrimEnd('\', '/')
if ($resolvedProjectDir -ne $resolvedRepoRoot) {
    Write-Error "ProjectDir '$ProjectDir' is inside a git repo but is not its root ('$repoRoot')."
    exit 1
}

$modelNote = if ($Model) { "the '$Model' model" } else { "its default model" }
Write-Host "This task will be sent to Agy's hosted backend (Google), using $modelNote, and will make real file edits in an isolated worktree - your real files are not touched." -ForegroundColor Yellow

# agy has no --worktree-equivalent flag (confirmed via agy --help) - unlike
# cline, which creates its own isolated worktree automatically, this script
# must create one itself before invoking agy, using --add-dir to point agy
# at it instead of $ProjectDir directly.
$worktreeId = Get-Date -Format 'yyyyMMddHHmmssfff'
$worktreeParentDir = Join-Path $env:TEMP "agy-worktrees"
if (-not (Test-Path $worktreeParentDir)) { New-Item -ItemType Directory -Path $worktreeParentDir | Out-Null }
$worktreePath = Join-Path $worktreeParentDir $worktreeId
$branchName = "delegate-agy-$worktreeId"

& git -C $ProjectDir worktree add $worktreePath -b $branchName
if ($LASTEXITCODE -ne 0) {
    Write-DelegationEvent -Skill 'delegate-agy' -Mode 'implement' -ProjectDir $ProjectDir -Model $agyModel `
        -TaskDescription $TaskDescription -Outcome 'failed' -Reason 'could not create an isolated worktree' `
        -DurationSeconds $stopwatch.Elapsed.TotalSeconds
    Write-Host "Could not create an isolated worktree - refusing to invoke Agy with --mode accept-edits directly against the real project." -ForegroundColor Red
    exit 1
}

# Same argv-escaping treatment as review.ps1 - reused for both the agy
# prompt AND the worktree commit message below, same reasoning as Phase 1's
# implement.ps1 (a single escaped string, one source of truth, used at both
# call sites). Confirmed necessary for agy.exe specifically in Task 2 (Q1):
# a raw, unescaped `"` fragments the argv and fails with exit code 2; this
# regex round-trips it clean.
$promptText = ($TaskDescription -replace '(\\*)"', '$1$1\"') -replace '(\\+)$', '$1$1'

$outFile = Join-Path $env:TEMP "agy-implement-$worktreeId.json"
$argsList = @('--print', $promptText, '--output-format', 'json', '--add-dir', $worktreePath, '--mode', 'accept-edits', '--print-timeout', "${TimeoutSeconds}s", '--dangerously-skip-permissions')
if ($Model) { $argsList += @('--model', $Model) }

# Same $ErrorActionPreference scoping as review.ps1 around its `& agy
# @argsList` call, and for the same reason (Task 2's live finding): a
# CLI-flag-parser-level stderr failure from agy.exe becomes a terminating
# NativeCommandError under 'Stop' otherwise, masking the intended red
# failure-message handling below.
$prevEAP = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
& agy @argsList *> $outFile
$exitCode = $LASTEXITCODE
$ErrorActionPreference = $prevEAP

$result = Get-AgyResult -OutputFile $outFile

if ($exitCode -ne 0 -or -not $result.Success) {
    $agyIncomplete = $true
    Write-Host "Agy implement task did not complete cleanly (exit $exitCode, reason: $($result.Reason))" -ForegroundColor Red
}

# Ensure whatever Agy did in the worktree is committed, so the diff/merge
# instructions below are accurate regardless of whether Agy itself commits -
# same reasoning, and the same exit-code checks, as Phase 1's implement.ps1
# final fix wave (an unchecked failed commit is a silent route to an empty
# diff being presented as a complete change).
$worktreeStatus = & git -C $worktreePath status --porcelain
if ($worktreeStatus) {
    & git -C $worktreePath add -A
    if ($LASTEXITCODE -ne 0) {
        Write-DelegationEvent -Skill 'delegate-agy' -Mode 'implement' -ProjectDir $ProjectDir -Model $agyModel `
            -TaskDescription $TaskDescription -Outcome 'failed' -Reason "git add -A failed in the worktree (exit $LASTEXITCODE)" `
            -DurationSeconds $stopwatch.Elapsed.TotalSeconds
        Write-Host "git add -A failed in the worktree (exit $LASTEXITCODE) - refusing to present a diff that may not reflect all of Agy's changes." -ForegroundColor Red
        Write-Host "The worktree at '$worktreePath' (branch '$branchName') still exists. To discard it:"
        Write-DiscardInstructions -ProjectDir $ProjectDir -WorktreePath $worktreePath -BranchName $branchName
        exit 1
    }
    & git -C $worktreePath commit -m "delegate-agy implement: $promptText" | Out-Null
    if ($LASTEXITCODE -ne 0) {
        Write-DelegationEvent -Skill 'delegate-agy' -Mode 'implement' -ProjectDir $ProjectDir -Model $agyModel `
            -TaskDescription $TaskDescription -Outcome 'failed' -Reason "git commit failed in the worktree (exit $LASTEXITCODE)" `
            -DurationSeconds $stopwatch.Elapsed.TotalSeconds
        Write-Host "git commit failed in the worktree (exit $LASTEXITCODE) - refusing to present a diff/merge instructions for a change that was never actually committed." -ForegroundColor Red
        Write-Host "The worktree at '$worktreePath' (branch '$branchName') still exists. To discard it:"
        Write-DiscardInstructions -ProjectDir $ProjectDir -WorktreePath $worktreePath -BranchName $branchName
        exit 1
    }
}

$baseBranch = ((& git -C $ProjectDir branch --show-current) -join '').Trim()

# Same detached-HEAD guard Phase 1 had to add after shipping without it -
# built in here from the start. If $ProjectDir is itself on a detached
# HEAD, $baseBranch is empty; fall back to $ProjectDir's own current
# commit, and refuse to print a diff at all if even that can't be resolved,
# rather than silently presenting an empty diff as a complete change.
$prevEAP2 = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
$mergeBase = if ($baseBranch) { ((& git -C $worktreePath merge-base HEAD $baseBranch 2>$null) -join '').Trim() } else { '' }
$ErrorActionPreference = $prevEAP2

if (-not $mergeBase) {
    # VERIFIED 2026-09-02: plain `git rev-parse HEAD` on a repo with no
    # commits (unborn HEAD, e.g. $ProjectDir was `git init`'d but never
    # committed to) does not fail silently - it echoes the literal argument
    # "HEAD" back to stdout while the real error goes to stderr (confirmed
    # live: exit 128, stdout is the 4-character string "HEAD"). The old code
    # here only checked truthiness, so that literal string passed as
    # non-empty and got used as a real base ref two lines below - live
    # reproduced: this exact scenario (agy's own worktree tooling creates an
    # orphan branch even from a zero-commit $ProjectDir, unlike cline's,
    # which refuses outright) produced a diff against the literal string
    # "HEAD" instead of hitting the unresolvable_base guard, and got
    # misclassified as an empty-diff no-op. `--verify` fails cleanly instead
    # of echoing the argument back.
    # Same $ErrorActionPreference scoping as the merge-base call above (and
    # documented at length elsewhere in this project): under this script's
    # global $ErrorActionPreference = 'Stop', a failing native command's
    # stderr write becomes a terminating NativeCommandError even with
    # `2>$null` present - live-reproduced here (`--verify`'s "fatal: Needed
    # a single revision" crashed the script before this fallback could ever
    # return, masking the intended unresolvable_base handling below).
    $prevEAPBase = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    $mergeBase = ((& git -C $ProjectDir rev-parse --verify HEAD 2>$null) -join '').Trim()
    $ErrorActionPreference = $prevEAPBase
}

if (-not $mergeBase) {
    Write-DelegationEvent -Skill 'delegate-agy' -Mode 'implement' -ProjectDir $ProjectDir -Model $agyModel `
        -TaskDescription $TaskDescription -Outcome 'failed' -Guard 'unresolvable_base' `
        -Reason 'could not resolve any base commit to diff against' -DurationSeconds $stopwatch.Elapsed.TotalSeconds
    Write-Host "Could not resolve any base commit to diff against - refusing to print a diff, since an unguarded empty base would silently present zero changes as a complete, safe-to-merge task." -ForegroundColor Red
    Write-Host "The worktree at '$worktreePath' (branch '$branchName') still exists. To discard it:"
    Write-DiscardInstructions -ProjectDir $ProjectDir -WorktreePath $worktreePath -BranchName $branchName
    exit 1
}

Write-Host "--- Agy's summary ---" -ForegroundColor Green
Write-Host $result.Text

$diffOutput = (& git -C $worktreePath diff "$mergeBase..HEAD") -join "`n"

# A resolvable base is not the same as a non-empty diff: Agy can report
# status:SUCCESS with a plausible-sounding summary while touching no files
# (nothing to commit, so the commit fallback above never ran, so worktree
# HEAD == $mergeBase). Left unguarded, that silently presents a no-op branch
# with merge instructions as if it were a completed task - the same failure
# class the detached-HEAD guard above exists to prevent, reached by a
# different route. Refuse to offer merge instructions for an empty diff;
# Agy's own summary (printed above) still reaches the user either way.
if (-not ($diffOutput -and $diffOutput.Trim())) {
    Write-DelegationEvent -Skill 'delegate-agy' -Mode 'implement' -ProjectDir $ProjectDir -Model $agyModel `
        -TaskDescription $TaskDescription -Outcome 'failed' -Guard 'empty_diff' `
        -Reason "agy reported completion but the worktree diff against $mergeBase is empty" -DurationSeconds $stopwatch.Elapsed.TotalSeconds
    Write-Host "Agy reported completion but the worktree diff against $mergeBase is EMPTY - no files were actually changed. Refusing to print merge instructions for a no-op branch." -ForegroundColor Red
    Write-Host "The worktree at '$worktreePath' (branch '$branchName') still exists. To discard it:"
    Write-DiscardInstructions -ProjectDir $ProjectDir -WorktreePath $worktreePath -BranchName $branchName
    exit 1
}

$finalReason = if ($agyIncomplete) { 'agy reported an incomplete/non-clean finish but a non-empty diff was produced - review carefully' } else { 'completed' }
Write-DelegationEvent -Skill 'delegate-agy' -Mode 'implement' -ProjectDir $ProjectDir -Model $agyModel `
    -TaskDescription $TaskDescription -Outcome 'success' -Reason $finalReason -DurationSeconds $stopwatch.Elapsed.TotalSeconds

Write-Host "`n--- Full diff of everything Agy did on branch '$branchName' (worktree: $worktreePath) ---" -ForegroundColor Cyan
Write-Host $diffOutput

Write-Host "`nNothing has been merged into '$ProjectDir'. To keep this change:"
Write-Host "  git -C `"$ProjectDir`" merge --no-ff $branchName"
Write-Host "After the merge succeeds, clean up the worktree and branch:"
Write-DiscardInstructions -ProjectDir $ProjectDir -WorktreePath $worktreePath -BranchName $branchName
Write-Host "To discard the change instead of merging it:"
Write-DiscardInstructions -ProjectDir $ProjectDir -WorktreePath $worktreePath -BranchName $branchName
