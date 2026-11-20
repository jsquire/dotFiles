[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$taskName = 'Remote Audio Volume Watcher'
$sourceDirectory = Join-Path $PSScriptRoot 'dist'
$sourceExecutable = Join-Path $sourceDirectory 'remote-audio-volume-watcher.exe'
$sourceChecksum = "$sourceExecutable.sha256"
$sourceIcon = Join-Path $sourceDirectory 'remote-audio.ico'
$sourceIconLicense = Join-Path $sourceDirectory 'LICENSE-Fluent-System-Icons.txt'
$installDirectory = Join-Path $env:LOCALAPPDATA 'remote-audio-volume-watcher'
$installedExecutable = Join-Path $installDirectory 'remote-audio-volume-watcher.exe'
$installedIcon = Join-Path $installDirectory 'remote-audio.ico'
$installedIconLicense = Join-Path $installDirectory 'LICENSE-Fluent-System-Icons.txt'

function Stop-InstalledWatcher {
    $processName = [IO.Path]::GetFileNameWithoutExtension($installedExecutable)
    $processes = Get-Process -Name $processName -ErrorAction SilentlyContinue |
        Where-Object { $_.Path -eq $installedExecutable }

    foreach ($process in $processes) {
        Stop-Process -Id $process.Id -Force
        Wait-Process -Id $process.Id -ErrorAction SilentlyContinue
    }
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

if (-not (Test-Path -LiteralPath $sourceIconLicense)) {
    throw "The tray icon license was not found at '$sourceIconLicense'."
}

$expectedHash = ((Get-Content -LiteralPath $sourceChecksum -Raw).Trim() -split '\s+')[0]
$actualHash = (Get-FileHash -LiteralPath $sourceExecutable -Algorithm SHA256).Hash

if ($expectedHash -ne $actualHash) {
    throw "The watcher checksum does not match. Expected '$expectedHash' and found '$actualHash'."
}

$existingTask = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue

if ($existingTask) {
    Stop-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
    Stop-InstalledWatcher
}

New-Item -ItemType Directory -Path $installDirectory -Force | Out-Null
Copy-Item -LiteralPath $sourceExecutable -Destination $installedExecutable -Force
Copy-Item -LiteralPath $sourceIcon -Destination $installedIcon -Force
Copy-Item -LiteralPath $sourceIconLicense -Destination $installedIconLicense -Force

$userId = "$env:USERDOMAIN\$env:USERNAME"
$action = New-ScheduledTaskAction -Execute $installedExecutable
$trigger = New-ScheduledTaskTrigger -AtLogOn -User $userId
$taskPrincipal = New-ScheduledTaskPrincipal -UserId $userId -LogonType Interactive -RunLevel Limited
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
    -Description 'Applies a configurable base volume to Remote Audio and application sessions.' `
    -Force | Out-Null

Start-ScheduledTask -TaskName $taskName
Write-Host "Installed and started '$taskName'." -ForegroundColor Green
