# Proves the Windows launcher detects the HTTP.sys proxy by health, falls back only when needed,
# and preloads the selected model before Copilot starts.
. (Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) "lib.ps1")

$cop = Join-Path $PS_REPO "scripts\copilot-local.ps1"
$roster = Join-Path $PS_REPO "scripts\local-models.json"
$log = Join-Path $env:TEMP ("ollama_launcher_" + [guid]::NewGuid().ToString("N") + ".log")

Invoke-LauncherPs1 -Src $cop -Providers "local,server" -Inputs @() -ModelArg "qwen38-27b-192k:latest" `
    -LocalRoster $roster -OllamaLog $log
$healthyLog = Get-Content $log
Assert-Eq "healthy proxy is selected" $true ($script:PS_LAST_OUT -like "*base=http://localhost:11435/v1*")
Assert-Eq "proxy health is checked" 1 @($healthyLog | Where-Object { $_ -eq "HEALTH_URL=http://127.0.0.1:11435/api/version" }).Count
Assert-Eq "direct health is not checked when proxy is healthy" 0 @($healthyLog | Where-Object { $_ -eq "HEALTH_URL=http://127.0.0.1:11434/api/version" }).Count
$preloadBody = ($healthyLog | Where-Object { $_ -like "PRELOAD_BODY=*" } | Select-Object -First 1) -replace "^PRELOAD_BODY=", ""
$preload = $preloadBody | ConvertFrom-Json
Assert-Eq "selected model is preloaded" "qwen38-27b-192k:latest" $preload.model
Assert-Eq "preload is non-streaming" $false $preload.stream
Assert-Eq "preload uses POST" "Post" ($healthyLog | Where-Object { $_ -like "PRELOAD_METHOD=*" } | ForEach-Object { $_ -replace "^PRELOAD_METHOD=", "" })
Assert-Eq "preload timeout covers cold load" "300" ($healthyLog | Where-Object { $_ -like "PRELOAD_TIMEOUT=*" } | ForEach-Object { $_ -replace "^PRELOAD_TIMEOUT=", "" })

Remove-Item $log -ErrorAction SilentlyContinue
Invoke-LauncherPs1 -Src $cop -Providers "local,server" -Inputs @() -ModelArg "qwen38-27b-192k:latest" `
    -LocalRoster $roster -ProxyMode "failure" -OllamaLog $log
$fallbackLog = Get-Content $log
Assert-Eq "direct endpoint is fallback" $true ($script:PS_LAST_OUT -like "*base=http://localhost:11434/v1*")
Assert-Eq "fallback warning is shown" $true ($script:PS_LAST_OUT -like "*compatibility proxy is unavailable*")
Assert-Eq "direct health is checked after proxy failure" 1 @($fallbackLog | Where-Object { $_ -eq "HEALTH_URL=http://127.0.0.1:11434/api/version" }).Count

Remove-Item $log -ErrorAction SilentlyContinue
Invoke-LauncherPs1 -Src $cop -Providers "local,server" -Inputs @() -ModelArg "qwen38-27b-192k:latest" `
    -LocalRoster $roster -ProxyMode "failure" -DirectMode "failure" -OllamaLog $log -ExpectedExitCode 1
Assert-Eq "total outage blocks Copilot launch" $false ($script:PS_LAST_OUT -like "*CAPTURE model=*")
Assert-Eq "total outage is explicit" $true ($script:PS_LAST_OUT -like "*Ollama is unavailable on ports 11434 and 11435*")

Remove-Item $log -ErrorAction SilentlyContinue
Invoke-LauncherPs1 -Src $cop -Providers "local,server" -Inputs @() -ModelArg "qwen38-27b-192k:latest" `
    -LocalRoster $roster -PreloadMode "failure" -OllamaLog $log -ExpectedExitCode 1
Assert-Eq "preload failure blocks Copilot launch" $false ($script:PS_LAST_OUT -like "*CAPTURE model=*")
Assert-Eq "preload failure is explicit" $true ($script:PS_LAST_OUT -like "*Ollama could not load qwen38-27b-192k:latest*")

Remove-Item $log -ErrorAction SilentlyContinue
if (PS-Summary "ollama-launcher-health") { exit 0 } else { exit 1 }
