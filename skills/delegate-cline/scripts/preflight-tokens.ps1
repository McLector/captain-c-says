param(
    [Parameter(Mandatory)]
    [string]$PromptFile,

    [Parameter(Mandatory)]
    [ValidateSet('3b', '7b')]
    [string]$ModelSize,

    [string]$ProjectDir = (Get-Location).Path
)

. "$PSScriptRoot\log-event.ps1"
$stopwatch = [System.Diagnostics.Stopwatch]::StartNew()

# Both qwen2.5-coder:3b and :7b run with a default Ollama runtime context
# window of 4096 tokens - confirmed live 2026-08-31 via a plain /api/generate
# call (no num_ctx override) followed by /api/ps, against Ollama 0.33.2 on
# this machine. The models' own native max (32768) is not the effective
# budget, since this design deliberately does not raise num_ctx.
$contextWindow = 4096
$responseReserve = 512

$promptText = Get-Content -Path $PromptFile -Raw -Encoding UTF8

# Conservative chars-per-token estimate: code and structured text tend to
# tokenize denser than plain English prose (more short, punctuation-heavy
# tokens), so a naive chars/4 ratio can undercount. Bias conservative with
# chars/3 rather than risk a false "proceed".
$estimatedPromptTokens = [math]::Ceiling($promptText.Length / 3.0)
$budget = $contextWindow - $responseReserve

if ($estimatedPromptTokens -ge $budget) {
    $result = [PSCustomObject]@{
        Proceed               = $false
        EstimatedPromptTokens = $estimatedPromptTokens
        ContextWindow         = $contextWindow
        Message               = "Estimated ~$estimatedPromptTokens prompt tokens against a $contextWindow-token context window (with a $responseReserve-token reserve for the response) - this prompt is likely to get truncated. Trim the prompt, route to a different target, or proceed anyway knowing truncation is likely."
    }
} else {
    $result = [PSCustomObject]@{
        Proceed               = $true
        EstimatedPromptTokens = $estimatedPromptTokens
        ContextWindow         = $contextWindow
        Message               = "Estimated ~$estimatedPromptTokens prompt tokens, within the $contextWindow-token context window ($budget-token budget after reserving $responseReserve for the response) - proceeding."
    }
}

Write-DelegationEvent -Skill 'delegate-cline' -Mode 'local-model' -ProjectDir $ProjectDir -Model "qwen2.5-coder:$ModelSize" `
    -TaskDescription (Split-Path -Leaf $PromptFile) -Outcome $(if ($result.Proceed) { 'success' } else { 'blocked' }) `
    -Guard $(if ($result.Proceed) { $null } else { 'token_budget' }) -Reason $result.Message `
    -DurationSeconds $stopwatch.Elapsed.TotalSeconds

$result | ConvertTo-Json -Compress
