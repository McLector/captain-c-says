param(
    [Parameter(Mandatory)]
    [string]$ProjectDir,

    [Parameter(Mandatory)]
    [string]$Description,

    [int]$TimeoutSeconds = 300,

    [int]$MaxDiffLines = 400,

    [ValidateSet('auto-approve-false', 'plan-mode')]
    [string]$ReviewGuard = 'auto-approve-false'
)

# Verified 2026-08-31 (Task 3, delegation plan): --auto-approve false does not
# hang when the prompt tempts an edit. Live smoke test with a tempting "just
# fix it directly" prompt against a real bug (division by zero) completed in
# 39.4s of a 60s timeout, exit code 0, finishReason "completed". Cline noted
# the read tool isn't offered in this non-interactive --auto-approve false
# session, so it never had an edit tool to seek approval for in the first
# place - it reviewed the diff and commented without touching any files. No
# hang was observed; default left as 'auto-approve-false'.

$ErrorActionPreference = 'Stop'

. "$PSScriptRoot\parse-cline-json.ps1"

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
    Write-Error "ProjectDir '$ProjectDir' is not a git repository."
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
# to cline.
$statOutput = (& git -C $ProjectDir diff --stat HEAD) -join "`n"
$statusOutput = (& git -C $ProjectDir status --porcelain) -join "`n"

if ($changedLines -gt $MaxDiffLines) {
    Write-Warning "Diff has $changedLines changed lines (limit $MaxDiffLines) - sending file summary only, not the full diff. Consider a chunked per-file review instead."
    $diffSection = "[DIFF TOO LARGE FOR INLINE REVIEW: $changedLines changed lines, limit is $MaxDiffLines]`nFile summary only:`n$statOutput"
} else {
    $fullDiff = (& git -C $ProjectDir diff HEAD) -join "`n"
    $diffSection = "$statOutput`n`n$fullDiff"
}

$providersPath = "$HOME\.cline\data\settings\providers.json"
$activeProvider = "unknown"
if (Test-Path $providersPath) {
    $activeProvider = (Get-Content $providersPath -Raw | ConvertFrom-Json).lastUsedProvider
}
Write-Host "This diff will be sent to cline's active provider ('$activeProvider') for review." -ForegroundColor Yellow

$promptText = "You are reviewing a code change. Comment on correctness, simplification, and risk. Do not edit any files - comments only.`n`nChange description: $Description`n`nUntracked/status (filenames only - untracked file CONTENTS are not included below, only tracked-file diffs are):`n$statusOutput`n`nDiff:`n$diffSection"

# NOTE: Windows PowerShell 5.1's native-command argument marshalling mishandles
# embedded double quotes when a splatted array is passed to `cline` (an
# npm-generated .ps1 shim that re-splats its own $args into a nested `node`
# invocation). Unescaped quotes shift the command-line quoting boundaries and
# either get silently dropped or, in longer multi-line prompts, cause the
# single prompt argument to fragment into multiple argv tokens (cline then
# errors with "Unknown command or unquoted prompt"). Escaping embedded quotes
# keeps the prompt intact as one argument. Confirmed by live testing against
# this machine's installed cline 3.0.60 CLI - see task-2-report.md.
#
# VERIFIED 2026-08-31 (final fix wave, Finding 1): the naive
# `.Replace('"', '\"')` only escapes the quote itself and does NOT double any
# backslashes already immediately preceding it (CommandLineToArgvW rule: N
# backslashes immediately before a quote must become 2N+1 backslashes to
# preserve N literal backslashes plus one literal quote through parsing). Any
# diff already containing an escaped-quote sequence like `\"` - i.e. nearly
# any JSON/Python/JS/Go/C/Java source diff - broke this: reproduced live with
# `printf("hello"); and json {"k": "va\"lue"}` followed by `end --json -t 300`
# via a node echo-argv harness - the naive escape collapsed the whole prompt
# PLUS the following `--json -t 300` flags into a single argv token (verified:
# argv came back as one element containing all of it, flags gone). The regex
# below (doubles any backslash run before a quote, then adds the escaping
# backslash + quote; separately doubles a trailing backslash run at the very
# end of the string so it doesn't escape the shim's own closing quote)
# round-trips correctly through the same node echo-argv harness for every case
# above, `--json`/`-t`/`300` intact as separate tokens.
$promptText = ($promptText -replace '(\\*)"', '$1$1\"') -replace '(\\+)$', '$1$1'

$outFile = Join-Path $env:TEMP "cline-review-$(Get-Date -Format 'yyyyMMddHHmmss').json"

if ($ReviewGuard -eq 'plan-mode') {
    $argsList = @($promptText, '--json', '-c', $ProjectDir, '-p', '-t', $TimeoutSeconds)
} else {
    $argsList = @($promptText, '--json', '-c', $ProjectDir, '--auto-approve', 'false', '-t', $TimeoutSeconds)
}

# Same $ErrorActionPreference scoping as the disclosure-line git calls above:
# a CLI-flag-parser-level stderr failure from cline.exe would otherwise
# become a terminating NativeCommandError under 'Stop', masking the intended
# red failure-message handling below (backported from Phase 2's agy scripts,
# which hit this live).
$prevEAP = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
& cline @argsList *> $outFile
$exitCode = $LASTEXITCODE
$ErrorActionPreference = $prevEAP

$result = Get-ClineResult -OutputFile $outFile

if ($exitCode -ne 0 -or -not $result.Success) {
    Write-Host "Cline review FAILED (exit $exitCode, reason: $($result.Reason))" -ForegroundColor Red
    Write-Host "--- raw output ---"
    Write-Host $result.RawOutput
    exit 1
}

Write-Host "--- Cline review ---" -ForegroundColor Green
Write-Host $result.Text
