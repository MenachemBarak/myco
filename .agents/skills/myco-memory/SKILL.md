---
name: myco-memory
description: >
  The complete project memory for the myco CLI, which gives each project folder its own Copilot
  CLI workspace via COPILOT_HOME. Holds the architecture, the invariants that must never
  regress, every design decision with its rationale and what breaks if reversed, the Windows
  dual-shell traps behind those decisions, and the test, verification and release loop. Use for
  any change to myco, when running or extending its end-to-end suite across powershell.exe,
  pwsh.exe and cmd.exe, when touching argument forwarding, generated batch, console rendering,
  terminal width, process liveness, the registry, seeding or the installer, before overturning
  anything in the codebase that looks odd, and before tagging a release.
---

# myco — project memory

Everything a maintainer needs, in one place. This file is the index and the
always-on part; load a reference only when the work calls for it.

## What myco is

A Windows CLI that gives each project folder its own GitHub Copilot CLI
workspace. `myco start` points `COPILOT_HOME` at `<project>\.copilot`, so
sessions, history and settings stay with the project instead of piling into one
global directory. A numbered registry lets you list every folder and resume any
recent session by a short id such as `001002`.

PowerShell and `cmd.exe` entry points over one shared core. No compilation, no
dependencies, no package manager.

## The one mechanism

Everything rests on a single fact: **the Copilot CLI reads `COPILOT_HOME` to
decide where its configuration and state live, and the login is stored
elsewhere.** That is why a project workspace does not require signing in again.

If a future Copilot release moves authentication into `COPILOT_HOME`, or stops
reading that variable, myco's premise breaks. Check this first when something
large stops working.

## Where to look

| You are doing this | Load this |
| --- | --- |
| Changing entry points, argument forwarding, generated batch, rendering, width, liveness | `references/shell-traps.md` |
| Running, filtering or extending the test suite; installing; releasing | `references/maintenance.md` |
| Asking why something is the way it is, or planning to change a design | `references/decisions.md` |
| Finding your way around the code | The repository map below |

Do not read all three speculatively. Each is self-contained.

## Commands

`start`, `continue`, `sessions`, `resume`, `recover`, `status`, `config`,
`forget`, `prune`, `version`, `help`.

`recover` reopens every session touched in a window — two hours by default,
`--hours=<n>` to change — as one Windows Terminal tab each. It is the only
command that needs `wt`, and it skips sessions that are still running unless
given `--all`.

## Repository map

```
bin/myco.ps1        PowerShell entry point. Defines the `myco` function.
bin/myco.cmd        cmd.exe entry point. Hands arguments to PowerShell, runs the plan.
lib/myco-core.ps1   All logic. Registry, sessions, rendering, command dispatch.
lib/myco-run.ps1    Shim myco.cmd calls. Writes the batch plan.
install/            User-scope install and uninstall. No admin rights.
test/Run-Tests.ps1  The whole suite. End to end, through real shells.
```

`lib/myco-core.ps1` only defines functions. `Invoke-MycoCore` is the dispatcher;
it returns `ExitCode` and an optional `Plan`. **It never launches Copilot
itself** — the caller does, because only the caller's own shell can keep a
directory change. Adding a command means a `case` there, a function beside its
peers, a line in `Show-MycoHelp`, and a test.

## Invariants

Not style preferences. Each is load-bearing, and several were learned by
breaking them.

- **`COPILOT_HOME` is always restored**, in both shells, including on failure.
  Leaking it silently redirects the user's next plain `copilot` run.
- **Arguments reach Copilot separately.** Splat a variable; `@(...)` is the
  array subexpression operator, not splatting, and collapses everything into a
  single argument against the npm `copilot.ps1` shim.
- **Workspace ids are stable and never reused.** `forget` and `prune` must not
  renumber survivors, because users keep ids in their heads and in notes.
- **`forget` and `prune` touch the registry only.** They must never delete a
  `.copilot` folder.
- **An unreadable registry is set aside, never overwritten**, so a corrupt file
  is recoverable.
- **Adopted workspaces are never seeded**, and nothing is ever seeded from
  itself.
- **Active means a process genuinely exists and started no later than its lock
  was written.** Do not simplify this back to "a lock file exists".
- **`recover` resumes concrete session ids, never list positions**, and skips
  sessions that are still running unless asked otherwise.
- **The Windows Terminal stub must stay first on `PATH` in tests.** Without it
  the suite opens real terminal windows.
- **Nothing is emitted that the console cannot render**; glyphs degrade one
  character at a time.
- **Terminal width comes from `$Host.UI.RawUI`.** `[Console]::WindowWidth`
  throws whenever output is redirected.
- **No machine-specific absolute paths in tracked files.** A test enforces this
  over `git ls-files`; write `%APPDATA%` or `<project>`, never a real home path.
- **PowerShell 5.1 must keep working.** It is the `powershell.exe` every Windows
  box already has. No `if` used as an inline expression, no PS7-only operators.

## Two subtleties worth knowing before you touch them

**Liveness.** Copilot marks a live session with an `inuse.<pid>.lock` file, but
those files survive crashes, and Windows hands process ids out again. On a real
machine 258 such locks were present, and four of the live ids behind them
belonged to `chrome`, `msedge` and `OpenConsole`. So a lock counts as proof of
life only when the process still exists **and** started no later than the lock
was written: whoever wrote the lock had to be alive at that moment, so anything
that started later merely inherited the id.

**Rendering.** Glyphs degrade one character at a time against the console
encoding, not all at once. Code page 437 has the full box-drawing set but no
filled circle or ellipsis, so it keeps its borders and only swaps those two.

## The working agreement

This repository is maintained test-first, and the git history is the proof.

1. Write the failing test first. Run it. Capture the real counts.
2. **Commit the failing test on its own** — tests and fixtures only. Verify with
   `git show --name-only <commit>`; a production file there is a process defect.
3. Then write the fix, and commit it with the passing counts.
4. Put the evidence in the commit message: the command, the pass/fail/skip line,
   and for behavioural fixes what you verified against the **real** Copilot CLI
   rather than the stub.

Never `git stash` here; use a scratch commit on your own branch.

Subjects: `test: RED - …`, `fix: GREEN - …`, `feat: GREEN - …`, `chore: …`.
Releases get an annotated tag `vX.Y.Z` matching `Get-MycoVersion` in
`lib/myco-core.ps1`.

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File test\Run-Tests.ps1
pwsh       -NoProfile -ExecutionPolicy Bypass -File test\Run-Tests.ps1 -PsExe pwsh.exe
```

Both must pass before anything ships. Details in `references/maintenance.md`.

## Care with the user's machine

This tool manipulates real Copilot state, and the registry you are touching is
probably the owner's own.

- Register throwaway folders under `%TEMP%`, and `myco forget <id>` them
  afterwards. Do not leave demo workspaces in a real registry.
- Never delete a `.copilot` folder you did not create.
- Check `myco sessions` before and after, so you can prove you left the registry
  as you found it.
