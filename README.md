# Scriptorium

A work queue for Claude Code. You write tickets as GitHub issues. Workers (headless Claude Code runs on your PC) each
build one ticket in their own copy of the repo and open a pull request. A merger merges them. One web page shows what
runs, what waits, what it costs and what only you can decide.

It works on any git repo on GitHub. Plugins add an environment, for example
[Scriptorium for Unity](https://github.com/KadaXuanwu/Scriptorium-Unity): one Unity editor for each worker.

## How it works

1. **You file a ticket:** a GitHub issue with a priority (`P0`, `P1`, `P2`). The front desk skill writes it from
   what you describe ("ticket: ...").
2. **A free worker takes it,** unless another ticket in work changes the same files or its account is near its limit.
3. **The run builds it** in the worker's copy, runs the project's checks and pushes at each checkpoint.
4. **It ends in a pull request or a question for you.** A run that hits a usage limit pauses and resumes later.
5. **The merger merges the pull request,** which closes the ticket and files any follow-ups.

## What you get

### Tickets

- **The front desk.** Setup adds a `ticket` skill to your project. Your own Claude Code session uses it to turn what
  you describe into a complete ticket (priority, areas, size, complexity, blockers), report the queue, and pass your
  answers and corrections on.
- **A clear order.** Priority first, then the larger ticket, then the older one. A ticket without a priority is parked.
- **Blockers.** A line `Blocked by #3` holds a ticket until #3 closes.
- **Now and Force.** Give one ticket to one worker right away, or start a worker's next ticket past the limits.
- **Other repos.** A `repo:<Name>` label builds the ticket in another repo of yours.
- **Follow-ups.** Work a run finds outside its ticket comes back as a new ticket.

### Workers and merging

- **Parallel workers,** each in its own clone, one ticket at a time.
- **No two workers on the same files.** `area:*` labels keep tickets that touch the same code apart.
- **Checkpoints.** A run pushes its work and notes what is done and what is next, so a stop loses little.
- **A merger** squash-merges each worker pull request and sends conflicting ones back to their worker for a rebase.
- **Bot accounts.** A worker can post as its own GitHub bot, so GitHub notifies you of its comments and pull requests.
- **No loops.** A run that ends without a pull request or a question is parked with its reason until you press Retry.

### Questions, not guesses

- **Only product decisions.** A run asks about rules, looks and what a user sees, never about the workflow, and builds
  a sensible default for the rest.
- **Blocking or open.** A blocking question holds its work until you answer. An open one merges on its default, which
  you keep or change later.
- **Pictures.** A question about a look carries a screenshot of each choice; a new look comes as several candidates.
- **One click to answer.** Accept the default or send an answer from the page. It goes to GitHub as a comment.
- **Your comments count.** Comment on a ticket or its pull request and the run reads it at its next checkpoint,
  marks it 👀 and replies.

### The page

- **One web page** with Workers, Questions, Queue, Accounts, History and Details tabs.
- **Control each worker:** active, paused or disabled, and whether its run stops now, at the next checkpoint or after
  the ticket. Add, remove and rename workers, and move them between projects.
- **See what is left:** why each ticket waits, the typical hours and cost of the queue, stuck runs and parked tickets.
- **On your phone** as an installed app through Tailscale. The server listens on localhost only, and the page shows its
  last state when the PC is off.
- **Push notifications** through ntfy: blocking questions, stuck runs, limits, accounts that are out, scripts that are
  down, an empty queue, merges.

### Budget and models

- **Your Claude plan, never an API key.** Workers can share one account or each have their own; the page adds and
  signs in accounts.
- **Stop lines and pick-up limits.** Choose where each account's workers stop in each usage window, and how late a
  large ticket may start.
- **Usage guards.** Keep a share of each week for the front desk and your own use.
- **Spend room before it resets.** A ticket goes to the account with the most weekly room left per hour before its
  reset.
- **Nothing lost at a limit.** A run at a limit or an account that signs out is held and resumes in the same session.
- **Complexity picks the model.** Each complexity has its own model and effort, an optional advisor and fallback models.
  Add your own complexities per project.

### Plugins and projects

- **Plugins** add an environment (an engine, a build tool): they prepare it, give runs MCP servers, tools and rules,
  and add a playbook of their own.
- **Several projects on one PC,** shown together on one page, sharing the PC's accounts and workers.
- **Your own rules.** A project playbook tells every run how your project works.

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

Scripts run as hidden Windows tasks that start at logon and need nothing from you.

**A worker script for each worker:**

- Has the plugins open the environment before a run and leave it clean after.
- Picks the next job under a lock all workers share, so no ticket is taken twice: answers and rebases of its own pull
  requests first, then new tickets.
- Gives the run copies of the playbooks and only the tools, skills and MCP servers it needs.
- Reads the plan's usage from the run's log and shares it with the other workers.
- Tells the run to stop at its next checkpoint when the account reaches its stop line, and takes that back if room
  returns.
- Compacts a held run while its cache is warm, then resumes the same session when the account has room or you set the
  worker active.
- Switches a run to a fallback model when the plan refuses one, and resumes on another model at the Fable limit.
- Passes your comments on the ticket or pull request to the run.
- Checks that each run ended in a pull request, a question or a pause, and parks anything else.
- Detects an account that is signed out or refused, stops only its workers, returns their unstarted tickets to the
  queue, and tests the account until it answers again.
- Hands the tickets of a disabled or removed worker back to the queue.
- Records each run's log, model, time, cost and token numbers in the history.

**The merger:**

- Squash-merges worker pull requests that GitHub can merge, oldest first, which closes their tickets.
- Sends a pull request that conflicts with main, or has a comment of yours its run did not read, back to its worker.
- Files the follow-ups and open questions of a merged pull request as new tickets.

**The page server:**

- Reads GitHub and the workers' files, and serves the page to the PC and your Tailscale devices.
- Turns your clicks into labels, comments and worker controls.
- Sends the push notifications.
- Checks the accounts' usage when no run has read it lately.

**Also:**

- Every script restarts itself between jobs when Scriptorium, a plugin or `scriptorium.json` changes, never mid-run.
- A run cannot change the code that runs it: it gets no folder of Scriptorium or of a plugin.
- Only the runs use a model, apart from a tiny usage reading and the page's Ping.

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
