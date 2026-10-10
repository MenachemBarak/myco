#Requires -Version 5.1
<#
    Verify-Live-Harnesses.ps1 - proves myco drives the REAL harness CLIs.

    The suite runs against recording stubs, which cannot show whether the real
    tools accept the arguments myco builds for them. This script launches each
    one for real and lets the tool itself be the judge: an unknown flag, or an
    argument list collapsed into a single string by an npm .ps1 shim, makes the
    tool fail here even though every stubbed test passed.

    Most of it costs nothing. `--help` is appended to the launch, so each CLI
    parses everything myco passed, prints its own usage and exits - which also
    identifies which binary actually ran. One paid round trip per naming
    harness then proves a named session really is created and resumable.

    Isolation: its own MYCO_HOME under %TEMP%, workspaces under %TEMP%, and the
    real registry hashed before and after.

        pwsh -NoProfile -ExecutionPolicy Bypass -File test\Verify-Live-Harnesses.ps1
        pwsh -NoProfile -ExecutionPolicy Bypass -File test\Verify-Live-Harnesses.ps1 -SkipPaid
#>

param(
    [string]$RepoRoot = (Split-Path -Parent $PSScriptRoot),
    [switch]$SkipPaid
)

$ErrorActionPreference = 'Stop'
$entry = Join-Path $RepoRoot 'bin\myco.ps1'
$failures = 0

function Check {
    param([string]$What, [bool]$Ok, [string]$Detail = '')
    if ($Ok) { Write-Host ('  [PASS] ' + $What) -ForegroundColor Green }
    else {
        $script:failures++
        Write-Host ('  [FAIL] ' + $What) -ForegroundColor Red
        if ($Detail) { Write-Host ('         ' + $Detail.Trim()) -ForegroundColor DarkGray }
    }
}

function Invoke-MycoLive {
    param([string]$WorkDir, [string[]]$MycoArgs)
    $outFile = [System.IO.Path]::GetTempFileName()
    $errFile = [System.IO.Path]::GetTempFileName()
    $quoted = (@($MycoArgs) | ForEach-Object { "'" + ($_ -replace "'", "''") + "'" }) -join ' '
    $command = ". '$entry'; myco $quoted; exit `$LASTEXITCODE"
    $p = Start-Process -FilePath 'pwsh.exe' `
        -ArgumentList '-NoProfile', '-ExecutionPolicy', 'Bypass', '-Command', $command `
        -WorkingDirectory $WorkDir -NoNewWindow -Wait -PassThru `
        -RedirectStandardOutput $outFile -RedirectStandardError $errFile
    $out = Get-Content -LiteralPath $outFile -Raw -ErrorAction SilentlyContinue
    $err = Get-Content -LiteralPath $errFile -Raw -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $outFile, $errFile -Force -ErrorAction SilentlyContinue
    return [pscustomobject]@{ Output = ([string]$out + [string]$err); ExitCode = $p.ExitCode }
}

# What each real CLI prints for itself, so the right binary having run is
# proved by the tool rather than assumed from the command myco meant to use.
$signatures = @{
    copilot  = 'copilot'
    claude   = 'Usage: claude'
    opencode = 'opencode'
    pi       = 'AI coding assistant'
}

$realRegistry = Join-Path $env:APPDATA '.myco\registry.json'
$before = (Get-FileHash -LiteralPath $realRegistry -ErrorAction SilentlyContinue).Hash

$root = Join-Path $env:TEMP ('myco-live-harness-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Force -Path (Join-Path $root 'myco-home') | Out-Null
$claudeProjects = Join-Path $env:USERPROFILE '.claude\projects'
$claudeBefore = @(Get-ChildItem -LiteralPath $claudeProjects -Directory -ErrorAction SilentlyContinue |
    ForEach-Object { $_.Name })

$savedMyco = $env:MYCO_HOME
$hadMyco = Test-Path Env:\MYCO_HOME
# The invariant is that myco puts these back, not that they were empty: this
# script may itself be run from inside a myco-managed session.
$envBefore = @{}
foreach ($name in @('COPILOT_HOME', 'CLAUDE_CONFIG_DIR', 'XDG_DATA_HOME')) {
    $envBefore[$name] = [Environment]::GetEnvironmentVariable($name)
}
try {
    $env:MYCO_HOME = Join-Path $root 'myco-home'

    foreach ($tool in @('copilot', 'claude', 'opencode', 'pi')) {
        Write-Host ("`n" + $tool) -ForegroundColor Cyan
        $proj = Join-Path $root $tool
        New-Item -ItemType Directory -Force -Path $proj | Out-Null

        $r = Invoke-MycoLive -WorkDir $proj -MycoArgs @($tool, 'start', 'probe', '--help')
        Check ($tool + ' accepted every argument myco built for it') ($r.ExitCode -eq 0) $r.Output
        Check ('and it really was ' + $tool + ' that ran') ($r.Output -match [regex]::Escape($signatures[$tool])) $r.Output
        Check ('myco reported the harness it used') ($r.Output -match ('\(' + $tool)) $r.Output

        # Only copilot and pi keep project state in a folder of their own.
        $copilotFolder = Test-Path -LiteralPath (Join-Path $proj '.copilot')
        $piFolder = Test-Path -LiteralPath (Join-Path $proj '.pi')
        if ($tool -eq 'copilot') {
            Check 'copilot got its per-folder home' $copilotFolder $proj
        } elseif ($tool -eq 'pi') {
            Check 'pi got a session directory in the project' $piFolder $proj
        } else {
            Check ($tool + ' was left on its own state, as intended') `
            ((-not $copilotFolder) -and (-not $piFolder)) `
            ('unexpected folder created in ' + $proj)
        }
    }

    Write-Host "`nno harness environment escapes into the caller" -ForegroundColor Cyan
    foreach ($name in @('COPILOT_HOME', 'CLAUDE_CONFIG_DIR', 'XDG_DATA_HOME')) {
        $now = [Environment]::GetEnvironmentVariable($name)
        Check ($name + ' is exactly as it was before') ($now -eq $envBefore[$name]) `
        ('was <' + [string]$envBefore[$name] + '> now <' + [string]$now + '>')
    }

    if (-not $SkipPaid) {
        Write-Host "`na real named session on copilot" -ForegroundColor Cyan
        $proj = Join-Path $root 'paid-copilot'
        New-Item -ItemType Directory -Force -Path $proj | Out-Null
        $reply = 'Reply with the single word OK and nothing else.'
        $r = Invoke-MycoLive -WorkDir $proj -MycoArgs @('copilot', 'start', 'probe one', '-p', $reply)
        Check 'the session started' ($r.ExitCode -eq 0) $r.Output
        $yaml = @(Get-ChildItem -LiteralPath (Join-Path $proj '.copilot\session-state') -Directory -ErrorAction SilentlyContinue |
                Where-Object { -not $_.Name.StartsWith('.') } |
                ForEach-Object { Get-Content -LiteralPath (Join-Path $_.FullName 'workspace.yaml') -Raw })
        Check 'copilot stored the name myco gave it' (($yaml -join "`n") -match 'probe-one-\d{6}') ($yaml -join "`n")

        Write-Host "`na real named session on claude" -ForegroundColor Cyan
        $proj = Join-Path $root 'paid-claude'
        New-Item -ItemType Directory -Force -Path $proj | Out-Null
        $r = Invoke-MycoLive -WorkDir $proj -MycoArgs @('claude', 'start', 'probe two', '-p', $reply)
        Check 'claude ran the named session' ($r.ExitCode -eq 0) $r.Output
        $claudeDir = @(Get-ChildItem -LiteralPath $claudeProjects -Directory -ErrorAction SilentlyContinue |
                Where-Object { $claudeBefore -notcontains $_.Name })
        Check 'claude recorded it under this project directory' ($claudeDir.Count -ge 1) `
        ('new claude project folders: ' + (($claudeDir | ForEach-Object { $_.Name }) -join ', '))
        if ($claudeDir.Count -ge 1) {
            $jsonl = @(Get-ChildItem -LiteralPath $claudeDir[0].FullName -Filter '*.jsonl' -File -ErrorAction SilentlyContinue)
            Check 'and wrote a session there' ($jsonl.Count -ge 1) $claudeDir[0].FullName

            # The whole point of minting: the file is named after the id myco
            # generated, so myco can find this session again.
            $r = Invoke-MycoLive -WorkDir $proj -MycoArgs @('sessions')
            Check 'myco lists that claude session under the name it was given' `
            ($r.Output -match 'probe-two-\d{6}') $r.Output

            $idCells = @()
            foreach ($line in ($r.Output -split "`r?`n")) {
                if ($line -match '^\s*[\u2502|]\s*(\S+)\s*[\u2502|]') { $idCells += $Matches[1] }
            }
            $mycoId = @($idCells | Where-Object { $_ -match '^probe-two-\d{6}$' })
            Check 'the id column holds the full name-and-id' ($mycoId.Count -eq 1) ($idCells -join ', ')

            if ($mycoId.Count -eq 1) {
                $r = Invoke-MycoLive -WorkDir $root -MycoArgs @('resume', $mycoId[0], '-p', $reply)
                Check 'resuming that claude session by its myco id succeeded' ($r.ExitCode -eq 0) $r.Output
                $after = @(Get-ChildItem -LiteralPath $claudeDir[0].FullName -Filter '*.jsonl' -File)
                Check 'it reused the session rather than forking a new one' `
                ($after.Count -eq $jsonl.Count) `
                (($after | ForEach-Object { $_.Name }) -join ', ')
            }
        }
    } else {
        Write-Host "`nskipping the paid round trips" -ForegroundColor DarkGray
    }
} finally {
    if ($hadMyco) { $env:MYCO_HOME = $savedMyco } else { Remove-Item Env:\MYCO_HOME -ErrorAction SilentlyContinue }
    Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
    # Only the claude project folders this script caused are removed, never one
    # that was already there.
    foreach ($dir in @(Get-ChildItem -LiteralPath $claudeProjects -Directory -ErrorAction SilentlyContinue)) {
        if ($claudeBefore -notcontains $dir.Name) {
            Remove-Item -LiteralPath $dir.FullName -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

$after = (Get-FileHash -LiteralPath $realRegistry -ErrorAction SilentlyContinue).Hash
Check 'the real registry was left exactly as it was found' ($before -eq $after) ("$before -> $after")
Check 'no workspace was left behind under TEMP' (-not (Test-Path -LiteralPath $root)) $root

Write-Host ''
if ($failures -eq 0) { Write-Host 'live check: all checks passed' -ForegroundColor Green }
else { Write-Host ('live check: ' + $failures + ' check(s) failed') -ForegroundColor Red }
exit $failures
