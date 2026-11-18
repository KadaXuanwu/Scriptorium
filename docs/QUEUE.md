# The queue

Tickets are GitHub issues. Workers build them on their own, each in its own copy of the repo, and a merger merges
their pull requests. The owner talks only to the front desk and to the page.

## The parts

| Name | What | Uses a model |
| ---- | ---- | ------------ |
| Front desk | The owner's own Claude Code session in the main checkout, with the ticket skill (`.claude/skills/ticket`). It files tickets, reports the queue and passes answers on. Also any work by hand | yes |
| Worker 1 to N | A copy of the repo (`<main>-w1`, `-w2` and on, beside the main checkout), its environment (the plugins) and its worker script. Each can be disabled (Settings, `enabled`). The page adds and removes workers ([APP.md](APP.md), Workers) | no |
| Worker script | [worker.ps1](../worker.ps1), one for each worker. It has the plugins make the environment ready (Start), dispatches (Dispatching; the scripts share a lock, so never the same ticket twice), starts a run, and checks that it ended in a PR, a question or a pause. However a run ends, the plugins leave the environment clean (EndRun) | no |
| Run | One headless Claude Code session that does one job in a worker's copy, with what the plugins give it (GetRun); fresh for each job. Each turn reads the whole context again, so the cost of a turn grows with the context. Claude Code compacts it at the compact size of the ticket's complexity: at 167k with the default of `models.json` ([CONFIG.md](CONFIG.md), The compact size). A run never hands off to a fresh session: that read 24 turns again, a compaction 7. The tools no run uses are blocked (`$UnusedTools` in the worker script): 4,750 tokens less on every turn | yes |
| Page | [APP.md](APP.md): one web page on the owner's PC and phone with each worker's status and tickets, the questions for the owner, the queue with what is left, and the accounts with their stop lines; ntfy pushes | no |
| Merger | [merge.ps1](../merge.ps1): squash-merges every worker PR that GitHub can merge, oldest first. It labels a conflicting one `needs-rebase`, and one with an owner's comment that its run never marked read `answered`, for its worker ([comments.ps1](../comments.ps1)). It files a merged PR's follow-ups and open questions, each with its generation, a soft cap from 2 ([followup.ps1](../followup.ps1)) | no |

[setup.ps1](../setup.ps1) makes the copies, runs the plugins' setup, makes the labels and the logon tasks
(`Scriptorium <name> worker N`, `Scriptorium <name> merger`, `Scriptorium <name> app`). The tasks and one worker's setup
are in [tasks.ps1](../tasks.ps1), which the page's Add a worker uses too. The tasks run through `conhost --headless`,
so they have no window: with plain `powershell -WindowStyle Hidden`, Windows Terminal opens one, and closing it ends
the task. Logs: `<checkout>/.queue/`, one stream-json file for each run.

Stopping a task ends only its console host, not the loop inside. A script ends any older copy of itself for the same
project (and that copy's run) when it starts, so a restart is `Start-ScheduledTask` after `Stop-ScheduledTask`. Each
script restarts itself through its task when Scriptorium, a loaded plugin or the project's `scriptorium.json` changes
([restart.ps1](../restart.ps1)): a worker between jobs, so a run in progress finishes on the old code first; the merger
between passes; the page's server not while a sign-in, a GitHub write or a worker's setup runs. A paused run
(`paused.json`) resumes as before. To stop the queue, disable the tasks and end the `powershell.exe` processes that run
the scripts with `-Project "<main>"`.

GitHub builds nothing. A run's own checks are the gate, and a run that finds main broken fixes it in its PR.

## Labels

| Label | Means |
| ----- | ----- |
| `P0` / `P1` / `P2` | Queued; P0 first; within a priority the bigger ticket first (L, M, S), then the oldest. No priority label: parked, never taken |
| `area:*` | The files it changes, so two workers stay off the same files. A ticket waits while a ticket in flight (claimed, not waiting on the owner) holds the same area, or one inside the other: `area:api` clashes with `area:api/auth`, and `area:api/auth` does not clash with `area:api/search` ([areas.ps1](../areas.ps1)). The list is not fixed: whoever writes a ticket uses an area that fits or makes a new one (the ticket skill, Areas) |
| `size:S` / `M` / `L` | How much usage it will take, the front desk's estimate (a follow-up's: the run that writes it). None counts as M. It picks the pick-up limit only (Dispatching) |
| `complexity:*` | How hard it is to get right, the front desk's call (a follow-up's: the run that writes it, never its ticket's). It picks the model (Models). None counts as medium. Independent of size: a one-line core rule can be high and S, a rename across fifty files low and L |
| `repo:<Name>` | The work happens in the owner's repo `<Name>` ([PLAYBOOK.md](../PLAYBOOK.md), Another repository); it counts as an area |
| `worker:N` | Claimed by that worker, until its PR merges and closes the ticket |
| `needs-owner` | Waits on the owner. On a ticket: a worker's question (nothing could be built), or a stuck run; removing it hands it back. On a PR: held for questions, or a run that could not finish. Never a way to keep a ticket for later: park it (no priority) or give it a `Blocked by` line |
| `answered` | On a PR: the owner answered a held PR, or the merger found an owner's comment without 👀. Its worker applies them, then it merges |
| `needs-rebase` | On a PR: it conflicts with main; its worker rebases it |
| `follow-up` | A draft ticket that the merger filed from a merged PR's Follow-up section (one for each `###`), with questions for the owner. No worker takes it until the owner answers it (the page, Questions). One without questions is filed `P1` instead |
| `open-question` | A question that the merger filed from a merged PR's Open questions section (one for each `###`, `size:S`); the product has its default already. The owner keeps the default (closed) or changes it (queued `P1` with the answer) under the page's Questions |

A line `Blocked by #3, #5` in a ticket's body holds it until those close. A run must end in a PR, a question or a
pause (for the usage limit, or for an account that is out). The worker script parks anything else as `needs-owner`,
with the log's path, so a failing ticket never loops.

## Dispatching

An idle worker script, under the shared lock, takes the first of: its own PRs (`answered`, then `needs-rebase`), its own
ticket without an open PR (answered, rejected, given to it, or a run cut short), then new tickets. New tickets go in
queue order: the priority, then the bigger ticket, then the older one (`Get-SizeRank` in [limits.ps1](../limits.ps1)).
A fresh window then goes to the big tickets, and the small ones fill what the pick-up limits leave. Each ticket goes to
the idle worker whose account's free room most wants spending, labelled `worker:N` for it; the script stops at the
first that falls to itself. The arithmetic is [budget.ps1](../budget.ps1) and, for the ceiling,
[limits.ps1](../limits.ps1), which the page reads too.

**The budget.** It is better to reach the limit on every account than to reach a weekly reset with room unused. In
each window of an account the workers may fill it to a **ceiling**: its **stop line** (by default the week at 100 %,
since a run that reaches the weekly limit pauses until the reset, and the 5-hour window at 98 %, since readings come in
whole per cent and lag), less a **reserve**. The owner moves an account's stop lines on the page (Settings, `stopAt`).
The reserve is only in the week, and only on an account that the register (Settings, `accounts`) gives a human use,
`frontdesk` or `personal`. Each human use has a **usage guard**:

- The owner sets its share of a whole week on the account (Settings, `keep`).
- Its reserve is that share times the share of the week left: three days after a reset it keeps 4/7 of the share. The
  part for the days gone is free for the workers.
- The reserve is an offset below the stop line: a lower stop line moves the ceiling down with it. The ceiling is never
  below 0.

More rules:

- **Pick-up limits:** an account has one for each ticket size, in the 5-hour window only: the share of the window from
  which its workers take no new ticket of that size (Settings, `pickUp`). A bigger ticket stops being taken earlier, so
  a run seldom reaches the stop line. Defaults: S 90 %, M 75 %, L 50 %. The week has none: there only the ceiling holds
  a new ticket back.
- **Complexity switches:** the owner switches a complexity off and on for each worker (Settings,
  `workers.<id>.complexity`; the worker's Config). Off: that worker takes no new ticket of it, forced or not, and the
  answers and rebases of its PRs of it wait. A ticket already started goes on, also a held run that resumes. The test is
  `Test-ComplexityOff` ([limits.ps1](../limits.ps1)), the same for the workers and the page.
- **Fits:** an account takes a new ticket while its 5-hour usage is under the pick-up limit of the ticket's size and
  both windows are under their ceilings (`Get-Fit`). A worker's own PR or ticket and a forced ticket do not use the
  pick-up limits.
- **Best fit:** of the idle workers whose accounts take the ticket, the one whose free weekly room most wants spending:
  room per hour left before the weekly reset loses it; then the most 5-hour room. A ticket that nobody takes waits; the
  next one that somebody takes goes ahead of it.
- **Over the ceiling:** a worker whose account is at its ceiling in either window takes no job, not even its own PR's
  answers. It looks again every poll, as the ceiling rises toward the reset. A run that reaches it ends at its next
  checkpoint (The usage limit).
- **History:** `.queue/history.jsonl` keeps the dollar cost of every run (a resumed run's less the part before its
  pause) and its rise in each window, from its log's first and last usage reading. The page shows typical times and
  costs from it; the dispatcher does not read it.
- **Usage:** per account in `.queue/usage.json`, from the runs' logs. When it is older than 30 minutes, the script reads
  it again with a one-word Haiku request. That reading is the account's, so the front desk's and the owner's own use
  count too. Each reading keeps the login's email; when a login folder is signed in to another account, its reading
  counts as none. A save keeps each window from the stored reading where that one is further on (a later reset, or the
  same reset and a higher share): a run that waits on a long task has only an old event in its log.
- **Idle:** each worker script writes its state to `.queue/worker-<N>.json` (a running one also its account, ticket size
  and the usage it started from). An idle state older than two polls is a stopped script, left out. A worker whose
  account is out is not idle and gets no ticket (An account that is out).

## Complexities

A ticket's `complexity:<name>` label picks the model and effort of its run. Scriptorium has four, in
[models.json](../models.json): `low`, `medium`, `high` and `design`. A project changes them or adds its own in
`scriptorium.json` ([CONFIG.md](CONFIG.md), Complexities). One list, `Get-Complexities` in
[project.ps1](../project.ps1), gives them to the worker script, the merger, setup and the page.

| Complexity | For | Model |
| ---------- | --- | ----- |
| `low` | Clear what to do: a doc, a number, a rename, more of a pattern | Opus 5.5 at medium effort |
| `medium` | Judgement within known patterns: a feature or a bug in one part | Opus 5.5 at high effort, with the advisor |
| `high` | Hard to get right: core rules, work across parts, a bug nobody can explain | Opus 5.5 at xhigh effort, with the advisor |
| `design` | The ticket does not give the shape of the solution: the worker finds it, and the choice stays | Fable 5.2 at high effort |

`design` is how a feature works, a final look, or a code structure that is expensive to change later. The test: if the
ticket names the structure and the rule, and the work is to build them, it is not `design`. Judgement at a few points is
what the advisor is for. Not `design`: a rule the ticket already decides, a placeholder, a bug, a measuring run, more of
a pattern.

## Models

[models.json](../models.json), in git: each model's effort and its API price per million tokens (input, output), and for
each complexity its candidates, best first (answer and rebase jobs run on their ticket's complexity). A run takes the
first candidate that its account was not refused. A start that the plan refuses ("requires usage credits") costs
nothing, goes into `.queue/access.json` for a day, and the job starts again on the next candidate. After the day the
model is tried again, so a plan that gains it finds it. With no candidate left, the ticket waits in the queue for that
day (An account that is out).

A run gets `--model` and `--effort` and names both in its PR. The effort is the model's own in `models`, or the one a
candidate names after `@` (`claude-opus-5-5@high`). `afterFable` is the model for the rest of a job whose account
reached the Fable limit (The Fable limit). Runs use the plan logins, never an API key, so no script reads `price`: it is
there for the front desk, which weighs a model's cost with it. A pick-up limit is the same for every model: a Fable
ticket costs about 2.5 times an Opus one of its size, so it reaches the stop line sooner.

**The advisor:** a run of a complexity with `advisor` gets `advisor.model` (Fable 5.2) as its advisor
(`Get-AdvisorRule` in [project.ps1](../project.ps1), `Get-Advisor` in [limits.ps1](../limits.ps1)). The run calls it
when it decides to, inside its own turn; the advisor reads the whole session, uncached. A run on the advisor's own model
gets none, nor does a run while its account has no Fable (The Fable limit). The worker script sets it for each run:
`advisorModel` in the run's settings file, else `CLAUDE_CODE_DISABLE_ADVISOR_TOOL=1`, so a login's own settings do not
count. A session keeps its advisor through a hold, a resume and a compaction.

**Without the advisor:** a new run of a complexity with the advisor, on an account that cannot give it now, takes the
complexity's `advisorFallback` effort, where one is set (`Get-FallbackEffort`), and keeps it through a resume.

The front desk keeps `models.json` current: a new model or price, a plan change, or the owner's verdict on PRs by model.
The run costs by model are in `.queue/history.jsonl`. Change `updated` with it.

## Settings

The main checkout's `.queue/settings.json`, not in git, is read before every decision and run, so a change applies from
the next. Setup writes a first one.

```json
{
  "accounts": {
    "main": { "uses": ["worker:1", "frontdesk", "personal"] },
    "second": { "configDir": "C:/Users/<you>/.claude-second", "uses": ["worker:2"] }
  },
  "model": "claude-sonnet-5-5", "workers": { "2": { "ghConfigDir": "..." } },
  "plugins": { "unity": { "editors": "D:/Unity" } }
}
```

- `accounts`: **the account register**, which login each use runs on: `worker:N` (several workers may share one),
  `frontdesk`, `personal`. To move a use, move its entry: a worker runs on the account listed with it from its next run
  (a paused run resumes on the one it started on). For `frontdesk` and `personal`, the owner signs that login in where
  they work, and the entry tells the budget which account keeps room for them. `configDir` is a Claude Code config
  folder with its own login (`CLAUDE_CONFIG_DIR`). Left out: the Windows user's command-line login (`default` in the
  queue's files), shared with the owner's terminal sessions. The page adds, signs in and removes accounts and moves
  workers between them ([APP.md](APP.md), Accounts). By hand: `$env:CLAUDE_CONFIG_DIR = '<folder>'; claude auth login`.
  A worker in no entry runs on the command-line login.
- `accounts.<name>.stopAt`: the account's stop lines, for example `{ "five_hour": 0.9, "seven_day": 0.8 }`: the share of
  each window where its workers stop. Left out: 0.98 and 1. `seven_day_overage_included`: the Fable week's, from which
  no new session gets the advisor (The Fable limit; left out: 0.98). The page's meters set it.
- `accounts.<name>.pickUp`: the account's pick-up limits, for example `{ "five_hour": { "L": 0.6 } }`. Left out: S 0.9,
  M 0.75, L 0.5. `seven_day_overage_included.design`: the Fable week's design line, from which no new `design` ticket
  starts (The Fable limit; left out: 0.9). The page's meters set it.
- `keep`: the share of a whole week that each human use's usage guard holds on its account, for example
  `{ "frontdesk": 0.1, "personal": 0.15 }` (the defaults). The guard keeps the part of it for the time left; 0 keeps
  nothing. The page's guard sliders set it.
- `complexities.<name>.compactAt`: the compact size of a complexity's runs on this PC, for example
  `{ "design": { "compactAt": 250000 } }`, over `scriptorium.json`'s ([CONFIG.md](CONFIG.md), The compact size). It is
  the same for every worker. A worker's Config sets it.
- `model`: overrides the complexities' models for every run, or one worker's in `workers.<id>`: a full id, at its
  effort in `models.json` (xhigh if it is not listed). Left out: the complexity picks.
- `ghConfigDir`: a `gh` login folder (`GH_CONFIG_DIR`) signed in as a GitHub bot account for the worker. Its comments,
  PRs, pushes and commits are the bot's, so GitHub notifies the owner of them. Sign a folder in once:
  `$env:GH_CONFIG_DIR = '<folder>'; gh auth login`, in a browser signed in as the bot. Left out, or not signed in: the
  owner's own login, and GitHub notifies nobody.
- `merger.ghConfigDir`: the same for the merger, which then merges as that bot.
- `plugins.<name>`: settings of a plugin for this PC, over its entry in `scriptorium.json` ([PLUGINS.md](PLUGINS.md)).
- `ntfy.topic`, `ntfy.server`: the page's pushes ([APP.md](APP.md), Notifications).
- `workers.<id>`: `model` or `ghConfigDir` for that worker only, `enabled`, `assignedOnly` and `complexity`.
- `workers.<id>.complexity`: the worker's complexity switches, for example `{ "design": false }`: it takes no ticket of
  a complexity set to false (Dispatching). Left out: every complexity is on. The worker's Config sets it.
- `workers.<id>.assignedOnly: true` keeps a worker to the tickets labelled `worker:<id>` and their PRs: no worker gives
  it a new ticket, and it takes none. The front desk labels the ticket.
- `workers.<id>.enabled: false` disables a worker, for example one whose borrowed account is gone. The page's worker
  status sets it ([APP.md](APP.md), Worker status). A disabled worker's run wraps up at its next checkpoint, and its
  paused run is dropped. Once its run has ended, the next worker to dispatch takes its PRs and the tickets they close;
  its tickets without a PR go back to the queue. The same for a worker that the page removed: a `worker:<N>` label with
  no `.queue/worker-<N>.json` counts as gone. Work since its last checkpoint push is lost. Enabled again, it takes jobs
  from the next poll. Give a worker an account (the page's worker card) before you enable it; otherwise it runs on the
  command-line login.

## The usage limit

The worker script reads the plan's usage from the run's log while it works, and shares it with the other workers in
the main checkout's `.queue/usage.json`, per account. When the account reaches the workers' ceiling, the script writes a
note for the run (`limit.md`). The run ends at its next checkpoint, with its work pushed and a handoff comment, and opens
no PR ([PLAYBOOK.md](../PLAYBOOK.md), Usage limit). The script withdraws the note if the account has room again before
the run ends.

The script then compacts the session at once (`claude -p /compact --resume`), while its cache is warm: at the resume the
cache is gone, and a whole session would be read again at full price. It holds the ticket (`paused.json`, `AtLimit`),
comments on it, and resumes the same session when the account takes an S ticket again. It looks every poll and a minute
after each window reset.

A run that the plan's own limit cuts off before its checkpoint is paused, not parked: `<copy>/.queue/paused.json` keeps
its session, a comment on the ticket says when it resumes, and after the reset the script resumes that same session,
with its context and uncommitted work. Close the ticket to drop it.

## The Fable limit

The plan has a weekly window for Fable alone: the CLI's rate limit events name it `seven_day_overage_included`, and its
message says "Fable limit". Only Fable requests carry it, not a run on another model with the Fable advisor. It stops
Fable, not the account, so it is not one of the budget's windows.

- **The reading:** only a Fable run or a refusal updates it; no probe reads it. The page shows its share
  ([APP.md](APP.md), Accounts).
- **Two lines,** each the account's own (the page's Fable week meter), else a default in [limits.ps1](../limits.ps1)
  (`Get-FableLines`, `Test-FableOut`). `.queue/usage.json` keeps the window's last reading. Both hold until the reset.
  - **The design line** (`pickUp.seven_day_overage_included.design`, 90 %): no new Fable run starts on the account, so
    no dispatcher gives a worker on it a `design` ticket, and the Queue tab gives the reason. A PR's job of a `design`
    ticket still runs on Fable. The line is below the stop line, so the Fable runs in flight end under it and the
    advisor goes on all week.
  - **The stop line** (`stopAt.seven_day_overage_included`, 98 %): no new session on the account gets the advisor, and
    a PR's job of a `design` ticket starts on `afterFable`. A session keeps the advisor it started with. The design line
    is never above the stop line. A refusal for the Fable limit writes a reading of 100 %.
- **A ticket that no run began** goes back to the queue, for a worker whose account has Fable.
- **A run cut off by it:** the script resumes the same session at once on `afterFable` (Models), with an instruction in
  the job's message. The run decides whether the decisions that the ticket is on Fable for are made. If they are, it
  finishes and names both models in its PR. If not, it pushes its work, posts a handoff comment with the decisions still
  open, writes `handoff.md` in its queue folder and ends without a PR. The script then puts the ticket back in the
  queue, and a worker whose account has Fable starts it fresh from the comment.
- **A PR's job** (answers, rebase) goes on with `afterFable`: the PR already holds the ticket's decisions.

## An account that is out

An account is out when it takes no runs: a subscription that ends, a sign-out while a ticket works. The fact is the
account's, not a ticket's: `.queue/out.json` holds it for every worker and for the page, per account the kind, the
service's text and the time of the last test.

- **Kinds** (`Get-Refusal` in [limits.ps1](../limits.ps1), checked with real result lines): `login` (the account is
  signed out), `subscription` (a payment past due, a subscription that ended) and `start` (a run did no work and its
  first request failed, for a cause the text does not name: the service is down, a wrong model name). `start` catches
  every wording the list does not know.
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
  resumed run are parked. The Fable limit has its own rules.
- **Not an account's failure:** a run that ended before its first request (a session to resume that is gone) is its own
  failure and is parked.
- **The run:** a run that did work, or a PR's job, is held with its session (`paused.json`, `LoggedOut`), without a
  comment. A ticket that no run began is not held.
- **The worker:** it starts no run and takes no ticket. Its tickets that no run holds and that have no PR go back to the
  queue, for a worker on another account (`Remove-Claims`), so the ticket and its areas do not wait with the account.
- **The test:** every 10 minutes, and within 30 seconds after the folder's login changes (a sign-in), a worker sends the
  account a probe: one word from Haiku, which costs nothing when refused. When the account answers, the record goes, a
  held run resumes its session and the worker takes tickets again.
- **A switch of account:** within 30 seconds the worker drops a run held for the old account and starts its ticket
  fresh on the new one. A session cannot follow to another login.
- **What the owner does:** sign the account in again, renew the subscription, or give the worker another account (the
  page, Accounts and the worker's card).

## The owner's pause

A run that ends at its checkpoint for a pause (`stop.md`) keeps its session the same way: the script compacts it at
once, holds the ticket (`paused.json`, `Stopped`) without a comment, and resumes the same session when the owner sets
the worker active and the account takes an S ticket. Nothing is kept after "Pause now" (the process ends), after a run
that ended with an error, or for a disabled worker: that ticket starts fresh from its handoff comment. A run held at a
checkpoint (a pause or a stop line) also starts fresh if the owner moved the worker to another account meanwhile
(`Get-Hold` in [limits.ps1](../limits.ps1)).

## Plugins

A worker's environment comes from the project's plugins ([PLUGINS.md](PLUGINS.md)). The worker script calls `Start`
before each look for a job, `GetRun` and `Start` for another repo's checkout before a run, and `EndRun` after it.
A `Start` or `GetRun` that throws starts no run: the worker's card shows the error, and the worker tries again at its
next look. With no plugin, a run gets no MCP server and only the base's tools.

## Working a job

The run follows [PLAYBOOK.md](../PLAYBOOK.md), then each plugin's playbook, then the project's own (`playbook` in
`scriptorium.json`). Before each run, the worker script copies the first two into `.queue/playbooks` of the worker's
copy and names them in the run's first message; the project's own the run reads from `origin/main`. A run gets no
folder of Scriptorium or of a plugin, so it cannot change the code that runs it.
