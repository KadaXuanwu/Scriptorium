# Scriptorium

A work queue for Claude Code. You write tickets as GitHub issues. Workers, headless Claude Code runs on your PC, each
build one ticket in their own copy of the repo and open a pull request. A merger merges the pull requests. One web page
shows you what runs, what waits, what it costs and what only you can decide.

It works on any git repo on GitHub. A plugin teaches it an environment, for example
[Scriptorium for Unity](https://github.com/KadaXuanwu/Scriptorium-Unity): one Unity editor for each worker.

**On this page:** [How a ticket goes through](#how-a-ticket-goes-through) ·
[What you get](#what-you-get) · [What you can set](#what-you-can-set) ·
[Built-in token savings](#built-in-token-savings) · [In the background](#in-the-background) ·
[What it needs](#what-it-needs) · [Quick start](#quick-start) · [Limits](#limits) · [Docs](#docs)

## How a ticket goes through

1. You file a ticket: a GitHub issue with a priority (`P0`, `P1`, `P2`), its areas, a size and a complexity. The
   front desk, a skill for your own Claude Code session, writes it from what you describe.
2. A free worker takes the first ticket that its account has room for and whose files no ticket in work changes.
3. The run builds the ticket in the worker's copy of the repo and runs the project's checks. At each checkpoint it
   pushes its work, so a stop loses little.
4. The run ends in a pull request, in a question for you, or held at a usage limit. A held run goes on later, in the
   same session.
5. The merger squash-merges the pull request, which closes the ticket. A merged pull request can add follow-ups and
   open questions.

## What you get

### Tickets and workers

- **A copy for each worker.** Each worker has its own clone beside your checkout and builds one ticket at a time.
- **A fixed order.** The priority first, then the larger ticket, then the older one. A ticket with no priority is
  parked: no worker takes it.
- **No two workers on the same files.** An `area:*` label names the files a ticket changes. A ticket waits while a
  ticket in work holds the same area. A line `Blocked by #3` holds a ticket until that ticket closes.
- **Now and Force.** Now gives one queued ticket to one worker at once. Force starts a worker's next ticket past the
  limits.
- **Other repos.** A ticket with a `repo:<Name>` label is built in another repo of yours, and its pull request opens
  there.
- **Bot accounts.** A worker can write as its own GitHub bot, so GitHub notifies you of its comments and pull
  requests.
- **A merger.** It merges each worker pull request that GitHub can merge, oldest first. One that conflicts with main
  goes back to its worker for a rebase.
- **Stuck runs do not loop.** A run that ends with no pull request and no question is parked with its reason. You
  press Retry; nothing retries alone.

### Questions, not guesses

- **Only what you decide.** A run asks about the product: a rule, a look, what a user sees. It never asks about the
  workflow, and it builds a default for the rest.
- **Blocking or open.** A blocking question holds its pull request or ticket until you answer. An open question
  merges on its default, and you keep or change the default later.
- **One answer box.** Each question has Accept default and Send answer. Your answer goes to GitHub as a comment, and
  the queue does the rest.
- **Pictures.** A question about a look carries a screenshot of each choice. A new look comes as three candidates.
- **Your comments count.** A comment of yours on a ticket or its pull request overrides the ticket. The run reads it
  at its next checkpoint, marks it 👀 and replies.
- **Follow-ups.** Work that a run finds outside its ticket arrives as a new ticket. One with a question waits for
  your answer first.

### The page

- **Six tabs:** Workers, Questions, Queue, Accounts, History and Details.
- **Workers:** what each worker does now and takes next, with a progress bar against the typical run of that size.
  A switch sets a worker Active, Paused or Disabled, and you choose how its run ends: now, at the next checkpoint, or
  after the ticket. The page adds, removes and renames workers.
- **Queue:** the queued tickets with why each waits, the typical hours and cost of what is left, the stuck runs and
  the parked tickets.
- **Accounts:** a meter for each usage window, with handles that you drag to move a limit. The page adds an account
  and signs it in.
- **History:** the merged pull requests, and each run with its model, its time and its cost.
- **On your phone:** the page installs to the home screen like an app, through Tailscale. The server listens on
  localhost only, and nothing is open to the internet. With the PC off, the page shows its last state.
- **Pushes** through ntfy: a blocking question, a stuck run, a usage limit, an account that is out, a script that is
  down, an empty queue and each merge.

### The budget

- **Your Claude plan, never an API key.** The workers run on plan logins. Several workers can share one account, or
  each can have its own.
- **Stop lines.** For each usage window of an account, you set the share where its workers stop.
- **Pick-up limits.** A large ticket is not started late in a 5-hour window, so a run seldom reaches the stop line.
- **Usage guards.** The front desk and your own use each keep a share of the week on their account.
- **Room is spent where it would be lost.** A ticket goes to the worker whose account has the most weekly room for
  each hour that is left before its reset.
- **A run at a limit is not lost.** It ends at its next checkpoint, and the same session goes on when the account
  has room again.
- **An account that is out** (signed out, or its subscription refused) stops only its own workers. Their tickets
  that no run began go back to the queue, and the workers start again when the account answers.

### Models

- **A complexity picks the model and the effort.** Four are built in: `low`, `medium`, `high` and `design`. A
  project changes them or adds its own.
- **An advisor.** The runs of a complexity can ask a stronger model for a second opinion when they decide to.
- **Fallbacks.** If the plan refuses a model, the run takes the next candidate of its complexity.

### Plugins and projects

- **Plugins.** The base knows git, GitHub and Claude Code, and no engine or build tool. A plugin adds one
  environment through six hooks and a playbook of its own. It can give a run MCP servers, tool rules, environment
  variables and a line for its first message.
- **Several projects on one PC.** One page shows them together. The accounts with their limits and the workers'
  numbers are the PC's, and a worker moves from one project to another on the page.
- **The front desk.** Setup adds a ticket skill to the project. It writes tickets, reports the queue and passes your
  answers on.

## What you can set

| Where | In git | What |
| ----- | ------ | ---- |
| `scriptorium.json` at the project's root ([docs/CONFIG.md](docs/CONFIG.md)) | yes | `name`, `plugins` with their settings, `repos`, `playbook` (the project's own rules for a run), `allowedTools`, `port`, `compactAt`, and `complexities`: each with `description`, `models`, `advisor`, `advisorFallback` and `compactAt` |
| The page, Details ([docs/APP.md](docs/APP.md), Details) | no | For each complexity of a project: the model, the effort, the compact size, the advisor switch and the effort of a run without the advisor. Also the advisor's model and the project's colour |
| The page, Accounts | no | The stop line of each window, the pick-up limit of each ticket size, the usage guards, and the two lines of the Fable week. Add, sign in, rename and remove an account |
| The page, Workers | no | A worker's status, account, project, name and the complexities that it takes. Add and remove a worker |
| The PC's settings, `%LOCALAPPDATA%\Scriptorium\settings.json` ([docs/QUEUE.md](docs/QUEUE.md), Settings) | no | `accounts` (which login each use runs on, with `stopAt` and `pickUp`), `keep`, and `workers.<id>`: `enabled`, `assignedOnly`, `complexity`, `name`, `ghConfigDir` |
| The project's settings on the PC, `.queue/settings.json` in the main checkout | no | `complexities.<name>` (`model`, `compactAt`, `advisor`, `advisorFallback`), `advisor.model`, `color`, `model` (one model for every run), `ghConfigDir`, `merger.ghConfigDir`, `plugins.<name>`, `ntfy.topic`, `ntfy.server` |
| `models.json` in the Scriptorium folder ([docs/QUEUE.md](docs/QUEUE.md), Models) | yes | The models with their effort and price, the efforts, each complexity's candidates, `afterFable`, the default `compactAt`, `runCap` and the advisor's model |

The page writes the two settings files, so you seldom edit them by hand. A change counts from the next run.

## Built-in token savings

Each turn of a run reads its whole context again, so a token in the fixed start of a run is paid on every turn. Each
number below was measured apart, the newest with Claude Code 2.1.323. They do not add up to one total.

### Always on

| What | How |
| ---- | --- |
| One fresh session for one job | Each job starts a new session, and a run never hands off to another one. Claude Code compacts its context at the compact size of its complexity (167,000 tokens by default). A handoff read 24 turns again, a compaction 7 |
| The unused tools are blocked | 4,750 tokens less on every turn, and 1,977 for `Workflow`. `Skill` and `ToolSearch` stay: without them, the tools that Claude Code holds back load in full |
| No skills that a run does not use | Claude Code's own skills and those of the claude.ai account are off: 6,077 tokens less on every turn. The project's and the plugins' skills stay |
| No MCP server of the login | A run gets only the servers that the project's plugins give it |
| No advisor by accident | The worker script sets the advisor for each run or turns it off, so an advisor in a login's own settings does not count. A run on the advisor's own model gets none |
| The environment is ready first | The plugins open what a run needs (an editor, a server) before the run starts, so no turn waits for it |
| A compaction before each hold | A run that stops at a usage limit or for your pause is compacted at once, with its own model, tools and settings, so the compaction reads the context from the warm cache. At the resume the cache is gone, and a whole session would be read again at full price. A run whose pause you take back goes on at once, with no compaction |
| A resume in place of a new start | A held run goes on in the same session, with its context and its uncommitted work. At the Fable limit it goes on in that session on another model |
| Fewer runs cut off | A large ticket is not started late in a 5-hour window, so a run seldom reaches the stop line. The stop note is taken back if the account has room again before the run ends |
| Fewer rebase runs | Two tickets that change the same files never run at the same time |
| The next run does not start from zero | Each checkpoint pushes the work and writes what is done and what is next. A handoff comment, a follow-up's Cause line and an open question's Where line tell the next run where to start |
| An answer that needs no run starts none | Accept default closes an open question and merges a held pull request as it is. A follow-up whose default is "no" closes |
| A short playbook | Five parts that few runs need are files of their own. A run reads a part only when its job needs it |
| Short tool output | The playbook tells a run to read a file part once and to keep a command's output short. Its commands for comments and for git print only what the run needs. A run does not read the project's `CLAUDE.md` a second time: Claude Code has loaded it already |
| A cheap usage reading | The usage comes from the run's own log. Without a run, and only when the last reading is older than 30 minutes, a one-word request with no tools reads it: about 900 tokens, where the whole harness took 46,097 |
| No model outside the runs | The dispatcher, the merger, the page and the pushes are scripts. No agent talks to another: a run reads only its own ticket |
| No loop on a failure | A failing ticket is parked for you. A follow-up of a follow-up has a soft cap |

### Trials

Two changes are trials. Each can be reverted alone, and a later check decides whether it stays.

- **The PowerShell tool is blocked:** 3,800 tokens less on every turn. The run's one shell is Bash, and a PowerShell
  command goes through it.
- **The Turns rule** in the playbook: before each message, the run sends all tool calls that do not need each
  other's result in that one message.

### Settings that trade cost for quality

- **The model and the effort** of each complexity (the page, Details).
- **The advisor switch** of each complexity. Each call of the advisor reads the whole session, uncached.
- **The compact size.** A larger size keeps more of the work in view and costs more on each turn. A size that is
  not a plain number from 67000 to 967000 stops the scripts: Claude Code once read `250k` as its minimum without a
  word.
- **The cap of one run:** `runCap` in `models.json`, 60 dollars at the API's price. A run that reaches it is parked
  for you.

### Measure it

Each run's line in `.queue/history.jsonl` has its cost and its numbers: requests, tool calls, the tokens of the
first request, the context size, the cache reads and writes, the compactions and the advisor's cost.

```powershell
powershell -NoProfile -File D:\Work\Scriptorium\report.ps1 -Project D:\Work\MyApp
```

It prints the medians for each complexity and model. With `-Logs <a worker's .queue\logs>` it prints the tools that
the runs were given and how often they called each: run it after a Claude Code update to keep the block list right.

## In the background

Three kinds of script run on the PC as Windows tasks with no window. They start when you log on and need nothing
from you.

- **A worker script** for each worker:
  - It has the plugins make the environment ready before a run and leave it clean after it.
  - It chooses the next job under a lock that all workers share, so no ticket is taken twice.
  - It reads the plan's usage from the run's log and tells the run to stop at its next checkpoint when the account
    reaches its stop line.
  - It tells the run when you comment on its ticket or its pull request.
  - It checks that the run ended in a pull request, a question or a pause, and parks anything else.
  - It holds a stopped run with its session, and resumes it when the account has room or you set the worker active.
  - It tests an account that is out every 10 minutes.
  - It gives the tickets of a disabled or removed worker back to the queue.
- **The merger:**
  - It merges the worker pull requests.
  - It sends a pull request that conflicts with main, or that has a comment of yours its run did not read, back to
    its worker.
  - It files the follow-ups and the open questions of a merged pull request as tickets.
- **The page's server:** it reads GitHub once a minute and the workers' files every 10 seconds, sends the pushes and
  does what you click.

Also:

- **New code loads by itself.** A worker restarts between two jobs when Scriptorium, a plugin or the project's
  `scriptorium.json` changes, never in a run.
- **A run cannot change the code that runs it.** It gets copies of the playbooks, and no folder of Scriptorium or
  of a plugin.
- **A record of each run:** one log file for each run, and one line in the history with its model, time and cost.
- **Only the runs use a model,** with two small exceptions: the usage reading above, and Ping, which starts an
  account's 5-hour window.

## What it needs

- Windows 10 or 11, with Windows PowerShell 5.1 (it comes with Windows).
- [git](https://git-scm.com).
- The [GitHub CLI](https://cli.github.com), signed in (`gh auth login`), with write access to the repo.
- [Claude Code](https://claude.com/claude-code), signed in with a Claude plan (Pro or Max). Runs use the plan, never an
  API key.
- A project in a git repo whose origin is on GitHub.
- Optional: [Tailscale](https://tailscale.com) for the page on your phone, and the [ntfy](https://ntfy.sh) app for
  pushes.
- What the project's plugins need (each plugin's README says).

## Quick start

Clone Scriptorium beside your project, then run its setup on the project:

```powershell
git clone https://github.com/KadaXuanwu/Scriptorium D:\Work\Scriptorium
```

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File D:\Work\Scriptorium\setup.ps1 -Project D:\Work\MyApp -Commit -Start
```

Setup does this:

1. It writes `scriptorium.json` into the project and installs the plugins it detects.
2. It adds the ticket skill and `.queue/` to `.gitignore`, then commits and pushes those files (`-Commit`).
3. It makes one worker's copy of the repo, the GitHub labels and the logon tasks, and starts them (`-Start`).

Run it with `-WhatIf` first to see each step. It is safe to run again.

Or let Claude Code do it: paste [PROMPT.md](PROMPT.md) into Claude Code in your project.

## What you do by hand

1. Open the page: `http://127.0.0.1:8770` on the PC.
2. Add workers and plan accounts on the page (Workers, Accounts). One account runs everything at first: your own login.
3. For the page on your phone: sign in to Tailscale on the PC and the phone, allow Serve when `tailscale serve` asks,
   open the address that setup prints ("On your Tailscale devices"), and add the page to the phone's home screen.
   Only for the first project of a PC: a later project shows in the same app, beside the first.
4. For pushes: subscribe to the ntfy topic that setup prints, in the ntfy app.
5. File tickets: ask your own Claude Code session in the project ("ticket: ..."), or write GitHub issues with a
   priority label (`P0`, `P1`, `P2`).

## Limits

- Windows only: Task Scheduler and Windows PowerShell 5.1.
- One project for each setup run. Several projects on one PC each need their own run and their own `port`. Each has
  its own queue and page server. The accounts with their limits and the worker numbers are the PC's
  ([docs/QUEUE.md](docs/QUEUE.md), Settings). One page shows every project together.
- Claude Code and GitHub are fixed: no other agent, no other forge.
- A worker's copy is a full clone, beside the main checkout.
- GitHub builds and tests nothing: a run's own checks are the gate.

## Docs

- [docs/QUEUE.md](docs/QUEUE.md): the queue: labels, dispatching, the budget, models, settings.
- [docs/APP.md](docs/APP.md): the page.
- [PLAYBOOK.md](PLAYBOOK.md): what a run does.
- [docs/CONFIG.md](docs/CONFIG.md): `scriptorium.json`.
- [docs/PLUGINS.md](docs/PLUGINS.md): the plugin contract, and how to publish a plugin.
- [CONTRIBUTING.md](CONTRIBUTING.md): how to send a change.

## Licence

MIT. See [LICENSE](LICENSE).
