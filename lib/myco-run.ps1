#Requires -Version 5.1
<#
    Executable shim used by myco.cmd.

    cmd.exe hands the user's arguments over as MYCO_ARGC / MYCO_ARG_n
    environment variables. That keeps arguments such as --model out of
    PowerShell's parameter binder and preserves them exactly as typed.

    When a launch is needed this writes a batch fragment to -PlanFile, which
    myco.cmd then runs inside the caller's own cmd.exe session so that the
    directory change survives.
#>
param(
    [string]$Shell = 'cmd',
    [string]$PlanFile = '',
    [string]$CurrentDirectory = ''
)

. (Join-Path $PSScriptRoot 'myco-core.ps1')

$argv = @()
$count = 0
if ($env:MYCO_ARGC) { [void][int]::TryParse($env:MYCO_ARGC, [ref]$count) }
for ($i = 1; $i -le $count; $i++) {
    $value = [Environment]::GetEnvironmentVariable('MYCO_ARG_' + $i)
    if ($null -eq $value) { $value = '' }
    $argv += $value
}

$result = Invoke-MycoCore -Arguments $argv -CurrentDirectory $CurrentDirectory

if ($result.Plan -and $PlanFile) {
    try {
        Write-MycoCmdPlan -PlanFile $PlanFile -Plan $result.Plan
    } catch {
        Write-MycoError $_.Exception.Message
        exit 1
    }
}

exit ([int]$result.ExitCode)
