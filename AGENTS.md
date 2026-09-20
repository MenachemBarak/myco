# AGENTS.md — maintaining myco

Read this before changing anything. It is the handoff for any agent or person
who picks this project up cold.

Deeper material lives beside it:

| File | What it holds |
| --- | --- |
| `docs/DECISIONS.md` | Every design decision, why it was made, and what breaks if it is reversed. |
| `.agents/skills/myco-shell-traps/SKILL.md` | The Windows dual-shell traps that already cost real debugging time. |
| `.agents/skills/myco-maintenance/SKILL.md` | The working loop: test, TDD, release. |
| `.github/agents/myco-maintainer.agent.md` | A Copilot CLI agent preloaded with all of the above. |

## What myco is

A Windows CLI that gives each project folder its own GitHub Copilot CLI
workspace. `myco start` points `COPILOT_HOME` at `<project>\.copilot`, so
sessions, history and settings stay with the project instead of piling into one
global directory. A numbered registry lets you list every folder and resume any
recent session by a short id such as `001002`.

Shipped as PowerShell and `cmd.exe` entry points over one shared core. No
compilation, no dependencies, no package manager.

## The one mechanism

Everything rests on a single fact: **the Copilot CLI reads `COPILOT_HOME` to
decide where its configuration and state live, and the login is stored
elsewhere.** That is why a project workspace does not require signing in again.

If a future Copilot release moves authentication into `COPILOT_HOME`, or stops
reading that variable, myco's premise breaks. Check this first when something
large stops working.

## Repository map

```
bin/myco.ps1        PowerShell entry point. Defines the `myco` function.
bin/myco.cmd        cmd.exe entry point. Hands arguments to PowerShell, runs the plan.
lib/myco-core.ps1   All logic. Registry, sessions, rendering, command dispatch.
lib/myco-run.ps1    Shim myco.cmd calls. Writes the batch plan.
install/            User-scope install and uninstall. No admin rights.
test/Run-Tests.ps1  The whole suite. End to end, through real shells.
docs/DECISIONS.md   Decision log.
```

`lib/myco-core.ps1` only defines functions. `Invoke-MycoCore` is the dispatcher;
it returns `ExitCode` and an optional `Plan`. It never launches Copilot itself —
the caller does, because only the caller's own shell can keep a directory
change.

## Run the tests

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File test\Run-Tests.ps1
pwsh       -NoProfile -ExecutionPolicy Bypass -File test\Run-Tests.ps1 -PsExe pwsh.exe
```

Both must pass before anything ships. The suite drives the real entry points
through real `powershell.exe`, `pwsh.exe` and `cmd.exe` sessions, with a
recording stub standing in for the Copilot CLI, so it is fast and costs nothing.

Narrow it while iterating:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File test\Run-Tests.ps1 -Filter '*active*'
```

Every test runs in a sandbox with `MYCO_HOME`, `USERPROFILE` and `TEMP`
redirected. **A test must never touch the real registry or the real global
Copilot home.** If you add a test that needs new environment isolation, extend
the sandbox rather than reaching outside it.

## How to change this project

This repository is maintained test-first, and the git history is the proof.

1. Write the failing test first. Run it. Capture the real counts.
2. **Commit the failing test on its own** — tests and fixtures only, no
   production files. `git show --name-only <commit>` must show only test files.
3. Then write the fix, and commit it with the passing counts.
4. Put the evidence in the commit message: the command, the pass/fail/skip
   line, and for behavioural fixes what you verified against the real Copilot
   CLI rather than the stub.

Never use `git stash` here. Use a scratch commit on your own branch instead.

Commit subjects follow `test: RED - …`, `fix: GREEN - …`, `feat: GREEN - …`,
`chore: …`. Releases get an annotated tag, `vMAJOR.MINOR.PATCH`, matching
`Get-MycoVersion` in `lib/myco-core.ps1`.

## Invariants

These are not style preferences. Each one is load-bearing, and several were
learned by breaking them.

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
- **Adopted workspaces are never seeded.** Seeding only ever applies to a
  `.copilot` myco just created, and never copies a folder into itself.
- **Active means a process is genuinely running.** See below.
- **Nothing is emitted that the console cannot render.** See below.
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
that started later merely inherited the id. Do not simplify this back to "does
a lock file exist".

**Rendering.** Glyphs degrade one character at a time against the console
encoding, not all at once. Code page 437 has the full box-drawing set but no
filled circle or ellipsis, so it keeps its borders and only swaps those two.
Console width comes from `$Host.UI.RawUI`, because `[Console]::WindowWidth`
throws whenever output is redirected — which is exactly what happens when a
user pipes `myco sessions`.

## Releasing

1. Both suites green.
2. Bump `Get-MycoVersion` in `lib/myco-core.ps1`.
3. Reinstall locally and verify against the real Copilot CLI, not just the stub.
4. Commit, annotate a tag, push both.

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File install\install.ps1
```

The installer is idempotent and replaces its own profile line rather than
appending a second one.

## Care with the user's machine

This tool manipulates real Copilot state. When testing by hand:

- Register throwaway folders under `%TEMP%`, and `myco forget <id>` them
  afterwards. Do not leave demo workspaces in a real registry.
- Never delete a `.copilot` folder you did not create.
- Check `myco sessions` before and after, so you can prove you left the
  registry as you found it.
