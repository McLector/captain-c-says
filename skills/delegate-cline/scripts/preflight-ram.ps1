param(
    [Parameter(Mandatory)]
    [ValidateSet('3b', '7b')]
    [string]$ModelSize
)

$freeRamGB = (Get-CimInstance Win32_OperatingSystem).FreePhysicalMemory / 1MB

$modelName = if ($ModelSize -eq '3b') { 'qwen2.5-coder:3b' } else { 'qwen2.5-coder:7b' }
$alreadyWarm = $false
try {
    $psResponse = Invoke-RestMethod -Uri "http://localhost:11434/api/ps" -ErrorAction Stop
    if ($psResponse.models) {
        $alreadyWarm = [bool]($psResponse.models | Where-Object { $_.name -eq $modelName })
    }
} catch {
    # Ollama not reachable - free RAM check still stands on its own.
}

if ($ModelSize -eq '7b') {
    $result = [PSCustomObject]@{
        Proceed     = $false
        FreeRamGB   = [math]::Round($freeRamGB, 2)
        AlreadyWarm = $alreadyWarm
        Message     = "7b always warns before use: $([math]::Round($freeRamGB,2))GB free right now. Confirm you want to proceed, fall back to 3b, or wait."
    }
} else {
    $threshold = 3.5
    if ($freeRamGB -ge $threshold) {
        $result = [PSCustomObject]@{
            Proceed     = $true
            FreeRamGB   = [math]::Round($freeRamGB, 2)
            AlreadyWarm = $alreadyWarm
            Message     = "$([math]::Round($freeRamGB,2))GB free, above the ${threshold}GB threshold for 3b - proceeding."
        }
    } else {
        $result = [PSCustomObject]@{
            Proceed     = $false
            FreeRamGB   = [math]::Round($freeRamGB, 2)
            AlreadyWarm = $alreadyWarm
            Message     = "Only $([math]::Round($freeRamGB,2))GB free, below the ${threshold}GB threshold for 3b. Proceed anyway, wait, or route elsewhere?"
        }
    }
}

# VERIFIED 2026-08-31 (final fix wave, Finding 5): SKILL.md documents invoking
# this script as `powershell -File .../preflight-ram.ps1 -ModelSize 3b` and
# reading the `Message` field off the captured object. Confirmed live that
# this invocation style puts the returned PSCustomObject through PowerShell's
# default table/list formatter for display, which TRUNCATES the Message
# column and loses the object shape entirely when captured from a `powershell
# -File` child process - the caller gets formatted text (effectively
# System.Object[] of strings), not a queryable object, so `$r.Proceed` comes
# back $null. Emitting the result as a single JSON line (instead of a bare
# `return`) lets a caller running this via
# `powershell -File ... | ConvertFrom-Json` get the full, untruncated Message
# text and a reliably parseable object back - matches SKILL.md's updated
# invocation instructions.
$result | ConvertTo-Json -Compress
