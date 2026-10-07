#Requires -Version 5.1
<#
    Verify-Live-Names.ps1 - proves named sessions against the REAL Copilot CLI.

    The suite runs against a recording stub, which cannot show how Copilot
    *parses* what myco hands it, nor what it writes to disk afterwards. This
    script drives the whole named-session path through the real tool:

        start <name>  ->  copilot stores <slug>-<id> as the session name
        sessions      ->  that id is what the table shows
        resume <slug>-<id> and resume <id>  ->  both reach that same session
        a second start     ->  takes the next number
        start with no name ->  refused, and creates nothing

    Run it before a release, and after touching naming, launching or session
    ids. It costs a few AI credits.

    Isolation, which is not optional:
      - its own MYCO_HOME under %TEMP%, so the real registry is never read or
        written; the script hashes that registry before and after to prove it
      - its workspace lives under %TEMP% and is deleted afterwards
      - nothing outside that root is touched

        pwsh -NoProfile -ExecutionPolicy Bypass -File test\Verify-Live-Names.ps1
#>

param([string]$RepoRoot = (Split-Path -Parent $PSScriptRoot))

$ErrorActionPreference = 'Stop'
$entry = Join-Path $RepoRoot 'bin\myco.ps1'
$failures = 0

function Check {
    param([string]$What, [bool]$Ok, [string]$Detail = '')
    if ($Ok) { Write-Host ('  [PASS] ' + $What) -ForegroundColor Green }
    else {
        $script:failures++
        Write-Host ('  [FAIL] ' + $What) -ForegroundColor Red
        if ($Detail) { Write-Host ('         ' + $Detail) -ForegroundColor DarkGray }
    }
}

function Invoke-MycoLive {
    <#  Runs myco the way a user does: a real shell, dot-sourcing the entry
        point, with both streams captured. Write-MycoError goes straight to
        the console error handle, so stderr has to be redirected too. #>
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

function Get-LiveSessionDirectory {
    <#  Real session folders only. The CLI also keeps its own bookkeeping in
        session-state, which is why the dot-prefixed ones are excluded here
        exactly as myco excludes them. #>
    param([string]$StateRoot)
    return @(Get-ChildItem -LiteralPath $StateRoot -Directory -ErrorAction SilentlyContinue |
        Where-Object { -not $_.Name.StartsWith('.') })
}

function Get-LiveSessionName {
    param([string]$StateRoot)
    return @(Get-LiveSessionDirectory -StateRoot $StateRoot | ForEach-Object {
            $meta = Get-Content -LiteralPath (Join-Path $_.FullName 'workspace.yaml') -Raw -ErrorAction SilentlyContinue
            if ($meta -match '(?m)^name:\s*(.+?)\s*$') { $Matches[1] } else { '(none)' }
        })
}

$realRegistry = Join-Path $env:APPDATA '.myco\registry.json'
$before = (Get-FileHash -LiteralPath $realRegistry -ErrorAction SilentlyContinue).Hash

$root = Join-Path $env:TEMP ('myco-live-names-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
$proj = Join-Path $root 'checkout-service'
New-Item -ItemType Directory -Force -Path (Join-Path $root 'myco-home'), $proj | Out-Null
$stateRoot = Join-Path $proj '.copilot\session-state'
$reply = 'Reply with the single word OK and nothing else.'

$savedMyco = $env:MYCO_HOME
$hadMyco = Test-Path Env:\MYCO_HOME
try {
    $env:MYCO_HOME = Join-Path $root 'myco-home'

    Write-Host "`nstart, with a name that has to be slugified" -ForegroundColor Cyan
    $r = Invoke-MycoLive -WorkDir $proj -MycoArgs @('start', 'Fix the LOGIN loop!', '-p', $reply)
    Check 'myco start succeeded against the real CLI' ($r.ExitCode -eq 0) $r.Output
    Check 'start printed the id it assigned' ($r.Output -match 'fix-the-login-loop-001001') $r.Output

    $dirs = @(Get-LiveSessionDirectory -StateRoot $stateRoot)
    Check 'the real CLI created exactly one session' ($dirs.Count -eq 1) ('found ' + $dirs.Count)
    if ($dirs.Count -ne 1) { throw 'cannot continue without a session' }

    $firstUuid = $dirs[0].Name
    $yaml = Get-Content -LiteralPath (Join-Path $dirs[0].FullName 'workspace.yaml') -Raw
    Check 'copilot stored the slugified name-and-id' ($yaml -match '(?m)^name:\s*fix-the-login-loop-001001\s*$') $yaml
    Check 'copilot marked the session user-named' ($yaml -match '(?m)^user_named:\s*true\s*$') $yaml

    Write-Host "`nthe sessions table" -ForegroundColor Cyan
    $r = Invoke-MycoLive -WorkDir $proj -MycoArgs @('sessions')
    Write-Host $r.Output
    $idCells = @()
    foreach ($line in ($r.Output -split "`r?`n")) {
        if ($line -match '^\s*[\u2502|]\s*(\S+)\s*[\u2502|]') { $idCells += $Matches[1] }
    }
    Check 'the ID column holds the full name-and-id' ($idCells -contains 'fix-the-login-loop-001001') ($idCells -join ', ')
    Check 'the CLI lock folder is not listed as a session' ($r.Output -notmatch 'session-operation-locks') $r.Output

    Write-Host "`nresume by the full name-and-id" -ForegroundColor Cyan
    $r = Invoke-MycoLive -WorkDir $root -MycoArgs @('resume', 'fix-the-login-loop-001001', '-p', $reply)
    Check 'resume by name-and-id succeeded' ($r.ExitCode -eq 0) $r.Output
    $dirs = @(Get-LiveSessionDirectory -StateRoot $stateRoot)
    Check 'it reused that session instead of forking a new one' `
    (($dirs.Count -eq 1) -and ($dirs[0].Name -eq $firstUuid)) ((Get-LiveSessionName $stateRoot) -join ', ')

    Write-Host "`nresume by the bare id" -ForegroundColor Cyan
    $r = Invoke-MycoLive -WorkDir $root -MycoArgs @('resume', '001001', '-p', $reply)
    Check 'resume by bare id succeeded' ($r.ExitCode -eq 0) $r.Output
    $dirs = @(Get-LiveSessionDirectory -StateRoot $stateRoot)
    Check 'the bare id reached the same session' `
    (($dirs.Count -eq 1) -and ($dirs[0].Name -eq $firstUuid)) ((Get-LiveSessionName $stateRoot) -join ', ')

    Write-Host "`na second start takes the next number" -ForegroundColor Cyan
    $r = Invoke-MycoLive -WorkDir $proj -MycoArgs @('start', 'split billing', '-p', $reply)
    Check 'the second start succeeded' ($r.ExitCode -eq 0) $r.Output
    $names = Get-LiveSessionName $stateRoot
    Check 'the second session is numbered 001002' ($names -contains 'split-billing-001002') ($names -join ', ')

    Write-Host "`nstart with no name is refused" -ForegroundColor Cyan
    $r = Invoke-MycoLive -WorkDir $proj -MycoArgs @('start')
    Check 'a nameless start exits non-zero' ($r.ExitCode -ne 0) ('exit code ' + $r.ExitCode)
    Check 'and says a name is required' ($r.Output -match '(?i)name is required') $r.Output
    Check 'and started no further session' (@(Get-LiveSessionDirectory -StateRoot $stateRoot).Count -eq 2) `
    ((Get-LiveSessionName $stateRoot) -join ', ')
} finally {
    if ($hadMyco) { $env:MYCO_HOME = $savedMyco } else { Remove-Item Env:\MYCO_HOME -ErrorAction SilentlyContinue }
    Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
}

$after = (Get-FileHash -LiteralPath $realRegistry -ErrorAction SilentlyContinue).Hash
Check 'the real registry was left exactly as it was found' ($before -eq $after) ("$before -> $after")
Check 'no workspace was left behind under TEMP' (-not (Test-Path -LiteralPath $root)) $root

Write-Host ''
if ($failures -eq 0) { Write-Host 'live check: all checks passed' -ForegroundColor Green }
else { Write-Host ('live check: ' + $failures + ' check(s) failed') -ForegroundColor Red }
exit $failures
