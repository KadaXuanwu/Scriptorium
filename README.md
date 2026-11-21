# Scriptorium

A work queue for Claude Code. You write tickets as GitHub issues. Workers (headless Claude Code runs on your PC) each
build one ticket in their own copy of the repo and open a pull request. A merger merges them. One web page shows what
runs, what waits, what it costs and what only you can decide.

It runs on Windows, macOS and Linux and works on any git repo on GitHub. Plugins add an environment, for example
[Scriptorium for Unity](https://github.com/KadaXuanwu/Scriptorium-Unity): one Unity editor for each worker (Windows
only).

## How it works

1. **You file a ticket:** a GitHub issue with a priority (`P0`, `P1`, `P2`). The front desk skill writes it from
   what you describe ("ticket: ...").
2. **A free worker takes it,** unless another ticket in work changes the same files or its account is near its limit.
3. **The run builds it** in the worker's copy, runs the project's checks and pushes at each checkpoint.
4. **It ends in a pull request or a question for you.** A run that hits a usage limit pauses and resumes later.
5. **The merger merges the pull request,** which closes the ticket and files any follow-ups.

## What you get

### Tickets

- **The front desk:** a `ticket` skill in your project that turns what you describe into a complete ticket, reports the
  queue and passes your answers on.
- **Blockers, Now and Force:** hold a ticket until another closes, give a ticket to a worker right away, or start one
  past the limits.
- **Other repos:** a `repo:<Name>` label builds a ticket in another repo of yours.

### Workers

- **Parallel workers,** each in its own clone, never two on the same files.
- **A merger** that merges pull requests and sends conflicts back for a rebase.
- **Bot accounts,** so GitHub notifies you of a worker's comments and pull requests.

### Questions, not guesses

- A run asks you only product decisions (rules, looks, what a user sees) and builds a default for the rest.
- A blocking question holds the work; an open one merges on its default, which you can change later.
- Every question comes with a screenshot of what it is about; one about a look, with a screenshot of each choice.
- Comment on a ticket or pull request and the run reads it at its next checkpoint. Only comments from the repo's
  owner, its collaborators and members of its organization count, so strangers on a public repo cannot steer a run.

### The page

- Workers, questions, queue, accounts and history on one page, with controls to pause, stop or add workers.
- Installs on your phone through Tailscale; nothing is open to the internet.
- Push notifications through ntfy.

### Budget and models

- **Your Claude plan, never an API key.** One or several accounts, shared by workers or one each.
- **Limits you set:** where each account's workers stop, how late a large ticket may start, and a share kept for your
  own use.
- **Nothing lost at a limit:** a held run resumes in the same session.
- **Complexity picks the model,** with effort, an optional advisor and fallbacks.

### Plugins and projects

- **Plugins** prepare an environment (an engine, a build tool) and give runs its tools and rules.
- **Several projects** on one PC, on one page.
- **A project playbook** tells every run how your project works.

## Built-in token savings

| | What | How |
| - | ---- | --- |
| 🆕 | Fresh session per job | Each job starts clean; Claude Code compacts when the context grows large. No handoffs between runs. |
| 🚫 | Unused tools blocked | Tools a run never needs are not loaded. |
| 🧩 | No unused skills | Claude Code's built-in and account skills are off; the project's and plugins' skills stay. |
| 🔌 | No stray MCP servers | A run only gets the servers its plugins give it. |
| 🎛️ | No accidental advisor | The advisor is set per run, never inherited from a login's settings. |
| ⚡ | Environment ready first | Plugins open the editor or server before the run starts, so no turn waits. |
| 🗜️ | Compact before a hold | A paused run is compacted while its cache is still warm, so the resume is cheap. |
| ⏯️ | Resume, don't restart | A held run continues in the same session with its context and work. |
| ⏰ | Fewer cut-off runs | Large tickets are not started late in a usage window. |
| 🔀 | Fewer rebases | Tickets that change the same files never run at once. |
| 📍 | Start where the last left off | Each checkpoint writes what is done and what is next. |
| ✅ | Answers that need no run | Accepting a default merges or closes without starting a run. |
| 📖 | Short playbook | Rarely needed parts are separate files, read only when needed. |
| ✂️ | Short tool output | Runs read files in parts and keep command output short. |
| 📏 | Cheap usage reading | Usage comes from the run's own log, with a tiny request only when there is none. |
| 🤖 | No model outside runs | Dispatcher, merger, page and notifications are plain scripts. |
| 🔁 | No retry loops | Failing tickets are parked; follow-ups of follow-ups are capped. |
| 🧪 | Trial: no PowerShell tool | Runs use Bash only. |
| 🧪 | Trial: batched tool calls | Independent tool calls go out in one message. |

The model, effort, advisor and compact size of each complexity are yours to set on the page, and a per-run cost cap
in `models.json`. `report.ps1` prints each run's cost and token numbers ([docs/QUEUE.md](docs/QUEUE.md)).

## In the background

Scripts run as hidden logon tasks that start when you log in and need nothing from you: Task Scheduler tasks on
Windows, launchd agents on macOS, systemd user services on Linux.

- **A worker script** for each worker picks the next ticket (never one another worker has), prepares the environment,
  watches the account's usage, passes your comments to the run, and holds or resumes runs at limits. A run that ends
  without a pull request or a question is parked; an account that signs out stops only its own workers.
- **The merger** merges pull requests, sends conflicts back to their worker, and files follow-ups and open questions as
  new tickets.
- **The page server** reads GitHub and the workers, carries out your clicks and sends notifications.

Scripts pick up new Scriptorium or plugin code between jobs, never mid-run, and a run cannot change the code that runs
it.

## What it needs

- Windows 10 or 11 (Windows PowerShell 5.1 is built in), or macOS or Linux with
  [PowerShell 7.4 or later](https://aka.ms/powershell) (`pwsh`). Linux needs systemd.
- [git](https://git-scm.com) and the [GitHub CLI](https://cli.github.com), signed in with write access to the repo.
- [Claude Code](https://claude.com/claude-code), signed in with a Claude Pro or Max plan.
- Optional: [Tailscale](https://tailscale.com) for the page on your phone, and [ntfy](https://ntfy.sh) for
  notifications.

## Quick start

1. Get Scriptorium:

   ```powershell
   git clone https://github.com/KadaXuanwu/Scriptorium D:\Work\Scriptorium
   ```

2. Check that the PC and the project have what it needs. Each missing part comes with how to fix it, and nothing
   changes:

   ```powershell
   powershell -NoProfile -ExecutionPolicy Bypass -File D:\Work\Scriptorium\setup.ps1 -Check -Project D:\Work\MyApp
   ```

   On macOS or Linux:

   ```sh
   pwsh -NoProfile -File ~/Work/Scriptorium/setup.ps1 -Check -Project ~/Work/MyApp
   ```

3. Set it up:

   ```powershell
   powershell -NoProfile -ExecutionPolicy Bypass -File D:\Work\Scriptorium\setup.ps1 -Project D:\Work\MyApp -Commit -Start
   ```

   On macOS or Linux:

   ```sh
   pwsh -NoProfile -File ~/Work/Scriptorium/setup.ps1 -Project ~/Work/MyApp -Commit -Start
   ```

Setup adds `scriptorium.json`, the ticket skill, the GitHub labels, one worker and the logon tasks, then prints the
page address and the ntfy topic. Add `-WhatIf` to preview. It is safe to run again.

Or paste [PROMPT.md](PROMPT.md) into Claude Code in your project.

Then open the page, add workers and accounts, and file your first ticket.

## Uninstall

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File D:\Work\Scriptorium\uninstall.ps1 -Project D:\Work\MyApp
```

On macOS or Linux: `pwsh -NoProfile -File ~/Work/Scriptorium/uninstall.ps1 -Project ~/Work/MyApp`.

It ends the project's page, merger and workers, removes their logon tasks, takes the workers out of the PC's settings,
deletes the worker copies, takes the page off Tailscale and deletes the project's `.queue` folder. A worker copy that
holds work GitHub does not have stays, and uninstall names it: an editor often leaves changed files in a copy, so
expect to delete some copies by hand. Tickets, pull requests, branches and Claude accounts are
never touched.

- `-Repo` also deletes the labels setup made on GitHub (tickets lose their `P0`, `size:S` and other labels),
  `scriptorium.json`, the ticket skill and the `.queue/` line of `.gitignore`. Add `-Commit` to commit and push that.
- `-KeepCopies` leaves the worker copies.
- `-WhatIf` prints each step and changes nothing.

When no project on the PC uses Scriptorium any more, it names what is left to delete by hand: the PC's settings
folder, the login folders of accounts added on the page, and the Scriptorium folder.

## Limits

- macOS and Linux are new. CI runs every test there and registers, starts and removes a logon task, but no queue has
  run a ticket there yet: setup, the page, a run and the sign-in from the page are untested. On macOS the login is
  read from the keychain, which may ask once for access. Tell us what breaks.
- On macOS and Linux, the pictures of a question go up at full size: the small copy needs Windows.
- Claude Code and GitHub only.
- GitHub builds and tests nothing: a run's own checks are the gate.

## Docs

- [docs/QUEUE.md](docs/QUEUE.md): labels, dispatching, budget, models, settings.
- [docs/APP.md](docs/APP.md): the page.
- [docs/CONFIG.md](docs/CONFIG.md): `scriptorium.json`.
- [docs/PLUGINS.md](docs/PLUGINS.md): writing a plugin.
- [PLAYBOOK.md](PLAYBOOK.md): what a run does.
- [CONTRIBUTING.md](CONTRIBUTING.md): sending a change.

## Licence

MIT. See [LICENSE](LICENSE).
