[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$taskName = 'Polychrome Display Watcher'
$sourceDirectory = Join-Path $PSScriptRoot 'dist'
$sourceExecutable = Join-Path $sourceDirectory 'polychrome-display-watcher.exe'
$sourceChecksum = "$sourceExecutable.sha256"
$sourceIcon = Join-Path $sourceDirectory 'security.ico'
$installDirectory = Join-Path $env:LOCALAPPDATA 'polychrome-display-watcher'
$installedExecutable = Join-Path $installDirectory 'polychrome-display-watcher.exe'
$installedIcon = Join-Path $installDirectory 'security.ico'
$currentIdentity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = [Security.Principal.WindowsPrincipal]::new($currentIdentity)

if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'Run this installer from an elevated PowerShell session.'
}

if (-not (Test-Path -LiteralPath $sourceExecutable)) {
    throw "The prebuilt watcher was not found at '$sourceExecutable'."
}

if (-not (Test-Path -LiteralPath $sourceChecksum)) {
    throw "The checksum was not found at '$sourceChecksum'."
}

if (-not (Test-Path -LiteralPath $sourceIcon)) {
    throw "The tray icon was not found at '$sourceIcon'."
}

$expectedHash = ((Get-Content -LiteralPath $sourceChecksum -Raw).Trim() -split '\s+')[0]
$actualHash = (Get-FileHash -LiteralPath $sourceExecutable -Algorithm SHA256).Hash

if ($expectedHash -ne $actualHash) {
    throw "The watcher checksum does not match. Expected '$expectedHash' and found '$actualHash'."
}

$existingTask = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue

if ($existingTask) {
    Stop-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
}

New-Item -ItemType Directory -Path $installDirectory -Force | Out-Null
Copy-Item -LiteralPath $sourceExecutable -Destination $installedExecutable -Force
Copy-Item -LiteralPath $sourceIcon -Destination $installedIcon -Force

$userId = "$env:USERDOMAIN\$env:USERNAME"
$action = New-ScheduledTaskAction -Execute $installedExecutable
$trigger = New-ScheduledTaskTrigger -AtLogOn -User $userId
$taskPrincipal = New-ScheduledTaskPrincipal -UserId $userId -LogonType Interactive -RunLevel Highest
$settings = New-ScheduledTaskSettingsSet `
    -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries `
    -ExecutionTimeLimit ([TimeSpan]::Zero) `
    -MultipleInstances IgnoreNew

Register-ScheduledTask `
    -TaskName $taskName `
    -Action $action `
    -Trigger $trigger `
    -Principal $taskPrincipal `
    -Settings $settings `
    -Description 'Restarts ASRock Polychrome DISPLAY after the interactive display wakes.' `
    -Force | Out-Null

Start-ScheduledTask -TaskName $taskName
Write-Host "Installed and started '$taskName'." -ForegroundColor Green
