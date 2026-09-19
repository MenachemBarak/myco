#Requires -Version 5.1
<#
.SYNOPSIS
    Removes myco from the current user's PATH, PowerShell profiles and disk.

.DESCRIPTION
    Undoes install.ps1. Your project .copilot folders are never touched, and
    the myco registry is kept unless -Purge is given.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File install\uninstall.ps1
#>
[CmdletBinding()]
param(
    [string]$InstallDir = '',
    [switch]$Purge
)

$ErrorActionPreference = 'Stop'

function Write-Step { param([string]$Text) Write-Host ('  ' + $Text) }

$mycoHome = if ($env:MYCO_HOME) { $env:MYCO_HOME } else { Join-Path $env:APPDATA '.myco' }
if (-not $InstallDir) { $InstallDir = Join-Path $mycoHome 'app' }
$binTarget = Join-Path $InstallDir 'bin'

Write-Host ''
Write-Host 'Uninstalling myco' -ForegroundColor Cyan
Write-Host ''

# ----------------------------------------------------------------- user PATH

$userPath = [Environment]::GetEnvironmentVariable('PATH', 'User')
if ($userPath) {
    $entries = @($userPath -split ';' | Where-Object { $_ })
    $kept = @($entries | Where-Object { $_.TrimEnd('\') -ine $binTarget.TrimEnd('\') })
    if ($kept.Count -ne $entries.Count) {
        [Environment]::SetEnvironmentVariable('PATH', ($kept -join ';'), 'User')
        Write-Step 'PATH       launcher removed'
    } else {
        Write-Step 'PATH       nothing to remove'
    }
}

# --------------------------------------------------------- PowerShell profile

$marker = '# myco'
$profilePaths = @(
    (Join-Path $env:USERPROFILE 'Documents\WindowsPowerShell\Microsoft.PowerShell_profile.ps1'),
    (Join-Path $env:USERPROFILE 'Documents\PowerShell\Microsoft.PowerShell_profile.ps1')
)
$documents = [Environment]::GetFolderPath('MyDocuments')
if ($documents) {
    $profilePaths += (Join-Path $documents 'WindowsPowerShell\Microsoft.PowerShell_profile.ps1')
    $profilePaths += (Join-Path $documents 'PowerShell\Microsoft.PowerShell_profile.ps1')
}

$cleaned = 0
foreach ($profilePath in @($profilePaths | Sort-Object -Unique)) {
    if (-not (Test-Path -LiteralPath $profilePath -PathType Leaf)) { continue }
    $existing = @(Get-Content -LiteralPath $profilePath)
    $kept = @($existing | Where-Object { $_ -notmatch [regex]::Escape($marker) })
    if ($kept.Count -ne $existing.Count) {
        Set-Content -LiteralPath $profilePath -Value $kept -Encoding UTF8
        $cleaned++
    }
}
Write-Step ('profile    ' + $cleaned + ' profile(s) cleaned')

# ---------------------------------------------------------------------- disk

if (Test-Path -LiteralPath $InstallDir -PathType Container) {
    Remove-Item -LiteralPath $InstallDir -Recurse -Force
    Write-Step ('files      removed ' + $InstallDir)
}

if ($Purge) {
    foreach ($file in @('registry.json', 'config.json')) {
        $path = Join-Path $mycoHome $file
        if (Test-Path -LiteralPath $path -PathType Leaf) { Remove-Item -LiteralPath $path -Force }
    }
    Write-Step 'registry   purged'
} else {
    Write-Step 'registry   kept (use -Purge to delete it)'
}

Write-Host ''
Write-Host 'Done. Your project .copilot folders were left untouched.' -ForegroundColor Green
Write-Host ''
