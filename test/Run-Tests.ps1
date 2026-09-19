#Requires -Version 5.1
<#
.SYNOPSIS
    End-to-end test suite for myco.

.DESCRIPTION
    These tests drive the real myco entry points through real shells
    (Windows PowerShell, PowerShell 7 and cmd.exe). Copilot itself is replaced
    by a recording stub on PATH so the suite is fast, deterministic and free.

    Every test runs inside a disposable sandbox with MYCO_HOME and USERPROFILE
    redirected, so the suite never touches the developer's real myco registry
    or their real global Copilot directory.
#>
[CmdletBinding()]
param(
    [string]$Filter = '*',
    [ValidateSet('powershell.exe', 'pwsh.exe')][string]$PsExe = 'powershell.exe',
    [switch]$KeepSandbox
)

$ErrorActionPreference = 'Stop'

$script:DefaultPsExe = $PsExe

$script:RepoRoot = Split-Path -Parent $PSScriptRoot
$script:MycoPs1 = Join-Path $script:RepoRoot 'bin\myco.ps1'
$script:MycoCmd = Join-Path $script:RepoRoot 'bin\myco.cmd'
$script:SandboxRoot = Join-Path $env:TEMP ('myco-tests\' + [guid]::NewGuid().ToString('N').Substring(0, 8))
$script:Passed = 0
$script:Failed = 0
$script:Skipped = 0
$script:Failures = New-Object System.Collections.ArrayList

# ---------------------------------------------------------------- assertions

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw "Assertion failed: $Message" }
}

function Assert-Equal {
    param($Expected, $Actual, [string]$Message)
    if ([string]$Expected -ne [string]$Actual) {
        throw "Assertion failed: $Message`n  expected: <$Expected>`n  actual  : <$Actual>"
    }
}

function Assert-Match {
    param([string]$Text, [string]$Pattern, [string]$Message)
    if ($Text -notmatch $Pattern) {
        throw "Assertion failed: $Message`n  pattern : <$Pattern>`n  in text : <$Text>"
    }
}

function Assert-NoMatch {
    param([string]$Text, [string]$Pattern, [string]$Message)
    if ($Text -match $Pattern) {
        throw "Assertion failed: $Message`n  pattern must NOT match: <$Pattern>`n  in text : <$Text>"
    }
}

function It {
    param([string]$Name, [scriptblock]$Body)
    if ($Name -notlike $Filter) { $script:Skipped++; return }
    try {
        & $Body
        $script:Passed++
        Write-Host ('  [PASS] ' + $Name) -ForegroundColor Green
    } catch {
        $script:Failed++
        [void]$script:Failures.Add(("$Name`n    " + ($_.Exception.Message -replace "`n", "`n    ")))
        Write-Host ('  [FAIL] ' + $Name) -ForegroundColor Red
        Write-Host ('         ' + ($_.Exception.Message -replace "`n", "`n         ")) -ForegroundColor DarkRed
    }
}

function Describe {
    param([string]$Name, [scriptblock]$Body)
    Write-Host ''
    Write-Host $Name -ForegroundColor Cyan
    & $Body
}

# ------------------------------------------------------------------- sandbox

function New-Sandbox {
    $root = Join-Path $script:SandboxRoot ([guid]::NewGuid().ToString('N').Substring(0, 8))
    $userProfile = Join-Path $root 'userprofile'
    $mycoHome = Join-Path $root 'mycohome'
    $stubBin = Join-Path $root 'stubbin'
    $projects = Join-Path $root 'projects'
    $temp = Join-Path $root 'temp'
    foreach ($d in @($root, $userProfile, $mycoHome, $stubBin, $projects, $temp)) {
        New-Item -ItemType Directory -Force -Path $d | Out-Null
    }

    $log = Join-Path $root 'copilot-calls.log'

    # Recording stub that impersonates the copilot CLI. Arguments are recorded
    # one per line as well as verbatim, so an entry point that collapses them
    # into a single argument is detectable.
    $stub = @'
@echo off
>>"%MYCO_TEST_LOG%" echo [call]
>>"%MYCO_TEST_LOG%" echo cwd=%CD%
>>"%MYCO_TEST_LOG%" echo home=%COPILOT_HOME%
>>"%MYCO_TEST_LOG%" echo args=%*
:myco_stub_loop
if "%~1"=="" goto :myco_stub_done
>>"%MYCO_TEST_LOG%" echo arg=%~1
shift
goto :myco_stub_loop
:myco_stub_done
exit /b 0
'@
    Set-Content -LiteralPath (Join-Path $stubBin 'copilot.cmd') -Value $stub -Encoding ASCII

    # npm installs both copilot.cmd and copilot.ps1, and PowerShell resolves the
    # .ps1 shim in preference to the .cmd one. The suite mirrors that, because
    # argument handling differs sharply between the two.
    $stubPs1 = @'
$log = $env:MYCO_TEST_LOG
Add-Content -LiteralPath $log -Value '[call]'
Add-Content -LiteralPath $log -Value ('cwd=' + (Get-Location).Path)
Add-Content -LiteralPath $log -Value ('home=' + [string]$env:COPILOT_HOME)
Add-Content -LiteralPath $log -Value ('args=' + ($args -join ' '))
foreach ($a in $args) { Add-Content -LiteralPath $log -Value ('arg=' + [string]$a) }
exit 0
'@
    Set-Content -LiteralPath (Join-Path $stubBin 'copilot.ps1') -Value $stubPs1 -Encoding UTF8

    [pscustomobject]@{
        Root        = $root
        UserProfile = $userProfile
        MycoHome    = $mycoHome
        StubBin     = $stubBin
        Projects    = $projects
        Temp        = $temp
        Log         = $log
    }
}

function New-Project {
    param($Sandbox, [string]$Name)
    $p = Join-Path $Sandbox.Projects $Name
    New-Item -ItemType Directory -Force -Path $p | Out-Null
    return $p
}

function New-FakeSession {
    <#  Creates a session-state directory shaped like a real Copilot session. #>
    param(
        [string]$CopilotHome,
        [string]$Name,
        [datetime]$UpdatedAt,
        [string]$SessionCwd = 'D:\somewhere',
        [switch]$Active,
        [string]$SessionId
    )
    if (-not $SessionId) { $SessionId = [guid]::NewGuid().ToString() }
    $dir = Join-Path $CopilotHome ('session-state\' + $SessionId)
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    $stamp = $UpdatedAt.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ss.fffZ')
    $yaml = @(
        "id: $SessionId",
        "cwd: $SessionCwd",
        'client_name: github/cli',
        "name: $Name",
        'user_named: false',
        'summary_count: 0',
        'fork_count: 0',
        "created_at: $stamp",
        "updated_at: $stamp"
    ) -join "`n"
    Set-Content -LiteralPath (Join-Path $dir 'workspace.yaml') -Value $yaml -Encoding UTF8
    Set-Content -LiteralPath (Join-Path $dir 'events.jsonl') -Value '{}' -Encoding UTF8
    if ($Active) {
        Set-Content -LiteralPath (Join-Path $dir 'inuse.4242.lock') -Value '' -Encoding ASCII
    }
    return $SessionId
}

function Get-CopilotCalls {
    param($Sandbox)
    if (-not (Test-Path -LiteralPath $Sandbox.Log)) { return @() }
    $calls = New-Object System.Collections.ArrayList
    $current = $null
    foreach ($line in (Get-Content -LiteralPath $Sandbox.Log)) {
        switch -Regex ($line) {
            '^\[call\]$' {
                $current = [pscustomobject]@{
                    Cwd     = ''
                    Home    = ''
                    CliArgs = ''
                    ArgList = (New-Object System.Collections.ArrayList)
                }
                [void]$calls.Add($current)
            }
            '^cwd=(.*)$' { if ($current) { $current.Cwd = $Matches[1].Trim() } }
            '^home=(.*)$' { if ($current) { $current.Home = $Matches[1].Trim() } }
            '^args=(.*)$' { if ($current) { $current.CliArgs = $Matches[1].Trim() } }
            '^arg=(.*)$' { if ($current) { [void]$current.ArgList.Add($Matches[1].Trim()) } }
        }
    }
    return $calls.ToArray()
}

function Get-LastCopilotCall {
    param($Sandbox)
    $calls = @(Get-CopilotCalls -Sandbox $Sandbox)
    if ($calls.Count -eq 0) { throw 'Expected copilot to be invoked, but it never was.' }
    return $calls[$calls.Count - 1]
}

function Clear-CopilotCalls {
    param($Sandbox)
    Remove-Item -LiteralPath $Sandbox.Log -Force -ErrorAction SilentlyContinue
}

# ------------------------------------------------------------- shell drivers

function ConvertTo-PsLiteral {
    param([string]$Value)
    return "'" + ($Value -replace "'", "''") + "'"
}

function Invoke-Myco {
    <#  Runs myco the way a real user would: as a dot-sourced PowerShell
        function, or as myco.cmd called from a batch script. Reports the
        shell's working directory afterwards so directory changes made by
        myco can be asserted. #>
    param(
        $Sandbox,
        [string]$WorkDir,
        [string[]]$MycoArgs = @(),
        [ValidateSet('pwsh', 'cmd', 'pwsh7')][string]$Shell = 'pwsh'
    )

    $id = [guid]::NewGuid().ToString('N').Substring(0, 8)
    $outFile = Join-Path $Sandbox.Root ("out-$id.txt")

    if ($Shell -eq 'cmd') {
        $driver = Join-Path $Sandbox.Root ("drv-$id.cmd")
        $quoted = ($MycoArgs | ForEach-Object {
                if ($_ -match '[\s"]') { '"' + ($_ -replace '"', '""') + '"' } else { $_ }
            }) -join ' '
        $lines = @(
            '@echo off',
            ('cd /d "' + $WorkDir + '"'),
            ('call "' + $script:MycoCmd + '" ' + $quoted),
            'echo MYCO_EXIT=%ERRORLEVEL%',
            'echo FINALCWD=%CD%',
            'if defined COPILOT_HOME (echo LEAK=%COPILOT_HOME%) else (echo LEAK=)'
        )
        Set-Content -LiteralPath $driver -Value ($lines -join "`r`n") -Encoding ASCII
        $runner = { & cmd.exe /c $driver 2>&1 | Out-File -LiteralPath $outFile -Encoding UTF8 }
    } else {
        $psExe = if ($Shell -eq 'pwsh7') { 'pwsh.exe' } else { $script:DefaultPsExe }
        $driver = Join-Path $Sandbox.Root ("drv-$id.ps1")
        $argList = if ($MycoArgs.Count -gt 0) {
            ($MycoArgs | ForEach-Object { ConvertTo-PsLiteral $_ }) -join ','
        } else { '' }
        $lines = @(
            '$ErrorActionPreference = ''Continue''',
            '$global:LASTEXITCODE = 0',
            ('Set-Location -LiteralPath ' + (ConvertTo-PsLiteral $WorkDir)),
            ('. ' + (ConvertTo-PsLiteral $script:MycoPs1)),
            ('$mycoArgs = @(' + $argList + ')'),
            'myco @mycoArgs',
            'Write-Output ("MYCO_EXIT=" + $global:LASTEXITCODE)',
            'Write-Output ("FINALCWD=" + (Get-Location).Path)',
            'Write-Output ("LEAK=" + [string]$env:COPILOT_HOME)'
        )
        Set-Content -LiteralPath $driver -Value ($lines -join "`r`n") -Encoding UTF8
        $runner = {
            & $psExe -NoProfile -ExecutionPolicy Bypass -File $driver 2>&1 |
                Out-File -LiteralPath $outFile -Encoding UTF8
        }
    }

    $saved = @{}
    foreach ($k in 'MYCO_HOME', 'USERPROFILE', 'MYCO_TEST_LOG', 'PATH', 'COPILOT_HOME', 'TEMP', 'TMP') {
        $saved[$k] = [Environment]::GetEnvironmentVariable($k)
    }
    $previousErrorAction = $ErrorActionPreference
    try {
        # myco reports problems on stderr; with 'Stop' those lines would be
        # rethrown here instead of being captured for assertions.
        $ErrorActionPreference = 'Continue'
        $env:MYCO_HOME = $Sandbox.MycoHome
        $env:USERPROFILE = $Sandbox.UserProfile
        $env:MYCO_TEST_LOG = $Sandbox.Log
        $env:COPILOT_HOME = ''
        $env:TEMP = $Sandbox.Temp
        $env:TMP = $Sandbox.Temp
        $env:PATH = $Sandbox.StubBin + ';' + $saved['PATH']
        & $runner
    } finally {
        $ErrorActionPreference = $previousErrorAction
        foreach ($k in @($saved.Keys)) {
            [Environment]::SetEnvironmentVariable($k, $saved[$k])
        }
    }

    $text = if (Test-Path -LiteralPath $outFile) { Get-Content -LiteralPath $outFile -Raw } else { '' }
    if ($null -eq $text) { $text = '' }

    $finalCwd = if ($text -match 'FINALCWD=(.*)') { $Matches[1].Trim() } else { '' }
    $exit = if ($text -match 'MYCO_EXIT=(.*)') { $Matches[1].Trim() } else { '' }
    $leak = if ($text -match 'LEAK=(.*)') { $Matches[1].Trim() } else { '' }

    [pscustomobject]@{
        Output   = $text
        FinalCwd = $finalCwd
        ExitCode = $exit
        Leak     = $leak
    }
}

# --------------------------------------------------------------------- tests

Write-Host ''
Write-Host 'myco end-to-end suite' -ForegroundColor White
Write-Host ('sandbox: ' + $script:SandboxRoot) -ForegroundColor DarkGray

Describe 'myco start' {

    It 'creates a .copilot folder in the current directory when none exists' {
        $sb = New-Sandbox
        $proj = New-Project -Sandbox $sb -Name 'alpha'
        $r = Invoke-Myco -Sandbox $sb -WorkDir $proj -MycoArgs @('start')
        Assert-True (Test-Path -LiteralPath (Join-Path $proj '.copilot')) `
            "expected .copilot to be created in the project folder. Output:`n$($r.Output)"
    }

    It 'launches copilot with --yolo, in the project directory, with COPILOT_HOME redirected' {
        $sb = New-Sandbox
        $proj = New-Project -Sandbox $sb -Name 'alpha'
        $null = Invoke-Myco -Sandbox $sb -WorkDir $proj -MycoArgs @('start')
        $call = Get-LastCopilotCall -Sandbox $sb
        Assert-Match $call.CliArgs '--yolo' 'copilot must be launched with --yolo'
        Assert-Equal $proj $call.Cwd 'copilot must run in the project directory'
        Assert-Equal (Join-Path $proj '.copilot') $call.Home 'COPILOT_HOME must point at the project .copilot'
    }

    It 'registers the project as workspace 001 on first use' {
        $sb = New-Sandbox
        $proj = New-Project -Sandbox $sb -Name 'alpha'
        $null = Invoke-Myco -Sandbox $sb -WorkDir $proj -MycoArgs @('start')
        $r = Invoke-Myco -Sandbox $sb -WorkDir $proj -MycoArgs @('sessions')
        Assert-Match $r.Output '\[001\]' 'first workspace must be listed with id 001'
    }

    It 'assigns sequential ids to additional workspaces' {
        $sb = New-Sandbox
        $a = New-Project -Sandbox $sb -Name 'alpha'
        $b = New-Project -Sandbox $sb -Name 'beta'
        $null = Invoke-Myco -Sandbox $sb -WorkDir $a -MycoArgs @('start')
        $null = Invoke-Myco -Sandbox $sb -WorkDir $b -MycoArgs @('start')
        $r = Invoke-Myco -Sandbox $sb -WorkDir $a -MycoArgs @('sessions')
        Assert-Match $r.Output '\[001\]' 'workspace 001 must be listed'
        Assert-Match $r.Output '\[002\]' 'workspace 002 must be listed'
    }

    It 'adopts an existing .copilot folder instead of recreating it' {
        $sb = New-Sandbox
        $proj = New-Project -Sandbox $sb -Name 'alpha'
        New-Item -ItemType Directory -Force -Path (Join-Path $proj '.copilot') | Out-Null
        $marker = Join-Path $proj '.copilot\marker.txt'
        Set-Content -LiteralPath $marker -Value 'preexisting' -Encoding ASCII
        $null = Invoke-Myco -Sandbox $sb -WorkDir $proj -MycoArgs @('start')
        Assert-True (Test-Path -LiteralPath $marker) 'an existing .copilot must not be clobbered'
        $r = Invoke-Myco -Sandbox $sb -WorkDir $proj -MycoArgs @('sessions')
        Assert-Match $r.Output 'adopted' 'a pre-existing .copilot must be recorded as adopted'
    }

    It 'registers a project only once across repeated runs' {
        $sb = New-Sandbox
        $proj = New-Project -Sandbox $sb -Name 'alpha'
        $null = Invoke-Myco -Sandbox $sb -WorkDir $proj -MycoArgs @('start')
        $null = Invoke-Myco -Sandbox $sb -WorkDir $proj -MycoArgs @('start')
        $r = Invoke-Myco -Sandbox $sb -WorkDir $proj -MycoArgs @('sessions')
        Assert-NoMatch $r.Output '\[002\]' 'the same folder must not be registered twice'
    }

    It 'forwards extra arguments through to copilot' {
        $sb = New-Sandbox
        $proj = New-Project -Sandbox $sb -Name 'alpha'
        $null = Invoke-Myco -Sandbox $sb -WorkDir $proj -MycoArgs @('start', '--model', 'gpt-5.4')
        $call = Get-LastCopilotCall -Sandbox $sb
        Assert-Match $call.CliArgs '--model gpt-5\.4' 'extra arguments must be forwarded to copilot'
    }

    It 'passes every argument to copilot separately, never as one string' {
        $sb = New-Sandbox
        $proj = New-Project -Sandbox $sb -Name 'alpha'
        $null = Invoke-Myco -Sandbox $sb -WorkDir $proj -MycoArgs @('start', '--model', 'gpt-5.4')
        $call = Get-LastCopilotCall -Sandbox $sb
        Assert-Equal 3 $call.ArgList.Count `
            ("copilot must receive three separate arguments, got: " + (($call.ArgList | ForEach-Object { "<$_>" }) -join ' '))
        Assert-Equal '--yolo' $call.ArgList[0] 'first argument must be --yolo'
        Assert-Equal '--model' $call.ArgList[1] 'second argument must be --model'
        Assert-Equal 'gpt-5.4' $call.ArgList[2] 'third argument must be the model name'
    }

    It 'keeps an argument containing spaces as a single argument' {
        $sb = New-Sandbox
        $proj = New-Project -Sandbox $sb -Name 'alpha'
        $null = Invoke-Myco -Sandbox $sb -WorkDir $proj -MycoArgs @('start', '-p', 'do the thing')
        $call = Get-LastCopilotCall -Sandbox $sb
        Assert-Equal 3 $call.ArgList.Count 'a quoted prompt must stay one argument'
        Assert-Equal 'do the thing' $call.ArgList[2] 'the prompt text must survive intact'
    }

    It 'refuses to shadow the global home copilot directory' {
        $sb = New-Sandbox
        $r = Invoke-Myco -Sandbox $sb -WorkDir $sb.UserProfile -MycoArgs @('start')
        Assert-Match $r.Output '(?i)global' 'must explain that the home .copilot cannot be managed'
        Assert-NoMatch $r.ExitCode '^0$' 'must exit with a non-zero status'
    }

    It 'does not leak COPILOT_HOME into the calling shell' {
        $sb = New-Sandbox
        $proj = New-Project -Sandbox $sb -Name 'alpha'
        $r = Invoke-Myco -Sandbox $sb -WorkDir $proj -MycoArgs @('start')
        Assert-Equal '' $r.Leak 'COPILOT_HOME must be restored after copilot exits'
    }
}

Describe 'myco continue' {

    It 'launches copilot with --yolo --continue' {
        $sb = New-Sandbox
        $proj = New-Project -Sandbox $sb -Name 'alpha'
        $null = Invoke-Myco -Sandbox $sb -WorkDir $proj -MycoArgs @('continue')
        $call = Get-LastCopilotCall -Sandbox $sb
        Assert-Match $call.CliArgs '--yolo' 'copilot must be launched with --yolo'
        Assert-Match $call.CliArgs '--continue' 'copilot must be launched with --continue'
    }

    It 'registers the folder just like start does' {
        $sb = New-Sandbox
        $proj = New-Project -Sandbox $sb -Name 'alpha'
        $null = Invoke-Myco -Sandbox $sb -WorkDir $proj -MycoArgs @('continue')
        $r = Invoke-Myco -Sandbox $sb -WorkDir $proj -MycoArgs @('sessions')
        Assert-Match $r.Output '\[001\]' 'continue must register the workspace too'
    }
}

Describe 'myco sessions' {

    It 'nests session ids under their workspace id' {
        $sb = New-Sandbox
        $proj = New-Project -Sandbox $sb -Name 'alpha'
        $null = Invoke-Myco -Sandbox $sb -WorkDir $proj -MycoArgs @('start')
        $ch = Join-Path $proj '.copilot'
        $null = New-FakeSession -CopilotHome $ch -Name 'Newest work' -UpdatedAt (Get-Date).AddMinutes(-1)
        $null = New-FakeSession -CopilotHome $ch -Name 'Older work' -UpdatedAt (Get-Date).AddHours(-5)
        $r = Invoke-Myco -Sandbox $sb -WorkDir $proj -MycoArgs @('sessions')
        Assert-Match $r.Output '001001' 'first nested session id must be 001001'
        Assert-Match $r.Output '001002' 'second nested session id must be 001002'
        Assert-Match $r.Output 'Newest work' 'session names must be shown'
    }

    It 'orders sessions most-recent first' {
        $sb = New-Sandbox
        $proj = New-Project -Sandbox $sb -Name 'alpha'
        $null = Invoke-Myco -Sandbox $sb -WorkDir $proj -MycoArgs @('start')
        $ch = Join-Path $proj '.copilot'
        $null = New-FakeSession -CopilotHome $ch -Name 'OLDEST' -UpdatedAt (Get-Date).AddDays(-3)
        $null = New-FakeSession -CopilotHome $ch -Name 'NEWEST' -UpdatedAt (Get-Date)
        $r = Invoke-Myco -Sandbox $sb -WorkDir $proj -MycoArgs @('sessions')
        Assert-Match $r.Output '001001[^\r\n]*NEWEST' 'the newest session must be 001001'
    }

    It 'shows at most the last 15 sessions per workspace' {
        $sb = New-Sandbox
        $proj = New-Project -Sandbox $sb -Name 'alpha'
        $null = Invoke-Myco -Sandbox $sb -WorkDir $proj -MycoArgs @('start')
        $ch = Join-Path $proj '.copilot'
        for ($i = 1; $i -le 18; $i++) {
            $null = New-FakeSession -CopilotHome $ch -Name ("Session $i") -UpdatedAt (Get-Date).AddMinutes(-$i)
        }
        $r = Invoke-Myco -Sandbox $sb -WorkDir $proj -MycoArgs @('sessions')
        Assert-Match $r.Output '001015' 'the 15th session must be listed'
        Assert-NoMatch $r.Output '001016' 'no more than 15 sessions may be listed'
    }

    It 'marks sessions that are currently active' {
        $sb = New-Sandbox
        $proj = New-Project -Sandbox $sb -Name 'alpha'
        $null = Invoke-Myco -Sandbox $sb -WorkDir $proj -MycoArgs @('start')
        $ch = Join-Path $proj '.copilot'
        $null = New-FakeSession -CopilotHome $ch -Name 'Live one' -UpdatedAt (Get-Date) -Active
        $r = Invoke-Myco -Sandbox $sb -WorkDir $proj -MycoArgs @('sessions')
        Assert-Match $r.Output '001001\s+\*' 'an in-use session must be flagged with *'
    }

    It 'reports an empty registry cleanly' {
        $sb = New-Sandbox
        $proj = New-Project -Sandbox $sb -Name 'alpha'
        $r = Invoke-Myco -Sandbox $sb -WorkDir $proj -MycoArgs @('sessions')
        Assert-Match $r.Output '(?i)no workspaces' 'an empty registry must produce a friendly message'
        Assert-Equal '0' $r.ExitCode 'listing an empty registry is not an error'
    }

    It 'does not list the global home copilot folder' {
        $sb = New-Sandbox
        $proj = New-Project -Sandbox $sb -Name 'alpha'
        New-Item -ItemType Directory -Force -Path (Join-Path $sb.UserProfile '.copilot') | Out-Null
        $null = Invoke-Myco -Sandbox $sb -WorkDir $proj -MycoArgs @('start')
        $r = Invoke-Myco -Sandbox $sb -WorkDir $proj -MycoArgs @('sessions')
        Assert-NoMatch $r.Output '\[000\]' 'the global copilot home must never be listed'
    }
}

Describe 'myco resume' {

    It 'moves the shell into the workspace and resumes the chosen session' {
        $sb = New-Sandbox
        $proj = New-Project -Sandbox $sb -Name 'alpha'
        $null = Invoke-Myco -Sandbox $sb -WorkDir $proj -MycoArgs @('start')
        $ch = Join-Path $proj '.copilot'
        $null = New-FakeSession -CopilotHome $ch -Name 'Newer' -UpdatedAt (Get-Date)
        $target = New-FakeSession -CopilotHome $ch -Name 'Older' -UpdatedAt (Get-Date).AddHours(-2)

        Clear-CopilotCalls -Sandbox $sb
        $r = Invoke-Myco -Sandbox $sb -WorkDir $sb.Projects -MycoArgs @('resume', '001002')
        $call = Get-LastCopilotCall -Sandbox $sb
        Assert-Match $call.CliArgs ([regex]::Escape($target)) 'the second session uuid must be resumed'
        Assert-Match $call.CliArgs '--yolo' 'resume must also use --yolo'
        Assert-Equal $proj $call.Cwd 'copilot must run from the workspace directory'
        Assert-Equal $proj $r.FinalCwd 'the shell must be left inside the workspace directory'
    }

    It 'resumes the most recent session when given a bare workspace id' {
        $sb = New-Sandbox
        $proj = New-Project -Sandbox $sb -Name 'alpha'
        $null = Invoke-Myco -Sandbox $sb -WorkDir $proj -MycoArgs @('start')
        Clear-CopilotCalls -Sandbox $sb
        $r = Invoke-Myco -Sandbox $sb -WorkDir $sb.Projects -MycoArgs @('resume', '001')
        $call = Get-LastCopilotCall -Sandbox $sb
        Assert-Match $call.CliArgs '--continue' 'a bare workspace id must continue the latest session'
        Assert-Equal $proj $r.FinalCwd 'the shell must be left inside the workspace directory'
    }

    It 'accepts dotted id forms' {
        $sb = New-Sandbox
        $proj = New-Project -Sandbox $sb -Name 'alpha'
        $null = Invoke-Myco -Sandbox $sb -WorkDir $proj -MycoArgs @('start')
        $ch = Join-Path $proj '.copilot'
        $target = New-FakeSession -CopilotHome $ch -Name 'Only' -UpdatedAt (Get-Date)
        Clear-CopilotCalls -Sandbox $sb
        $null = Invoke-Myco -Sandbox $sb -WorkDir $sb.Projects -MycoArgs @('resume', '001.001')
        $call = Get-LastCopilotCall -Sandbox $sb
        Assert-Match $call.CliArgs ([regex]::Escape($target)) 'dotted ids must resolve'
    }

    It 'fails clearly for an unknown workspace id' {
        $sb = New-Sandbox
        $proj = New-Project -Sandbox $sb -Name 'alpha'
        $null = Invoke-Myco -Sandbox $sb -WorkDir $proj -MycoArgs @('start')
        $r = Invoke-Myco -Sandbox $sb -WorkDir $proj -MycoArgs @('resume', '099')
        Assert-Match $r.Output '(?i)(unknown|no workspace)' 'must report the unknown id'
        Assert-NoMatch $r.ExitCode '^0$' 'must exit non-zero'
    }

    It 'fails clearly for an out-of-range session index' {
        $sb = New-Sandbox
        $proj = New-Project -Sandbox $sb -Name 'alpha'
        $null = Invoke-Myco -Sandbox $sb -WorkDir $proj -MycoArgs @('start')
        $r = Invoke-Myco -Sandbox $sb -WorkDir $proj -MycoArgs @('resume', '001009')
        Assert-Match $r.Output '(?i)(no session|out of range|has only)' 'must report the missing session'
        Assert-NoMatch $r.ExitCode '^0$' 'must exit non-zero'
    }

    It 'reports a workspace whose folder has disappeared' {
        $sb = New-Sandbox
        $proj = New-Project -Sandbox $sb -Name 'alpha'
        $null = Invoke-Myco -Sandbox $sb -WorkDir $proj -MycoArgs @('start')
        Remove-Item -LiteralPath $proj -Recurse -Force
        $r = Invoke-Myco -Sandbox $sb -WorkDir $sb.Projects -MycoArgs @('resume', '001')
        Assert-Match $r.Output '(?i)(missing|not found|no longer)' 'must report the vanished folder'
        Assert-NoMatch $r.ExitCode '^0$' 'must exit non-zero'
    }
}

Describe 'cross-shell behaviour' {

    It 'works end to end from cmd.exe' {
        $sb = New-Sandbox
        $proj = New-Project -Sandbox $sb -Name 'alpha'
        $r = Invoke-Myco -Sandbox $sb -WorkDir $proj -MycoArgs @('start') -Shell cmd
        Assert-True (Test-Path -LiteralPath (Join-Path $proj '.copilot')) `
            "cmd.exe must be able to create the workspace. Output:`n$($r.Output)"
        $call = Get-LastCopilotCall -Sandbox $sb
        Assert-Match $call.CliArgs '--yolo' 'cmd.exe must launch copilot with --yolo'
    }

    It 'changes the cmd.exe working directory on resume' {
        $sb = New-Sandbox
        $proj = New-Project -Sandbox $sb -Name 'alpha'
        $null = Invoke-Myco -Sandbox $sb -WorkDir $proj -MycoArgs @('start') -Shell cmd
        $r = Invoke-Myco -Sandbox $sb -WorkDir $sb.Projects -MycoArgs @('resume', '001') -Shell cmd
        Assert-Equal $proj $r.FinalCwd 'cmd.exe must be left in the workspace directory'
    }

    It 'does not leak COPILOT_HOME into the cmd.exe session' {
        $sb = New-Sandbox
        $proj = New-Project -Sandbox $sb -Name 'alpha'
        $r = Invoke-Myco -Sandbox $sb -WorkDir $proj -MycoArgs @('start') -Shell cmd
        Assert-Equal '' $r.Leak 'COPILOT_HOME must be cleared again in cmd.exe'
    }

    It 'shares one registry between cmd.exe and PowerShell' {
        $sb = New-Sandbox
        $a = New-Project -Sandbox $sb -Name 'alpha'
        $b = New-Project -Sandbox $sb -Name 'beta'
        $null = Invoke-Myco -Sandbox $sb -WorkDir $a -MycoArgs @('start') -Shell cmd
        $null = Invoke-Myco -Sandbox $sb -WorkDir $b -MycoArgs @('start') -Shell pwsh
        $r = Invoke-Myco -Sandbox $sb -WorkDir $a -MycoArgs @('sessions') -Shell cmd
        Assert-Match $r.Output '\[001\]' 'workspace registered from cmd must be listed'
        Assert-Match $r.Output '\[002\]' 'workspace registered from PowerShell must be listed'
    }

    It 'passes arguments separately from cmd.exe too' {
        $sb = New-Sandbox
        $proj = New-Project -Sandbox $sb -Name 'alpha'
        $null = Invoke-Myco -Sandbox $sb -WorkDir $proj -MycoArgs @('start', '--model', 'gpt-5.4') -Shell cmd
        $call = Get-LastCopilotCall -Sandbox $sb
        Assert-Equal 3 $call.ArgList.Count `
            ("copilot must receive three separate arguments, got: " + (($call.ArgList | ForEach-Object { "<$_>" }) -join ' '))
        Assert-Equal 'gpt-5.4' $call.ArgList[2] 'the model name must survive cmd.exe quoting'
    }

    It 'keeps a spaced argument intact from cmd.exe' {
        $sb = New-Sandbox
        $proj = New-Project -Sandbox $sb -Name 'alpha'
        $null = Invoke-Myco -Sandbox $sb -WorkDir $proj -MycoArgs @('start', '-p', 'do the thing') -Shell cmd
        $call = Get-LastCopilotCall -Sandbox $sb
        Assert-Equal 3 $call.ArgList.Count 'a quoted prompt must stay one argument through cmd.exe'
        Assert-Equal 'do the thing' $call.ArgList[2] 'the prompt text must survive cmd.exe quoting'
    }

    It 'leaves no plan file behind after a normal cmd.exe run' {
        $sb = New-Sandbox
        $proj = New-Project -Sandbox $sb -Name 'alpha'
        $null = Invoke-Myco -Sandbox $sb -WorkDir $proj -MycoArgs @('start') -Shell cmd
        $left = @(Get-ChildItem -LiteralPath $sb.Temp -Filter 'myco-plan-*.cmd' -File -ErrorAction SilentlyContinue)
        Assert-Equal 0 $left.Count 'the plan file must be removed once it has run'
    }

    It 'sweeps away stale plan files abandoned by an interrupted run' {
        $sb = New-Sandbox
        $proj = New-Project -Sandbox $sb -Name 'alpha'
        $stale = Join-Path $sb.Temp 'myco-plan-000000000.cmd'
        Set-Content -LiteralPath $stale -Value '@echo off' -Encoding ASCII
        (Get-Item -LiteralPath $stale).LastWriteTime = (Get-Date).AddDays(-3)
        $null = Invoke-Myco -Sandbox $sb -WorkDir $proj -MycoArgs @('sessions') -Shell cmd
        Assert-True (-not (Test-Path -LiteralPath $stale)) `
            'an abandoned plan file older than a day must be cleaned up'
    }

    It 'keeps plan files belonging to a concurrent run' {
        $sb = New-Sandbox
        $proj = New-Project -Sandbox $sb -Name 'alpha'
        $fresh = Join-Path $sb.Temp 'myco-plan-111111111.cmd'
        Set-Content -LiteralPath $fresh -Value '@echo off' -Encoding ASCII
        $null = Invoke-Myco -Sandbox $sb -WorkDir $proj -MycoArgs @('sessions') -Shell cmd
        Assert-True (Test-Path -LiteralPath $fresh) `
            'a plan file from another in-flight myco must not be deleted'
    }
}

Describe 'seeding and configuration' {

    It 'stores all myco state under MYCO_HOME' {
        $sb = New-Sandbox
        $proj = New-Project -Sandbox $sb -Name 'alpha'
        $null = Invoke-Myco -Sandbox $sb -WorkDir $proj -MycoArgs @('start')
        Assert-True (Test-Path -LiteralPath (Join-Path $sb.MycoHome 'registry.json')) `
            'the registry must live under MYCO_HOME'
    }

    It 'seeds a new .copilot with the global settings and mcp config' {
        $sb = New-Sandbox
        $globalHome = Join-Path $sb.UserProfile '.copilot'
        New-Item -ItemType Directory -Force -Path $globalHome | Out-Null
        Set-Content -LiteralPath (Join-Path $globalHome 'settings.json') -Value '{"theme":"dark"}' -Encoding ASCII
        Set-Content -LiteralPath (Join-Path $globalHome 'mcp-config.json') -Value '{"mcpServers":{}}' -Encoding ASCII
        $proj = New-Project -Sandbox $sb -Name 'alpha'
        $null = Invoke-Myco -Sandbox $sb -WorkDir $proj -MycoArgs @('start')
        $seeded = Join-Path $proj '.copilot\settings.json'
        Assert-True (Test-Path -LiteralPath $seeded) 'settings.json must be seeded into the new workspace'
        Assert-Match (Get-Content -LiteralPath $seeded -Raw) 'dark' 'seeded settings must match the global file'
        Assert-True (Test-Path -LiteralPath (Join-Path $proj '.copilot\mcp-config.json')) `
            'mcp-config.json must be seeded into the new workspace'
    }

    It 'never seeds over an adopted .copilot' {
        $sb = New-Sandbox
        $globalHome = Join-Path $sb.UserProfile '.copilot'
        New-Item -ItemType Directory -Force -Path $globalHome | Out-Null
        Set-Content -LiteralPath (Join-Path $globalHome 'settings.json') -Value '{"theme":"global"}' -Encoding ASCII
        $proj = New-Project -Sandbox $sb -Name 'alpha'
        New-Item -ItemType Directory -Force -Path (Join-Path $proj '.copilot') | Out-Null
        Set-Content -LiteralPath (Join-Path $proj '.copilot\settings.json') -Value '{"theme":"mine"}' -Encoding ASCII
        $null = Invoke-Myco -Sandbox $sb -WorkDir $proj -MycoArgs @('start')
        Assert-Match (Get-Content -LiteralPath (Join-Path $proj '.copilot\settings.json') -Raw) 'mine' `
            'an adopted workspace must keep its own settings'
    }

    It 'honours seed=none' {
        $sb = New-Sandbox
        $globalHome = Join-Path $sb.UserProfile '.copilot'
        New-Item -ItemType Directory -Force -Path $globalHome | Out-Null
        Set-Content -LiteralPath (Join-Path $globalHome 'settings.json') -Value '{"theme":"dark"}' -Encoding ASCII
        $proj = New-Project -Sandbox $sb -Name 'alpha'
        $null = Invoke-Myco -Sandbox $sb -WorkDir $proj -MycoArgs @('config', 'seed', 'none')
        $null = Invoke-Myco -Sandbox $sb -WorkDir $proj -MycoArgs @('start')
        Assert-True (-not (Test-Path -LiteralPath (Join-Path $proj '.copilot\settings.json'))) `
            'seed=none must leave the new workspace empty'
    }
}

Describe 'registry maintenance' {

    It 'prune removes workspaces whose folders are gone' {
        $sb = New-Sandbox
        $a = New-Project -Sandbox $sb -Name 'alpha'
        $b = New-Project -Sandbox $sb -Name 'beta'
        $null = Invoke-Myco -Sandbox $sb -WorkDir $a -MycoArgs @('start')
        $null = Invoke-Myco -Sandbox $sb -WorkDir $b -MycoArgs @('start')
        Remove-Item -LiteralPath $a -Recurse -Force
        $null = Invoke-Myco -Sandbox $sb -WorkDir $sb.Projects -MycoArgs @('prune')
        $r = Invoke-Myco -Sandbox $sb -WorkDir $b -MycoArgs @('sessions')
        Assert-NoMatch $r.Output '\[001\]' 'the pruned workspace must be gone'
        Assert-Match $r.Output '\[002\]' 'the surviving workspace must keep its id'
    }

    It 'forget removes a single workspace without renumbering the others' {
        $sb = New-Sandbox
        $a = New-Project -Sandbox $sb -Name 'alpha'
        $b = New-Project -Sandbox $sb -Name 'beta'
        $null = Invoke-Myco -Sandbox $sb -WorkDir $a -MycoArgs @('start')
        $null = Invoke-Myco -Sandbox $sb -WorkDir $b -MycoArgs @('start')
        $null = Invoke-Myco -Sandbox $sb -WorkDir $b -MycoArgs @('forget', '001')
        $r = Invoke-Myco -Sandbox $sb -WorkDir $b -MycoArgs @('sessions')
        Assert-NoMatch $r.Output '\[001\]' 'the forgotten workspace must be gone'
        Assert-Match $r.Output '\[002\]' 'remaining ids must be stable'
    }

    It 'forget leaves the .copilot folder on disk' {
        $sb = New-Sandbox
        $a = New-Project -Sandbox $sb -Name 'alpha'
        $null = Invoke-Myco -Sandbox $sb -WorkDir $a -MycoArgs @('start')
        $null = Invoke-Myco -Sandbox $sb -WorkDir $a -MycoArgs @('forget', '001')
        Assert-True (Test-Path -LiteralPath (Join-Path $a '.copilot')) `
            'forget must only affect the registry, never the disk'
    }

    It 'survives a corrupt registry file' {
        $sb = New-Sandbox
        $proj = New-Project -Sandbox $sb -Name 'alpha'
        $null = Invoke-Myco -Sandbox $sb -WorkDir $proj -MycoArgs @('start')
        Set-Content -LiteralPath (Join-Path $sb.MycoHome 'registry.json') -Value '{ not json' -Encoding ASCII
        $r = Invoke-Myco -Sandbox $sb -WorkDir $proj -MycoArgs @('sessions')
        Assert-NoMatch $r.Output '(?i)unhandled|stack trace' 'a corrupt registry must not crash myco'
    }
}

Describe 'usability' {

    It 'prints help when invoked with no arguments' {
        $sb = New-Sandbox
        $proj = New-Project -Sandbox $sb -Name 'alpha'
        $r = Invoke-Myco -Sandbox $sb -WorkDir $proj -MycoArgs @()
        Assert-Match $r.Output 'myco start' 'help must document start'
        Assert-Match $r.Output 'myco continue' 'help must document continue'
        Assert-Match $r.Output 'myco sessions' 'help must document sessions'
        Assert-Match $r.Output 'myco resume' 'help must document resume'
    }

    It 'rejects an unknown command with a non-zero exit code' {
        $sb = New-Sandbox
        $proj = New-Project -Sandbox $sb -Name 'alpha'
        $r = Invoke-Myco -Sandbox $sb -WorkDir $proj -MycoArgs @('bogus')
        Assert-Match $r.Output '(?i)unknown command' 'must name the problem'
        Assert-NoMatch $r.ExitCode '^0$' 'must exit non-zero'
    }

    It 'reports a version' {
        $sb = New-Sandbox
        $proj = New-Project -Sandbox $sb -Name 'alpha'
        $r = Invoke-Myco -Sandbox $sb -WorkDir $proj -MycoArgs @('version')
        Assert-Match $r.Output '\d+\.\d+\.\d+' 'version must be printed'
    }

    It 'status describes the current folder' {
        $sb = New-Sandbox
        $proj = New-Project -Sandbox $sb -Name 'alpha'
        $null = Invoke-Myco -Sandbox $sb -WorkDir $proj -MycoArgs @('start')
        $r = Invoke-Myco -Sandbox $sb -WorkDir $proj -MycoArgs @('status')
        Assert-Match $r.Output '001' 'status must show the workspace id for the current folder'
    }
}

Describe 'repository hygiene' {

    It 'contains no machine-specific absolute paths in tracked files' {
        Push-Location $script:RepoRoot
        try {
            $tracked = @(& git ls-files 2>$null)
        } finally { Pop-Location }
        if ($tracked.Count -eq 0) { throw 'no tracked files found - run this from a git checkout' }

        # Built at runtime so this test file does not match itself.
        $userDir = 'C:' + [char]92 + 'Users' + [char]92
        $projDir = 'C:' + [char]92 + 'projects' + [char]92
        $offenders = New-Object System.Collections.ArrayList
        foreach ($f in $tracked) {
            $full = Join-Path $script:RepoRoot $f
            if (-not (Test-Path -LiteralPath $full -PathType Leaf)) { continue }
            $content = Get-Content -LiteralPath $full -Raw -ErrorAction SilentlyContinue
            if ($null -eq $content) { continue }
            if ($content.Contains($userDir) -or $content.Contains($projDir)) {
                [void]$offenders.Add($f)
            }
        }
        Assert-Equal 0 $offenders.Count ('tracked files leak local paths: ' + ($offenders -join ', '))
    }

    It 'ships installation scripts for both shells' {
        Assert-True (Test-Path -LiteralPath (Join-Path $script:RepoRoot 'install\install.ps1')) `
            'install.ps1 must exist'
        Assert-True (Test-Path -LiteralPath (Join-Path $script:RepoRoot 'install\install.cmd')) `
            'install.cmd must exist'
        Assert-True (Test-Path -LiteralPath (Join-Path $script:RepoRoot 'install\uninstall.ps1')) `
            'uninstall.ps1 must exist'
    }
}

# -------------------------------------------------------------------- report

Write-Host ''
Write-Host ('-' * 60)
Write-Host ("passed: {0}  failed: {1}  skipped: {2}" -f $script:Passed, $script:Failed, $script:Skipped)

if ($script:Failed -gt 0) {
    Write-Host ''
    Write-Host 'Failures:' -ForegroundColor Red
    foreach ($f in $script:Failures) { Write-Host ('  - ' + $f) -ForegroundColor DarkRed }
}

if (-not $KeepSandbox) {
    Remove-Item -LiteralPath $script:SandboxRoot -Recurse -Force -ErrorAction SilentlyContinue
} else {
    Write-Host ('sandbox kept at: ' + $script:SandboxRoot) -ForegroundColor DarkGray
}

if ($script:Failed -gt 0) { exit 1 }
exit 0
