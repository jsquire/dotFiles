# Local token budgets are derived from the roster's registry ctx, not from a global constant.
#
# This suite covers what test_launchers_parity.ps1 deliberately excludes. Parity asserts that the
# launchers resolve selections identically to the pre-refactor baseline (cf852ee^), so it cannot
# also assert a value that was intentionally changed after that baseline. The parity tuple drops
# prompt=/out= and the crush JSON drops context_window/default_max_tokens; those fields are asserted
# here instead, against explicit numbers rather than a re-derivation of the launcher's own formula.
#
# The rule under test:
#   copilot  prompt = floor(ctx * 0.75),  output = min(16384, ctx - prompt)
#   crush    max_tokens = min(16384, floor(ctx / 4))
#
# Crush gets only the reply cap locally: its context_window rides on the providers block, which the
# launcher writes only in server mode, so crush keeps managing the local window itself.
#
# Why it exists: one global 51200/16384 pair was applied to every local model regardless of its
# window. That over-committed small-context models (Ollama silently drops the oldest turns to make
# the prompt fit, so a session quietly loses its own history with no error) and simultaneously
# throttled the 128K-256K models the roster was assembled to exploit. The image_llm slot is the
# clearest case: qwen3:8b holds 40960 tokens and was being handed a 51200 prompt cap.
#
#   test_token_budgets.ps1

. (Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) "lib.ps1")

$cop = Join-Path $PS_REPO "scripts\copilot-local.ps1"
$cru = Join-Path $PS_REPO "scripts\crush-task.ps1"

# "<prompt>/<output>" for a copilot selection.
function Copilot-Budget($inputs, $modelArg) {
    Invoke-LauncherPs1 -Src $cop -Providers "local,server" -Inputs $inputs -ModelArg $modelArg
    $line = ($script:PS_LAST_OUT -split "`n" | Where-Object { $_ -like 'CAPTURE model=*' } | Select-Object -First 1)
    $p = if ($line -match 'prompt=(\S+)') { $Matches[1] } else { "?" }
    $o = if ($line -match 'out=(\S+)') { $Matches[1] } else { "?" }
    "$p/$o"
}

# "<max_tokens>" for a crush selection.
function Crush-Budget($inputs) {
    Invoke-LauncherPs1 -Src $cru -Providers "local,server" -Inputs $inputs
    if (-not $script:PS_CRUSH) { return "NONE" }
    $j = Get-Content $script:PS_CRUSH -Raw | ConvertFrom-Json
    "$($j.models.large.max_tokens)"
}

# -- copilot: production menu (page 1) -------------------------------------------------------
Assert-Eq "copilot prod 1 heavy 212K"   "162816/16384" (Copilot-Budget @("1", "1") "")
Assert-Eq "copilot prod 2 coder 144K"   "110592/16384" (Copilot-Budget @("1", "2") "")
Assert-Eq "copilot prod 6 agentic 198K" "152064/16384" (Copilot-Budget @("1", "6") "")
# The regression case: an 8B at 40960 must not be handed the old 51200 prompt cap.
Assert-Eq "copilot prod 7 image 40K"    "30720/10240"  (Copilot-Budget @("1", "7") "")

# -- copilot: experimental menu (page 2), spanning every distinct window in the fixture -------
Assert-Eq "copilot exp 2 256K"  "196608/16384" (Copilot-Budget @("2", "2") "")
Assert-Eq "copilot exp 3 128K"  "98304/16384"  (Copilot-Budget @("2", "3") "")
Assert-Eq "copilot exp 9 128K"  "98304/16384"  (Copilot-Budget @("2", "9") "")

# -- copilot: direct -Model path resolves through the registry too ----------------------------
Assert-Eq "copilot direct qwen3:8b" "30720/10240" (Copilot-Budget @() "qwen3:8b")

# -- crush: the reply cap is a quarter of the model's window, capped at 16K --------------------
Assert-Eq "crush prod 1 heavy 212K"  "16384" (Crush-Budget @("1", "1"))
Assert-Eq "crush prod 2 coder 144K"  "16384" (Crush-Budget @("1", "2"))
# The regression case again: a 40K model must not be promised the full 16K reply budget.
Assert-Eq "crush prod 5 image 40K"   "10240" (Crush-Budget @("1", "5"))
Assert-Eq "crush exp 2 256K"         "16384" (Crush-Budget @("2", "2"))
Assert-Eq "crush exp 3 128K"         "16384" (Crush-Budget @("2", "3"))

# -- the squire-server provider keeps its roster-advertised caps, unchanged by this rule -------
# 54272/8192 comes from server-models.json, not from any registry ctx, and must stay that way.
Assert-Eq "copilot server keeps roster caps" "54272/8192" (Copilot-Budget @("3", "1") "")

if (PS-Summary "token-budgets-ps") { exit 0 } else { exit 1 }
