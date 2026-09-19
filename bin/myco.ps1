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

    if (-not (Get-Command copilot -ErrorAction SilentlyContinue)) {
        Write-MycoError 'the copilot CLI was not found on PATH. Install it with: npm install -g @github/copilot'
        $global:LASTEXITCODE = 127
        return
    }

    $hadCopilotHome = Test-Path Env:\COPILOT_HOME
    $previousCopilotHome = if ($hadCopilotHome) { $env:COPILOT_HOME } else { $null }
    $exitCode = 0

    # Splatted, not wrapped in @(): the npm shim on PATH is copilot.ps1, and a
    # single array argument would reach Copilot as one collapsed string.
    $copilotArgs = @($plan.CopilotArgs)

    try {
        Set-Location -LiteralPath $plan.WorkDir
        $env:COPILOT_HOME = $plan.CopilotHome
        & copilot @copilotArgs
        if ($null -ne $LASTEXITCODE) { $exitCode = [int]$LASTEXITCODE }
    } catch {
        Write-MycoError $_.Exception.Message
        $exitCode = 1
    } finally {
        if ($hadCopilotHome) {
            $env:COPILOT_HOME = $previousCopilotHome
        } else {
            Remove-Item Env:\COPILOT_HOME -ErrorAction SilentlyContinue
        }
    }

    $global:LASTEXITCODE = $exitCode
}

if ($args.Count -gt 0) { myco @args }
