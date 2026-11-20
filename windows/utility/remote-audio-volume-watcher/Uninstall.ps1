[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$taskName = 'Remote Audio Volume Watcher'
$installDirectory = Join-Path $env:LOCALAPPDATA 'remote-audio-volume-watcher'
$installedExecutable = Join-Path $installDirectory 'remote-audio-volume-watcher.exe'
$existingTask = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue

function Stop-InstalledWatcher {
    $processName = [IO.Path]::GetFileNameWithoutExtension($installedExecutable)
    $processes = Get-Process -Name $processName -ErrorAction SilentlyContinue |
        Where-Object { $_.Path -eq $installedExecutable }

    foreach ($process in $processes) {
        Stop-Process -Id $process.Id -Force
        Wait-Process -Id $process.Id -ErrorAction SilentlyContinue
    }
}

if ($existingTask) {
    Stop-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
    Stop-InstalledWatcher
    Unregister-ScheduledTask -TaskName $taskName -Confirm:$false
}

if (Test-Path -LiteralPath $installDirectory) {
    Remove-Item -LiteralPath $installDirectory -Recurse -Force
}

Write-Host "Removed '$taskName' and its installed files." -ForegroundColor Green
