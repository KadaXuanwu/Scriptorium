# The page

One web page shows the queue ([QUEUE.md](QUEUE.md)) to the owner: which ticket each worker has, what is unclear, what is
left and what it costs. The owner never manages the workflow there: the scripts do. On a phone it installs to the home
screen like an app. Its name is Scriptorium. Its icon is drawn in `app/icon.svg`, which also says how to export the
PNGs. The home screen gets the tile, because a home screen gives a picture a background of its own. The browser tab
and the page show the mark alone, with no background: `mark-on-light.png` in the light colour scheme and
`mark-on-dark.png` in the dark one.

- **Address:** `http://127.0.0.1:<port>` on the PC (`port` in `scriptorium.json`, 8770 when left out). On the owner's
  own devices: `https://<the PC's Tailscale name>` for the first project on the PC, and the same with a port from 8443
  up for each later one (Setup).
- **Code:** `app/server.ps1` (the logon task `Scriptorium <name> app`), `app/state.ps1` (the snapshot, the owner's
  choices turned into queue changes, and the pushes, checked by `app.test.ps1`), `app/web/` (the page: plain HTML, CSS
  and JS, no build step).
- **Log:** `.queue/app.log` in the main checkout.

## Shape

| Part | What | Uses a model |
| ---- | ---- | ------------ |
| GitHub | The record of the work: tickets, questions and answers, PRs | no |
| Queue files | The live state in `.queue/` (main checkout and copies), written by the scripts and the runs (Data) | no |
| Server | Reads both, serves the page and one snapshot (`/api/state`), does the owner's actions (`/api/action`), shows a run's steps (`/api/log?worker=N`), sends pushes. It listens on localhost only. It reads GitHub once a minute in a background job and the local files every 10 s. An action's GitHub writes also run in a background job, so a slow GitHub delays only that action's answer, never the page | no |
| Tailscale | Tailscale Serve puts the server on the owner's devices with a certificate, at an address of its own for each project (Setup); nothing is open to the internet | no |
| ntfy | Pushes to the phone; a tap opens the page on that project and tab | no |

No chat between agents: the scripts coordinate the runs, and a run reads only its own ticket. The server, the page and
the pushes use no model (except an account's Ping): every choice below is a script's.

## The page

One fixed viewport: the page itself never scrolls, so nothing moves when a scrollbar comes or goes. Each list scrolls
in its own pane. The title's line is as high as a button on every tab. The cards of one row (Workers, Accounts) share
their row lines, so each part and each button sits at the same height in each card. A card always has the same parts in
the same order; text that comes and goes has a line of its own. The tabs are a rail on a wide screen, a rail of icons on
a tablet, and a bar at the bottom on a phone.

**Pull down to refresh.** With the list at its top, a drag down on a touch screen brings a round mark from the top
edge. It turns blue after 110 px, and letting go there loads the page again: new code and a fresh state.

Each tab with a count shows it also at 0: Workers the workers with a run in flight, Accounts the accounts in use that
are not out, Questions the blocking questions (else the others), Queue the queued tickets and stuck runs. A count is red
when something there needs the owner: a worker's script down, an account out, a blocking question, a stuck run. A state
is an icon and a word, never colour alone. The browser tab's title carries the blocking questions before the name and
the working workers after it: "(1) Scriptorium · 2 working".

### Workers

**Worker status.** A worker has one of three statuses, on a switch that is always clickable:

| Status | Means |
| ------ | ----- |
| Active | Takes tickets when it can. A worker at its usage limit, at its account's stop line or whose account is out stays active |
| Paused | Takes none, and keeps its ticket. A run that ended at its checkpoint for the pause keeps its session too, compacted ([QUEUE.md](QUEUE.md), The owner's pause) |
| Disabled | Takes none, and its ticket is free: other workers take its PRs, and its ticket without a PR goes back to the queue |

Pause and Disable ask how the run in flight ends: **Now** (its process ends; work since the last checkpoint push is
lost), **Next checkpoint** (it saves its work, then stops; after a pause its session is kept and resumes) or **After the
ticket**. A worker with no run changes at once. The status stays Active until the run has ended that way; the switch
marks the target, and a line says "Pauses after the ticket". Active discards a pause or a disable that has not happened
yet.

What a worker does now is a line under its name: Working (or applying answers, rebasing), Usage limit with the reset
time, Resumes within a minute, Account at its stop line, Free, the words of a plugin while it makes the environment
ready (the worker's state `opening`, for example a first import), Its environment failed (a plugin's hook threw; the
error is in Now), or Script silent (its state file is older than 15 minutes: the script is gone, even if its run still
works). When its account is out, the line names the cause and the next test: Account signed out, Subscription refused
or Runs do not start.

**Config,** beside Steps, opens the worker's config: a dialog with a row for each complexity. Each change saves at
once. On a phone a complexity has two lines: its switch and compact size, then its model and effort.

- **The switch** is this worker's (`workers.<id>.complexity`). Press it to switch the complexity off or on again. Off:
  this worker takes no new ticket of that complexity and leaves the answers and rebases of its PRs of it. A ticket
  already started goes on. While a complexity is off, the Config button counts the ones the worker takes. A worker
  that the settings give a model of its own (`model`, [QUEUE.md](QUEUE.md), Settings) names it on the switch.
- **Model and effort** are two lists: the models and the efforts of [models.json](../models.json). The pick is the
  same for every worker, is saved for this PC (`complexities.<name>.model`) and applies from the next run
  ([QUEUE.md](QUEUE.md), Models, The owner's pick). A pick that is not the base's shows the base's under it as
  Default. Pick the default pair again, and the PC follows `models.json` and `scriptorium.json` again.
- **Compacts near** is the compact size of the complexity in thousands of tokens ([CONFIG.md](CONFIG.md), The compact
  size). It is the same for every worker, is saved for this PC (`complexities.<name>.compactAt`) and applies from the
  next run. The Info tab shows it for each complexity.

Each card has two slots:

- **Now:** the ticket it holds, or Free. A run shows its tags and a progress bar: the time worked against the typical
  run of that size, with what is left and the typical cost. A run held at its usage limit keeps its bar, with a pause
  mark. Under it, the run's last checkpoint: done and next.
- **Next:** the ticket it takes when the slot is free, in the dispatcher's order: its own PR to answer or rebase, its
  own ticket, then the first queued ticket whose area is free and whose size its account takes now, one ticket for each
  worker. If the queue holds it back, it still shows the best one, with a lock and the reason. **Force** (the arrow)
  moves the next ticket into a free slot now, also a locked one: it writes that ticket's number to
  `.queue/force-<N>.json`, the worker takes it at its next poll (`Select-Forced`), and the run goes past the stop line
  and the pick-up limits.

**A ticket's tags** stand in one order on every tab: kind (your answers, a rebase, part), repo (only another repo than
the project's), areas, size, then the model and effort of its run (Now) or, for a ticket not started, its complexity
(Next, Queue).

**Add and remove.** The last tile of the list adds a worker; the cross at the top right of a card removes one. Each asks
first, in the page's one dialog.

- **Add a worker** asks for its account. The server gives it the lowest number that has no state file and no task,
  writes its settings entry (active, on that account) and its state file `setup`, so its card shows at once. A
  background job (`Install-Worker` in `tasks.ps1`) makes its copy `<main>-w<N>` (a copy that a removed worker left is
  used again), runs each plugin's `PrepareCopy` in it, makes the label `worker:<N>` in this repo and in each repo a
  `repo:` label names, registers its logon task, and starts it. A setup that fails, or takes more than an hour, disables
  the worker, shows the reason in Now and sends a push. git in the job never asks for a sign-in: it fails instead.
- **Remove** takes only a disabled worker with no run in flight (`Get-RemoveRefusal`). The server ends its task and its
  loop (`Uninstall-Worker`), then deletes its state and force files, its settings entry, its control entries and its
  place in each account's uses. Its copy stays: it may hold work that no checkpoint pushed.

### Questions

One list of questions about the product, in two groups ([PLAYBOOK.md](../PLAYBOOK.md), What to ask):

- **Blocking:** a held PR (its Decision line; its Held questions under More) and a ticket's question (the worker's last
  comment).
- **Not blocking:** an open question (its default is built already) and a follow-up that asks.

Every question has one answer box and two buttons: **Accept default** and **Send answer**. The server decides what the
queue does (`Get-AnswerRoute`), and the answer goes on GitHub as the owner's comment:

| Question | Accept default | An answer |
| -------- | -------------- | --------- |
| Held PR | It merges as it is | Its worker applies the answer, then it merges |
| Ticket's question | Back to its worker with "take your default" | Back to its worker with the answer |
| Open question | Closed; nothing runs | Queued `P1`: a run changes the built default |
| Follow-up | Queued `P1`, or closed if its "Do this?" default is no | Queued `P1` with the answer; a bare "no" closes it |

**Pictures:** a question that shows a look carries screenshots of its choices. They live on the branch `shots-t<N>`.
The repo may be private, so the server fetches each one once with the owner's `gh` login and keeps it in `.queue/shots`
(`/api/shot`, which serves nothing but a picture of a shots branch).

### Queue

- **What is left:** the count of queued tickets, the sum of their typical run hours and of their typical cost.
- **Stuck:** a run that ended with no PR and no question, or a PR its run could not finish. Each shows why, from the
  end of the run's log (`Get-StuckReason`), and **Retry**, which gives it back to its worker. Nothing retries alone.
- **Up next:** the unclaimed tickets in dispatch order, each with its areas, size, complexity, typical time and cost,
  why it waits, and its priority.
- **On hold:** a ticket labelled `needs-owner` with no question on it.
- **Parked:** no priority; a priority queues one.

### Accounts

Per account: a status (Ready, At its stop line, Signed out, Subscription refused, Runs do not start, Not used), its
email and plan, the human uses on it (front desk, you), and a meter for each window. Under the week's meter, the
**Fable week**, where the account has a reading of it ([QUEUE.md](QUEUE.md), The Fable limit), with two handles: the
**D** handle is the design line, the other the stop line of the advisor.

**The meter** shows where the workers stop. The fill is the share used. The handle is the **stop line**: drag it to set
the share where this account's workers stop (`stopAt`). The hatched part right of it is what they leave.

**The pick-up limits.** Above the 5-hour meter stand three small handles, each under the letter of a ticket size: L, M
and S. Drag one to set the share from which this account's workers take no new ticket of that size (`pickUp`).

**The usage guards.** On the week's meter, each human use of the account (the front desk, the owner's own use) keeps room
left of the handle, in its colour. Under the meter each guard has a slider: its share of a whole week, from 0 % to 50 %
(`keep`). It keeps the part of that share for the time left.

On a touch screen a slider moves only after a hold of 0.3 s on its handle, so a scroll never moves one.

Also: **Sign in** (again) and **Ping**. The last tile adds an account: a dialog asks for its name and email, and the
sign-in starts on this tab. The cross on a card removes an account that nothing uses: its login is signed out, and its
folder stays.

- **The sign-in** is `claude auth login`, run by the server. The page shows its link: open it on any device, sign in as
  that account (not your own: the browser may already be signed in), and paste the code it shows.
- **Ping:** one Haiku reply of one dot, with no tools, settings, plugins or `CLAUDE.md`, about 770 tokens. It starts the
  account's 5-hour window now. It is the only action here that uses tokens.

### History

Recent merges in every repo; recent runs with model, duration and cost.

### Info

What the queue does and what to expect, for someone who does not know it, in plain sections: In short, What needs you,
How a ticket goes through, Who builds what, Complexities (a table with the model, effort, advisor and compact size of each complexity, the
project's own among them), Plugins (each active plugin's title, version and description, or "None: a plain git repo"),
Limits, In the background, GitHub and The tabs. Each value the owner sets links to the tab that sets it. Every setting
and reading comes from the snapshot; none is typed into the text, and no environment is named in it. **A change to a
queue rule changes this text in the same pull request.** The tab is drawn last, and a fault in it shows one line, not a
broken page.

**Estimates.** A typical run is the median of the finished whole-ticket runs of that size on that model, else of that
size on any model (`Get-Typical`): its wall time, and its cost in dollars at the API's price.

**An action shows at once.** The page changes the card as soon as the owner acts. The card then shows a turning ring
and its controls are greyed until a snapshot from the server confirms the action. If the server refuses, the page takes
the change back and says why. The 10 s refresh redraws a list only when its content changed and no box or menu in it has
focus.

**With the PC off** (or Tailscale disconnected) the page still opens: it is kept on the device (`web/sw.js`), with the
last state it reached, greyed out under a banner.

Actions need the `X-Queue: 1` header, so no other website open in a browser can trigger them: a browser asks the
server first, and the server says yes only to the pages of this PC's projects (Projects).

## Projects

One app shows every project that Scriptorium runs on the PC. Each project keeps its own queue, workers and page
server ([README.md](../README.md), Limits); the page shows one project at a time.

- **The switch** is a list above every view, while the PC has two projects or more. A choice reloads the page on that
  project and stays on the device. So nothing of one project (a draft, an open dialog, a late answer) reaches
  another: both can have a worker 1.
- **How:** the page stays at its address and loads the other project's state, steps and pictures from that project's
  own server, and it sends the owner's actions there. A page on the PC uses the project's address on the PC; a page on
  a Tailscale device uses its Tailscale address (Setup). A project with no Tailscale address shows on the PC only.
- **The list** is in every snapshot (`name`, `projects`): the server takes it from the logon tasks of the pages
  (`Get-PcProjects`, [tasks.ps1](../tasks.ps1)) and from Tailscale's mapping, at its start and every five minutes.
- **The guard:** a server answers the page of another address only when that address is in its own list
  (`Get-PageOrigin`, [state.ps1](../app/state.ps1)): an exact match, never the asking page's own word. Every other
  site's page stays out, as before.
- **A push** opens the app with its project named (`?project=<name>`), at the PC's plain Tailscale address when a
  project has it: the phone app is there. Without Tailscale it opens the project's own address on the PC.
- **A project whose server does not answer** shows its last state greyed out under the banner, which names it. The
  switch still works.
- The last state on the device is kept for each project.
- **Why not one address with a path for each project:** Windows gives a second program a path of a port only while no
  program holds the root of that port, and the reverse ("Access is denied", measured 2026-11-18). The first project's
  page is at the root of its port, and the phone app, the docs and every check use that address. So each project
  keeps its own address, and its Tailscale address must stay: the app loads the project from there.

## Notifications

Sent when the server sees: a new blocking question (high), a stuck run, a worker at its usage limit and resumed, a run
that stopped at its account's stop line, a worker whose account is out or whose runs do not start (one push, not one
for each test), a failed setup, a script down (high), no worker active ("safe to switch off"), the queue empty with every
worker free, and merges (low). A resume after the owner's pause sends none. The texts are short and carry no ticket
content, since ntfy's public server relays them. The topic is `ntfy.topic` in `.queue/settings.json` (setup makes a
random one); `ntfy.server` overrides `https://ntfy.sh`.

## Data

- **Worker state** (`.queue/worker-<N>.json`): the state its script wrote (idle, running, paused for a limit or a login,
  signedout, over-budget, drained, stopped, disabled, opening with a plugin's words in `report`, error with the hook's
  error), or the server's for a worker it sets up (setup, setup-failed with its error); the job (ticket, title, repo,
  kind, PR, model, effort, start or the time worked so far, log), its copy and queue folder, and its account's budget
  for each window. Refreshed every poll, and every 30 s while running. `Get-WorkerStatus` turns these, the control and
  `enabled` into the status and what the worker does.
- **Control** (`.queue/control.json`, written by the server only): `workers.<N>` is `drain` (no new job; the run
  finishes) or `stop` (no new job; the run wraps up at its next checkpoint, and a run that waits for its limit is held).
  `disable.<N>` marks a worker to disable after its ticket. Paused is a control entry; disabled is
  `workers.<N>.enabled: false` in the settings and a `stop` entry too. The worker script reads the two at different
  moments of its loop, so a status change never passes through a moment with neither.
- **History** (`.queue/history.jsonl`): each run's `duration` in seconds of wall time (`wall: true` marks it).
- **Progress** (`<copy>/.queue/progress.json`): the run's last checkpoint, `{ticket, done, next}`.

## Setup

`setup.ps1` registers the task, makes the ntfy topic and runs `tailscale serve`. The owner's part, once: Tailscale
signed in on the PC and the phone (the same account), Serve allowed on the tailnet (the link that `tailscale serve`
prints the first time), the ntfy app subscribed to the topic, and the page added to the phone's home screen. The
home screen is for the first project of a PC only: a later one shows in the same app (Projects).

**The address on Tailscale.** A PC has one Tailscale name, and each project's page needs an address of its own. Setup
reads what Tailscale serves (`tailscale serve status --json`) and never changes an address that is there:

- The first project gets the plain address: `tailscale serve --bg <port>`, at `https://<name>`.
- A later project gets the first free port from 8443 up: `tailscale serve --bg --https=8443 <port>`, at
  `https://<name>:8443`. Not the page's own port: Windows keeps that port for the page's server alone.
- A page that has an address keeps it. Setup prints the address at its end.

The server reads the addresses from the same mapping (`Get-ServeUrl`, [project.ps1](../project.ps1)), at its start
and every five minutes. The one app uses them to show each project (Projects). To take an address away:
`tailscale serve --https=<its port> off` (443 for the plain one).
