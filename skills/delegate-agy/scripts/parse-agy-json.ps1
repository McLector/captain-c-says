function Get-AgyResult {
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

    $raw = Get-Content -Path $OutputFile -Raw -Encoding UTF8

    try {
        $parsed = $raw | ConvertFrom-Json
    } catch {
        return [PSCustomObject]@{
            Success   = $false
            Text      = $null
            Model     = $null
            Reason    = "output was not valid JSON: $($_.Exception.Message)"
            RawOutput = $raw
        }
    }

    # A "SUCCESS" status with an empty/whitespace-only response is not a
    # usable result - observed live on the diff-too-large fallback path in
    # review.ps1's Step 8 test, where agy attempts a "command"-class tool
    # call that headless mode auto-denies, and comes back with
    # {"status":"SUCCESS","response":""}. Treating this as Success=$true
    # would make review.ps1 print "--- Agy review ---" followed by nothing -
    # a silent, misleading success (the same failure class Phase 1 fixed as
    # a Critical for cline). Checked explicitly here, deliberately, rather
    # than relying on this always happening to break JSON parsing via
    # merged stderr text landing ahead of the JSON in the output file (which
    # is incidental to stream ordering and not guaranteed).
    $statusIsSuccess = ($parsed.status -eq "SUCCESS")
    $isEmptyResponse = [string]::IsNullOrWhiteSpace($parsed.response)

    $reason = $parsed.status
    if ($statusIsSuccess -and $isEmptyResponse) {
        $reason = "agy returned SUCCESS but an empty response (likely a denied tool call on the diff-too-large fallback path)"
    }

    return [PSCustomObject]@{
        Success   = ($statusIsSuccess -and -not $isEmptyResponse)
        Text      = $parsed.response
        Model     = $null
        Reason    = $reason
        RawOutput = $raw
    }
}
