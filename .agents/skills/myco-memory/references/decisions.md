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

## 9. Recovering a working set

### 9.1 `myco recover` reopens recent sessions as Windows Terminal tabs

One tab per session, each with the workspace as its working directory and the
session name as its title.

**Why.** Losing a terminal loses the whole working set, and reopening six
projects by hand is tedious enough that people do not bother.

**Measured.** The real `wt` accepts the exact argument vector myco builds:
`-w new`, then `new-tab --title <name> -d <dir> <shell> -NoExit -Command <cmd>`
segments chained with a literal `;` argument. Verified by launching real tabs
and checking each landed in the right directory.

### 9.2 The window is the last two hours, on `updated_at`

Overridden with `--hours=<n>`, accepted in both `--hours=6` and `--hours 6`
form, rejected with a clear message when it is not a positive number.

### 9.3 A running session is never reopened, and the skip is reported

**Why.** It did not need recovering, and a second Copilot process on one
session would contend for the same state and lock file. Skipping also makes the
command idempotent: running it twice does not double-open anything.

**Consequence.** After a crash every process is gone, so everything recent is
recovered — which is the case the command exists for.

**Corrected in 1.2.1.** The first release skipped silently and offered `--all`
to reopen running sessions anyway. On a real machine with eight chats open,
`recover --dry-run` listed two with no explanation, and the output looked like
a bug rather than a decision. The count of sessions left alone is now always
reported, and `--all` was removed: reopening a live session is precisely what
recover must not do, so it should not sit one flag away. The option now fails
with a message explaining why, rather than being silently ignored.

### 9.4 Tabs resume a concrete session id, never a list position

**Why.** `001002` means "second in the current list" (see 3.3). Between
building the list and the tab starting, that position could mean a different
conversation. The uuid cannot drift.

### 9.5 A tab dot-sources the launcher rather than trusting the profile

Each tab runs `. '<install>\bin\myco.ps1'; myco resume <uuid>`, using `pwsh`
when present and `-NoExit` so a failure stays on screen instead of the tab
vanishing.

**Why.** It works whether or not the user's profile integration is in place,
and it reuses the tested resume path — which also sets `COPILOT_HOME` and
records workspace usage — rather than reimplementing a launch.

**Consequence.** The core has to know where its own `bin\myco.ps1` is, so
`lib/myco-core.ps1` captures `$PSScriptRoot` at load time. That is correct for
a dot-sourced file: it reports the dot-sourced file's own directory, verified
from both entry points.

### 9.6 A new window by default, `--here` to use the current one

**Why.** Recovery produces a clean set of tabs instead of burying them among
whatever is already open.

### 9.7 A cap, and a dry run

Default 12 tabs. Above it, myco lists the set, refuses, and names the exact
`--max` value that would allow it. `--dry-run` lists and opens nothing.

**Why.** Opening thirty terminal tabs by surprise is hostile, and an
interactive confirmation would not work the same way across both shells.

### 9.8 Missing Windows Terminal is explained, not crashed

`wt` is only required by this one command, so the check happens when tabs are
about to open, and the message offers `--dry-run` and `myco resume` instead.

### 9.9 Testing it without opening windows

A `wt.cmd` stub earlier on `PATH` shadows the real `wt.exe`, because PATH
directory order is searched before PATHEXT extension order.

**Measured**, before the suite was allowed to depend on it — getting this wrong
would have opened real terminal windows on every test run.

Absence cannot be shadowed, so the "Windows Terminal is missing" case runs on a
reduced `PATH`. That in turn means driver shells are resolved to full paths
before the harness narrows `PATH`, or the harness cannot start `pwsh` itself.

---

## 10. Session names

### 10.1 YAML quoting is decoded

Copilot writes the name in YAML single-quoted style, where an apostrophe is
escaped by doubling it. myco strips the surrounding quotes and undoubles the
apostrophes; double-quoted values get their backslash escapes undone.

**Why it was missed.** The test fixture wrote names unquoted, so it was tidier
than reality. A real session displayed as `what does ''active'' require`.
`New-FakeSession` now quotes and escapes exactly as Copilot does.

**Lesson, again.** A fixture that is cleaner than the real artefact hides real
bugs — the same way the missing `copilot.ps1` stub did in 2.6.

### 10.2 myco trusts each workspace folder in its own `.copilot`

Copilot asks *Confirm folder trust* the first time a session runs in a folder,
and records the answer in `trustedFolders` inside that `COPILOT_HOME`'s
`config.json`. Since every myco workspace has its own `COPILOT_HOME`, every
workspace starts untrusted. That is one prompt per project for `start`, but
`recover` opens many tabs at once and each would stop on its own prompt instead
of resuming.

**Why it is not an escalation.** Running myco in a folder is itself the
deliberate act of choosing it, and sessions are launched with `--yolo` already.
Only the workspace's own folder is trusted, only in that workspace's config,
and never in the global Copilot home.

**The file belongs to Copilot, so it is edited surgically.** It is JSON with a
`//` comment header that `ConvertFrom-Json` cannot parse, and PowerShell 7
turns ISO date strings into `DateTime` objects, so a parse-and-rewrite would
silently rewrite values such as `firstLaunchAt`. Only the `trustedFolders`
array is touched; everything else survives byte for byte, asserted against the
bytes on disk rather than a parsed object.

**Failure is never fatal.** If the edit cannot be made, myco warns and carries
on; the only cost is the prompt coming back.

### 10.3 Atomic replace needs a real backup path

`File::Replace(source, destination, $null)` throws *The path is empty* on
PowerShell 7. The registry writer had been catching that and falling back to a
plain copy, so writes were quietly not atomic. Both writers now share
`Move-MycoFileAtomic`, which passes a real backup path and deletes it
afterwards.

**Found by accident** while adding trusted folders, because that code path had
no silent fallback to hide it.

---

## 11. Semicolons and Windows Terminal

### 11.1 No argument passed to `wt` may contain a semicolon

**Measured, after a real failure.** Windows Terminal splits its whole command
line on `;` wherever it appears, regardless of argv boundaries. The first
implementation passed an inline payload:

```
pwsh -NoExit -Command ". '<install>\bin\myco.ps1'; myco resume <uuid>"
```

wt ended the first tab's command at that semicolon and started a second tab
whose executable was the remaining text, producing two tabs per session: a
shell that never resumed, and

```
[error 2147942402 (0x80070002) when launching `" myco resume <uuid>"']
```

**The fix.** Tabs now run `-File <launcher> resume <uuid>`, which needs no
statement separator. `bin\myco.ps1` already ends by running the arguments it
was given, so the same file both defines the function and performs the resume.

**The same trap applies to titles.** A session named `Fix this; then that`
would split identically, so titles have semicolons replaced. Nothing else needs
escaping: `&`, `|`, `"` and `%` all survive, because arguments are passed as
argv rather than through a shell. All four were measured.

### 11.2 Why the suite did not catch it

The stub records arguments and does not parse them, so it cannot see a split
that happens inside wt. Worse, the earlier live check **substituted a
semicolon-free payload** for the real one; it verified the shape of the
argument vector and not its content, which is exactly where the bug was.

**Lesson, for the third time in this project.** A double that is tidier than
the real thing — a `.cmd`-only stub for a `.ps1` shim, an unquoted fixture for
a YAML-quoted name, a simplified payload for the real command — hides the class
of bug it was meant to catch. The suite now asserts the invariant directly: no
argument other than the separator may contain a semicolon.

---

## 12. Live verification

### 12.1 `test/Verify-Live.ps1` exercises the real tools, and reverts

The stubbed suite cannot see how the real Copilot CLI and the real Windows
Terminal parse what myco hands them, and two bugs escaped through that gap. The
live script creates one real session, runs `myco recover` verbatim, and proves
the recovered tab actually resumed by waiting for a Copilot process to attach
and write its lock file.

**Nothing about the launch is substituted**, because substituting the payload
is what hid the semicolon bug.

### 12.2 It is isolated in three dimensions

| Dimension | How |
| --- | --- |
| State | `MYCO_HOME` and the workspace live under `%TEMP%`, so the real registry is never read or written. |
| Windows | Terminal window handles are captured before and after; only genuinely new windows are closed. |
| Processes | Copilot process ids are captured before and after; only new ones are stopped. |

**Why handles rather than processes.** Windows Terminal hosts every window in a
single process, so killing that process would close the user's own sessions.
Windows are enumerated individually and closed with `WM_CLOSE`, once per tab.

**Why it is not part of the suite.** It costs AI credits and opens a real
window. It is run deliberately, before a release or after touching anything the
stubs cannot model.

---

## 13. Housekeeping

### 13.1 Abandoned plan files are swept

`myco-plan-*.cmd` fragments older than a day are removed from `TEMP` at startup;
fresher ones are left alone in case another myco is mid-flight.

**Why.** A `cmd.exe` run interrupted while the plan is executing never reaches
its own cleanup.

### 13.2 User-scope install, no administrator rights

Copies to `%APPDATA%\.myco\app`, appends to the **user** `PATH`, and rewrites a
single marked line in the PowerShell profiles.

**Why idempotent.** Re-running the installer must not accumulate profile lines.

### 13.3 PowerShell 5.1 compatibility is kept

No `if` used as an inline expression inside a larger expression, and no
PS7-only operators.

**Why.** `powershell.exe` is present on every Windows machine; `pwsh` is not.
Both are tested on every run.
