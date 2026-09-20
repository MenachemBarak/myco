---
name: myco-shell-traps
description: >
  Windows dual-shell traps for CLI tools that must work in both PowerShell and cmd.exe, each
  one verified by a real failure in the myco project. Use when writing or debugging PowerShell
  or cmd entry points, forwarding arguments to another CLI, generating batch files, changing
  the caller's working directory, rendering box-drawing or non-ascii output to a console,
  measuring terminal width, detecting whether a process is still running, or writing tests that
  drive real shells. Read before touching bin/myco.ps1, bin/myco.cmd, lib/myco-run.ps1 or the
  rendering and liveness code in lib/myco-core.ps1.
---

# Windows dual-shell traps

Each trap below caused a real, observed failure. They are easy to reintroduce
because the wrong version usually looks right and often half-works.

## 1. `@(...)` is not splatting

```powershell
& copilot @($plan.CopilotArgs)   # WRONG - one argument
$copilotArgs = @($plan.CopilotArgs)
& copilot @copilotArgs           # RIGHT - splatted
```

`@(...)` is the array subexpression operator. Against a native `.exe` the
difference is often invisible, because PowerShell stringifies the array into
something the exe can re-split. Against a **PowerShell** target it is fatal: the
whole list arrives as one argument.

Observed: `error: unexpected argument '--yolo -p ... --silent' found`.

This matters here because npm installs both `copilot.cmd` and `copilot.ps1`,
and PowerShell prefers the `.ps1`. Verify what a command actually resolves to
before assuming:

```powershell
(Get-Command copilot).Source
```

**Testing consequence.** A `.cmd` stub cannot catch this, because cmd flattens
arguments anyway. Provide stubs matching the real install layout, and record
each argument separately.

## 2. The comma operator binds tighter than `+`

```powershell
$lines = @(
    'cd /d "' + $dir + '"',     # WRONG - becomes three elements
    ('cd /d "' + $dir + '"')    # RIGHT
)
```

Inside an array literal, `'a' + $x + 'b'` is parsed as `'a'`, `$x + 'b'`. A
generated batch file silently came out with each line split across three lines,
producing `cd /d "` followed by a bare path. Parenthesise every computed element
of an array literal.

## 3. Native stderr throws under `$ErrorActionPreference = 'Stop'`

A CLI that reports problems on stderr will have those lines rethrown as
exceptions by a caller running under `Stop`. In a test harness this fails the
very error-path tests that are asserting on that output. Set `Continue` around
the invocation and restore it afterwards.

## 4. A child process cannot change the caller's directory

Two mechanisms work, and both were verified:

- **PowerShell**: a dot-sourced function. `Set-Location` inside it persists.
- **cmd.exe**: a batch file invoked with `call`. `cd /d` inside it persists.

So the tool decides what to do, then hands the caller a plan to execute in its
own session. In `cmd.exe`, release `setlocal` *before* running the plan,
otherwise the `cd` is rolled back with the scope.

## 5. Undefined variables echo literally in cmd

```bat
echo LEAK=%COPILOT_HOME%
```

prints the literal `%COPILOT_HOME%` when unset, not an empty string. Any test
asserting "this variable is empty" must branch:

```bat
if defined COPILOT_HOME (echo LEAK=%COPILOT_HOME%) else (echo LEAK=)
```

## 6. `[Console]::WindowWidth` throws when output is redirected

`The handle is invalid.` — and redirection is the normal case whenever a user
pipes or captures output. Prefer `$Host.UI.RawUI.WindowSize.Width`, which still
answers, and guard both:

```powershell
$width = 0
try { $width = [int]$Host.UI.RawUI.WindowSize.Width } catch { }
if ($width -le 0) { try { $width = [int][Console]::WindowWidth } catch { } }
if ($width -le 0) { $width = 100 }
```

## 7. Code page 437 has box drawing, but not every glyph

A measured surprise. Legacy `cmd.exe` consoles render `┌ ─ │ ┼` perfectly, and
also `·`. They cannot render `●`, `…` or `→`.

So degrade **per character**, not all at once:

```powershell
$ch = [string][char]$CodePoint
if ($Encoding.GetString($Encoding.GetBytes($ch)) -eq $ch) { return $ch }
return $Fallback
```

All-or-nothing fallback needlessly throws away borders that work.

**Testing consequence.** To see mojibake you must capture the raw bytes and
decode with the code page under test. Let the batch file do its own redirect;
piping through PowerShell re-encodes and hides the problem.

## 8. A lock file does not prove a process is alive

Lock files outlive crashes, and Windows reuses process ids. Measured on one real
machine: 258 stale locks, and four of the nine live ids behind them belonged to
`chrome`, `msedge` and `OpenConsole`.

The sound test correlates the lock with the process:

```powershell
# The writer had to exist when the lock was written, so anything that
# started later merely inherited the id.
if ($started -le $lock.LastWriteTime.AddMinutes(2)) { return $true }
```

Treat an unreadable start time as not-alive. Take one process snapshot per
listing rather than querying per candidate, and resolve liveness only for the
rows actually displayed.

## 9. PowerShell 5.1 has no inline `if` expression

```powershell
$s = 'x' + (if ($n -eq 1) { 'a' } else { 'b' })   # parse error in 5.1
```

Assigning an `if` to a variable is fine; using one *inside* a larger expression
is not. `powershell.exe` ships on every Windows machine, so test there too, not
only in `pwsh`.

## 10. Environment variables beat command lines for handoff

Passing user arguments from `cmd.exe` to PowerShell as `MYCO_ARGC` and
`MYCO_ARG_n` removes a whole quoting layer. Prompts containing spaces, quotes or
`%` survive untouched, and nothing binds to PowerShell's parameter parser.
