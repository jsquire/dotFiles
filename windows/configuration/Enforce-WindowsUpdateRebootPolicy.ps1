#Requires -Version 5.1
<#
.SYNOPSIS
    Prevents Windows Update from rebooting without explicit user approval.

.DESCRIPTION
    Applies Group Policy registry settings and disables Update Orchestrator reboot
    scheduled tasks to ensure Windows Update never reboots the machine automatically.

    Root cause: The legacy "NoAutoRebootWithLoggedOnUsers" policy alone is ignored by
    the modern Update Orchestrator (MoUsoCoreWorker.exe). This script applies the full
    set of policies needed to enforce manual reboot approval:

      1. AUOptions = 2 (Notify before download AND install)
      2. NoAutoRebootWithLoggedOnUsers = 1 (no reboot while logged in)
      3. Active Hours extended to 4 AM - 1 AM (21-hour window)
      4. Update Orchestrator reboot tasks disabled with locked permissions

    Safe to re-run after Windows updates re-enable reboot tasks.

.NOTES
    Must be run as Administrator. Self-elevates if not already elevated.
    Creates a timestamped registry backup before making changes.
#>

[CmdletBinding()]
param(
    [switch]$SkipBackup,
    [switch]$RestoreOnly
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition

# ── Self-Elevation ──────────────────────────────────────────────────────────────

function Test-IsAdmin {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]$identity
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

if (-not (Test-IsAdmin)) {
    Write-Host "Not running as Administrator. Requesting elevation..." -ForegroundColor Yellow
    $args = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$($MyInvocation.MyCommand.Definition)`"")
    if ($SkipBackup) { $args += '-SkipBackup' }
    if ($RestoreOnly) { $args += '-RestoreOnly' }
    Start-Process powershell.exe -ArgumentList $args -Verb RunAs -Wait
    exit
}

# ── Helper Functions ────────────────────────────────────────────────────────────

function Write-Step {
    param([string]$Message)
    Write-Host "`n>> $Message" -ForegroundColor Cyan
}

function Write-OK {
    param([string]$Message)
    Write-Host "   [OK] $Message" -ForegroundColor Green
}

function Write-Warn {
    param([string]$Message)
    Write-Host "   [WARN] $Message" -ForegroundColor Yellow
}

function Write-Fail {
    param([string]$Message)
    Write-Host "   [FAIL] $Message" -ForegroundColor Red
}

function Set-RegistryValue {
    param(
        [string]$Path,
        [string]$Name,
        [int]$Value
    )
    if (-not (Test-Path $Path)) {
        New-Item -Path $Path -Force | Out-Null
    }
    Set-ItemProperty -Path $Path -Name $Name -Value $Value -Type DWord -Force
}

# ── Registry Paths ──────────────────────────────────────────────────────────────

$AUPath = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU"
$WUPath = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate"

# ── Backup ──────────────────────────────────────────────────────────────────────

function Backup-Registry {
    Write-Step "Backing up current Windows Update policy registry keys"

    $timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
    $backupFile = Join-Path $ScriptDir "WU-Policy-Backup-$timestamp.reg"

    $regPaths = @(
        "HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate"
    )

    $exportSuccess = $true
    foreach ($rp in $regPaths) {
        $result = & reg.exe export $rp $backupFile /y 2>&1
        if ($LASTEXITCODE -ne 0) {
            # Key might not exist yet — that's fine
            Write-Warn "Registry key '$rp' not found (nothing to back up, will be created)"
            $exportSuccess = $false
        }
    }

    if ($exportSuccess) {
        Write-OK "Backup saved to: $backupFile"
    }

    return $backupFile
}

# ── Restore ─────────────────────────────────────────────────────────────────────

function Restore-Backup {
    $backups = Get-ChildItem -Path $ScriptDir -Filter "WU-Policy-Backup-*.reg" | Sort-Object LastWriteTime -Descending
    if ($backups.Count -eq 0) {
        Write-Fail "No backup files found in $ScriptDir"
        return
    }

    Write-Host "`nAvailable backups:" -ForegroundColor Cyan
    for ($i = 0; $i -lt $backups.Count; $i++) {
        Write-Host "  [$i] $($backups[$i].Name) ($($backups[$i].LastWriteTime))"
    }

    $choice = Read-Host "`nEnter number to restore (or 'q' to cancel)"
    if ($choice -eq 'q') { return }

    $idx = [int]$choice
    if ($idx -lt 0 -or $idx -ge $backups.Count) {
        Write-Fail "Invalid selection"
        return
    }

    $file = $backups[$idx].FullName
    Write-Step "Restoring from: $($backups[$idx].Name)"
    & reg.exe import $file 2>&1 | Out-Null
    if ($LASTEXITCODE -eq 0) {
        Write-OK "Registry restored successfully. Run 'gpupdate /force' to apply."
    } else {
        Write-Fail "Registry restore failed"
    }
}

if ($RestoreOnly) {
    Restore-Backup
    Read-Host "`nPress Enter to exit"
    exit
}

# ── Step 1: Backup ──────────────────────────────────────────────────────────────

if (-not $SkipBackup) {
    Backup-Registry
}

# ── Step 2: Configure Automatic Updates (AUOptions = 2) ────────────────────────

Write-Step "Configuring Automatic Updates: Notify before download AND install"

Set-RegistryValue -Path $AUPath -Name "AUOptions" -Value 2
Write-OK "AUOptions = 2 (Notify for download and notify for install)"

Set-RegistryValue -Path $AUPath -Name "NoAutoUpdate" -Value 0
Write-OK "NoAutoUpdate = 0 (Update detection remains active)"

# ── Step 3: No Auto Reboot With Logged On Users ────────────────────────────────

Write-Step "Enforcing: No auto-reboot with logged-on users"

Set-RegistryValue -Path $AUPath -Name "NoAutoRebootWithLoggedOnUsers" -Value 1
Write-OK "NoAutoRebootWithLoggedOnUsers = 1"

# ── Step 4: Extend Active Hours (4 AM - 1 AM = 21 hours) ───────────────────────

Write-Step "Extending Active Hours (4:00 AM - 1:00 AM)"

Set-RegistryValue -Path $WUPath -Name "SetActiveHours" -Value 1
Set-RegistryValue -Path $WUPath -Name "ActiveHoursStart" -Value 4
Set-RegistryValue -Path $WUPath -Name "ActiveHoursEnd" -Value 1
Write-OK "Active hours: 4:00 AM - 1:00 AM (21 hours)"

# ── Step 5: Remove any deadline enforcement policies ────────────────────────────

Write-Step "Removing deadline enforcement policies (if any)"

$deadlineValues = @(
    "ConfigureDeadlineForQualityUpdates",
    "ConfigureDeadlineForFeatureUpdates",
    "ConfigureDeadlineGracePeriod",
    "ConfigureDeadlineNoAutoReboot"
)

foreach ($val in $deadlineValues) {
    $existing = Get-ItemProperty -Path $WUPath -Name $val -ErrorAction SilentlyContinue
    if ($existing) {
        Remove-ItemProperty -Path $WUPath -Name $val -Force
        Write-OK "Removed $val"
    }
}
Write-OK "No deadline enforcement policies active"

# ── Step 6: Disable Update Orchestrator Reboot Tasks ───────────────────────────

Write-Step "Disabling Update Orchestrator reboot scheduled tasks"

$rebootTasks = @(
    "Reboot_AC",
    "Reboot_Battery",
    "Reboot"
)
$taskPath = "\Microsoft\Windows\UpdateOrchestrator\"

foreach ($taskName in $rebootTasks) {
    try {
        $task = Get-ScheduledTask -TaskPath $taskPath -TaskName $taskName -ErrorAction SilentlyContinue
        if ($task) {
            if ($task.State -ne 'Disabled') {
                Disable-ScheduledTask -TaskPath $taskPath -TaskName $taskName | Out-Null
                Write-OK "Disabled task: $taskName"
            } else {
                Write-OK "Task already disabled: $taskName"
            }

            # Lock the task file to prevent Windows from re-enabling it
            $taskFile = Join-Path $env:SystemRoot "System32\Tasks\Microsoft\Windows\UpdateOrchestrator\$taskName"
            if (Test-Path $taskFile) {
                try {
                    $acl = Get-Acl $taskFile
                    $currentUser = [Security.Principal.WindowsIdentity]::GetCurrent().Name
                    $rule = New-Object Security.AccessControl.FileSystemAccessRule(
                        "SYSTEM", "WriteData", "Deny"
                    )
                    $acl.AddAccessRule($rule)
                    Set-Acl -Path $taskFile -AclObject $acl
                    Write-OK "Locked task file permissions for: $taskName (SYSTEM WriteData denied)"
                } catch {
                    Write-Warn "Could not lock task file for $taskName — $($_.Exception.Message)"
                }
            }
        } else {
            Write-OK "Task not found (may not exist on this build): $taskName"
        }
    } catch {
        Write-Warn "Could not process task $taskName — $($_.Exception.Message)"
    }
}

# ── Step 7: Apply Group Policy ──────────────────────────────────────────────────

Write-Step "Applying Group Policy changes"

$gpResult = & gpupdate /force 2>&1
if ($LASTEXITCODE -eq 0) {
    Write-OK "Group Policy updated successfully"
} else {
    Write-Warn "gpupdate returned non-zero exit code. Output: $gpResult"
}

# ── Step 8: Verification ───────────────────────────────────────────────────────

Write-Step "Verifying applied settings"

$allGood = $true

function Verify-RegValue {
    param([string]$Path, [string]$Name, [int]$Expected, [string]$Description)

    try {
        $actual = (Get-ItemProperty -Path $Path -Name $Name -ErrorAction Stop).$Name
        if ($actual -eq $Expected) {
            Write-OK "$Description = $actual"
        } else {
            Write-Fail "$Description = $actual (expected $Expected)"
            $script:allGood = $false
        }
    } catch {
        Write-Fail "$Description — not found"
        $script:allGood = $false
    }
}

Verify-RegValue $AUPath "AUOptions" 2 "AUOptions (Notify before download)"
Verify-RegValue $AUPath "NoAutoUpdate" 0 "NoAutoUpdate (detection active)"
Verify-RegValue $AUPath "NoAutoRebootWithLoggedOnUsers" 1 "NoAutoRebootWithLoggedOnUsers"
Verify-RegValue $WUPath "SetActiveHours" 1 "SetActiveHours (policy-controlled)"
Verify-RegValue $WUPath "ActiveHoursStart" 4 "ActiveHoursStart (4 AM)"
Verify-RegValue $WUPath "ActiveHoursEnd" 1 "ActiveHoursEnd (1 AM)"

# Verify reboot tasks are disabled
foreach ($taskName in $rebootTasks) {
    $task = Get-ScheduledTask -TaskPath $taskPath -TaskName $taskName -ErrorAction SilentlyContinue
    if ($task) {
        if ($task.State -eq 'Disabled') {
            Write-OK "Reboot task '$taskName' is Disabled"
        } else {
            Write-Fail "Reboot task '$taskName' is $($task.State) — expected Disabled"
            $allGood = $false
        }
    }
}

# ── Summary ─────────────────────────────────────────────────────────────────────

Write-Host "`n" -NoNewline
Write-Host ("=" * 60) -ForegroundColor White
if ($allGood) {
    Write-Host "  ALL SETTINGS VERIFIED — Windows Update will not auto-reboot." -ForegroundColor Green
    Write-Host "  You will be notified before downloads and installations." -ForegroundColor Green
} else {
    Write-Host "  SOME SETTINGS COULD NOT BE VERIFIED — review output above." -ForegroundColor Red
}
Write-Host ("=" * 60) -ForegroundColor White
Write-Host ""
Write-Host "Tip: Re-run this script after major Windows updates if reboot" -ForegroundColor DarkGray
Write-Host "     tasks get re-enabled. Use -RestoreOnly to undo changes." -ForegroundColor DarkGray
Write-Host ""

Read-Host "Press Enter to exit"
