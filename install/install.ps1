#Requires -Version 5.1
<#
.SYNOPSIS
    Installs myco for the current user, for both PowerShell and cmd.exe.

.DESCRIPTION
    Copies myco into %APPDATA%\.myco\app, puts the launcher on the user PATH so
    cmd.exe can find it, and adds one dot-source line to your PowerShell
    profiles so that `myco resume` can move your shell into the workspace.

    Nothing is written outside your own user profile and no administrator
    rights are needed.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File install\install.ps1
#>
[CmdletBinding()]
param(
    [string]$InstallDir = '',
    [switch]$NoPath,
    [switch]$NoProfile
)

$ErrorActionPreference = 'Stop'

function Write-Step { param([string]$Text) Write-Host ('  ' + $Text) }

$sourceRoot = Split-Path -Parent $PSScriptRoot

if (-not $InstallDir) {
    $mycoHome = if ($env:MYCO_HOME) { $env:MYCO_HOME } else { Join-Path $env:APPDATA '.myco' }
    $InstallDir = Join-Path $mycoHome 'app'
}

Write-Host ''
Write-Host 'Installing myco' -ForegroundColor Cyan
Write-Host ''

# ---------------------------------------------------------------- copy files

foreach ($folder in @('bin', 'lib')) {
    $from = Join-Path $sourceRoot $folder
    if (-not (Test-Path -LiteralPath $from -PathType Container)) {
        throw "source folder '$folder' is missing - run this script from a myco checkout"
    }
}

$binTarget = Join-Path $InstallDir 'bin'
New-Item -ItemType Directory -Force -Path $binTarget | Out-Null
foreach ($folder in @('bin', 'lib')) {
    $from = Join-Path $sourceRoot $folder
    $to = Join-Path $InstallDir $folder
    if (Test-Path -LiteralPath $to -PathType Container) {
        Remove-Item -LiteralPath $to -Recurse -Force
    }
    Copy-Item -LiteralPath $from -Destination $to -Recurse -Force
}
Write-Step ('files      ' + $InstallDir)

# ----------------------------------------------------------------- user PATH

if (-not $NoPath) {
    $userPath = [Environment]::GetEnvironmentVariable('PATH', 'User')
    if ($null -eq $userPath) { $userPath = '' }
    $entries = @($userPath -split ';' | Where-Object { $_ })
    $already = $entries | Where-Object { $_.TrimEnd('\') -ieq $binTarget.TrimEnd('\') }
    if ($already) {
        Write-Step 'PATH       already contains the myco launcher'
    } else {
        $updated = (@($entries) + @($binTarget)) -join ';'
        [Environment]::SetEnvironmentVariable('PATH', $updated, 'User')
        Write-Step 'PATH       added for cmd.exe (open a new terminal to pick it up)'
    }
    if (($env:PATH -split ';') -notcontains $binTarget) {
        $env:PATH = $env:PATH + ';' + $binTarget
    }
}

# --------------------------------------------------------- PowerShell profile

if (-not $NoProfile) {
    $marker = '# myco'
    $line = '. "' + (Join-Path $binTarget 'myco.ps1') + '"   ' + $marker

    $profilePaths = @(
        (Join-Path $env:USERPROFILE 'Documents\WindowsPowerShell\Microsoft.PowerShell_profile.ps1'),
        (Join-Path $env:USERPROFILE 'Documents\PowerShell\Microsoft.PowerShell_profile.ps1')
    )
    $documents = [Environment]::GetFolderPath('MyDocuments')
    if ($documents) {
        $profilePaths += (Join-Path $documents 'WindowsPowerShell\Microsoft.PowerShell_profile.ps1')
        $profilePaths += (Join-Path $documents 'PowerShell\Microsoft.PowerShell_profile.ps1')
    }
    $profilePaths = @($profilePaths | Sort-Object -Unique)

    foreach ($profilePath in $profilePaths) {
        $parent = Split-Path -Parent $profilePath
        if (-not (Test-Path -LiteralPath $parent -PathType Container)) {
            New-Item -ItemType Directory -Force -Path $parent | Out-Null
        }
        $existing = @()
        if (Test-Path -LiteralPath $profilePath -PathType Leaf) {
            $existing = @(Get-Content -LiteralPath $profilePath)
        }
        $kept = @($existing | Where-Object { $_ -notmatch [regex]::Escape($marker) })
        $kept += $line
        Set-Content -LiteralPath $profilePath -Value $kept -Encoding UTF8
    }
    Write-Step 'profile    myco function registered for PowerShell 5.1 and 7'
}

# ------------------------------------------------------------------- verify

$checkCmd = Join-Path $binTarget 'myco.cmd'
$checkPs1 = Join-Path $binTarget 'myco.ps1'
if (-not (Test-Path -LiteralPath $checkCmd -PathType Leaf)) { throw 'install failed: myco.cmd is missing' }
if (-not (Test-Path -LiteralPath $checkPs1 -PathType Leaf)) { throw 'install failed: myco.ps1 is missing' }

if (-not (Get-Command copilot -ErrorAction SilentlyContinue)) {
    Write-Host ''
    Write-Host '  note: the copilot CLI is not on PATH yet.' -ForegroundColor Yellow
    Write-Host '        install it with: npm install -g @github/copilot' -ForegroundColor Yellow
}

Write-Host ''
Write-Host 'Done. Open a new terminal, then try:' -ForegroundColor Green
Write-Host '  cd <your project>'
Write-Host '  myco start'
Write-Host '  myco sessions'
Write-Host ''
