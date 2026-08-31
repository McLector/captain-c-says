function Get-ClineResult {
    param(
        [Parameter(Mandatory)]
        [string]$OutputFile
    )

    if (-not (Test-Path $OutputFile)) {
        return [PSCustomObject]@{
            Success   = $false
            Text      = $null
            Model     = $null
            Reason    = "output file not found: $OutputFile"
            RawOutput = $null
        }
    }

    $lines = Get-Content -Path $OutputFile -Encoding UTF8
    $runResultLine = $lines | Where-Object { $_ -match '"type"\s*:\s*"run_result"' } | Select-Object -Last 1

    if (-not $runResultLine) {
        return [PSCustomObject]@{
            Success   = $false
            Text      = $null
            Model     = $null
            Reason    = "no run_result line found in cline output"
            RawOutput = ($lines -join "`n")
        }
    }

    try {
        $parsed = $runResultLine | ConvertFrom-Json
    } catch {
        return [PSCustomObject]@{
            Success   = $false
            Text      = $null
            Model     = $null
            Reason    = "run_result line was not valid JSON: $($_.Exception.Message)"
            RawOutput = ($lines -join "`n")
        }
    }

    # A "completed" finishReason with an empty/whitespace-only text is not a
    # usable result - the same failure class Phase 2 found live for agy (a
    # denied tool call on a fallback path can report success with nothing to
    # show). Checked explicitly here rather than relying on this always
    # happening to break something else further downstream.
    $finishedCompleted = ($parsed.finishReason -eq "completed")
    $isEmptyText = [string]::IsNullOrWhiteSpace($parsed.text)

    $reason = $parsed.finishReason
    if ($finishedCompleted -and $isEmptyText) {
        $reason = "cline reported completed but returned empty text"
    }

    return [PSCustomObject]@{
        Success   = ($finishedCompleted -and -not $isEmptyText)
        Text      = $parsed.text
        Model     = $parsed.model
        Reason    = $reason
        RawOutput = ($lines -join "`n")
    }
}
