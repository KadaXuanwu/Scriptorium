# Scriptorium

A work queue for Claude Code. You write tickets as GitHub issues. Workers, headless Claude Code runs on your PC, each
build one ticket in their own copy of the repo and open a pull request. A merger merges the pull requests. One web page
shows you what runs, what waits, what it costs and what only you can decide.

It works on any git repo on GitHub. A plugin teaches it an environment, for example
[Scriptorium for Unity](https://github.com/KadaXuanwu/Scriptorium-Unity): one Unity editor for each worker.

## What you get

- **Workers.** Each worker has its own copy of the repo beside your checkout and takes the next ticket that fits. Two
  tickets that change the same files never run at the same time.
- **The page.** Workers, questions, the queue, accounts and history on your PC, and on your phone through Tailscale.
  Pushes through ntfy for a question that blocks work, a stuck run or an account that is out.
- **A budget.** The workers use your Claude plan's usage up to the stop lines you set, and keep room for your own use.
- **Models by complexity.** A ticket's complexity picks the model and effort of its run. The project can add its own.
- **Questions, not guesses.** A worker asks only what you decide, and builds a default for the rest.
- **The front desk.** A ticket skill for your own Claude Code session: it writes the tickets and passes your answers on.

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
   and add the page to the phone's home screen.
4. For pushes: subscribe to the ntfy topic that setup prints, in the ntfy app.
5. File tickets: ask your own Claude Code session in the project ("ticket: ..."), or write GitHub issues with a
   priority label (`P0`, `P1`, `P2`).

## Limits

- Windows only: Task Scheduler and Windows PowerShell 5.1.
- One project for each setup run. Several projects on one PC each need their own run and their own `port`.
- Claude Code and GitHub are fixed: no other agent, no other forge.
- A worker's copy is a full clone, beside the main checkout.

## Docs

- [docs/QUEUE.md](docs/QUEUE.md): the queue: labels, dispatching, the budget, models, settings.
- [docs/APP.md](docs/APP.md): the page.
- [PLAYBOOK.md](PLAYBOOK.md): what a run does.
- [docs/CONFIG.md](docs/CONFIG.md): `scriptorium.json`.
- [docs/PLUGINS.md](docs/PLUGINS.md): the plugin contract, and how to publish a plugin.
- [CONTRIBUTING.md](CONTRIBUTING.md): how to send a change.

## Licence

MIT. See [LICENSE](LICENSE).
