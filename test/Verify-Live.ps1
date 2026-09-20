#Requires -Version 5.1
<#
.SYNOPSIS
    Isolated live verification of myco against the real Copilot CLI and the
    real Windows Terminal.

.DESCRIPTION
    Run-Tests.ps1 replaces Copilot and Windows Terminal with stubs, which keeps
    it fast and free but cannot see how the real tools parse what myco hands
    them. Two bugs escaped that way: an argument list collapsed by the npm
    copilot.ps1 shim, and a command split in half by Windows Terminal at an
    embedded semicolon.

    This script closes that gap without leaving debris. Everything it touches
    is isolated and reverted:

      state     MYCO_HOME and the workspace live under a temporary folder, so
                the real registry is never read or written
      windows   terminal windows are identified by handle before and after, and
                only genuinely new ones are closed
      processes Copilot processes are counted before and after, and only ones
                this script started are stopped

    It runs the real "myco recover" verbatim. Nothing about the launch is
    substituted, because substituting the payload is precisely what hid the
    semicolon bug.

    Costs a few AI credits: it creates one real Copilot session and resumes it.

.EXAMPLE
    pwsh -NoProfile -ExecutionPolicy Bypass -File test\Verify-Live.ps1
#>
[CmdletBinding()]
param(
    [switch]$KeepArtifacts
)

$ErrorActionPreference = 'Stop'

$script:RepoRoot = Split-Path -Parent $PSScriptRoot
$script:Launcher = Join-Path $script:RepoRoot 'bin\myco.ps1'
$script:Failures = New-Object System.Collections.ArrayList

function Write-Step { param([string]$Text) Write-Host ('  ' + $Text) -ForegroundColor DarkGray }
function Write-Pass { param([string]$Text) Write-Host ('  [PASS] ' + $Text) -ForegroundColor Green }
function Write-Fail {
    param([string]$Text)
    [void]$script:Failures.Add($Text)
    Write-Host ('  [FAIL] ' + $Text) -ForegroundColor Red
}

# ------------------------------------------------------------ window tracking

Add-Type -TypeDefinition @"
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;
public class MycoWin {
  [DllImport("user32.dll")] static extern bool EnumWindows(EnumProc cb, IntPtr p);
  [DllImport("user32.dll")] static extern int GetWindowTextLength(IntPtr h);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] static extern int GetWindowText(IntPtr h, StringBuilder s, int n);
  [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr h);
  [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
  [DllImport("user32.dll")] public static extern bool PostMessage(IntPtr h, uint m, IntPtr w, IntPtr l);
  [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int cmd);
  delegate bool EnumProc(IntPtr h, IntPtr p);
  public static List<long> Handles(uint want) {
    var res = new List<long>();
    EnumWindows((h, p) => {
      uint pid; GetWindowThreadProcessId(h, out pid);
      if (pid == want && IsWindowVisible(h) && GetWindowTextLength(h) > 0) res.Add(h.ToInt64());
      return true;
    }, IntPtr.Zero);
    return res;
  }
}
"@ -Language CSharp

function Get-TerminalHandles {
    $handles = New-Object System.Collections.ArrayList
    foreach ($p in @(Get-Process -Name WindowsTerminal -ErrorAction SilentlyContinue)) {
        foreach ($h in @([MycoWin]::Handles($p.Id))) { [void]$handles.Add([long]$h) }
    }
    return @($handles.ToArray())
}

function Close-TerminalWindow {
    param([long]$Handle)
    # A window holding several tabs needs one close per tab.
    foreach ($i in 1..6) {
        [void][MycoWin]::PostMessage([IntPtr]$Handle, 0x0010, [IntPtr]::Zero, [IntPtr]::Zero)
        Start-Sleep -Milliseconds 500
    }
}

function Get-CopilotPids {
    return @(Get-Process -Name copilot -ErrorAction SilentlyContinue | ForEach-Object { $_.Id })
}

# -------------------------------------------------------------------- set-up

Write-Host ''
Write-Host 'myco live verification (real Copilot CLI, real Windows Terminal)' -ForegroundColor White
Write-Host ''

foreach ($required in @('copilot', 'wt')) {
    if (-not (Get-Command $required -ErrorAction SilentlyContinue)) {
        Write-Host ("  $required was not found on PATH; cannot verify live.") -ForegroundColor Yellow
        exit 2
    }
}

$stamp = [guid]::NewGuid().ToString('N').Substring(0, 8)
$root = Join-Path $env:TEMP ('myco-live\' + $stamp)
$workspace = Join-Path $root 'project'
$mycoHome = Join-Path $root 'mycohome'
New-Item -ItemType Directory -Force -Path $workspace, $mycoHome | Out-Null

$windowsBefore = @(Get-TerminalHandles)
$copilotBefore = @(Get-CopilotPids)
Write-Step ('isolated state : ' + $root)
Write-Step ('terminal windows open: ' + $windowsBefore.Count + ', copilot processes: ' + $copilotBefore.Count)

$savedMycoHome = [Environment]::GetEnvironmentVariable('MYCO_HOME')
$newWindows = @()

try {
    $env:MYCO_HOME = $mycoHome

    # ---------------------------------------------------------- seed a session

    Write-Step 'creating one real Copilot session...'
    $seed = Join-Path $root 'seed.ps1'
    @(
        ('Set-Location -LiteralPath ' + "'" + $workspace + "'"),
        ('. ' + "'" + $script:Launcher + "'"),
        'myco start -p "reply with exactly LIVE_SEED" --silent'
    ) -join "`r`n" | Set-Content -LiteralPath $seed -Encoding UTF8
    & pwsh.exe -NoProfile -ExecutionPolicy Bypass -File $seed | Out-Null

    $stateRoot = Join-Path $workspace '.copilot\session-state'
    $sessionDirs = @(Get-ChildItem -LiteralPath $stateRoot -Directory -ErrorAction SilentlyContinue)
    if ($sessionDirs.Count -eq 1) {
        Write-Pass 'myco start created exactly one session in the project workspace'
    } else {
        Write-Fail ('expected one session, found ' + $sessionDirs.Count)
        throw 'cannot continue without a seeded session'
    }

    # -------------------------------------------------------- recover for real

    Write-Step 'running the real "myco recover"...'
    $rec = Join-Path $root 'recover.ps1'
    @(
        ('Set-Location -LiteralPath ' + "'" + $workspace + "'"),
        ('. ' + "'" + $script:Launcher + "'"),
        'myco recover --hours=1 --max=2'
    ) -join "`r`n" | Set-Content -LiteralPath $rec -Encoding UTF8
    $recoverOutput = (& pwsh.exe -NoProfile -ExecutionPolicy Bypass -File $rec 2>&1 | Out-String)

    # Get the recovered window out of the way as soon as it exists. It is real
    # and must stay running to be checked, but it should not take over the
    # screen of whoever is running the verification.
    foreach ($attempt in 1..20) {
        $seen = @(Get-TerminalHandles | Where-Object { $windowsBefore -notcontains $_ })
        if ($seen.Count -gt 0) {
            foreach ($h in $seen) { [void][MycoWin]::ShowWindow([IntPtr]$h, 6) }
            break
        }
        Start-Sleep -Milliseconds 500
    }

    Start-Sleep -Seconds 12
    $windowsAfter = @(Get-TerminalHandles)
    $newWindows = @($windowsAfter | Where-Object { $windowsBefore -notcontains $_ })

    if ($newWindows.Count -eq 1) {
        Write-Pass 'recover opened exactly one terminal window'
    } else {
        Write-Fail ('expected one new window, got ' + $newWindows.Count +
            ' (a split command line shows up here as an extra window)')
    }

    if ($recoverOutput -notmatch '(?i)error|cannot find') {
        Write-Pass 'recover reported no launch error'
    } else {
        Write-Fail ('recover reported a problem:' + "`n" + $recoverOutput.Trim())
    }

    # A resumed session attaches a live Copilot process and writes a lock, which
    # is the only proof that the tab really resumed rather than merely opening.
    $lockSeen = $false
    foreach ($attempt in 1..10) {
        $locks = @(Get-ChildItem -LiteralPath $sessionDirs[0].FullName -Filter 'inuse.*.lock' `
                -File -ErrorAction SilentlyContinue)
        if ($locks.Count -gt 0) { $lockSeen = $true; break }
        Start-Sleep -Seconds 2
    }
    if ($lockSeen) {
        Write-Pass 'the recovered tab actually resumed the session (a Copilot process attached)'
    } else {
        Write-Fail 'no Copilot process attached, so the tab opened but never resumed'
    }

    $copilotAfter = @(Get-CopilotPids)
    if (@($copilotAfter | Where-Object { $copilotBefore -notcontains $_ }).Count -ge 1) {
        Write-Pass 'exactly the expected new Copilot process appeared'
    } else {
        Write-Fail 'no new Copilot process appeared'
    }

} finally {

    # ------------------------------------------------------------------ revert

    Write-Host ''
    Write-Step 'cleaning up...'

    foreach ($h in @($newWindows)) { Close-TerminalWindow -Handle $h }
    Start-Sleep -Seconds 2

    foreach ($id in @(Get-CopilotPids | Where-Object { $copilotBefore -notcontains $_ })) {
        try { Stop-Process -Id $id -Force -ErrorAction SilentlyContinue } catch { }
    }

    if ($savedMycoHome) {
        $env:MYCO_HOME = $savedMycoHome
    } else {
        Remove-Item Env:\MYCO_HOME -ErrorAction SilentlyContinue
    }

    if (-not $KeepArtifacts) {
        Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
        # Drop the shared parent too, but only once it is empty, so a
        # concurrent run is never disturbed.
        $parent = Split-Path -Parent $root
        if ((Test-Path -LiteralPath $parent) -and
            @(Get-ChildItem -LiteralPath $parent -Force -ErrorAction SilentlyContinue).Count -eq 0) {
            Remove-Item -LiteralPath $parent -Force -ErrorAction SilentlyContinue
        }
    }

    $leftoverWindows = @(Get-TerminalHandles | Where-Object { $windowsBefore -notcontains $_ })
    $leftoverProcs = @(Get-CopilotPids | Where-Object { $copilotBefore -notcontains $_ })
    if ($leftoverWindows.Count -eq 0 -and $leftoverProcs.Count -eq 0) {
        Write-Pass 'left no terminal window or Copilot process behind'
    } else {
        Write-Fail ('left ' + $leftoverWindows.Count + ' window(s) and ' +
            $leftoverProcs.Count + ' process(es) behind')
    }
}

Write-Host ''
if ($script:Failures.Count -eq 0) {
    Write-Host 'Live verification passed.' -ForegroundColor Green
    Write-Host ''
    exit 0
}
Write-Host ('Live verification failed: ' + $script:Failures.Count + ' problem(s).') -ForegroundColor Red
Write-Host ''
exit 1
