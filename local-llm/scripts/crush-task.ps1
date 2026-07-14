<#
.SYNOPSIS
    Task picker for Crush — writes a project-level .crush.json with the right
    MCP servers enabled for the selected task, then launches Crush.

.DESCRIPTION
    Each task profile enables only the MCP servers relevant to that task,
    keeping the tool count low so the model can reliably use them all.

    Profiles:
      Coding      — no MCP servers (code tools + LSP only)
      Code review — Qwen3-Coder model, no MCP (different perspective)
      Documents   — office authoring (docx/pptx/xlsx) via the 'office' skill: the
                    model writes python-docx/python-pptx/openpyxl and runs it with uv.
                    No document MCP servers — the skill costs almost no context.
      Image       — imagegen-mcp (image generation)

    The .crush.json is written to the current directory. Crush merges it
    on top of the global config at ~/.config/crush/crush.json.
#>

param(
    [ValidateSet("coding", "review", "docs", "image")]
    [string]$Task,
    [string]$Model
)

# -- Provider gating (local Ollama / remote CachyOS server) --------------------
# Baked in by the installer; falls back to both if the placeholder was not substituted.
$LlProviders = "__LL_PROVIDERS__"
if ($LlProviders -like "*__*" -or [string]::IsNullOrWhiteSpace($LlProviders)) { $LlProviders = "local,server" }
function Test-LlProvider { param([string]$Name) return ((",$LlProviders,") -like "*,$Name,*") }

# Switch the CachyOS server's active model via the accountless web endpoint (:4090). The server
# loads one model at a time, so POST the mode then poll /status until it is ready before launching
# Crush (so we never hand Crush a not-yet-loaded model).
function Invoke-SquireSwitch {
    param([string]$Mode)
    $ip = "__SQUIRE_SERVER_IP__"; $port = "4090"
    try {
        Invoke-RestMethod -Uri "http://${ip}:${port}/switch" -Method Post -ContentType 'application/json' `
            -Body "{`"mode`":`"$Mode`"}" -TimeoutSec 10 -ErrorAction Stop | Out-Null
    } catch {
        Write-Host "  WARN: could not reach the model-switch service at http://${ip}:${port}/ - is the server up?"
        return
    }
    Write-Host -NoNewline "  ... switching server to $Mode"
    for ($i = 0; $i -lt 30; $i++) {
        try {
            $st = Invoke-RestMethod -Uri "http://${ip}:${port}/status" -TimeoutSec 5 -ErrorAction Stop
            if ($st.mode -eq $Mode -and $st.api_up) { Write-Host " - ready."; return }
        } catch {}
        Write-Host -NoNewline "."
        Start-Sleep -Seconds 3
    }
    Write-Host " (still loading; give it a few more seconds)"
}

$DefaultModel = if ($Model) { $Model } else { "qwen36-128k" }
$ReviewModel  = "qwen3coder-65k"

# 5090 model assignments per task profile
$ModelByTask = @{
    coding  = "qwen36-27b-212k"   # heavy coding default (Qwen3.6-27B dense)
    review  = "qwen3coder-144k"   # Qwen3-Coder 30B-A3B
    docs    = "glm47-flash-198k"  # GLM-4.7-Flash for office authoring (roomy, capable)
    image   = "qwen3:8b"          # image-gen companion (HiDream)
}
$SelectedModel = $null
$OffloadMode = $false
$Provider = "ollama"
$SwitchMode = $null
$ServerMcp = $null

function Write-CrushConfig {
    param(
        [hashtable]$McpOverrides,
        [string]$SystemPromptPrefix,
        [string]$Model,
        [string]$Provider = "ollama",
        [string]$ActiveLabel
    )
    $config = @{ mcp = $McpOverrides }
    # Output cap + assumed window, by provider. Server (vLLM on the 4090) window per mode: coder/devstral
    # 56K, glm 54K, mistral 64K, image companion 32K -> cap output at 8K so agentic context isn't starved
    # (image companion caps output at 2K — it only emits a small tool call). Local Ollama runs 128K-256K
    # windows, so a larger 32K cap is cheap.
    $maxTok = 16384; $ctxWin = 65536
    if ($Provider -eq "server") {
        $maxTok = 8192
        switch ($ActiveLabel) {
            "mistral-small" { $ctxWin = 65536 }
            "glm-4.7-flash" { $ctxWin = 55296 }
            "qwen3-coder"   { $ctxWin = 57344 }
            "devstral"      { $ctxWin = 57344 }
            "qwen3-4b"      { $ctxWin = 32768; $maxTok = 2048 }  # image companion: 1.7B, 32K served; small output (tool call only)
            default         { $ctxWin = 32768 }
        }
    }
    $providerBlock = @{}
    # Server provider: expose ONE 'active-model' entry (so /model can't pick a not-yet-loaded model),
    # relabeled "Active: <model>" for visibility.
    if ($ActiveLabel) {
        $providerBlock["models"] = @(
            @{ name = "Active: $ActiveLabel"; id = "active-model"; context_window = $ctxWin; default_max_tokens = $maxTok }
        )
    }
    if ($SystemPromptPrefix) {
        $providerBlock["system_prompt_prefix"] = $SystemPromptPrefix
    }
    if ($providerBlock.Count -gt 0) {
        $config["providers"] = @{ $Provider = $providerBlock }
    }
    if ($Model) {
        $config["models"] = @{
            "large" = @{
                "model" = $Model
                "provider" = $Provider
                "max_tokens" = $maxTok
            }
            "small" = @{
                "model" = $Model
                "provider" = $Provider
                "max_tokens" = $maxTok
            }
        }
    }
    $json = $config | ConvertTo-Json -Depth 5
    Set-Content -Path ".crush.json" -Value $json -Encoding UTF8
}

# If no task specified, show picker
if (-not $Task) {
    Write-Host ""
    if (Test-LlProvider 'local') {
    Write-Host "  --- Coding ---"
    Write-Host "  [1] Heavy coding        (Qwen3.6 27B dense, no MCP)"
    Write-Host "  [2] Light coding        (Qwen3-Coder 30B, no MCP)"
    Write-Host "  [3] Code review         (Qwen3-Coder 30B, no MCP)"
    Write-Host ""
    Write-Host "  --- Writing & Documents ---"
    Write-Host "  [4] Documents           (GLM-4.7-Flash + office skill: docx/pptx/xlsx via Python)"
    Write-Host ""
    Write-Host "  --- Visual ---"
    Write-Host "  [5] Image generation    (Qwen3 8B + HiDream MCP)"
    Write-Host ""
    Write-Host "  ══ EXPERIMENTAL · models under evaluation ════════════════"
    Write-Host "  --- Heavy-coding bench (coding profile, swap model) ---"
    Write-Host "  [H1] Qwen3.6 27B dense (default)"
    Write-Host "  [H2] Qwen3.6 35B-A3B MoE"
    Write-Host "  [H3] Gemma 4 31B dense"
    Write-Host "  [H4] Qwen3-Coder 30B-A3B"
    Write-Host "  [H5] GLM-4.7-Flash"
    Write-Host "  [H6] North Mini Code 1.0    (Cohere, agentic coding)"
    Write-Host "  [H7] Nemotron Cascade 2 30B (NVIDIA, reasoning/agentic)"
    Write-Host "  [H8] Ornith-1.0-35B         (MIT, agentic-coding reasoning)"
    Write-Host ""
    Write-Host "  --- Big-MoE expert-offload bench (experts->RAM; partial offload, slower) ---"
    Write-Host "  [O2] Qwen3-Next-80B-A3B     (offload, Q4_K_M ~45 GB)"
    Write-Host ""
    }
    if (Test-LlProvider 'server') {
    Write-Host "  --- Remote (CachyOS server - one standing model, switch only when needed) ---"
    Write-Host "  [S] CachyOS: Mistral-Small   (default - office/authoring, 64K)"
    Write-Host "  [G] CachyOS: GLM-4.7-Flash   (agentic/reasoning - switches server)"
    Write-Host "  [C] CachyOS: Qwen3-Coder     (coding-first - switches server)"
    Write-Host "  [D] CachyOS: Devstral-2 24B  (coding-alt, agentic - switches server)"
    Write-Host "  [I] CachyOS: Image gen       (HiDream + Qwen3-4B - switches server)"
    Write-Host ""
    }
    $defaultChoice = if (Test-LlProvider 'local') { "1" } else { "S" }
    $choice = Read-Host "  Select profile [$defaultChoice]"
    if (-not $choice) { $choice = $defaultChoice }

    switch ($choice.ToUpper()) {
        "1"  { $Task = "coding" }
        "2"  { $Task = "coding"; $SelectedModel = "qwen3coder-144k" }
        "3"  { $Task = "review" }
        "4"  { $Task = "docs" }
        "5"  { $Task = "image" }
        "H1" { $Task = "coding"; $SelectedModel = "qwen36-27b-212k" }
        "H2" { $Task = "coding"; $SelectedModel = "qwen36-35b-256k" }
        "H3" { $Task = "coding"; $SelectedModel = "gemma4-31b-128k" }
        "H4" { $Task = "coding"; $SelectedModel = "qwen3coder-144k" }
        "H5" { $Task = "coding"; $SelectedModel = "glm47-flash-198k" }
        "H6" { $Task = "coding"; $SelectedModel = "northmini-code-256k" }
        "H7" { $Task = "coding"; $SelectedModel = "nemotron-c2-256k" }
        "H8" { $Task = "coding"; $SelectedModel = "ornith-35b-256k" }
        "O2" { $Task = "coding"; $SelectedModel = "qwen3next-80b-offload"; $OffloadMode = $true }
        "S"  { $Provider = "server"; $SwitchMode = "mistral";   $SelectedModel = "mistral-small"; $ServerMcp = @{ "imagegen-mcp" = @{ disabled = $true } } }
        "G"  { $Provider = "server"; $SwitchMode = "glm";       $SelectedModel = "glm-4.7-flash"; $ServerMcp = @{ "imagegen-mcp" = @{ disabled = $true } } }
        "C"  { $Provider = "server"; $SwitchMode = "coder";     $SelectedModel = "qwen3-coder";   $ServerMcp = @{ "imagegen-mcp" = @{ disabled = $true } } }
        "D"  { $Provider = "server"; $SwitchMode = "coder-alt"; $SelectedModel = "devstral";      $ServerMcp = @{ "imagegen-mcp" = @{ disabled = $true } } }
        "I"  { $Provider = "server"; $SwitchMode = "image";     $SelectedModel = "qwen3-4b";      $ServerMcp = @{ "imagegen-mcp" = @{ disabled = $false } } }
        default {
            Write-Host "  Invalid selection, defaulting to heavy coding."
            $Task = "coding"
        }
    }
}

# Friendly labels for the launch-identity banner (keyed on the resolved alias; doubles as the
# human-readable bench roster registry).
$ModelLabel = @{
    "qwen36-27b-212k"       = "Qwen3.6 27B (+MTP)"
    "qwen36-35b-256k"       = "Qwen3.6 35B-A3B MoE"
    "gemma4-31b-128k"       = "Gemma 4 31B dense"
    "qwen3coder-144k"       = "Qwen3-Coder 30B-A3B"
    "glm47-flash-198k"      = "GLM-4.7-Flash"
    "northmini-code-256k"   = "North Mini Code 1.0"
    "nemotron-c2-256k"      = "Nemotron Cascade 2 30B-A3B"
    "ornith-35b-256k"       = "Ornith-1.0-35B"
    "qwen3next-80b-offload" = "Qwen3-Next-80B-A3B (partial offload)"
    "mistral-small"         = "Mistral-Small (CachyOS vLLM)"
    "glm-4.7-flash"         = "GLM-4.7-Flash (CachyOS vLLM)"
    "qwen3-coder"           = "Qwen3-Coder (CachyOS vLLM)"
    "devstral"              = "Devstral-2 24B (CachyOS vLLM)"
    "qwen3-4b"              = "Qwen3-4B image companion (CachyOS vLLM)"
}

# Resolve the model: explicit -Model wins, then picker selection, then per-task default.
if (-not $SelectedModel) {
    $SelectedModel = if ($Model) { $Model } else { $ModelByTask[$Task] }
}
$DefaultModel = $SelectedModel
$ReviewModel  = $SelectedModel

$ModelFriendly = if ($ModelLabel.ContainsKey($DefaultModel)) { $ModelLabel[$DefaultModel] } else { $DefaultModel }
Write-Host ""
Write-Host "  ▶ $ModelFriendly  ·  alias=$DefaultModel" -ForegroundColor Cyan

if ($Provider -eq "server") {
    if ($SwitchMode) { Invoke-SquireSwitch $SwitchMode }
    Write-CrushConfig -McpOverrides $ServerMcp -Model "active-model" -Provider "server" -ActiveLabel $SelectedModel
    Write-Host "  Profile: Remote CachyOS server ($SelectedModel via vLLM, addressed as active-model)"
}
else {
switch ($Task) {
    "coding" {
        Write-CrushConfig -McpOverrides @{
            "imagegen-mcp" = @{ disabled = $true }
        } -Model $DefaultModel
        Write-Host "  Profile: Coding ($DefaultModel, no MCP servers)"
    }
    "review" {
        $reviewGuide = @"
You are a code reviewer. Focus on:
- Bugs, logic errors, and edge cases
- Security vulnerabilities (injection, auth, data exposure)
- Performance issues (N+1 queries, unnecessary allocations, blocking calls)
- API contract violations and type mismatches
- Concurrency issues (race conditions, deadlocks)
Do NOT comment on style, formatting, or naming conventions unless they cause bugs.
Be direct. If the code is correct, say so briefly.
"@
        Write-CrushConfig -McpOverrides @{
            "imagegen-mcp" = @{ disabled = $true }
        } -SystemPromptPrefix $reviewGuide -Model $ReviewModel
        Write-Host "  Profile: Code review (Qwen3-Coder 30B)"
    }
    "docs" {
        # Office authoring uses the vendored 'office' skill (discovered natively by crush from
        # ~/.config/crush/skills/office). The model writes python-docx/python-pptx/openpyxl and
        # runs it via `uv run --with ...` — no document MCP servers, near-zero context cost.
        Write-CrushConfig -McpOverrides @{
            "imagegen-mcp" = @{ disabled = $true }
        } -Model $DefaultModel
        Write-Host "  Profile: Documents / office authoring ($DefaultModel + office skill: docx/pptx/xlsx via Python)"
    }
    "image" {
        Write-CrushConfig -McpOverrides @{
            "imagegen-mcp" = @{ disabled = $false }
        } -Model $SelectedModel
        Write-Host "  Profile: Image generation (HiDream) — using $SelectedModel for VRAM headroom"
    }
}
}

Write-Host "  Config: $(Resolve-Path .crush.json)"
Write-Host ""

if ($OffloadMode) {
    # Big-MoE offload mode: run a dedicated Ollama serve with expert CPU-offload, then
    # restore the managed server when Crush exits. The model alias already carries
    # num_gpu 99; offload-serve.ps1 sets LLAMA_ARG_N_CPU_MOE so experts spill to RAM.
    $offloadScript = Join-Path $PSScriptRoot "offload-serve.ps1"
    Write-Host "  Offload mode: experts -> system RAM (partial; slower than VRAM-resident)" -ForegroundColor DarkYellow
    & $offloadScript -Action start -NCpuMoe 24
    try {
        crush
    } finally {
        & $offloadScript -Action stop
    }
} else {
    crush
}
