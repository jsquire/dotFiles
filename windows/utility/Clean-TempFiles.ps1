#Requires -Version 5.1
<#
.SYNOPSIS
    Deep-cleans temp files, caches, and logs that Disk Cleanup misses.

.DESCRIPTION
    Scans and cleans locations that Windows Disk Cleanup doesn't cover:
    - User and system TEMP directories
    - Windows Update download cache
    - CBS, DISM, and Windows Update ETL logs
    - User crash dumps
    - Edge browser cache
    - Visual Studio and VSCode cached data
    - NuGet package cache (via dotnet CLI)
    - OneDrive logs
    - Explorer thumbnail cache
    - WinGet temp files
    - DirectX and AMD shader caches
    - Recycle Bin
    - WinSxS component store (via DISM)

    Explicitly SKIPS:
    - C:\Windows\Installer (breaks MSI uninstalls)
    - NVIDIA shader cache (user preference)

    Runs in REPORT MODE by default (no deletions).
    Pass -Confirm to actually delete files.

.PARAMETER Confirm
    When specified, actually deletes files. Without this flag, only reports what would be cleaned.

.PARAMETER SkipDISM
    Skip the DISM /StartComponentCleanup step (WinSxS).

.EXAMPLE
    # Report only (safe, no changes)
    .\Clean-TempFiles.ps1

    # Actually clean
    .\Clean-TempFiles.ps1 -Confirm

    # Clean but skip DISM (faster)
    .\Clean-TempFiles.ps1 -Confirm -SkipDISM

.NOTES
    Must be run as Administrator for system-level locations.
    Self-elevates if not already elevated.
#>

[CmdletBinding(SupportsShouldProcess = $false)]
param(
    [switch]$Confirm,
    [switch]$SkipDISM
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Continue'

$DryRun = -not $Confirm

# ── Self-Elevation ──────────────────────────────────────────────────────────────

function Test-IsAdmin {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]$identity
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

if (-not (Test-IsAdmin)) {
    Write-Host "Not running as Administrator. Requesting elevation..." -ForegroundColor Yellow
    $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$($MyInvocation.MyCommand.Definition)`"")
    if ($Confirm) { $argList += '-Confirm' }
    if ($SkipDISM) { $argList += '-SkipDISM' }
    Start-Process powershell.exe -ArgumentList $argList -Verb RunAs -Wait
    exit
}

# ── Output Helpers ──────────────────────────────────────────────────────────────

function Write-Header {
    param([string]$Message)
    Write-Host "`n>> $Message" -ForegroundColor Cyan
}

function Write-OK {
    param([string]$Message)
    Write-Host "   [OK] $Message" -ForegroundColor Green
}

function Write-Skip {
    param([string]$Message)
    Write-Host "   [SKIP] $Message" -ForegroundColor DarkGray
}

function Write-Err {
    param([string]$Message)
    Write-Host "   [ERR] $Message" -ForegroundColor Red
}

# ── Size Helpers ────────────────────────────────────────────────────────────────

function Get-DirSize {
    param([string]$Path)
    if (-not (Test-Path $Path -ErrorAction SilentlyContinue)) { return 0 }
    $size = 0
    Get-ChildItem -Path $Path -Recurse -Force -File -ErrorAction SilentlyContinue |
        ForEach-Object { $size += $_.Length }
    return $size
}

function Format-Size {
    param([long]$Bytes)
    if ($Bytes -ge 1GB) { return "{0:N1} GB" -f ($Bytes / 1GB) }
    if ($Bytes -ge 1MB) { return "{0:N1} MB" -f ($Bytes / 1MB) }
    if ($Bytes -ge 1KB) { return "{0:N0} KB" -f ($Bytes / 1KB) }
    return "$Bytes bytes"
}

# ── Cleanup Engine ──────────────────────────────────────────────────────────────

$script:totalCleaned = 0
$script:totalFound = 0
$script:results = @()

function Clean-Directory {
    <#
    .SYNOPSIS
        Removes contents of a directory (or the directory itself).
    .PARAMETER Path
        Path to clean.
    .PARAMETER Label
        Human-readable label for output.
    .PARAMETER MinAgeDays
        Only delete files older than this many days. 0 = delete all.
    .PARAMETER DeleteRoot
        If true, deletes the directory itself (not just contents).
    .PARAMETER FileFilter
        Optional wildcard filter for files (e.g., "*.log", "*.tmp").
    #>
    param(
        [string]$Path,
        [string]$Label,
        [int]$MinAgeDays = 0,
        [switch]$DeleteRoot,
        [string]$FileFilter = "*"
    )

    if (-not (Test-Path $Path -ErrorAction SilentlyContinue)) {
        Write-Skip "$Label — path not found"
        return
    }

    $cutoff = (Get-Date).AddDays(-$MinAgeDays)
    $files = Get-ChildItem -Path $Path -Recurse -Force -File -Filter $FileFilter -ErrorAction SilentlyContinue
    if ($MinAgeDays -gt 0) {
        $files = $files | Where-Object { $_.LastWriteTime -lt $cutoff }
    }

    $size = ($files | Measure-Object -Property Length -Sum).Sum
    if (-not $size) { $size = 0 }
    $count = ($files | Measure-Object).Count

    $script:totalFound += $size
    $script:results += [PSCustomObject]@{
        Label = $Label
        Size  = $size
        Count = $count
    }

    if ($count -eq 0) {
        Write-Skip "$Label — nothing to clean"
        return
    }

    $sizeStr = Format-Size $size

    if ($DryRun) {
        Write-Host ("   [REPORT] {0,-45} {1,12}  ({2} files)" -f $Label, $sizeStr, $count) -ForegroundColor Yellow
    } else {
        # Delete files
        $deleted = 0
        foreach ($f in $files) {
            try {
                Remove-Item $f.FullName -Force -ErrorAction Stop
                $deleted += $f.Length
            } catch {
                # File locked or in use — skip silently
            }
        }

        # Clean empty directories if deleting root
        if ($DeleteRoot) {
            try { Remove-Item $Path -Recurse -Force -ErrorAction SilentlyContinue } catch {}
        } else {
            # Remove empty subdirectories
            Get-ChildItem -Path $Path -Directory -Recurse -Force -ErrorAction SilentlyContinue |
                Sort-Object { $_.FullName.Length } -Descending |
                ForEach-Object {
                    $items = Get-ChildItem $_.FullName -Force -ErrorAction SilentlyContinue
                    if (-not $items) {
                        try { Remove-Item $_.FullName -Force -ErrorAction Stop } catch {}
                    }
                }
        }

        $script:totalCleaned += $deleted
        Write-OK ("{0,-45} freed {1}" -f $Label, (Format-Size $deleted))
    }
}

# ── Mode Banner ─────────────────────────────────────────────────────────────────

Write-Host ""
Write-Host ("=" * 65) -ForegroundColor White
if ($DryRun) {
    Write-Host "  REPORT MODE — showing what would be cleaned (no deletions)" -ForegroundColor Yellow
    Write-Host "  Re-run with -Confirm to actually delete files." -ForegroundColor Yellow
} else {
    Write-Host "  CLEANUP MODE — files will be permanently deleted" -ForegroundColor Red
}
Write-Host ("=" * 65) -ForegroundColor White

# ── Category 1: User Temp ───────────────────────────────────────────────────────

Write-Header "User Temp Directory ($env:TEMP)"

# General temp files older than 1 day
Clean-Directory -Path $env:TEMP -Label "User TEMP (files >1 day old)" -MinAgeDays 1

# ── Category 2: System Temp ─────────────────────────────────────────────────────

Write-Header "System Temp Directory"

Clean-Directory -Path "$env:SystemRoot\Temp" -Label "Windows TEMP (files >1 day old)" -MinAgeDays 1

# ── Category 3: Windows Update Caches ───────────────────────────────────────────

Write-Header "Windows Update Caches"

Clean-Directory -Path "$env:SystemRoot\SoftwareDistribution\Download" -Label "WU Download Cache"
Clean-Directory -Path "$env:SystemRoot\SoftwareDistribution\DeliveryOptimization" -Label "Delivery Optimization Cache"

# ── Category 4: Windows Logs ────────────────────────────────────────────────────

Write-Header "Windows Logs (CBS, DISM, WU ETL)"

Clean-Directory -Path "$env:SystemRoot\Logs\CBS" -Label "CBS Logs (>7 days)" -MinAgeDays 7 -FileFilter "*.log"
Clean-Directory -Path "$env:SystemRoot\Logs\CBS" -Label "CBS Cab files" -FileFilter "*.cab"
Clean-Directory -Path "$env:SystemRoot\Logs\DISM" -Label "DISM Logs (>7 days)" -MinAgeDays 7
Clean-Directory -Path "$env:SystemRoot\Logs\WindowsUpdate" -Label "WU ETL Logs (>7 days)" -MinAgeDays 7
Clean-Directory -Path "$env:SystemRoot\Panther" -Label "Windows Panther logs (>7 days)" -MinAgeDays 7

# ── Category 5: Crash Dumps ────────────────────────────────────────────────────

Write-Header "Crash Dumps"

Clean-Directory -Path "$env:LOCALAPPDATA\CrashDumps" -Label "User crash dumps"
Clean-Directory -Path "$env:SystemRoot\Minidump" -Label "System minidumps"

# Memory.dmp
$memDump = "$env:SystemRoot\Memory.dmp"
if (Test-Path $memDump) {
    $dmpSize = (Get-Item $memDump -Force).Length
    $script:totalFound += $dmpSize
    $script:results += [PSCustomObject]@{ Label = "System Memory.dmp"; Size = $dmpSize; Count = 1 }
    if ($DryRun) {
        Write-Host ("   [REPORT] {0,-45} {1,12}" -f "System Memory.dmp", (Format-Size $dmpSize)) -ForegroundColor Yellow
    } else {
        try {
            Remove-Item $memDump -Force -ErrorAction Stop
            $script:totalCleaned += $dmpSize
            Write-OK "System Memory.dmp — freed $(Format-Size $dmpSize)"
        } catch {
            Write-Err "Could not delete Memory.dmp (may be locked)"
        }
    }
}

# ── Category 6: Error Reports ──────────────────────────────────────────────────

Write-Header "Windows Error Reports"

Clean-Directory -Path "C:\ProgramData\Microsoft\Windows\WER" -Label "System error reports"
Clean-Directory -Path "$env:LOCALAPPDATA\Microsoft\Windows\WER" -Label "User error reports"

# ── Category 7: Browser Caches ─────────────────────────────────────────────────

Write-Header "Browser Caches"

# Edge
Clean-Directory -Path "$env:LOCALAPPDATA\Microsoft\Edge\User Data\Default\Cache" -Label "Edge Cache"
Clean-Directory -Path "$env:LOCALAPPDATA\Microsoft\Edge\User Data\Default\Code Cache" -Label "Edge Code Cache"

# Chrome (if present)
Clean-Directory -Path "$env:LOCALAPPDATA\Google\Chrome\User Data\Default\Cache" -Label "Chrome Cache"
Clean-Directory -Path "$env:LOCALAPPDATA\Google\Chrome\User Data\Default\Code Cache" -Label "Chrome Code Cache"

# ── Category 8: Developer Caches ───────────────────────────────────────────────

Write-Header "Developer Tool Caches"

Clean-Directory -Path "$env:APPDATA\Code\CachedData" -Label "VSCode CachedData"

# NuGet — use dotnet CLI for proper cleanup
$nugetPath = "$env:USERPROFILE\.nuget\packages"
if (Test-Path $nugetPath) {
    $nugetSize = Get-DirSize $nugetPath
    $script:totalFound += $nugetSize
    $script:results += [PSCustomObject]@{ Label = "NuGet package cache"; Size = $nugetSize; Count = 0 }
    if ($DryRun) {
        Write-Host ("   [REPORT] {0,-45} {1,12}" -f "NuGet package cache", (Format-Size $nugetSize)) -ForegroundColor Yellow
    } else {
        $dotnet = Get-Command dotnet -ErrorAction SilentlyContinue
        if ($dotnet) {
            & dotnet nuget locals all --clear 2>&1 | Out-Null
            $script:totalCleaned += $nugetSize
            Write-OK "NuGet cache cleared via 'dotnet nuget locals all --clear'"
        } else {
            Clean-Directory -Path $nugetPath -Label "NuGet package cache"
        }
    }
} else {
    Write-Skip "NuGet package cache — not found"
}

# npm cache (if present)
$npmCache = "$env:APPDATA\npm-cache"
if (Test-Path $npmCache) {
    $npmSize = Get-DirSize $npmCache
    if ($npmSize -gt 1MB) {
        $script:totalFound += $npmSize
        $script:results += [PSCustomObject]@{ Label = "npm cache"; Size = $npmSize; Count = 0 }
        if ($DryRun) {
            Write-Host ("   [REPORT] {0,-45} {1,12}" -f "npm cache", (Format-Size $npmSize)) -ForegroundColor Yellow
        } else {
            $npm = Get-Command npm -ErrorAction SilentlyContinue
            if ($npm) {
                & npm cache clean --force 2>&1 | Out-Null
                $script:totalCleaned += $npmSize
                Write-OK "npm cache cleared via 'npm cache clean --force'"
            } else {
                Clean-Directory -Path $npmCache -Label "npm cache"
            }
        }
    }
}

# pip cache (if present)
$pipCache = "$env:LOCALAPPDATA\pip\cache"
if (Test-Path $pipCache) {
    $pipSize = Get-DirSize $pipCache
    if ($pipSize -gt 1MB) {
        $script:totalFound += $pipSize
        $script:results += [PSCustomObject]@{ Label = "pip cache"; Size = $pipSize; Count = 0 }
        if ($DryRun) {
            Write-Host ("   [REPORT] {0,-45} {1,12}" -f "pip cache", (Format-Size $pipSize)) -ForegroundColor Yellow
        } else {
            Clean-Directory -Path $pipCache -Label "pip cache"
        }
    }
}

# VS installer logs in TEMP
Clean-Directory -Path $env:TEMP -Label "VS installer logs in TEMP" -FileFilter "dd_*.log" -MinAgeDays 1
Clean-Directory -Path $env:TEMP -Label "VS temp directories" -FileFilter "*.tmp" -MinAgeDays 1

# ── Category 9: OneDrive Logs ──────────────────────────────────────────────────

Write-Header "OneDrive Logs"

Clean-Directory -Path "$env:LOCALAPPDATA\Microsoft\OneDrive\logs" -Label "OneDrive logs (>7 days)" -MinAgeDays 7

# ── Category 10: Explorer & UI Caches ──────────────────────────────────────────

Write-Header "Explorer and UI Caches"

# Thumbnail cache — only the thumbcache_*.db files
Clean-Directory -Path "$env:LOCALAPPDATA\Microsoft\Windows\Explorer" -Label "Explorer thumbnail cache" -FileFilter "thumbcache_*.db"
Clean-Directory -Path "$env:LOCALAPPDATA\D3DSCache" -Label "DirectX shader cache"
Clean-Directory -Path "$env:LOCALAPPDATA\AMD\DxCache" -Label "AMD shader cache"

# ── Category 11: WinGet temp ───────────────────────────────────────────────────

Write-Header "WinGet Temp"

Clean-Directory -Path "$env:TEMP\WinGet" -Label "WinGet temp files"

# ── Category 12: Recycle Bin ────────────────────────────────────────────────────

Write-Header "Recycle Bin"

$recyclePath = 'C:\$Recycle.Bin'
if (Test-Path $recyclePath -ErrorAction SilentlyContinue) {
    $recycleSize = Get-DirSize $recyclePath
    $script:totalFound += $recycleSize
    $script:results += [PSCustomObject]@{ Label = "Recycle Bin"; Size = $recycleSize; Count = 0 }
    if ($DryRun) {
        Write-Host ("   [REPORT] {0,-45} {1,12}" -f "Recycle Bin", (Format-Size $recycleSize)) -ForegroundColor Yellow
    } else {
        try {
            Clear-RecycleBin -Force -ErrorAction Stop
            $script:totalCleaned += $recycleSize
            Write-OK "Recycle Bin emptied"
        } catch {
            Write-Err "Could not empty Recycle Bin — $($_.Exception.Message)"
        }
    }
} else {
    Write-Skip "Recycle Bin — empty or inaccessible"
}

# ── Category 13: WinSxS Component Cleanup (via DISM) ───────────────────────────

if (-not $SkipDISM) {
    Write-Header "WinSxS Component Store Cleanup (DISM)"

    if ($DryRun) {
        # Analyze only
        Write-Host "   [REPORT] Running DISM /AnalyzeComponentStore..." -ForegroundColor Yellow
        $dismOutput = & DISM /Online /Cleanup-Image /AnalyzeComponentStore 2>&1
        $reclaimable = $dismOutput | Select-String "Reclaimable"
        if ($reclaimable) {
            Write-Host "   [REPORT] $($reclaimable.Line.Trim())" -ForegroundColor Yellow
        }
        $recommended = $dismOutput | Select-String "Component Store Cleanup Recommended"
        if ($recommended) {
            Write-Host "   [REPORT] $($recommended.Line.Trim())" -ForegroundColor Yellow
        }
    } else {
        Write-Host "   Running DISM /StartComponentCleanup (this may take a few minutes)..." -ForegroundColor Cyan
        $dismOutput = & DISM /Online /Cleanup-Image /StartComponentCleanup 2>&1
        if ($LASTEXITCODE -eq 0) {
            Write-OK "DISM component cleanup completed"
        } else {
            Write-Err "DISM cleanup finished with warnings — $LASTEXITCODE"
        }
    }
}

# ── Category 14: Windows.old and Upgrade Leftovers ─────────────────────────────

Write-Header "Upgrade Leftovers"

foreach ($upgradeDir in @('C:\Windows.old', 'C:\$WINDOWS.~BT', 'C:\$WinREAgent')) {
    if (Test-Path $upgradeDir -ErrorAction SilentlyContinue) {
        $dirSize = Get-DirSize $upgradeDir
        if ($dirSize -gt 0) {
            $script:totalFound += $dirSize
            $script:results += [PSCustomObject]@{ Label = $upgradeDir; Size = $dirSize; Count = 0 }
            if ($DryRun) {
                Write-Host ("   [REPORT] {0,-45} {1,12}" -f $upgradeDir, (Format-Size $dirSize)) -ForegroundColor Yellow
            } else {
                try {
                    # Take ownership first (these are often SYSTEM-protected)
                    & takeown /F $upgradeDir /R /D Y 2>&1 | Out-Null
                    & icacls $upgradeDir /grant Administrators:F /T /Q 2>&1 | Out-Null
                    Remove-Item $upgradeDir -Recurse -Force -ErrorAction Stop
                    $script:totalCleaned += $dirSize
                    Write-OK "$upgradeDir removed"
                } catch {
                    Write-Err "Could not fully remove $upgradeDir — $($_.Exception.Message)"
                }
            }
        }
    }
}

# ── Summary ─────────────────────────────────────────────────────────────────────

Write-Host ""
Write-Host ("=" * 65) -ForegroundColor White

if ($DryRun) {
    Write-Host ""
    Write-Host "  REPORT SUMMARY" -ForegroundColor Cyan
    Write-Host ""

    # Show sorted results
    $script:results | Where-Object { $_.Size -gt 0 } |
        Sort-Object Size -Descending |
        ForEach-Object {
            Write-Host ("   {0,-45} {1,12}" -f $_.Label, (Format-Size $_.Size))
        }

    Write-Host ""
    Write-Host "  Total reclaimable: $(Format-Size $script:totalFound)" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "  To clean, re-run with:  .\Clean-TempFiles.ps1 -Confirm" -ForegroundColor Yellow
} else {
    Write-Host ""
    Write-Host "  CLEANUP COMPLETE" -ForegroundColor Green
    Write-Host "  Total freed: $(Format-Size $script:totalCleaned)" -ForegroundColor Green
    Write-Host ""
    Write-Host "  Note: Some files may have been skipped (locked/in-use)." -ForegroundColor DarkGray
}

Write-Host ("=" * 65) -ForegroundColor White
Write-Host ""

Read-Host "Press Enter to exit"
