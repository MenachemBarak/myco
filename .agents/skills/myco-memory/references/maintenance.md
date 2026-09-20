# Maintaining myco

Part of the `myco-memory` skill. Load for any change to myco, for adding or
debugging its tests, or before tagging a release.

`SKILL.md` holds the architecture and invariants, and `decisions.md` explains
why anything is the way it is. This file is the mechanics.

## The loop

```powershell
# whole suite, both shells - required before anything ships
powershell -NoProfile -ExecutionPolicy Bypass -File test\Run-Tests.ps1
pwsh       -NoProfile -ExecutionPolicy Bypass -File test\Run-Tests.ps1 -PsExe pwsh.exe

# while iterating
powershell -NoProfile -ExecutionPolicy Bypass -File test\Run-Tests.ps1 -Filter '*active*'

# keep the sandbox to inspect what a test produced
powershell -NoProfile -ExecutionPolicy Bypass -File test\Run-Tests.ps1 -Filter '*table*' -KeepSandbox
```

The suite is self-contained: a recording stub stands in for Copilot, so it is
fast and costs nothing. `-PsExe` selects which PowerShell the `pwsh` shell
drivers use, which is how both versions get covered.

## Test-first, and the history proves it

1. Write the failing test. Run it. Copy the real `passed/failed/skipped` line.
2. **Commit the failing test alone** — tests and fixtures only. Verify with
   `git show --name-only <commit>`; a production file in that commit is a
   defect in the process.
3. Write the fix. Run both shells. Commit with the passing counts.
4. Put the evidence in the message: the command, the counts, and what you
   verified against the real Copilot CLI.

Never `git stash` in this repository; use a scratch commit on a branch.

Subjects: `test: RED - …`, `fix: GREEN - …`, `feat: GREEN - …`, `chore: …`.

## Writing a test

Helpers in `test/Run-Tests.ps1`:

| Helper | Use |
| --- | --- |
| `New-Sandbox` | Disposable `MYCO_HOME`, `USERPROFILE`, `TEMP`, stub `PATH`. |
| `New-Project` | A folder to run myco in. |
| `New-FakeSession` | A session-state folder; `-Active`, `-LockPid`, `-LockWrittenAt` drive liveness. |
| `Start-TestProcess` | A real live process, cleaned up at the end. |
| `Invoke-Myco` | Runs myco for real; `-Shell pwsh|pwsh7|cmd`, `-CodePage` for encoding tests. |
| `Get-LastCopilotCall` | What Copilot received: `Cwd`, `Home`, `CliArgs`, `ArgList`. |
| `Get-TableRow` | Rendered table rows, either glyph style. |

`Invoke-Myco` returns `Output`, `FinalCwd`, `ExitCode` and `Leak` — the last two
exist so exit codes and `COPILOT_HOME` restoration are assertable, and
`FinalCwd` is how the directory-change behaviour is proven.

Rules:

- Never reach outside the sandbox. If a test needs new isolation, extend
  `New-Sandbox`.
- Assert behaviour a user could notice, not internal shape.
- Anything about processes, encodings or shells must be driven through the real
  thing. Mocking those tests the mock — see `decisions.md` 8.4.

## Verify against the real tools

The stubs cannot see how the real Copilot CLI and the real Windows Terminal
*parse* what myco hands them, and two bugs have escaped through that gap: an
argument list collapsed by the npm `copilot.ps1` shim, and a command split in
half by Windows Terminal at an embedded semicolon. Run the live check before a
release, and after touching launching, argument handling or session state:

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File test\Verify-Live.ps1
```

It creates one real session, runs `myco recover` verbatim, and proves the
recovered tab actually resumed by waiting for a Copilot process to attach and
write its lock file. It costs a few AI credits and briefly opens a window,
which it minimises and then closes.

**Never improvise a probe instead.** It is isolated in three dimensions, and
each one was learned the hard way:

| Dimension | How | Why |
| --- | --- | --- |
| State | temp `MYCO_HOME`, workspace under `%TEMP%` | the real registry is never read or written |
| Windows | window handles captured before and after; only new ones closed | a failed tab keeps its window open, so ad-hoc probes litter the user's screen |
| Processes | Copilot pids captured before and after; only new ones stopped | never kill a session you did not start |

Windows Terminal hosts every window in **one** process, so never kill
`WindowsTerminal` — that would close the user's own sessions. Enumerate
top-level windows and post `WM_CLOSE` to the specific handles, once per tab.

And do not substitute the payload when checking a launch. Verifying a
semicolon-free stand-in is what let the semicolon bug through.

## Leave the machine as you found it

The registry being manipulated may be the owner's real one.

- Note the workspace ids before you start; `myco sessions`.
- Only `myco forget` ids you created.
- Never delete a `.copilot` folder you did not create.
- Sweep `%TEMP%` for `myco-*` leftovers when you finish.

## Install and release

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File install\install.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File install\uninstall.ps1   # -Purge also drops the registry
```

The installer copies to `%APPDATA%\.myco\app`, adds the launcher to the user
`PATH` for `cmd.exe`, and rewrites one marked line in the PowerShell profiles.
It is idempotent, needs no administrator rights, and writes nothing outside the
user profile. Reinstall after changing anything under `bin/` or `lib/`,
otherwise you are testing the previously installed copy.

Release: both suites green, bump `Get-MycoVersion` in `lib/myco-core.ps1`,
reinstall and verify live, then commit, annotate a tag `vX.Y.Z`, and push both
the branch and the tag.

## Where things live

`lib/myco-core.ps1` holds all logic and only defines functions.
`Invoke-MycoCore` dispatches and returns `ExitCode` plus an optional `Plan`; it
never launches Copilot, because only the caller's own shell can keep a
directory change. Adding a command means a `case` there, a function beside its
peers, a line in `Show-MycoHelp`, and a test.
