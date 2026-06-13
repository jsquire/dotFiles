#Requires -Version 5.1
<#
.SYNOPSIS
    Idempotently hardens Windows Update policy to stop unattended/forced reboots.

.DESCRIPTION
    Root cause this addresses (JESSE-DESKTOP-O, 2026-06-13 ~01:30 reboot):
      * Active Hours policy was inverted (Start=4, End=1), exposing 01:00-04:00 as
        the only auto-restart window. The Update Orchestrator (MoUsoCoreWorker.exe)
        rebooted at 01:29 to finalize KB5094126.
      * NoAutoRebootWithLoggedOnUsers only protects an ACTIVE session, not an idle
        or locked one, so it did not apply overnight.

    This script:
      1. Sets a valid, maximum 18-hour Active Hours window (default 04:00-22:00).
      2. Applies the policy stack that actually GUARANTEES no forced reboots,
         covering the 22:00-04:00 gap that Active Hours cannot:
            ConfigureDeadlineNoAutoReboot = 1
            AlwaysAutoRebootAtScheduledTime = 0
            NoAutoRebootWithLoggedOnUsers  = 1

    It is fully idempotent: every value is read before writing; nothing is changed
    if it is already correct. Safe to re-run.

.PARAMETER ActiveHoursStart
    Active hours start hour (0-23). Default 4 (04:00).

.PARAMETER ActiveHoursEnd
    Active hours end hour (0-23). Default 22 (22:00). The span
    (End - Start, wrapping) must be 1-18 hours per Windows limits.

.PARAMETER DeferQualityUpdatesDays
    Optional. If > 0, also defers quality updates by this many days
    (DeferQualityUpdates=1 + DeferQualityUpdatesPeriodInDays=N). Default 0 (off).

.PARAMETER WhatIf
    Preview changes without writing anything.

.EXAMPLE
    # Apply with defaults (run from an elevated PowerShell):
    .\Fix-WindowsUpdateReboot.ps1

.EXAMPLE
    # Preview only:
    .\Fix-WindowsUpdateReboot.ps1 -WhatIf

.EXAMPLE
    # Apply and also defer quality updates 7 days:
    .\Fix-WindowsUpdateReboot.ps1 -DeferQualityUpdatesDays 7

.NOTES
    Requires an elevated (Administrator) session: it writes under
    HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate.

    Optional manual hardening NOT done here (Windows re-creates these, so it is
    brittle and intentionally left out): disabling the scheduled tasks under
    \Microsoft\Windows\UpdateOrchestrator\ (Reboot, Reboot_AC, Reboot_Battery).
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [ValidateRange(0, 23)]
    [int]$ActiveHoursStart = 4,

    [ValidateRange(0, 23)]
    [int]$ActiveHoursEnd = 22,

    [ValidateRange(0, 30)]
    [int]$DeferQualityUpdatesDays = 0
)

$ErrorActionPreference = 'Stop'

# --- Constants ---------------------------------------------------------------
$WuKey = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate'
$AuKey = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU'

# --- Pre-flight checks -------------------------------------------------------
function Test-IsAdministrator {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($id)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

if (-not (Test-IsAdministrator)) {
    Write-Error ("This script must be run from an elevated (Administrator) PowerShell session, " +
        "because it writes to HKLM\SOFTWARE\Policies. Re-launch as Administrator and try again.")
    exit 1
}

# Validate the active-hours span (Windows allows a contiguous window of 1-18 hours).
$span = ($ActiveHoursEnd - $ActiveHoursStart + 24) % 24
if ($span -eq 0) {
    Write-Error "ActiveHoursStart and ActiveHoursEnd are equal ($ActiveHoursStart); span must be 1-18 hours."
    exit 1
}
if ($span -gt 18) {
    Write-Error ("Active Hours span is $span hours (Start=$ActiveHoursStart, End=$ActiveHoursEnd). " +
        "Windows caps Active Hours at 18 hours. Choose a window of 18 hours or less.")
    exit 1
}

# --- Idempotent registry helper ----------------------------------------------
$script:ChangeCount = 0

function Ensure-RegKey {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) {
        if ($PSCmdlet.ShouldProcess($Path, 'Create registry key')) {
            New-Item -Path $Path -Force | Out-Null
            Write-Host ("  CREATED key  {0}" -f $Path) -ForegroundColor Yellow
        }
    }
}

function Set-RegValueIdempotent {
    param(
        [string]$Path,
        [string]$Name,
        [int]$Value,
        [string]$Type = 'DWord'
    )

    Ensure-RegKey -Path $Path

    $current = $null
    try {
        $current = (Get-ItemProperty -LiteralPath $Path -Name $Name -ErrorAction Stop).$Name
    }
    catch {
        $current = $null
    }

    $label = ('{0}\{1}' -f ($Path -replace '^HKLM:\\SOFTWARE\\Policies\\Microsoft\\Windows\\', ''), $Name)

    if ($null -ne $current -and [int]$current -eq $Value) {
        Write-Host ("  OK           {0} = {1}" -f $label, $Value) -ForegroundColor DarkGray
        return
    }

    if ($PSCmdlet.ShouldProcess($label, ("Set to {0} (was {1})" -f $Value, ($(if ($null -eq $current) { '<missing>' } else { $current }))))) {
        New-ItemProperty -LiteralPath $Path -Name $Name -Value $Value -PropertyType $Type -Force | Out-Null
        $old = if ($null -eq $current) { '<missing>' } else { $current }
        Write-Host ("  CHANGED      {0}: {1} -> {2}" -f $label, $old, $Value) -ForegroundColor Green
        $script:ChangeCount++
    }
}

# --- Apply -------------------------------------------------------------------
Write-Host ""
Write-Host "Applying Windows Update reboot-hardening policy (idempotent)..." -ForegroundColor Cyan
Write-Host ("Active Hours target: {0:00}:00 - {1:00}:00 ({2}h window)" -f $ActiveHoursStart, $ActiveHoursEnd, $span) -ForegroundColor Cyan
Write-Host ""

Write-Host "[Active Hours + deadline policy]  $WuKey"
Set-RegValueIdempotent -Path $WuKey -Name 'SetActiveHours'                -Value 1
Set-RegValueIdempotent -Path $WuKey -Name 'ActiveHoursStart'             -Value $ActiveHoursStart
Set-RegValueIdempotent -Path $WuKey -Name 'ActiveHoursEnd'               -Value $ActiveHoursEnd
Set-RegValueIdempotent -Path $WuKey -Name 'SetComplianceDeadline'        -Value 1
Set-RegValueIdempotent -Path $WuKey -Name 'ConfigureDeadlineNoAutoReboot' -Value 1

Write-Host ""
Write-Host "[Auto-update / no-forced-reboot]  $AuKey"
Set-RegValueIdempotent -Path $AuKey -Name 'NoAutoUpdate'                    -Value 0
Set-RegValueIdempotent -Path $AuKey -Name 'AUOptions'                       -Value 2
Set-RegValueIdempotent -Path $AuKey -Name 'NoAutoRebootWithLoggedOnUsers'   -Value 1
Set-RegValueIdempotent -Path $AuKey -Name 'AlwaysAutoRebootAtScheduledTime' -Value 0

if ($DeferQualityUpdatesDays -gt 0) {
    Write-Host ""
    Write-Host "[Optional: defer quality updates $DeferQualityUpdatesDays day(s)]  $WuKey"
    Set-RegValueIdempotent -Path $WuKey -Name 'DeferQualityUpdates'          -Value 1
    Set-RegValueIdempotent -Path $WuKey -Name 'DeferQualityUpdatesPeriodInDays' -Value $DeferQualityUpdatesDays
}

# --- Verification readout ----------------------------------------------------
Write-Host ""
Write-Host "Effective values after run:" -ForegroundColor Cyan
foreach ($k in @($WuKey, $AuKey)) {
    Write-Host ("  {0}" -f $k) -ForegroundColor White
    if (Test-Path -LiteralPath $k) {
        $props = Get-ItemProperty -LiteralPath $k
        $props.PSObject.Properties |
            Where-Object { $_.Name -notlike 'PS*' } |
            Sort-Object Name |
            ForEach-Object { Write-Host ("    {0,-34} = {1}" -f $_.Name, $_.Value) }
    }
    else {
        Write-Host "    (key not present)"
    }
}

Write-Host ""
if ($WhatIfPreference) {
    Write-Host "WhatIf: no changes were written." -ForegroundColor Yellow
}
else {
    Write-Host ("Done. {0} value(s) changed this run." -f $script:ChangeCount) -ForegroundColor Green
    if ($script:ChangeCount -eq 0) {
        Write-Host "System already compliant; nothing to do." -ForegroundColor Green
    }
}

# --- Context: last update-initiated restart ----------------------------------
Write-Host ""
Write-Host "Most recent restart-initiation events (System log, ID 1074):" -ForegroundColor Cyan
try {
    Get-WinEvent -FilterHashtable @{ LogName = 'System'; Id = 1074 } -MaxEvents 5 -ErrorAction Stop |
        Select-Object TimeCreated,
            @{ N = 'Initiator'; E = { ($_.Message -split "`r?`n")[0] } } |
        Format-Table -AutoSize -Wrap
}
catch {
    Write-Host "  (no 1074 events found or log unavailable)" -ForegroundColor DarkGray
}

Write-Host "Tip: after the next update cycle, re-check ID 1074 above. An unattended" -ForegroundColor DarkGray
Write-Host "     reboot would show MoUsoCoreWorker.exe / TrustedInstaller.exe as initiator." -ForegroundColor DarkGray
