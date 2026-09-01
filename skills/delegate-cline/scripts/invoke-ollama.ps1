param(
    [Parameter(Mandatory)]
    [string]$PromptFile,

    [Parameter(Mandatory)]
    [ValidateSet('3b', '7b')]
    [string]$ModelSize,

    [string]$ProjectDir = (Get-Location).Path,

    [int]$TimeoutSeconds = 60
)

. "$PSScriptRoot\log-event.ps1"
$stopwatch = [System.Diagnostics.Stopwatch]::StartNew()

$modelName = "qwen2.5-coder:$ModelSize"
$promptText = [string](Get-Content -Path $PromptFile -Raw -Encoding UTF8)

$body = @{
    model  = $modelName
    prompt = $promptText
    stream = $false
} | ConvertTo-Json -Compress

try {
    $response = Invoke-RestMethod -Uri 'http://localhost:11434/api/generate' -Method Post -Body $body -ContentType 'application/json' -TimeoutSec $TimeoutSeconds
} catch {
    Write-DelegationEvent -Skill 'delegate-cline' -Mode 'local-model' -ProjectDir $ProjectDir -Model $modelName `
        -TaskDescription $promptText -Outcome 'failed' -Reason "Ollama API call failed: $($_.Exception.Message)" `
        -DurationSeconds $stopwatch.Elapsed.TotalSeconds
    $failResult = [PSCustomObject]@{ Success = $false; Text = $null; Reason = "Ollama API call failed: $($_.Exception.Message)"; Model = $modelName }
    $failResult | ConvertTo-Json -Compress
    exit 1
}

# Live-confirmed 2026-08-31: Ollama's
# /api/generate response reports done_reason "stop" on a natural completion
# and "length" when generation was cut off before finishing - the same
# failure class every other guard in this project exists to catch (a target
# reporting completion while the result is actually unusable), just with a
# different symptom (truncated content, not empty content).
$isTruncated = ($response.done_reason -eq 'length')
$isEmpty = [string]::IsNullOrWhiteSpace($response.response)

$outcome = 'success'
$guard = $null
$reason = 'completed'
if ($isTruncated) {
    $outcome = 'failed'
    $guard = 'truncated'
    $reason = "Ollama reported done_reason 'length' - the response was cut off before finishing, not a complete answer."
} elseif ($isEmpty) {
    $outcome = 'failed'
    $guard = 'empty_response'
    $reason = "Ollama reported done_reason 'stop' but returned an empty response."
}

# Finding 3 (final whole-branch review, 2026-08-31): [int]$null evaluates to
# 0, so computing TokensTotal unconditionally silently fabricates 0 instead of
# null whenever either count is actually missing from Ollama's response - a
# real number where none is available. Only compute a real total when BOTH
# counts are actually present; otherwise pass $null through, same as
# TokensPrompt/TokensCompletion already correctly do.
$tokensTotal = if ($null -ne $response.prompt_eval_count -and $null -ne $response.eval_count) { [int]$response.prompt_eval_count + [int]$response.eval_count } else { $null }

Write-DelegationEvent -Skill 'delegate-cline' -Mode 'local-model' -ProjectDir $ProjectDir -Model $modelName `
    -TaskDescription $promptText -Outcome $outcome -Guard $guard -Reason $reason `
    -DurationSeconds $stopwatch.Elapsed.TotalSeconds `
    -TokensPrompt $response.prompt_eval_count -TokensCompletion $response.eval_count `
    -TokensTotal $tokensTotal

$result = [PSCustomObject]@{
    Success = ($outcome -eq 'success')
    Text    = $response.response
    Reason  = $reason
    Model   = $modelName
}
$result | ConvertTo-Json -Compress
