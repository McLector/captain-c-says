param(
    [Parameter(Mandatory)]
    [string]$ProjectDir,

    [Parameter(Mandatory)]
    [string]$Description,

    [int]$TimeoutSeconds = 300,

    [int]$MaxDiffLines = 400,

    [string]$Model
)

$ErrorActionPreference = 'Stop'

. "$PSScriptRoot\parse-agy-json.ps1"

# See delegate-cline's review.ps1 for the full explanation of why this
# $ErrorActionPreference scoping trick is needed around a native command whose
# failure path writes to stderr under 'Stop': `git rev-parse` on a non-repo
# would otherwise throw a raw NativeCommandError before the intended
# $LASTEXITCODE check below is ever reached.
$prevEAP = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
$null = & git -C $ProjectDir rev-parse --is-inside-work-tree 2>$null
$ErrorActionPreference = $prevEAP
if ($LASTEXITCODE -ne 0) {
    Write-Error "ProjectDir '$ProjectDir' is not a git repository."
    exit 1
}

# `--is-inside-work-tree` only confirms $ProjectDir is somewhere inside a
# repo, not that it IS the repo root - a monorepo subdirectory passes it too.
# That matters here because `git -C $ProjectDir diff HEAD` (and `status`)
# below use no pathspec: `-C` only changes cwd for git, which then resolves
# the repo root and diffs the WHOLE ancestor repo, not just $ProjectDir's own
# changes. If $ProjectDir were a subdirectory, the diff sent to Agy's hosted
# backend would silently be the entire ancestor repo's diff, while the
# disclosure message above told the user only the named directory was being
# sent - more than the user consented to. Require the two to actually match,
# the same guard as implement.ps1, for the same reason.
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

$shortstat = & git -C $ProjectDir diff --shortstat HEAD
$changedLines = 0
if ($shortstat -match '(\d+) insertion') { $changedLines += [int]$matches[1] }
if ($shortstat -match '(\d+) deletion')  { $changedLines += [int]$matches[1] }

# NOTE: git output is captured as a PowerShell array (one element per line).
# Interpolating an array directly into a string joins elements with a single
# space (via $OFS), collapsing every newline in a multi-line diff onto one
# line. Explicitly -join "`n" to preserve real line breaks in what gets sent
# to agy.
$statOutput = (& git -C $ProjectDir diff --stat HEAD) -join "`n"
$statusOutput = (& git -C $ProjectDir status --porcelain) -join "`n"

if ($changedLines -gt $MaxDiffLines) {
    Write-Warning "Diff has $changedLines changed lines (limit $MaxDiffLines) - sending file summary only, not the full diff. Consider a chunked per-file review instead."
    $diffSection = "[DIFF TOO LARGE FOR INLINE REVIEW: $changedLines changed lines, limit is $MaxDiffLines]`nFile summary only:`n$statOutput"
} else {
    $fullDiff = (& git -C $ProjectDir diff HEAD) -join "`n"
    $diffSection = "$statOutput`n`n$fullDiff"
}

$modelNote = if ($Model) { "the '$Model' model" } else { "its default model" }
Write-Host "This diff will be sent to Agy's hosted backend (Google), using $modelNote, for review." -ForegroundColor Yellow

$promptRaw = "You are reviewing a code change. Comment on correctness, simplification, and risk. Do not edit any files - comments only.`n`nChange description: $Description`n`nUntracked/status (filenames only - untracked file CONTENTS are not included below, only tracked-file diffs are):`n$statusOutput`n`nDiff:`n$diffSection"

# Task 2 Step 1/7 live findings (2026-08-31): agy.exe IS subject to the same
# Windows argv-quoting problem as cline, despite being a direct Go binary
# invoked via a single `& agy @argsList` splat (no npm shim in between). A
# raw, unescaped `"` in $promptText (e.g. from a real diff line like
# `return f"Hello, {name}!"`) breaks PowerShell's native-argument quoting and
# fragments the prompt into extra argv tokens - live-reproduced with
# `--print 'echo ... f"Hello, name!"'`: exit code 2,
# `agy.exe : Error: unexpected argument "name!".`. The same text through this
# escaping regex round-tripped clean (exit 0, echoed back verbatim). The
# regex also correctly preserves a backslash that already precedes a quote in
# the source text (verified: source containing a real `\"` two-character
# sequence is delivered as that same two-character sequence, not silently
# dropped) - same rule cline's Finding 1 documents. Kept identical to cline's
# regex.
$promptText = ($promptRaw -replace '(\\*)"', '$1$1\"') -replace '(\\+)$', '$1$1'

$outFile = Join-Path $env:TEMP "agy-review-$(Get-Date -Format 'yyyyMMddHHmmss').json"

# Task 2 Step 1/7 live findings (2026-08-31): --print-timeout accepts a bare
# seconds-suffixed value (not Go's compound "5m0s" format). Primary evidence
# at the actual default this script uses: Step 7's live review.ps1 run with
# $TimeoutSeconds defaulted to 300 passed --print-timeout "300s" and returned
# exit code 0 with a real multi-paragraph review (not a timeout-flag-parse
# error). Also confirmed at "60s" across four separate `agy --print ...
# --print-timeout "60s" ...` probes, each exit 0 with a valid SUCCESS
# response. Go's time.ParseDuration (which --print-timeout evidently uses)
# accepts a single unit-suffixed value like "300s" directly, so no conversion
# to "5m0s" is needed. Using "${TimeoutSeconds}s" as drafted.
$argsList = @('--print', $promptText, '--output-format', 'json', '--add-dir', $ProjectDir, '--mode', 'plan', '--print-timeout', "${TimeoutSeconds}s", '--sandbox')
if ($Model) { $argsList += @('--model', $Model) }

# Task 2 Step 1 live probe (2026-08-31): --sandbox combined with --mode plan
# and --add-dir did NOT block file reads. The live probe asked agy to read
# sample.py and check its content for a specific phrase; the response quoted
# the file's real path and correctly reported the phrase was absent, i.e. it
# actually read the file rather than complaining about being unable to. No
# change needed - --sandbox is kept.
#
# Same $ErrorActionPreference scoping as the `git rev-parse` check above, and
# for the same reason (cline's Finding 4): under 'Stop', agy.exe writing to
# stderr becomes a terminating NativeCommandError that aborts the script here,
# before the intended "Agy review FAILED" handling below ever runs. This is
# not hypothetical - it is exactly what happened live during Step 7 testing
# before the escaping fix above was added: the pre-fix argv fragmentation
# from an unescaped `"` made agy.exe's own flag parser write "Error:
# unexpected argument ..." to stderr, which - unscoped - killed the script
# with a raw NativeCommandError/RemoteException at this line instead of the
# intended red failure message. (Runtime errors agy catches internally, e.g.
# an invalid --model, are NOT affected - those come back as clean JSON with
# status "ERROR" on stdout and exit 1, handled fine either way; this scoping
# specifically protects against CLI-flag-parser-level stderr output.)
$prevEAP = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
& agy @argsList *> $outFile
$exitCode = $LASTEXITCODE
$ErrorActionPreference = $prevEAP

$result = Get-AgyResult -OutputFile $outFile

if ($exitCode -ne 0 -or -not $result.Success) {
    Write-Host "Agy review FAILED (exit $exitCode, reason: $($result.Reason))" -ForegroundColor Red
    Write-Host "--- raw output ---"
    Write-Host $result.RawOutput
    exit 1
}

Write-Host "--- Agy review ---" -ForegroundColor Green
Write-Host $result.Text
