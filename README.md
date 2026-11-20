# Scriptorium

A work queue for Claude Code. You write tickets as GitHub issues. Workers (headless Claude Code runs on your PC) each
build one ticket in their own copy of the repo and open a pull request. A merger merges them. One web page shows what
runs, what waits, what it costs and what only you can decide.

It works on any git repo on GitHub. Plugins add an environment, for example
[Scriptorium for Unity](https://github.com/KadaXuanwu/Scriptorium-Unity): one Unity editor for each worker.

## How it works

1. **You file a ticket:** a GitHub issue with a priority (`P0`, `P1`, `P2`). Your own Claude Code session can write
   it for you ("ticket: ...").
2. **A free worker takes it,** unless another ticket in work changes the same files or its account is near its limit.
3. **The run builds it** in the worker's copy, runs the project's checks and pushes at each checkpoint.
4. **It ends in a pull request or a question for you.** A run that hits a usage limit pauses and resumes later.
5. **The merger merges the pull request,** which closes the ticket and files any follow-ups.

## What you get

- 🧑‍🏭 **Parallel workers**, each in its own clone, never two on the same files.
- ❓ **Questions, not guesses.** A run asks you only product decisions, with screenshots for visual ones, and builds a
  default for the rest. You answer on the page with one click.
- 📊 **One page** for workers, questions, queue, accounts and history. Installs on your phone through Tailscale; the
  server is never open to the internet.
- 🔔 **Push notifications** through ntfy for questions, stuck runs, limits and merges.
- 💳 **Runs on your Claude plan, never an API key.** Set where each account stops; a run at a limit is held, not
  lost.
- 🧠 **The right model per ticket.** A ticket's complexity picks the model and effort, with an optional advisor and
  fallbacks.
- 🛑 **No loops.** A run that fails is parked for you to retry.
- 🔌 **Plugins** for engines and tools, and several projects on one PC in one page.

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

Scripts run as hidden Windows tasks that start at logon:

- **A worker script per worker** picks the next ticket, prepares the environment, watches usage, passes your comments
  to the run, and holds or resumes runs at limits.
- **The merger** merges pull requests, sends conflicts back for a rebase, and files follow-ups and open questions.
- **The page server** reads GitHub and the workers, sends notifications and does what you click.

Workers pick up new Scriptorium or plugin code between jobs, never mid-run. A run cannot change the code that runs it.

## What it needs

- Windows 10 or 11 (Windows PowerShell 5.1 is built in).
- [git](https://git-scm.com) and the [GitHub CLI](https://cli.github.com), signed in with write access to the repo.
- [Claude Code](https://claude.com/claude-code), signed in with a Claude Pro or Max plan.
- Optional: [Tailscale](https://tailscale.com) for the page on your phone, and [ntfy](https://ntfy.sh) for
  notifications.

## Quick start

```powershell
git clone https://github.com/KadaXuanwu/Scriptorium D:\Work\Scriptorium
```

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File D:\Work\Scriptorium\setup.ps1 -Project D:\Work\MyApp -Commit -Start
```

Setup adds `scriptorium.json`, the ticket skill, the GitHub labels, one worker and the logon tasks, then prints the
page address and the ntfy topic. Add `-WhatIf` to preview. It is safe to run again.

Or paste [PROMPT.md](PROMPT.md) into Claude Code in your project.

Then open the page, add workers and accounts, and file your first ticket.

## Limits

- Windows only.
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
