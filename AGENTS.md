# AGENTS.md — maintaining myco

myco is a Windows CLI that gives each project folder its own GitHub Copilot CLI
workspace, by pointing `COPILOT_HOME` at `<project>\.copilot`. PowerShell and
`cmd.exe` entry points over one shared core. No dependencies, no build step.

## The project memory

The full handoff lives in one skill, `.agents/skills/myco-memory/`:

| File | What it holds |
| --- | --- |
| `SKILL.md` | Architecture, repository map, invariants, the working agreement. Start here. |
| `references/decisions.md` | Every design decision, its rationale, and what breaks if reversed. |
| `references/shell-traps.md` | The Windows dual-shell traps behind those decisions. |
| `references/maintenance.md` | The test, verification and release loop. |

Agentic tools that support skills load this automatically; `copilot skill list`
should show `myco-memory`. **If your tool does not, read `SKILL.md` directly
before changing anything.**

## Before you change anything

The essentials, so that even a tool which never loads the skill does no harm.

- **Test first.** Write the failing test, run it, and **commit it alone** —
  tests and fixtures only. Then fix, and commit with the passing counts. Put the
  real numbers in the commit message. Never `git stash` in this repository.
- **Both shells must pass**, every time:

  ```powershell
  powershell -NoProfile -ExecutionPolicy Bypass -File test\Run-Tests.ps1
  pwsh       -NoProfile -ExecutionPolicy Bypass -File test\Run-Tests.ps1 -PsExe pwsh.exe
  ```

- **The stub is not the CLI.** For argument handling, launching or session
  state, verify against the real Copilot CLI before claiming success.
- **`COPILOT_HOME` is always restored**, in both shells, including on failure.
- **Splat arguments from a variable.** `@(...)` is the array subexpression
  operator, not splatting, and collapses the whole list into one argument.
- **`forget` and `prune` never delete a `.copilot` folder**, and workspace ids
  are never renumbered or reused.
- **Active means a process genuinely exists** and started no later than its lock
  file was written. Lock files outlive crashes and process ids get recycled.
- **PowerShell 5.1 must keep working**, and no machine-specific absolute paths
  may enter tracked files. A test enforces the latter over `git ls-files`.

## Care with the user's machine

This tool manipulates real Copilot state. Register throwaway folders under
`%TEMP%` and `myco forget` them afterwards, never delete a `.copilot` folder you
did not create, and check `myco sessions` before and after so you can show the
registry is as you found it.
