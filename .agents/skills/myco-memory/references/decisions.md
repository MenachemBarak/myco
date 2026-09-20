# Decisions

Part of the `myco-memory` skill. Load before overturning anything that looks
odd, before changing seeding, liveness, rendering or the registry, and whenever
you need the reasoning behind a design rather than its mechanics.

Every decision that shaped myco, why it was made, and what breaks if it is
reversed. Read `SKILL.md` first.

A decision marked **measured** was settled by running something on a real
machine rather than by reasoning about it.

---

## 1. Core mechanism

### 1.1 Per-folder `COPILOT_HOME`

`myco start` points `COPILOT_HOME` at `<project>\.copilot` for the life of one
session, then restores it.

**Why.** It is the only supported hook for relocating Copilot's configuration
and state, and it needs no cooperation from Copilot itself.

**Measured.** A brand-new `COPILOT_HOME` still runs without a fresh login, so
credentials are stored outside it. This was verified before any code was
written, because the whole idea collapses if a project workspace demands
re-authentication.

**If reversed.** There is no product. Watch for a Copilot release that moves
auth into `COPILOT_HOME` or stops reading it.

### 1.2 The variable is always restored

Both entry points restore the previous value, including on failure, and clear
it when it was previously unset.

**Why.** A leak silently redirects the user's next plain `copilot` run to the
wrong workspace — the kind of bug that is nearly impossible to attribute.

**Tested.** Both shells assert no leak after a run.

---

## 2. Why myco is a shell function, not an executable

### 2.1 The constraint

`myco resume 001002` must leave the user's shell inside the workspace folder. A
child process cannot change its parent's working directory.

### 2.2 PowerShell: a dot-sourced function

`bin/myco.ps1` defines a `myco` function, and the installer dot-sources it from
the profile.

**Measured.** `Set-Location` inside a function does persist in the caller's
session.

**Consequence.** The installer must edit the PowerShell profile. That is the
only reason it does, and it is called out in the README.

### 2.3 cmd.exe: a generated batch plan

`bin/myco.cmd` asks PowerShell what to do. PowerShell writes a small batch
fragment — `cd`, set `COPILOT_HOME`, run Copilot, restore — and `myco.cmd`
executes it with `call` in the caller's own session.

**Measured.** `cd /d` inside a `call`ed batch file does persist in the calling
session.

**Consequence.** `setlocal` is released before the plan runs, which both clears
the temporary argument variables and lets the plan's `cd` take effect.

### 2.4 No param block on the PowerShell function

`myco` reads `$args` instead of declaring parameters.

**Why.** Everything after the subcommand belongs to Copilot. A param block
would bind `--model` and friends to PowerShell instead of forwarding them.

### 2.5 Arguments cross into PowerShell as environment variables

`myco.cmd` exports `MYCO_ARGC` and `MYCO_ARG_1..n` rather than passing a command
line.

**Why.** It removes a whole quoting layer. A prompt containing spaces, quotes
or `%` survives without escaping games.

### 2.6 Splatting, not `@()`

**This was a real bug.** `& copilot @($plan.CopilotArgs)` passes *one* array
argument, because `@(...)` is the array subexpression operator, not splatting.

**Measured.** Against the real CLI this failed with
`error: unexpected argument '--yolo -p ... --silent' found`.

**Why the stub missed it.** npm installs both `copilot.cmd` and `copilot.ps1`,
and PowerShell resolves the `.ps1` shim first. The suite only had a `.cmd`
stub, which flattens arguments anyway and so could not see the difference. The
stub now mirrors the npm layout and records each argument separately.

**Lesson worth keeping.** A test double must match the real thing's *shape*,
not just its interface.

---

## 3. Registry

### 3.1 State lives in `%APPDATA%\.myco`, overridable by `MYCO_HOME`

`registry.json` and `config.json`. The override exists so the test suite can
sandbox itself, and so a user can relocate state.

### 3.2 Three-digit workspace ids, stable and never reused

Assigned in first-use order. `forget` removes an entry without renumbering the
rest.

**Why.** Users memorise ids and write them down. Renumbering on delete would
silently retarget a remembered id at a different project — a dangerous failure,
since `resume` then opens the wrong repository.

### 3.3 Session numbers are positions, not identities

`001002` means "the second entry in that workspace's current list", resolved to
a real session uuid at the moment you resume.

**Why.** Copilot session ids are uuids; nobody types those. Positions are
short and stable enough for the intended "list, then resume" flow.

**Known trade-off.** Positions shift as new sessions appear. This is documented
in the README rather than engineered away, because the alternative — a second
persistent id space that myco would have to keep synchronised with Copilot's
own session store — is a great deal of machinery for a list the user is looking
at anyway.

### 3.4 Atomic writes under a named mutex

Written to a temp file then swapped in, guarded by `Local\myco-registry-v1`.

**Why.** PowerShell and `cmd.exe` can be used at the same time, and a torn
registry loses every workspace at once. Abandoned-mutex exceptions are treated
as acquisition, which is correct: the previous holder died, and the data is
about to be rewritten wholesale anyway.

### 3.5 A corrupt registry is set aside, never overwritten

Moved to `registry.json.corrupt-<timestamp>`, with a warning, and myco carries
on with an empty registry.

**Why.** Overwriting destroys the only record of the user's workspaces.
Renaming keeps recovery possible.

### 3.6 `forget` and `prune` never touch disk

They edit the registry only. The `.copilot` folder is left exactly where it is.

**Why.** Deleting a folder full of session history is not something a
registry-maintenance command should ever do implicitly.

---

## 4. Discovery and adoption

### 4.1 No background scanning

myco registers a folder only when you actually run a command in it. There is no
crawl of the disk and no configured roots.

**Why.** Chosen deliberately by the project owner: "no need to active scan, only
when use myco commands".

### 4.2 An existing `.copilot` is adopted, never rebuilt

It is recorded with origin `adopted` and left untouched.

**Why.** It may hold real session history that predates myco.

### 4.3 The home folder is allowed; a drive root is not

`myco start` works anywhere except the root of a drive.

**History.** v1.0.0 refused the home folder, on the grounds that `~\.copilot` is
Copilot's global home. That was over-protective: pointing `COPILOT_HOME` there
merely reproduces Copilot's normal behaviour, and the owner wanted every folder
they run myco in to be registered. Relaxed in v1.0.1.

**Still refused.** A drive root, because a workspace there is almost always a
mistake.

**Consequence.** Seeding must skip a source that is also the destination,
otherwise the home case tries to copy `.copilot` into itself.

**Note.** `myco status` flags when you are standing in the global Copilot home,
and when a folder cannot be a workspace it gives the reason instead of
suggesting a command that would refuse.

---

## 5. Seeding

### 5.1 New workspaces are seeded from the global Copilot home; default `full`

| Mode | Copies |
| --- | --- |
| `none` | nothing |
| `config` | `settings.json`, `mcp-config.json` |
| `full` | the above plus `skills`, `instructions`, `installed-plugins` |

**Why.** An isolated workspace that has lost your model preference, MCP servers
and skills does not feel like your Copilot. `full` is the default because that
is the least surprising result.

**Cost.** Skills can run to several megabytes per project. `myco config seed
config` or `none` opts out.

### 5.2 Only ever on creation, never on adoption, never from itself

An adopted folder keeps its own settings; a folder is never seeded from itself.

---

## 6. Liveness: what "active" means

### 6.1 The bug

Until v1.1.0, "active" meant "an `inuse.<pid>.lock` file exists".

**Measured on a real machine.** 258 such locks, most from sessions that ended
weeks earlier, so nearly every session reported as active. Of the nine lock pids
that were live processes, only five were Copilot: the rest were `chrome`,
`msedge` and `OpenConsole` holding recycled ids.

### 6.2 The rule

A lock proves a session is running only when the process still exists **and**
started no later than the lock was written, with two minutes of tolerance for
clock granularity.

**Why it is sound.** The process that wrote the lock had to exist at the moment
it was written. Any process holding that id which started *after* the lock was
written therefore cannot be the author — it received the id after the original
died. An unreadable start time is treated as not-active, since a process this
session cannot inspect is not its own Copilot run.

### 6.3 Resolved late, from one snapshot

Process ids are collected once per listing, and liveness is evaluated only for
the sessions actually displayed.

**Why.** A workspace can hold hundreds of sessions but shows fifteen.

**Measured.** 716 sessions render in roughly 460 ms.

---

## 7. Presentation

### 7.1 A framed table per workspace

Columns `ID`, `STATUS`, `WHEN`, `SESSION`, a summary line with workspace and
running counts, and relative times.

**Why.** The previous indented list was hard to scan once a workspace had
fifteen sessions.

### 7.2 Width from `$Host.UI.RawUI`, never `[Console]::WindowWidth`

**Measured.** `[Console]::WindowWidth` throws `The handle is invalid` whenever
output is redirected — exactly what happens when a user pipes or captures
`myco sessions`. `RawUI` still reports a width there. Both are guarded, and the
result is clamped to 60–160.

### 7.3 Glyphs degrade per character, not all at once

Each glyph is used when the console encoding can round-trip it, otherwise an
ascii substitute is used.

**Measured, and it overturned an assumption.** The first design was
all-or-nothing, on the belief that code page 437 could not draw boxes. It can:
437 carries the full box-drawing set and is missing only the filled circle,
the ellipsis and the arrow. All-or-nothing would have thrown away borders that
work perfectly well.

**Invariant.** Never emit a character the console cannot represent. The test
decodes output using the very code page the console used, so a mangled
character shows up as a replacement character and fails.

### 7.4 The name column absorbs the remaining width

Fixed widths for the first three columns; the name column takes what is left
and truncates with an ellipsis.

**Why.** Wrapping destroys the alignment that makes a table scannable.

---

## 8. Testing

### 8.1 End to end through real shells

The suite runs the real entry points in real `powershell.exe`, `pwsh.exe` and
`cmd.exe` sessions and asserts on what those shells end up with — including
their final working directory.

**Why.** Every serious bug in this project lived in the seams between shells:
argument passing, quoting, directory persistence, encoding. Unit tests around
the core would have missed all of them.

### 8.2 Copilot is replaced by a recording stub

Installed as both `copilot.cmd` and `copilot.ps1`, mirroring npm, and recording
working directory, `COPILOT_HOME`, and each argument separately.

**Why both.** See 2.6 — the missing `.ps1` stub is precisely why a real bug
escaped.

### 8.3 Sandboxed environment

Each test redirects `MYCO_HOME`, `USERPROFILE` and `TEMP` into a disposable
folder.

**Why `USERPROFILE`.** So "global Copilot home" behaviour can be exercised
without touching the real one. **Why `TEMP`.** So plan-file cleanup can be
asserted without seeing other runs' litter.

### 8.4 Liveness is tested against real processes

Tests spawn actual processes, then assert running, exited and recycled-id cases,
the last by backdating the lock.

**Why.** The rule is about operating-system behaviour. Mocking it would test
the mock.

### 8.5 `$ErrorActionPreference` is `Continue` inside the runner

**Why.** myco reports problems on stderr. Under `Stop`, PowerShell rethrows
native stderr as an exception, so error-path tests failed on the very output
they were asserting.

### 8.6 cmd output is captured as raw bytes

The batch driver redirects to a file itself, and the harness decodes with the
code page under test.

**Why.** Piping through PowerShell re-encodes, which hides exactly the mojibake
the encoding tests exist to catch.

### 8.7 A test guards repository hygiene

It scans `git ls-files` for machine-specific absolute paths.

**Why.** This repository is public and was developed on a personal machine.

---

## 9. Housekeeping

### 9.1 Abandoned plan files are swept

`myco-plan-*.cmd` fragments older than a day are removed from `TEMP` at startup;
fresher ones are left alone in case another myco is mid-flight.

**Why.** A `cmd.exe` run interrupted while the plan is executing never reaches
its own cleanup.

### 9.2 User-scope install, no administrator rights

Copies to `%APPDATA%\.myco\app`, appends to the **user** `PATH`, and rewrites a
single marked line in the PowerShell profiles.

**Why idempotent.** Re-running the installer must not accumulate profile lines.

### 9.3 PowerShell 5.1 compatibility is kept

No `if` used as an inline expression inside a larger expression, and no
PS7-only operators.

**Why.** `powershell.exe` is present on every Windows machine; `pwsh` is not.
Both are tested on every run.
