# Contributing

Thank you for the help. Read this before you open a pull request.

## A pull request to the base

1. One topic for each pull request.
2. The base stays free of environments. It knows git, GitHub and Claude Code, nothing else: no engine, no build tool,
   no test runner. What an environment needs goes into a plugin ([docs/PLUGINS.md](../docs/PLUGINS.md)).
3. Every change to a queue rule has a test (`tests/*.test.ps1`) and the change to its doc in the same pull request:
   [docs/QUEUE.md](../docs/QUEUE.md), [docs/APP.md](../docs/APP.md), [PLAYBOOK.md](../PLAYBOOK.md) or the info text on the
   page's Details tab.
4. The code runs in Windows PowerShell 5.1 on Windows and in PowerShell 7 on macOS and Linux:
   - 5.1 syntax only: no `&&`, `||`, `?:` or `??`. Keep a new `.ps1` file in ASCII.
   - What differs between the systems goes in [platform.ps1](../platform.ps1) or the logon tasks of
     [tasks.ps1](../tasks.ps1), behind `$OnWindows` and `$OnMac`.
   - A path in `Join-Path` takes `/`: Windows reads it as `\`.
5. No new dependency. The page stays plain HTML, CSS and JS, with no build step.
6. A change to the plugin contract (a hook or a context field that goes away or changes its meaning) needs an issue
   first. It makes contract version 2.
7. Docs and comments: short sentences, active voice, one word for one meaning, steps as numbered lists.
8. Run the checks before you push:

   ```powershell
   powershell -NoProfile -ExecutionPolicy Bypass -File check.ps1
   ```

   It parses every `.ps1` and runs every `*.test.ps1`. On macOS or Linux, `pwsh -NoProfile -File check.ps1`. Each
   pull request runs it on Windows (in both PowerShells), Ubuntu and macOS.

## A pull request that lists a plugin

A pull request that adds a plugin to [plugins.json](../plugins.json) adds one entry and nothing else. The reviewer checks:

1. The plugin's repo is public.
2. It has a licence.
3. Its README says what the plugin needs on the PC and what each hook does to it.
4. `plugin.json` sets `api` to the contract version it was written for.
5. `plugin.ps1` only defines functions when it loads: it starts nothing and changes nothing.
6. `detect`, if the entry has it, matches only files of that environment.

A listed plugin stays its author's: its issues and pull requests go to its own repo.
