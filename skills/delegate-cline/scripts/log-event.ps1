function Write-DelegationEvent {
    param(
        [Parameter(Mandatory)][string]$Skill,
        [Parameter(Mandatory)][string]$Mode,
        # Finding 1 (final whole-branch review, 2026-08-31): PowerShell throws
        # a terminating error when $null OR "" is bound to a
        # [Parameter(Mandatory)][string] parameter - live-confirmed with
        # `-Model $null` - and that rejection happens during parameter
        # BINDING, before the function body ever runs. Coercing inside the
        # function body (below) cannot by itself prevent this: a minimal
        # repro function with an empty body and the same
        # [Parameter(Mandatory)][string] signature still throws on
        # `-Model $null`. [AllowNull()]/[AllowEmptyString()] are what actually
        # suppress that engine-level bind check; they are separate attributes
        # from [Parameter(Mandatory)] and from the [string] type, so adding
        # them keeps both as specified while letting a null/empty caller value
        # reach the body coercion below instead of throwing. Applied only to
        # the four params real callers can hand a null/empty value to
        # ($ProjectDir, $Model, $TaskDescription, $Reason) - see the specific
        # scenarios in the fix report. $Skill/$Mode/$Outcome are always
        # string literals from callers in this codebase, so a hard bind
        # failure there stays intentional.
        [Parameter(Mandatory)][AllowNull()][AllowEmptyString()][string]$ProjectDir,
        [Parameter(Mandatory)][AllowNull()][AllowEmptyString()][string]$Model,
        [Parameter(Mandatory)][AllowNull()][AllowEmptyString()][string]$TaskDescription,
        [Parameter(Mandatory)][string]$Outcome,
        [string]$Guard,
        [Parameter(Mandatory)][AllowNull()][AllowEmptyString()][string]$Reason,
        [Parameter(Mandatory)][double]$DurationSeconds,
        $TokensPrompt,
        $TokensCompletion,
        $TokensTotal
    )

    # Several real callers can hit null/empty here (a missing
    # `lastUsedProvider` property in providers.json resolves to $null with no
    # error; a parsed CLI JSON result missing its `Reason` field; an
    # unreadable prompt file leaving $promptText empty) and the crash this
    # guards against can fire AFTER a target CLI already produced a good
    # result but BEFORE it's printed, so the user would never see a
    # review/implementation that actually succeeded. Coerce to a fallback
    # placeholder instead of letting a null/empty value flow into the logged
    # event.
    if ([string]::IsNullOrEmpty($Reason)) { $Reason = '(none)' }
    if ([string]::IsNullOrEmpty($Model)) { $Model = 'unknown' }
    if ([string]::IsNullOrEmpty($TaskDescription)) { $TaskDescription = '(none)' }
    if ([string]::IsNullOrEmpty($ProjectDir)) { $ProjectDir = 'unknown' }

    $logDir = Join-Path $HOME '.claude\delegation-log'
    $logFile = Join-Path $logDir 'events.jsonl'

    $truncatedDescription = if ($TaskDescription.Length -gt 200) { $TaskDescription.Substring(0, 200) } else { $TaskDescription }

    $event = [PSCustomObject]@{
        timestamp        = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
        skill            = $Skill
        mode             = $Mode
        project_dir      = $ProjectDir
        model            = $Model
        task_description = $truncatedDescription
        outcome          = $Outcome
        guard            = if ($Guard) { $Guard } else { $null }
        reason           = $Reason
        duration_seconds = [math]::Round($DurationSeconds, 1)
        tokens           = @{
            prompt     = $TokensPrompt
            completion = $TokensCompletion
            total      = $TokensTotal
        }
    }

    # Finding 1 (final whole-branch review, 2026-08-31): a transient log-write
    # failure (locked file, full disk, permissions on the delegation-log
    # directory) must not throw a terminating error here - by the time this
    # runs, the calling script has usually already gotten a real result from
    # the target CLI, and killing the script now would hide that result from
    # the user. Warn and return instead. New-Item/Add-Content raise
    # NON-terminating errors by default, so `catch` only sees them under
    # $ErrorActionPreference = 'Stop' - true for review.ps1/implement.ps1's
    # script scope, but invoke-ollama.ps1 sets no EAP at all. Force
    # -ErrorAction Stop on both cmdlets so the catch is deterministic
    # regardless of the caller's own EAP.
    try {
        if (-not (Test-Path $logDir)) {
            New-Item -ItemType Directory -Path $logDir -Force -ErrorAction Stop | Out-Null
        }
        ($event | ConvertTo-Json -Compress) | Add-Content -Path $logFile -Encoding UTF8 -ErrorAction Stop
    } catch {
        Write-Warning "Failed to write delegation log event: $($_.Exception.Message)"
        return
    }
}
