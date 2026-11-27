# The queue

Tickets are GitHub issues. Workers build them on their own, each in its own copy of the repo, and a merger merges
their pull requests. The owner talks only to the front desk and to the page.

## The parts

| Name | What | Uses a model |
| ---- | ---- | ------------ |
| Front desk | The owner's own session of the coding tool in the main checkout, with the ticket skill (in the provider's skills folder: `SKILL.md` is Scriptorium's, `PROJECT.md` holds the project's own rules). It files tickets, reports the queue and passes answers on. Also any work by hand | yes |
| Worker 1 to N | A copy of the repo (`<main>-w1`, `-w2` and on, beside the main checkout), its environment (the plugins) and its worker script. Each can be disabled (Settings, `enabled`). The page adds and removes workers ([APP.md](APP.md), Workers) | no |
| Worker script | [worker.ps1](../worker.ps1), one for each worker. It has the plugins make the environment ready (Start), dispatches (Dispatching; the scripts share a lock, so never the same ticket twice), starts a run, and checks that it ended in a PR, a question or a pause. However a run ends, the plugins leave the environment clean (EndRun) | no |
| Run | One headless session of the provider's coding tool ([PLUGINS.md](PLUGINS.md), A provider) that does one job in a worker's copy, with what the plugins give it (GetRun); fresh for each job. Each turn reads the whole context again, so the cost of a turn grows with the context. Where the provider can, the tool compacts it at the compact size of the ticket's complexity ([CONFIG.md](CONFIG.md), The compact size). A run never hands off to a fresh session: that read 24 turns again, a compaction 7. What a run gets from the tool itself (its tools, its settings, its skills) is the provider's choice, and its README says it | yes |
| Page | [APP.md](APP.md): one web page on the owner's PC and phone with each worker's status and tickets, the questions for the owner, the queue with what is left, and the accounts with their stop lines; ntfy pushes | no |
| Merger | [merge.ps1](../merge.ps1): squash-merges every worker PR that GitHub can merge, oldest first. A PR on a branch that is not a ticket's (`t<N>`) is the owner's own: the merger leaves it alone. It labels a conflicting one `needs-rebase`, and one with an owner's comment that its run never marked read `answered`, for its worker ([comments.ps1](../comments.ps1)). It sends a PR whose open question or asking follow-up has no banner picture back the same way, once, with a comment; the second time it merges. It files a merged PR's follow-ups and open questions, each with its generation, a soft cap from 2 ([followup.ps1](../followup.ps1)). While the owner is away, it hands back what waits on the owner (No blocking) | no |

[setup.ps1](../setup.ps1) makes the copies, runs the plugins' setup, makes the labels and the logon tasks
(`Scriptorium <name> worker N`, `Scriptorium <name> merger`, `Scriptorium <name> app`). The tasks and one worker's setup
are in [tasks.ps1](../tasks.ps1), which the page's Add a worker uses too. On Windows they are Task Scheduler tasks that
run through `conhost --headless`, so they have no window: with plain `powershell -WindowStyle Hidden`, Windows Terminal
opens one, and closing it ends the task. On macOS each is a launchd agent in `~/Library/LaunchAgents`, on Linux a
systemd user service in `~/.config/systemd/user` (`scriptorium-<name>-worker-<N>`), with the PATH that setup ran
with. [uninstall.ps1](../uninstall.ps1) ends and removes all of that for one project (README.md, Uninstall). Logs: `<checkout>/.queue/`, one stream-json file for each run.

On Windows, stopping a task ends only its console host, not the loop inside. A script ends any older copy of itself for the same
project (and that copy's run) when it starts, so a restart is `Start-ScheduledTask` after `Stop-ScheduledTask`. Each
script restarts itself through its task (on macOS and Linux: it exits with code 75, and launchd or systemd starts it
again; launchd also starts it again 10 seconds after any other exit that is not 0) when Scriptorium, a loaded plugin or the project's `scriptorium.json` changes
([restart.ps1](../restart.ps1)): a worker between jobs, so a run in progress finishes on the old code first; the merger
between passes; the page's server not while a sign-in, a GitHub write, a worker's setup or a copy's delete runs, and also
after an error of its loop (old code may fail on what a pull took away). A script also restarts when a plugin that
`scriptorium.json` names and that was not installed gets its files: until then it waits for it
([PLUGINS.md](PLUGINS.md), Where a plugin comes from). A paused run
(`paused.json`) resumes as before. To stop the queue, disable the tasks and end the `powershell.exe` (`pwsh` on macOS
and Linux) processes that run the scripts with `-Project "<main>"`.

GitHub builds nothing. A run's own checks are the gate, and a run that finds main broken fixes it in its PR.

## Wakes

The merger and an idle worker each look every 5 minutes (`-PollSeconds`). Two files in the main checkout's `.queue`
end that wait early. A script wakes when its file was written after its look began, so no wake is lost. No model is
involved.

| File | Who writes it | Who wakes |
| ---- | ------------- | --------- |
| `wake-merger` | A worker script when its run ends; the page's server after a write to GitHub | The merger |
| `wake-workers` | The merger at the end of a pass that merged or labelled a PR; the page's server after a write to GitHub, and when its reading of GitHub (once a minute) offers new work | Every idle worker |

- A PR merges seconds after its run ends. GitHub does not know yet whether a new PR can merge, so the merger asks up
  to three times, 5 seconds apart.
- A merge closes the ticket and frees its areas. The merger wakes the workers after that, so the ticket that waited
  on those areas starts at once.
- The merger holds the workers' dispatch lock from a merge to its ticket's close. A worker that looked between the
  two would see its ticket open without a PR, and start it again.
- A comment on a PR that is already merged reaches no run. Comment while the run works: it reads comments at each
  checkpoint.
- New work that no script saw happen wakes the workers within a minute, from the server's reading of GitHub
  (`Test-NewWork` in [state.ps1](../app/state.ps1)): a ticket that the front desk filed or that got a priority, and
  an area that a held PR (`needs-owner`) freed. With the page's server down, these wait for the poll.

## Labels

| Label | Means |
| ----- | ----- |
| `P0` / `P1` / `P2` | Queued; P0 first; within a priority the bigger ticket first (L, M, S), then the oldest. No priority label: parked, never taken |
| `area:*` | The files it changes, so two workers stay off the same files. A ticket waits while a ticket in flight (claimed, not waiting on the owner) holds the same area, or one inside the other: `area:api` clashes with `area:api/auth`, and `area:api/auth` does not clash with `area:api/search` ([areas.ps1](../areas.ps1)). The list is not fixed: whoever writes a ticket uses an area that fits or makes a new one (the ticket skill, Areas) |
| `size:S` / `M` / `L` | How much usage it will take, the front desk's estimate (a follow-up's: the run that writes it). None counts as M. It picks the pick-up limit only (Dispatching) |
| `complexity:*` | How hard it is to get right, the front desk's call (a follow-up's: the run that writes it, never its ticket's). It picks the model (Models). None counts as medium. Independent of size: a one-line core rule can be high and S, a rename across fifty files low and L |
| `repo:<Name>` | The work happens in the owner's repo `<Name>` ([PLAYBOOK-repo.md](../playbook/PLAYBOOK-repo.md)); it counts as an area |
| `worker:N` | Claimed by that worker, until its PR merges and closes the ticket |
| `needs-owner` | Waits on the owner. On a ticket: a worker's question (nothing could be built), or a stuck run; removing it hands it back. On a PR: held for questions, or a run that could not finish. Never a way to keep a ticket for later: park it (no priority) or give it a `Blocked by` line. While the owner is away, the merger takes it off again (No blocking) |
| `answered` | On a PR: the owner answered a held PR, or the merger found an owner's comment without 👀 or a question without a banner picture. Its worker applies them, then it merges |
| `needs-rebase` | On a PR: it conflicts with main; its worker rebases it |
| `follow-up` | A draft ticket that the merger filed from a merged PR's Follow-up section (one for each `###`), with questions for the owner. No worker takes it until the owner answers it (the page, Questions). One without questions is filed `P1` instead |
| `open-question` | A question that the merger filed from a merged PR's Open questions section (one for each `###`, `size:S`); the product has its default already. The owner keeps the default (closed) or changes it (queued `P1` with the answer) under the page's Questions |

A line `Blocked by #3, #5` in a ticket's body holds it until those close, unless the owner forces it onto a worker (Queue next, Now). A run must end in a PR, a question or a
pause (for the usage limit, or for an account that is out). The worker script parks anything else as `needs-owner`,
with the log's path, so a failing ticket never loops.

## Dispatching

An idle worker script, under the shared lock, takes the first of: the ticket of the owner's Now (Now), the ticket
queued as its next and forced (Queue next), its own PRs (`answered`, then `needs-rebase`), its own
ticket without an open PR (answered, rejected, given to it, or a run cut short), the ticket queued as its next (Queue
next), then new tickets. A passive worker stops before the last two (A passive worker). New tickets go in
queue order: the priority, then the bigger ticket, then the older one (`Get-SizeRank` in [limits.ps1](../limits.ps1)).
A fresh window then goes to the big tickets, and the small ones fill what the pick-up limits leave. Each ticket goes to
the idle worker whose account's free room most wants spending, labelled `worker:N` for it; the script stops at the
first that falls to itself. The arithmetic is [budget.ps1](../budget.ps1) and, for the ceiling,
[limits.ps1](../limits.ps1), which the page reads too.

A worker gives tickets only to the workers on its own coding tool (Settings, `accounts.<name>.provider`): another
tool's account has other windows. In a project with workers on two tools, a ticket goes to the tool whose idle worker
looks first. To keep a kind of ticket from a tool, switch its complexity off for that tool's workers (a worker's
Config).

**The budget.** It is better to reach the limit on every account than to reach a reset with room unused. The windows
are the provider's ([PLUGINS.md](PLUGINS.md), A provider): one plan has 5 hours and a week, another a week alone,
another a month. In each window of an account the workers may fill it to a **ceiling**: its **stop line** (the
provider's default, for example a short window at 98 %, since readings come in whole per cent and lag, and a long one
at 100 %, since a run that reaches its limit pauses until the reset), less a **reserve**. The owner moves an account's
stop lines on the page (Settings, `stopAt`). The reserve is only in the one window that the provider marks to keep it
(`keep`, as a rule the longest), and only on an account that the register (Settings, `accounts`) gives a human use,
`frontdesk` or `personal`. Each human use has a **usage guard**:

- The owner sets its share of that whole window on the account (Settings, `keep`).
- Its reserve is that share times the share of the window left: three days after the reset of a week it keeps 4/7 of
  the share. The part for the time gone is free for the workers.
- The reserve is an offset below the stop line: a lower stop line moves the ceiling down with it. The ceiling is never
  below 0.

A provider that reads no usage has no budget: its workers run until the plan refuses, and then wait for the reset.

More rules:

- **Pick-up limits:** an account has one for each ticket size: the share of a window from which its workers take no
  new ticket of that size (Settings, `pickUp`). A bigger ticket stops being taken earlier, so a run seldom reaches
  the stop line. The account's shortest window has them: the provider's defaults, else the base's
  (`$BasePickUp` in [limits.ps1](../limits.ps1)) when the account has a longer window too. A provider can give them to
  a longer window too. A window with none, as the only window of an account, holds a new ticket back only at its
  ceiling.
- **Complexity switches:** the owner switches a complexity off and on for each worker (Settings,
  `workers.<id>.complexity`; the worker's Config). Off: that worker takes no new ticket of it from the queue, and the
  answers and rebases of its PRs of it wait. A ticket that the owner gives the worker by hand (Queue next, forced or
  not, and Now) it takes all the same. A ticket already started goes on, also a held run that resumes. The test is
  `Test-ComplexityOff` ([limits.ps1](../limits.ps1)), the same for the workers and the page.
- **Fits:** an account takes a new ticket while its usage is under the pick-up limit of the ticket's size, in each
  window that has them, and every window is under its ceiling (`Get-Fit`). A worker's own PR or ticket and a forced
  ticket do not use the pick-up limits.
- **Best fit:** of the idle workers whose accounts take the ticket, the one whose free room in the longest window most
  wants spending: room per hour left before the reset loses it; then the most room in the shortest window. A ticket
  that nobody takes waits; the next one that somebody takes goes ahead of it.
- **Over the ceiling:** a worker whose account is at its ceiling in any window takes no job, not even its own PR's
  answers. It looks again every poll, as the ceiling rises toward the reset. A run that reaches it ends at its next
  checkpoint (The usage limit).
- **History:** `.queue/history.jsonl` keeps the cost of every run, where the provider reads one (a resumed run's less
  the part before its pause), and its rise in each window, from its log's first and last usage reading. The page shows
  typical times and costs from it; the dispatcher does not read it. Each line also has the run's numbers as the
  provider reads them from its log ([PLUGINS.md](PLUGINS.md), ReadRun), for example `requests`, `toolCalls`,
  `commands` (a shell call counted as the commands it chains: a run batches its work in one call, so `commands` for
  each request shows it and `toolCalls` does not), `first` (the tokens of the first request), `ctxMean` and `ctxMax`
  (the context), `read` and `write` (tokens from and to the cache), `compactions`, `advisorCalls` and `advisorCost` (the
  cost of the advisor's model; a resumed run's less the part before its pause, which `paused.json` keeps as
  `AdvisorCost`). `resumed` says that the run went on in a held session.
  [report.ps1](../report.ps1) `-Project <main>` prints their medians for each complexity and model, of the whole-ticket
  runs. Then it prints the same for the parts of interrupted tickets, the resumed parts apart: `First` of a resumed
  part is what the resume reads again at full price.
- **Usage:** per account in the PC's `usage.json` (Settings, The PC's files), from the runs' logs. When it is older
  than 30 minutes, the script reads it again with a probe: the provider's cheapest request, the same as the page's
  Ping, which saves its reading too. That reading is the account's, so the front desk's and the owner's own use count
  too. With a provider whose logs hold no usage, the script sends the probe while a run works too (every
  `$RunProbeSeconds` in [budget.ps1](../budget.ps1), unless a Ping or another worker read the account since), so the
  page shows the run's usage and the stop line ends it, and once more when the run ends, so the next ticket is taken
  on what that run used.
  Each reading keeps the
  login's email; when a login folder is signed in to another account, its reading counts as none. A save keeps a window
  from the stored reading where that one has a later reset. A share can fall before its reset (a limit that was reset
  early), so a lower reading of the same window replaces the stored one; only a used-up window of some models stays
  until its reset (A model's limit). A run that waits on a long task has only an old reading in its log: its worker
  saves a reading only when the log has a new one (`Get-ReadingKey` in [budget.ps1](../budget.ps1)).
- **Idle:** each worker script writes its state to `.queue/worker-<N>.json` (a running one also its account, ticket size
  and the usage it started from). An idle state older than two polls is a stopped script, left out. A worker whose
  account is out is not idle and gets no ticket (An account that is out).

## Complexities

A ticket's `complexity:<name>` label picks the model and effort of its run. Scriptorium has four (`$BaseComplexities`
in [project.ps1](../project.ps1)): `low`, `medium`, `high` and `design`. The provider gives each its models, in its
`models.json` ([PLUGINS.md](PLUGINS.md), A provider). A project changes them or adds its own in `scriptorium.json`
([CONFIG.md](CONFIG.md), Complexities). One list, `Get-Complexities` in [project.ps1](../project.ps1), gives them to
the worker script, the merger, setup and the page.

The models that `scriptorium.json` names are the ones of the project's default provider, the first provider it lists.
A worker on another coding tool (Settings, `accounts.<name>.provider`) starts from the models of that tool's own
`models.json`, and for a complexity of the project's own from that tool's `medium` models. The picks of the worker's
own mapping go over these, on any tool (Models, A worker's mapping).

| Complexity | For |
| ---------- | --- |
| `low` | Clear what to do: a doc, a number, a rename, more of a pattern |
| `medium` | Judgement within known patterns: a feature or a bug in one part |
| `high` | Hard to get right: core rules, work across parts, a bug nobody can explain |
| `design` | The ticket does not give the shape of the solution: the worker finds it, and the choice stays |

A worker's Config on the page shows the model and effort of each for that worker.

`design` is how a feature works, a final look, or a code structure that is expensive to change later. The test: if the
ticket names the structure and the rule, and the work is to build them, it is not `design`. Judgement at a few points is
what the advisor is for. Not `design`: a rule the ticket already decides, a placeholder, a bug, a measuring run, more of
a pattern.

## Models

The provider's `models.json`, in its plugin's repo ([PLUGINS.md](PLUGINS.md), A provider): each model's effort and
name, the efforts a run can have (`efforts`), and for each complexity its candidates, best first (answer and rebase
jobs run on their ticket's complexity). A run takes the first candidate that its account was not refused. A start that
the plan refuses for its model costs nothing, goes into the PC's `access.json` for a day, and the job starts again on
the next candidate. After the day the model is tried again, so a plan that gains it finds it. With no candidate left,
the ticket waits in the queue for that day (An account that is out).

A run gets its model and effort and names both in its PR. The effort is the model's own in `models`, or the one a
candidate names after `@` (`<model>@high`). Runs use the plan logins, never an API key. A pick-up limit is the same for
every model: a ticket on a dearer model reaches the stop line sooner.

**A worker's mapping:** the owner's picks are each worker's. The worker's Config on the page sets, for each
complexity, the model and effort of that worker's runs, their compact size and their advisor ([APP.md](APP.md),
Workers, Config; Settings, `workers.<id>.mapping`). One function gives a worker's mapping to the worker script and
the page: `Get-WorkerMapping` in [project.ps1](../project.ps1).

- **A pick** is the complexity's one candidate, from the worker's next run. The page offers the models of `models`
  and the efforts of `efforts` (a model's own `efforts` where it has them), and the server saves nothing else: a
  coding tool may take an effort it does not know without a word. With a model that takes no efforts, a pick is the
  model alone. A model that `scriptorium.json` names
  for the complexity stays a valid pick. Two things do not follow the pick: a held run resumes on the model it started
  on, and a run without its advisor takes the complexity's `advisorFallback` effort (Without the advisor).
- **One for each coding tool:** a worker has a mapping for each tool it was on, under the provider plugin's name. On
  an account of another tool it runs on its mapping for that tool, and it finds the old one again when it comes back.
- **In any project:** the mapping is the PC's, so the worker takes it along to another project. A complexity of a
  project's own has its row only while the worker is in that project; the pick is kept for the worker's return.
- **A link:** a worker can use another worker's mapping instead of its own (`follows`), so one change counts for
  both.
  - A link goes over any number of workers: the picks are those of the last worker of the chain.
  - Only a worker on the same tool can be followed, and no link leads back to the worker itself.
  - The complexity switches are never linked: each worker keeps its own.
  - A worker that links loses its own picks for that tool, but for a project's own complexities. Its own again, it
    starts from the picks it ran on, so the change alters no run.
- **A link into another project:** the last worker of the chain then has no row for this project's own complexities.
  Those rows stay the following worker's own.
- **The followed worker goes to another tool:** the link stays. The picks are the ones that worker has for this tool,
  which it keeps.
- **A worker is removed:** a worker that followed it follows the worker that it followed. Where it followed nobody,
  the follower gets its picks as its own (`Remove-MappingLinks` in [app/state.ps1](../app/state.ps1)).
- **The dispatcher** judges each idle worker by that worker's own mapping: whether its account still has a model of
  the ticket's complexity (`Test-ModelLeft` in [worker.ps1](../worker.ps1)).
- **Before this, the picks were the project's** (`complexities.<name>` and `advisor.model` in the project's
  settings). Those keys are no longer read.

**The advisor,** with a provider that has one (`advisor.model` in its `models.json`): a run of a complexity with
`advisor` gets that model as its advisor (`Get-AdvisorRule` in [project.ps1](../project.ps1), `Get-Advisor` in
[limits.ps1](../limits.ps1)). A worker's mapping sets the switch and the fallback effort of each complexity and the
advisor's model for that worker, over the files (Settings, `workers.<id>.mapping`).
The run calls it when it decides to, inside its own turn. A run on the advisor's own model gets none, nor does a run
whose account has the advisor's model no longer (A model's limit). The worker script names the advisor of each run to
the provider, which switches it on for that run alone. A session keeps its advisor through a hold, a resume and a
compaction.

**Without the advisor:** a new run of a complexity with the advisor, on an account that cannot give it now, takes the
complexity's `advisorFallback` effort, where one is set (`Get-FallbackEffort`), and keeps it through a resume.

**The cap of a run,** in the tool's own count: `runCap` in `scriptorium.json` ([CONFIG.md](CONFIG.md)), else in the
provider's `models.json`. The project's holds for its default provider only. The worker script gives each run the cap, but not the compaction of its session. A run that reaches it is never an account's refusal, and the run is
not held: it is parked like a run without a PR, and the comment names the cap. The next run finds its pushed and its
uncommitted work ([PLAYBOOK.md](../PLAYBOOK.md), step 1). The cap is insurance. Without `runCap` in either file, or with a `runCap` of 0, a run has no cap.

## Settings

Two files, neither in git, are read before every decision and run, so a change applies from the next. Setup writes
the first ones.

- **The PC's:** `settings.json` in the PC's Scriptorium folder (`%LOCALAPPDATA%\Scriptorium` on Windows, `~/Library/Application Support/Scriptorium` on macOS, `~/.local/share/Scriptorium` on Linux), one for every project that
  Scriptorium runs on the PC.
  It holds `accounts`, `keep`, `workers`, `order` and `away`: the logins and their limits are the same for each
  project, a worker's number is the PC's, the page's order of the cards is the same on every device, and the owner is
  away from the whole PC.
- **The project's own:** the main checkout's `.queue/settings.json`, with every other key.

```json
{
  "accounts": {
    "main": { "provider": "<provider>", "uses": ["worker:1", "frontdesk", "personal"] },
    "second": { "provider": "<provider>", "configDir": "C:/Users/<you>/.<provider>-second", "uses": ["worker:2"] }
  },
  "workers": { "2": { "ghConfigDir": "..." } }
}
```

```json
{ "model": "<a model id>", "plugins": { "unity": { "editors": "D:/Unity" } } }
```

**The PC's files.** The same folder holds the accounts' records, which the workers of every project write:
`usage.json`, `out.json` and `access.json`. So two projects stop at the same lines of an account, and a reading of one
project's worker serves the other. The scripts read the two settings files as one object and save each key into its
file (`Read-ProjectSettings`, `Save-ProjectSettings` in [pc.ps1](../pc.ps1)). The page's server holds one lock of the
PC from an action's read to its save, so two projects' pages do not undo each other's change. A file that does not
parse stops the read with an error: it never reads as an empty one.

A PC key or an account record that a project's folder still holds (a project from before the PC's files, or an edit
by hand) moves to the PC's files at the next read (`Move-PcSettings`, `Move-PcRecords`). An account is one login
folder, not one name: an entry of a folder that the PC has adds its uses and only the fields that the PC's entry
lacks. A script from before the PC's files that still works on a run reads default lines until it restarts, so update
between runs.

- `accounts` (the PC's): **the account register**, which login each use runs on: `worker:N` (several workers may share one),
  `frontdesk`, `personal`. To move a use, move its entry: a worker runs on the account listed with it from its next run
  (a paused run resumes on the one it started on). For `frontdesk` and `personal`, the owner signs that login in where
  they work, and the entry tells the budget which account keeps room for them. `configDir` is a folder of the
  coding tool with its own login, which the provider names to the tool for each run. Left out: the user's command-line
  login (`default` in the queue's files), shared with the owner's terminal sessions. The page adds, signs in and
  removes accounts and moves workers between them ([APP.md](APP.md), Accounts); the provider's README says how to sign
  a folder in by hand. A worker in no entry runs on the command-line login.
- `accounts.<name>.provider`: **an account is one provider's**, the plugin's name, and **a worker runs on its
  account's coding tool**, in any project. So one project can have workers on two tools, and a worker that moves to
  another project keeps its tool.
  - Setup and the page's Add write it.
  - **Which providers a project's scripts have:** the ones its `scriptorium.json` lists, then each other one in the
    `plugins` folder of the Scriptorium install. So a provider that setup installed for one project serves the
    workers of every project. The first one the project lists is its **default provider**.
  - **To change a worker's tool,** put it on an account of that tool (the worker's card). It starts again on that
    tool before its next job. The page refuses the move while the worker has a run in flight: a session is its own
    tool's.
  - The PC has one command-line login, the entry with no `configDir`, and it is one provider's. A worker in no
    entry runs on that login, so on that tool; on a PC with no such entry, on the project's default provider.
  - Setup puts a new worker on the command-line login when that is the default provider's. Otherwise the worker goes
    to that provider's first account, or to a new one named after the provider, with a folder as its key in the
    usage records. A worker that is on an account already stays there.
  - A worker whose account is of a tool with no plugin on the PC does not run: its card says so. So does a page for
    that account: it lists only the accounts of the tools it has a plugin for.
  - An account from before this key names no provider. A project claims those accounts when one of its workers is on
    one of them: its scripts then write its default provider into each. A project that is new on the PC claims none,
    and so does a project whose `scriptorium.json` lists no provider of its own.
    Until then such an account counts as the default provider's of the project that reads it.
- `accounts.<name>.stopAt`: the account's stop lines, by the provider's names of its windows, for example
  `{ "<short window>": 0.9, "<long window>": 0.8 }`: the share of each window where its workers stop. Left out: the
  provider's. In a window of some models: the share from which no new session gets one of them as its advisor (A
  model's limit). The page's meters set it.
- `accounts.<name>.pickUp`: the account's pick-up limits, for example `{ "<short window>": { "L": 0.6 } }`. Left out:
  the provider's, else the base's (The budget). In a window of some models, under the name the provider gave its one
  limit: the start line, from which no new run starts on those models (A model's limit). The page's meters set it.
- `keep` (the PC's): the share of the whole window that each human use's usage guard holds on its account, for example
  `{ "frontdesk": 0.1, "personal": 0.15 }` (the defaults). The guard keeps the part of it for the time left; 0 keeps
  nothing. The page's guard sliders set it.
- `away` (the PC's): `true` while the owner is away: nothing that waits on the owner stops the work (No blocking). Left out:
  not away. The No blocking switch on the page's Workers tab sets it.
- `workers.<id>.mapping.<provider>` (the PC's): the worker's mapping for the coding tool of that provider plugin
  (Models, A worker's mapping). The worker's Config sets it. Left out: the files' values. In it:
  - `follows`: the number of the worker whose mapping this worker uses. Left out: its own.
  - `complexities.<name>.model`: the pick of a complexity's model and effort, as `model@effort`, for example
    `{ "medium": { "model": "<a model id>@high" } }`, over the complexity's candidates. The model alone with a tool
    that lists no efforts. Taken away when the pick is the base's own.
  - `complexities.<name>.compactAt`: the compact size of the complexity's runs, for example
    `{ "design": { "compactAt": 250000 } }`, over `scriptorium.json`'s ([CONFIG.md](CONFIG.md), The compact size).
  - `complexities.<name>.advisor`: the advisor switch of a complexity, `true` or `false`, over the files' `advisor`
    (Models, The advisor). Taken away when it equals the files' value.
  - `complexities.<name>.advisorFallback`: the effort of a run of the complexity without its advisor, an effort of
    `models.json`'s `efforts`, or `""` for the same effort (Without the advisor). Over the files' value, and taken
    away when it equals it.
  - `advisor.model`: the advisor's model, a model of `models.json`, over `models.json`'s `advisor.model`. Taken away
    for `models.json`'s own.
- `color`: the project's colour on the page, `#rrggbb` ([APP.md](APP.md), Details). Left out: a colour from the
  project's name. Details sets it.
- `model`: overrides the complexities' models for every run: a full id, at its effort in `models.json` (`models.json`'s
  `effort` if it is not listed). It goes over the mapping of every worker on the project's default provider too, and
  the worker's Config then says so. Left out: the complexity picks.
- `ghConfigDir`: a `gh` login folder (`GH_CONFIG_DIR`) signed in as a GitHub bot account for the worker. Its comments,
  PRs, pushes and commits are the bot's, so GitHub notifies the owner of them. Sign a folder in once:
  `$env:GH_CONFIG_DIR = '<folder>'; gh auth login`, in a browser signed in as the bot. Left out, or not signed in: the
  owner's own login, and GitHub notifies nobody.
- `merger.ghConfigDir`: the same for the merger, which then merges as that bot.
- `plugins.<name>`: settings of a plugin for this PC, over its entry in `scriptorium.json` ([PLUGINS.md](PLUGINS.md)).
- `ntfy.topic`, `ntfy.server`: the page's pushes ([APP.md](APP.md), Notifications).
- `workers.<id>` (the PC's): `ghConfigDir` for that worker only, `enabled`, `passive`, `complexity`, `mapping` and `name`
  (the worker's name on the page only; [APP.md](APP.md), Workers, Names).
- `workers.<id>.complexity`: the worker's complexity switches, for example `{ "design": false }`: it takes no ticket of
  a complexity set to false (Dispatching). Left out: every complexity is on. The worker's Config sets it.
- `workers.<id>.passive: true` makes a worker passive (A passive worker): it takes only what the owner gives it. The
  worker's Config sets it.
- `workers.<id>.enabled: false` disables a worker, for example one whose borrowed account is gone. The page's worker
  status sets it ([APP.md](APP.md), Worker status). Once its run has ended, the plugins close what they opened for it,
  an editor for example ([PLUGINS.md](PLUGINS.md), Close). A disabled worker's run wraps up at its next checkpoint, and its
  paused run is dropped. Once its run has ended, the next worker to dispatch takes its PRs and the tickets they close;
  its tickets without a PR go back to the queue. The same for a worker that the page removed or moved to another
  project: a `worker:<N>` label with no `.queue/worker-<N>.json` counts as gone. Work since its last checkpoint push is
  lost. Enabled again, it takes jobs from the next poll. Give a worker an account (the page's worker card) before you
  enable it; otherwise it runs on the command-line login.

## The usage limit

The worker script reads the plan's usage from the run's log while it works, and shares it with the other workers in
the PC's `usage.json`, per account. When the account reaches the workers' ceiling, the script writes a
note for the run (`limit.md`). The run ends at its next checkpoint, with its work pushed and a handoff comment, and opens
no PR ([PLAYBOOK.md](../PLAYBOOK.md), Usage limit). The script withdraws the note if the account has room again before
the run ends.

Where the provider can, the script then has it compact the session at once, while its cache is warm: at the resume
the cache is gone, and a whole session would be read again at full price. It holds the ticket (`paused.json`, `AtLimit`),
comments on it, and resumes the same session when the account takes an S ticket again. It looks every poll and a minute
after each window reset.

A run that the plan's own limit cuts off before its checkpoint is paused, not parked: `<copy>/.queue/paused.json` keeps
its session, a comment on the ticket says when it resumes, and after the reset the script resumes that same session,
with its context and uncommitted work. Close the ticket to drop it. The reset is the one the run's last reading names.
With a provider whose logs hold no usage, it is the latest reset of the account's windows at their ceiling, from the
probe when the run ended; with no such window (the service's own shortage), the script tries again after 30 minutes.

## A model's limit

A plan can have a window for some models alone, apart from the account's own: the provider names it in its
`models.json` with the models it covers ([PLUGINS.md](PLUGINS.md), A provider). Only runs on those models carry it, not
a run on another model with one of them as its advisor. It stops those models, not the account, so it is not one of
the budget's windows.

- **The reading:** only a run on its models or a refusal updates it; a probe may not read it. The page shows its share
  ([APP.md](APP.md), Accounts).
- **Two lines,** each the account's own (the window's meter on the page), else the provider's
  ([limits.ps1](../limits.ps1): `Get-ModelLines`, `Test-WindowOut`). The PC's `usage.json` keeps the window's last
  reading. Both hold until the reset.
  - **The start line** (the window's pick-up limit, `pickUp.<window>.<its name>`): no new run starts on the window's
    models on the account, so no dispatcher gives a worker on it a ticket that runs on one of them, and the Queue tab
    gives the reason. A PR's job of such a ticket still runs on its model. The line is below the stop line, so the runs
    in flight end under it and the advisor goes on.
  - **The stop line** (`stopAt.<window>`): no new session on the account gets one of the models as its advisor, and a
    PR's job of such a ticket starts on the window's `after` model. A session keeps the advisor it started with. The
    start line is never above the stop line. A refusal for the window's limit writes a reading of 100 %.
- **A ticket that no run began** goes back to the queue, for a worker whose account has the model left.
- **A run cut off by it:** the script resumes the same session at once on the window's `after` model, with an
  instruction in the job's message. The run decides whether the decisions that the ticket is on its first model for
  are made. If they are, it finishes and names both models in its PR. If not, it pushes its work, posts a handoff
  comment with the decisions still open, writes `handoff.md` in its queue folder and ends without a PR. The script then
  puts the ticket back in the queue, and a worker whose account has the model left starts it fresh from the comment.
- **A PR's job** (answers, rebase) goes on with the `after` model: the PR already holds the ticket's decisions.
- **A window with no `after` model:** a ticket goes back to the queue, and a PR's job is parked for the owner.

## An account that is out

An account is out when it takes no runs: a subscription that ends, a sign-out while a ticket works. The fact is the
account's, not a ticket's: the PC's `out.json` holds it for every worker of every project and for the page, per account the kind, the
service's text and the time of the last test.

- **Kinds** (`$OutKinds` in [limits.ps1](../limits.ps1); the provider reads them from a run's log,
  [PLUGINS.md](PLUGINS.md), ReadRun): `login` (the account is
  signed out), `subscription` (a payment past due, a subscription that ended) and `start` (a run did no work and its
  first request failed, for a cause the provider cannot name: the service is down, a wrong model name). `start` catches
  every wording the provider does not know.
- **What puts an account out:** a run that ends with `login` or `subscription`, or the usage reading's probe when the
  account refuses it for one of them. A `start` is tested first, because a record stops every worker on the account:
  the worker sends the account a probe. If the account refuses the probe too, the account is out.
- **A worker whose runs do not start:** if the account answers the probe, the cause is not the account's. The worker
  tries the job once more. If that run does not start either, only this worker stops (its own record, under
  `worker:<id>`), and the other workers on the account go on. It keeps its ticket: the cause may be every worker's (a
  wrong `model` in the settings). The worker tries a run again after an hour, or at once when the settings change. The
  ticket is never parked for it.
- **A plan with no model for a complexity** (Models): when the plan refuses the last candidate of a ticket's
  complexity, the ticket goes back to the queue. No dispatcher gives a ticket of that complexity to a worker on that
  account while the refusal is less than a day old (`Test-ModelLeft`); the Queue tab gives the reason. A PR's job and a
  resumed run are parked. A model's limit has its own rules.
- **Not an account's failure:** a run that ended before its first request (a session to resume that is gone) is its own
  failure and is parked.
- **The run:** a run that did work, or a PR's job, is held with its session (`paused.json`, `LoggedOut`), without a
  comment. A ticket that no run began is not held.
- **The worker:** it starts no run and takes no ticket. Its tickets that no run holds and that have no PR go back to the
  queue, for a worker on another account (`Remove-Claims`), so the ticket and its areas do not wait with the account.
- **The test:** every 10 minutes, and within 30 seconds after the folder's login changes (a sign-in), a worker sends the
  account a probe (the provider's cheapest request, which costs nothing when refused; with a provider that has
  none, the next run is the test). When the account answers, the record goes, a
  held run resumes its session and the worker takes tickets again.
- **A switch of account:** within 30 seconds the worker drops a run held for the old account and starts its ticket
  fresh on the new one. A session cannot follow to another login.
- **What the owner does:** sign the account in again, renew the subscription, or give the worker another account (the
  page, Accounts and the worker's card).

## The owner's pause

A run that ends at its checkpoint for a pause (`stop.md`) keeps its session the same way: the script compacts it at
once, holds the ticket (`paused.json`, `Stopped`) without a comment, and resumes the same session when the owner sets
the worker active and the account takes an S ticket. Nothing is kept after "Pause now" (the process ends), after a run
that ended with an error, for a disabled worker, or for a run that a Now ended (Now): that ticket starts fresh from
its handoff comment. A run held at a
checkpoint (a pause or a stop line) also starts fresh if the owner moved the worker to another account meanwhile
(`Get-Hold` in [limits.ps1](../limits.ps1)).

## No blocking

**No blocking** on the page's Workers tab is for the days when the owner is not there (Settings, `away`). It is one switch
for the PC: it counts for every project. While it is on, nothing that waits on the owner stops the work. A question
still reaches the owner: it waits under the page's Questions and blocks nothing. The rules are in
[away.ps1](../away.ps1). No model is involved but the runs.

- **A run** asks no blocking question. The worker script keeps the note `away.md` in the run's queue folder while the
  switch is on, also for a run that started before it. The run builds the answer that it recommends and files the
  question as an open question, with a `**Size:**` line for the work to change it ([PLAYBOOK.md](../PLAYBOOK.md),
  No blocking). The note carries the whole rule.
- **A held PR** (`needs-owner`, from before the switch or from a run that held all the same) has its default built.
  The merger takes the label off, files the PR's Decision line and Held questions as one `open-question` ticket of
  `size:M`, and merges the PR in the same pass.
- **A ticket's question** (`needs-owner`, the worker's last comment asks): the merger comments that the owner is away
  and takes the label off. The same worker takes the ticket again and builds its default.
- **A stuck run** (a ticket without a PR or a question; a PR whose answers or rebase did not finish) gets one more
  try: the merger comments and takes the label off.
- **Once:** the merger's comment starts `**Merger:** the owner is away`. A ticket or a stuck PR that has it is not
  handed back again, so a ticket that fails twice, or asks twice, waits for the owner.

What still waits for the owner:

- A follow-up that asks ("Do this?") and an open question. Each blocks nothing but its own work.
- A run that reached the cap for one run (`runCap`), and a second failure. A ticket `Blocked by` one of them waits
  with it.
- A ticket that the owner holds with `needs-owner` and no worker comment, and a parked ticket: a stub of the front
  desk too (the ticket skill, More than one ticket). The front desk writes no stub while the switch is on.
- An account that is signed out or refuses runs, and a script that is down.

The merger of a project looks at its next pass, at most 5 minutes later; the server wakes its own project's merger at
the click.

## Now

**Now** ends a worker's run for its next ticket. It is the answer **Replace now** to the arrow on the card of a worker
in a run ([APP.md](APP.md), Workers). The server writes the ticket to that worker's force file with `now`
(`.queue/force-<N>.json`).

- **The ticket** is the one the card shows as the worker's next: a queued ticket, also one that Queue next gave the
  worker. A PR's job takes no Now.
- **It waits** for that worker. No other worker takes it, and the page shows it as that worker's next.
- **A blocked ticket** takes Now too: the owner accepts a merge conflict with its blocker. The run's first message
  names the open blockers and tells the run to build on main as it is, without waiting or asking.
- **The run in progress** gets the stop note (`stop.md`). It ends at its next checkpoint: it pushes its work and
  posts a handoff comment. The script holds no session.
  - A ticket's run loses its claim. The ticket goes back to the queue and starts fresh from the comment, on any worker.
  - A PR's job stays the worker's. It starts again after the Now ticket.
  - The run is in the history as a part.
- **A run held at a checkpoint** (at the workers' stop line, or for a pause that ended) is freed the same way, within
  a minute: the script drops its session, and its ticket starts fresh from the handoff comment that the run posted
  when it was held (`Test-HeldAtCheckpoint` in [areas.ps1](../areas.ps1)). The Now run then uses the room kept under
  the stop line. The script does not look at the Now's ticket first.
- **Any other held run** was cut off mid-work: by the plan's own limit, by a model's window or by its account. It
  goes first, the page offers no Replace now for it, and a Now behind it ends.
- **The Now run** is a forced run: it does not stop at the workers' ceiling.
- **The model:** the server reads neither the window of the ticket's model on the account (A model's limit) nor the
  models that its plan refused (`access.json`).
  The plan can therefore refuse the start of a Now run. The ticket then goes back to the queue (Models).
- **The Now ends** without a run in these cases, and the worker deletes the file:
  - The ticket left the queue: closed or claimed by another worker.
    The worker takes only the ticket that the file names, never another one (`Select-Now` in [areas.ps1](../areas.ps1)).
  - The owner cancels the Now on the worker's card or on the ticket's row, or pauses or disables the worker. A cancel
    before the checkpoint withdraws the stop note, and the run goes on.

## Queue next

**Next** on the page's Queue tab gives one queued ticket to one worker as its next new ticket ([APP.md](APP.md),
Queue). It forces nothing. The server writes the ticket to that worker's next file (`.queue/next-<N>.json`).

- **The worker** is the server's pick ([APP.md](APP.md), Queue), or another worker that can take the ticket, which
  the owner chooses in the dialog: each worker runs the ticket on the models of its own mapping (Models, A worker's
  mapping). Not among them: a disabled worker and one whose script or account is out. A paused worker is among them,
  after the active ones: it keeps the ticket through its pause and takes it once the owner sets it active, so the
  owner can give a worker its first ticket before it starts. A worker at its
  usage limit is among them, and so is one with the ticket's complexity off, after the others: the switches hold
  back only the queue's own tickets (Complexity switches).
- **The ticket** waits for that worker. No other worker takes it. The worker's card shows it as its next, marked
  and tagged `queued next`, and its row on the Queue tab names the worker. One more Queue next for the same worker
  replaces the first, which goes back to the queue.
- **The worker takes it** when it looks for a new ticket: after its own PRs and tickets, in place of the queue's
  next ticket. It deletes the file then: the ticket is its own from there.
- **It waits** as a ticket of the queue does, and the card shows a lock with the reason:
  - for its open blockers and for an area that a ticket in flight holds (`Get-NextWait` in [areas.ps1](../areas.ps1));
  - for a model the account has left, and for the pick-up limit of its size;
  - with the worker, while its account is at the stop line.

  The worker takes no other new ticket meanwhile.
- **Forced** (the arrow on the worker's card, [APP.md](APP.md), Workers): the server writes `force` into the next
  file. The arrow does the same for a ticket that the card shows as the worker's next from the queue.
  - The worker then takes the ticket before its other jobs, past its blockers, the areas, the pick-up limits and the
    stop line, by the rules of a Now's ticket (`Select-Now`): that very ticket, never another one in its place.
  - A free worker takes it at its next poll. A worker in a run takes it after that run, or ends the run for it if
    the owner answers Replace now (Now).
  - Its run is a forced run: the worker writes its force file as it takes the ticket.
- **It ends** without a run in these cases:
  - The ticket left the queue: closed or claimed by another worker. For a forced one, the worker takes no other job
    in its place at that look.
  - The owner cancels it on the worker's card or on the ticket's row, or disables, removes or moves the
    worker. A cancel of a forced one takes the whole Queue next back, not only the force.
- A worker that holds a paused run keeps it: that run goes first, also before a forced ticket. Only Replace now
  frees it, and only one held at a checkpoint (Now).

## A passive worker

A passive worker takes only what the owner gives it, and keeps its environment closed between runs. It is a switch in
the worker's Config (`workers.<id>.passive`; [APP.md](APP.md), Workers), and the worker's Active then reads Passive.

- **It takes** the ticket of a Now, the ticket that the arrow forces (Queue next, Forced), its own PRs (`answered`,
  `needs-rebase`) and its own ticket without an open PR. A ticket that carries its `worker:<id>` label is its own.
- **It takes no** new ticket from the queue, and no worker gives it one. A ticket of Queue next waits on its card
  until the arrow forces it.
- **Its card** still shows the queue's best ticket as its next. That ticket is shown, not given: another worker
  takes it as before, unless the arrow gives it to the passive one first.
- **Its environment** opens only for a run. The plugins' `Start` runs before the run, not before each look for a
  job, so the run starts later by the time `Start` takes. When the worker waits with no run and none held, the
  plugins close what they opened (`Close`; [PLUGINS.md](PLUGINS.md)). A held run keeps it open: `Close` saves nothing.
- **After its script starts,** a passive worker with no held run closes its environment once: the script before may
  have left it open. An editor that the owner opened by hand in that copy closes with it.

## Plugins

A worker's environment comes from the project's plugins ([PLUGINS.md](PLUGINS.md)). The worker script calls `Start`
before each look for a job (a passive worker's: before a run, A passive worker), `GetRun` and `Start` for another
repo's checkout before a run, and `EndRun` after it.
A `Start` or `GetRun` that throws starts no run: the worker's card shows the error, and the worker tries again at its
next look. With no environment plugin, a run gets no MCP server and only the base's commands (`git`, `gh`). The
provider is a plugin too: with none, a worker starts no run and its card says so. A plugin that `scriptorium.json`
names and `setup.ps1` has not installed yet also starts no run: the card names it and says to run setup, and the
worker loads it by itself once setup has cloned it. A worker's run gets the playbook
and the hooks of its own provider, not of another provider that the project lists.

## Working a job

The run follows [PLAYBOOK.md](../PLAYBOOK.md), then each plugin's playbook, then the project's own (`playbook` in
`scriptorium.json`). Before each run, the worker script copies the first two into `.queue/playbooks` of the worker's
copy and names them in the run's first message; the project's own the run reads from `origin/main`. A run gets no
folder of Scriptorium or of a plugin, so it cannot change the code that runs it. The parts of `PLAYBOOK.md` that few
runs need (`PLAYBOOK-*.md`: follow-ups, another repository, pictures, the answered and the rebase job, a model's limit)
are copied beside it, and `PLAYBOOK.md` says when a run reads each. The message of an answered or a rebase job, of a
job in another repository and of a resume at a model's limit names its part. Each run holds the base playbook in its
context from its first turn, so a part saves its size on each turn of a run that does not read it.

## Further ideas

Not built. Each needs a trial before it is worth its cost.

- **A cheaper helper model.** A run hands its searching and the reading of docs to a cheap model, and gets back only
  the answer. It needs the provider to give a run its tool for helpers and a rule in the playbook.
  Measured with one coding tool: its tool for helpers is 2,702 tokens on every turn. Estimated from 328 run logs of
  one project (November 2026): searching and the reading of docs were about 6 % of the runs' cost, which is the most
  that a helper can save, and the helper tool would cost about 1.5 %. Not known: how often a run would hand work
  over, which decides the gain. The risk: a thin or wrong answer makes the run read the files anyway, and it pays
  twice.
