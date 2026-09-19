# myco

Per-project workspaces for the GitHub Copilot CLI, on Windows.

By default every Copilot CLI session — in every project you touch — piles into
one global directory. `myco` gives each project folder its own `.copilot`
directory, keeps a numbered registry of those folders, and lets you jump back
into any recent session with a short id.

```text
myco workspaces (2)

[001] checkout-service   (created)
      D:\work\checkout-service
      001001 *  2026-09-19 14:02  Fix the redirect loop after login
      001002    2026-09-18 09:11  Split the billing module
      001003    2026-09-17 16:40  Add contract tests

[002] design-system   (adopted)
      D:\work\design-system
      002001    2026-09-15 11:20  Token naming pass

* = session currently in use.  Resume with: myco resume <id>
```

```console
> myco resume 001002
```

…moves your shell into `D:\work\checkout-service` and reopens that exact
session.

## How it works

The Copilot CLI reads `COPILOT_HOME` to decide where its configuration and
session state live. `myco` sets it to `<project>\.copilot` for the duration of
a session and restores it afterwards, so nothing leaks into your shell.

Your Copilot login is **not** stored in `COPILOT_HOME`, so project workspaces
do not require you to sign in again.

## Install

Requires Windows, PowerShell 5.1 or 7, and the
[Copilot CLI](https://github.com/github/copilot-cli) on `PATH`.

```console
git clone https://github.com/MenachemBarak/myco.git
cd myco
powershell -ExecutionPolicy Bypass -File install\install.ps1
```

From `cmd.exe`:

```console
install\install.cmd
```

The installer copies myco into `%APPDATA%\.myco\app`, adds the launcher to your
**user** `PATH` so `cmd.exe` finds it, and adds a single dot-source line to your
PowerShell profiles. It needs no administrator rights and writes nothing outside
your user profile. Open a new terminal afterwards.

To remove it:

```console
powershell -ExecutionPolicy Bypass -File install\uninstall.ps1
```

Add `-Purge` to delete the registry as well. Your project `.copilot` folders are
never touched.

## Commands

| Command | What it does |
| --- | --- |
| `myco start [copilot args]` | Creates `.\.copilot` if missing, registers the folder, runs `copilot --yolo`. |
| `myco continue [copilot args]` | Same, but runs `copilot --yolo --continue`. |
| `myco sessions` | Lists every registered folder with its id and last 15 sessions. Aliases: `ls`, `list`. |
| `myco resume <id>` | Moves your shell into the folder and resumes. |
| `myco status` | Describes the current folder. |
| `myco config [key] [value]` | Shows or changes `seed` and `maxSessions`. |
| `myco forget <id>` | Removes a folder from the registry. The folder itself is left alone. |
| `myco prune` | Removes registry entries whose folders no longer exist. |
| `myco version`, `myco help` | The obvious. |

Anything you add after the subcommand is passed straight through to Copilot:

```console
myco start --model gpt-5.4
myco continue --add-dir ..\shared
```

## Ids

Folders get a three-digit id in the order you first use them: `001`, `002`, …
Sessions are numbered inside their folder, most recently updated first, so
`001002` is the second-newest session of folder `001`.

| Form | Meaning |
| --- | --- |
| `myco resume 001` | The folder's most recent session (`--continue`). |
| `myco resume 001002` | That folder's second-newest listed session. |
| `myco resume 001.002` | Same thing; `.`, `-` and `_` separators are accepted. |
| `myco resume <uuid or name>` | Anything that is not a myco id is handed to `copilot --resume` for the current folder. |

Session numbers are positions in the list, so they shift as new sessions appear.
Run `myco sessions` first, then resume. Folder ids never change and are never
reused, so `myco forget 001` does not renumber `002`.

## Discovery

`myco` only registers folders you actually use it in. Running `myco start` or
`myco continue` in a folder that already has a `.copilot` directory adopts it —
the existing directory is listed as `adopted` and is never modified or seeded.
There is no background scanning of your disk.

## Configuration

State lives in `%APPDATA%\.myco` (`registry.json` and `config.json`). Set
`MYCO_HOME` to move it.

| Setting | Default | Meaning |
| --- | --- | --- |
| `seed` | `full` | What to copy into a **newly created** `.copilot`. |
| `maxSessions` | `15` | How many sessions to list and address per folder. |

Seeding keeps a project session feeling like your normal Copilot:

| Value | Copies from your global Copilot home |
| --- | --- |
| `none` | nothing |
| `config` | `settings.json`, `mcp-config.json` |
| `full` | the above plus `skills`, `instructions`, `installed-plugins` |

```console
myco config seed config
myco config maxSessions 10
```

Seeding happens once, when myco creates the folder. Adopted folders are never
seeded.

## Safety

- Your home folder works like any other folder. Because `~\.copilot` is
  Copilot's default home, registering it simply reproduces normal Copilot
  behaviour; `myco status` points out when you are standing in it.
- Refuses to create a workspace at a drive root.
- A folder is never seeded from itself.
- `COPILOT_HOME` is restored after every session, in both shells.
- The registry is written atomically under a named mutex, so PowerShell and
  `cmd.exe` can be used at the same time.
- A registry that cannot be parsed is set aside rather than overwritten.
- `forget` and `prune` change the registry only; they never delete a `.copilot`.

## Why a shell function

`myco resume` has to leave your shell in the workspace folder, and a child
process cannot change its parent's working directory. So the PowerShell entry
point is a dot-sourced function, and the `cmd.exe` entry point is a batch file
that runs its plan with `call` inside your own session. That is the only reason
the installer touches your profile.

If you run `myco.cmd` from PowerShell without installing the profile function,
everything still works except that your shell stays where it was.

## Development

```console
powershell -ExecutionPolicy Bypass -File test\Run-Tests.ps1
powershell -ExecutionPolicy Bypass -File test\Run-Tests.ps1 -PsExe pwsh.exe
```

The suite drives the real entry points through real `powershell.exe`,
`pwsh.exe` and `cmd.exe` sessions, with a recording stub standing in for the
Copilot CLI. Each test runs in a disposable sandbox with `MYCO_HOME` and
`USERPROFILE` redirected, so it never touches your real registry or your real
Copilot home.

## Licence

MIT. See [LICENSE](LICENSE).
