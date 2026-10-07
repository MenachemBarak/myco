#Requires -Version 5.1
<#
    myco - PowerShell entry point.

    Dot-source this file to define the `myco` function:

        . <install-dir>\bin\myco.ps1

    The installer adds that line to your PowerShell profile. It has to be a
    function rather than a script so that `myco resume` can leave your shell
    inside the workspace folder.

    Running the file directly with arguments also works, but the directory
    change then only applies to the Copilot session, not to your shell.
#>

. (Join-Path (Split-Path -Parent $PSScriptRoot) 'lib\myco-core.ps1')

function myco {
    # No param block on purpose: everything, including flags such as --model,
    # must reach Copilot untouched instead of binding to PowerShell parameters.
    $mycoArgs = @($args)

    $directory = ''
    try {
        if ($PWD -and $PWD.Provider -and $PWD.Provider.Name -eq 'FileSystem') {
            $directory = $PWD.ProviderPath
        } else {
            $directory = (Get-Location -PSProvider FileSystem).ProviderPath
        }
    } catch {
        $directory = [System.IO.Directory]::GetCurrentDirectory()
    }

    $result = Invoke-MycoCore -Arguments $mycoArgs -CurrentDirectory $directory

    if (-not $result.Plan) {
        $global:LASTEXITCODE = [int]$result.ExitCode
        return
    }

    $plan = $result.Plan

    if (-not (Get-Command $plan.Command -ErrorAction SilentlyContinue)) {
        Write-MycoError ('the ' + $plan.Command + ' CLI was not found on PATH.')
        $global:LASTEXITCODE = 127
        return
    }

    # Every variable the harness needs is captured before it is changed, and
    # put back in the finally block. Leaking one would silently redirect the
    # user's next plain run of that tool.
    $previous = @{}
    foreach ($name in @($plan.EnvVars.Keys)) {
        $previous[$name] = [Environment]::GetEnvironmentVariable($name)
    }
    $exitCode = 0

    # Splatted, not wrapped in @(): the npm shims on PATH are .ps1 files, and a
    # single array argument would reach the tool as one collapsed string.
    $commandArgs = @($plan.CommandArgs)
    $command = $plan.Command

    try {
        Set-Location -LiteralPath $plan.WorkDir
        foreach ($name in @($plan.EnvVars.Keys)) {
            [Environment]::SetEnvironmentVariable($name, $plan.EnvVars[$name])
        }
        & $command @commandArgs
        if ($null -ne $LASTEXITCODE) { $exitCode = [int]$LASTEXITCODE }
    } catch {
        Write-MycoError $_.Exception.Message
        $exitCode = 1
    } finally {
        foreach ($name in @($previous.Keys)) {
            [Environment]::SetEnvironmentVariable($name, $previous[$name])
        }
    }

    $global:LASTEXITCODE = $exitCode
}

if ($args.Count -gt 0) { myco @args }
