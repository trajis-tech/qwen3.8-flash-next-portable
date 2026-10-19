# Set a fixed-size Windows page file for Strata. Needs administrator rights; takes effect after a reboot.
#
#   .\set_pagefile.ps1               fixed 65536 MB on this folder's drive; the system drive stays system-managed
#   .\set_pagefile.ps1 -Drive E      put it on another internal SSD
#   .\set_pagefile.ps1 -DryRun       show what would be written, change nothing (no admin needed)
#   .\set_pagefile.ps1 -Restore      put back the setting saved before the last change
#   START.bat -SetPageFile           same as the first line
#
# Strata's engine commits ~80 GiB in low-RAM mode (~100 GiB otherwise). Windows allows RAM + page file
# in total, and a system-managed page file may not grow in time, so Strata asks for a fixed 65536 MB.
param(
    [string]$Drive = "",
    [int]$SizeMB = 65536,
    [switch]$DryRun,
    [switch]$Restore,
    [switch]$Force,           # allow a USB/HDD/unknown drive
    [string[]]$FromValue,     # testing: pretend this is the current registry value
    [switch]$Elevated         # internal: set when this script relaunched itself as administrator
)

$ErrorActionPreference = "Stop"
$root = (Resolve-Path $PSScriptRoot).Path
$state = Join-Path $root "portable_state"
$key = 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Memory Management'
$sysDrive = $env:SystemDrive.Substring(0, 1).ToUpper()

function Write-Step($text) { Write-Host "-- $text" }
function Write-Warn($text) { Write-Host "!! $text" -ForegroundColor Yellow }
function Exit-Script($code) {
    if ($Elevated) { Read-Host "Press Enter to close this window" | Out-Null }
    exit $code
}
function Test-Admin {
    $id = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
    return $id.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

# Registry format: one "X:\pagefile.sys INITIAL MAX" line per drive; "0 0" = system-managed size;
# "?:\pagefile.sys" = Windows manages all drives automatically.
function Get-NewPagingFiles($current) {
    $entries = [ordered]@{}
    $auto = $false
    foreach ($line in $current) {
        $t = "$line".Trim()
        if (-not $t) { continue }
        if ($t.StartsWith("?:")) { $auto = $true; continue }
        $entries[$t.Substring(0, 1).ToUpper()] = $t
    }
    # Leaving automatic mode: keep a system-managed page file on the system drive (crash dumps need it).
    if ($auto -and -not $entries.Contains($sysDrive)) { $entries[$sysDrive] = "${sysDrive}:\pagefile.sys 0 0" }
    $entries[$Drive] = "${Drive}:\pagefile.sys $SizeMB $SizeMB"
    return @($entries.Values)
}

function Write-PagingFiles($value) {
    Set-ItemProperty $key -Name PagingFiles -Type MultiString -Value $value
    $back = @((Get-ItemProperty $key).PagingFiles)
    if (($back -join "|") -ne ($value -join "|")) { throw "the registry did not keep the new value: $($back -join ' ; ')" }
    Write-Step "Written:"
    $back | ForEach-Object { Write-Host "     $_" }
    Write-Step "Restart Windows for this to take effect. Model downloads resume on the next START.bat."
}

try {
    if (-not $Drive) {
        if ($root -notmatch '^[A-Za-z]:') { throw "This folder is not on a drive letter; pass -Drive" }
        $Drive = $root.Substring(0, 1)
    }
    $Drive = $Drive.TrimEnd(":", "\").ToUpper()
    if ($Drive -notmatch '^[A-Z]$') { throw "-Drive must be a drive letter such as D" }

    if (-not $DryRun -and -not (Test-Admin)) {
        Write-Step "Administrator rights are needed; Windows will ask for permission."
        $argList = @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", "`"$PSCommandPath`"", "-Elevated", "-Drive", $Drive, "-SizeMB", $SizeMB)
        if ($Restore) { $argList += "-Restore" }
        if ($Force) { $argList += "-Force" }
        try {
            $p = Start-Process powershell.exe -Verb RunAs -ArgumentList $argList -Wait -PassThru
        } catch {
            throw "Administrator permission was not granted; nothing was changed."
        }
        exit $p.ExitCode
    }

    if ($Restore) {
        $backup = Get-ChildItem $state -Filter "pagefile-backup-*.txt" -ErrorAction SilentlyContinue | Sort-Object Name -Descending | Select-Object -First 1
        if (-not $backup) { throw "No backup found in $state" }
        $value = @(Get-Content $backup.FullName | Where-Object { $_.Trim() })
        Write-Step "Restoring $($backup.Name)"
        if ($DryRun) { $value | ForEach-Object { Write-Host "     $_" }; Exit-Script 0 }
        Write-PagingFiles $value
        Exit-Script 0
    }

    # The target must be an internal drive that can hold the page file.
    $part = Get-Partition -DriveLetter $Drive -ErrorAction SilentlyContinue
    if (-not $part) { throw "Drive ${Drive}: was not found" }
    $disk = Get-PhysicalDisk | Where-Object DeviceId -eq "$($part.DiskNumber)" | Select-Object -First 1
    if ($disk) {
        Write-Step "Drive ${Drive}: $($disk.FriendlyName), bus $($disk.BusType), media $($disk.MediaType)"
        $bad = ("$($disk.BusType)" -in @("USB", "SD", "MMC")) -or ("$($disk.MediaType)" -eq "HDD")
        if ($bad -and -not $Force) { throw "Drive ${Drive}: is a USB or hard-disk drive; choose an internal SSD with -Drive, or add -Force" }
        if ("$($disk.MediaType)" -ne "SSD") { Write-Warn "Windows does not report drive ${Drive}: as an SSD; make sure it is one." }
    } else {
        Write-Warn "Could not identify the disk behind ${Drive}: (RAID or storage space?); make sure it is an internal SSD."
    }
    $existingMB = 0
    $usage = Get-CimInstance Win32_PageFileUsage -ErrorAction SilentlyContinue | Where-Object { $_.Name -like "${Drive}:\*" }
    if ($usage) { $existingMB = [int]($usage | Measure-Object AllocatedBaseSize -Sum).Sum }
    $freeMB = [math]::Floor((Get-PSDrive $Drive).Free / 1MB)
    if ($freeMB + $existingMB -lt $SizeMB + 1024) { throw "Drive ${Drive}: has $freeMB MB free; $SizeMB MB plus 1 GB headroom is needed" }

    $current = if ($PSBoundParameters.ContainsKey("FromValue")) { @($FromValue | ForEach-Object { $_ -split "," }) } else { @((Get-ItemProperty $key).PagingFiles) }
    $new = Get-NewPagingFiles $current
    Write-Step "Current setting:"
    $current | ForEach-Object { Write-Host "     $_" }
    Write-Step "New setting:"
    $new | ForEach-Object { Write-Host "     $_" }
    if (($current -join "|") -eq ($new -join "|")) { Write-Step "Already set; nothing to change."; Exit-Script 0 }
    if ($DryRun) { Write-Step "Dry run: nothing was changed."; Exit-Script 0 }

    New-Item -ItemType Directory -Force $state | Out-Null
    $backupFile = Join-Path $state ("pagefile-backup-" + (Get-Date -Format "yyyyMMddHHmmss") + ".txt")
    Set-Content -Encoding ascii -Path $backupFile -Value $current
    Write-Step "Backup of the current setting: $backupFile  (undo with set_pagefile.ps1 -Restore)"
    Write-PagingFiles $new
    Exit-Script 0
} catch {
    Write-Warn $_.Exception.Message
    Exit-Script 1
}
