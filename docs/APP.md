# The page

One web page shows the queue ([QUEUE.md](QUEUE.md)) to the owner: which ticket each worker has, what is unclear, what is
left and what it costs. The owner never manages the workflow there: the scripts do. On a phone it installs to the home
screen like an app. Its name is Scriptorium. Its icon is drawn in `app/icon.svg`, which also says how to export the
PNGs. The home screen gets the tile, because a home screen gives a picture a background of its own. The start screen
of the installed app shows that tile too, on the manifest's `background_color`: this is the tile's own colour, so
the tile shows no edge there. The browser tab
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

**Config,** beside Steps, opens the worker's config: a dialog with a switch for each complexity. The switch is this
worker's (`workers.<id>.complexity`) and saves at once. Press it to switch the complexity off or on again. Off: this
worker takes no new ticket of that complexity and leaves the answers and rebases of its PRs of it, and the switch
counts those PR jobs. A ticket already started goes on. While a complexity is off, the Config button counts the ones
the worker takes. The model, the effort, the compact size and the advisor are the same for all workers of a project:
Details sets them.

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

- **Add a worker** asks for its account, and for its project while the PC has two or more: the page sends it to the
  server of that project. The server gives it the lowest number that has no state file here and no
  task in any project of the PC (a worker's number is the PC's: two projects never have a worker of one number),
  writes its settings entry (active, on that account) and its state file `setup`, so its card shows at once. A
  background job (`Install-Worker` in `tasks.ps1`) makes its copy `<main>-w<N>` (a copy that a removed worker left is
  used again), runs each plugin's `PrepareCopy` in it, makes the label `worker:<N>` in this repo and in each repo a
  `repo:` label names, registers its logon task, and starts it. A setup that fails, or takes more than an hour, disables
  the worker, shows the reason in Now and sends a push. git in the job never asks for a sign-in: it fails instead.
- **Remove** takes only a disabled worker with no run in flight (`Get-RemoveRefusal`). The server ends its task and its
  loop (`Uninstall-Worker`), and every process that still runs from its copy: its editor is not in the loop's process
  tree (`Test-CopyProcess`). Then it deletes its state and force files, its settings entry, its control entries and its
  place in each account's uses. Its copy stays: it may hold work that no checkpoint pushed.

**The project choice.** While the PC has two projects or more, the project mark after "Worker N" is a choice. A pick
asks first, then moves the worker to that project with its number. Its account, its status (active, paused or
disabled) and its complexity switches stay. The account, `enabled` and the switches are the PC's settings, and the
move does not change them; a pause is in the old project's `control.json`, and the server carries it over. Its copy
of the old project stays on the PC. It has no state file there, so the other workers of the old project take its open
PRs, and its claimed tickets with no PR go back to the queue (`Get-NextJob`, [worker.ps1](../worker.ps1)). The choice
is greyed while the worker has a run or a ticket, or its setup runs.

- **Refused** (`Get-MoveRefusal`), each before the first change: a setup that still runs; a run in flight (pause or
  disable it, then move it); a held run or a disable after its ticket (disable it first: Disabled drops the held run and
  gives its ticket back to the queue). A worker whose GitHub bot (`ghConfigDir`, signed in) cannot push to the new
  project's repo is refused too: invite the bot to the repo first. A bot folder that is not signed in is not checked:
  the worker then writes as the owner.
- **The server** of the new project does the whole move (`move-worker`). It finds the old project by its name among
  the PC's logon tasks, so nothing from the request becomes a path. Then, in this order: it writes the worker's
  control entry here from its status (`Get-CarriedStatus`), so the new script never finds a paused worker active; it
  writes the state file `setup`; it ends the old task, loop and copy processes (`Uninstall-Worker`); it deletes the old
  state and force files and every entry of the worker in the old `control.json`; then it starts the setup job of Add a
  worker, which makes its copy `<main>-w<N>` of the new project at its first move there. If the worker cannot leave
  its old project, the server takes the state file here away again and says why.
- **No entry stays in the old `control.json`.** There a `disable` mark of a worker with no state file is due
  (`Get-DueDisables`). The old project's server would then write `enabled: false` in the PC's settings and disable the
  worker in its new project.

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
**D** handle is the design line, the other the stop line of the Fable advisor ("Fable advisor stops at").

**The meter** shows where the workers stop. The fill is the share used. The handle is the **stop line**: drag it to set
the share where this account's workers stop (`stopAt`). The hatched part right of it is what they leave.

**The pick-up limits.** Above the 5-hour meter stand three small handles, each under the letter of a ticket size: L, M
and S. Drag one to set the share from which this account's workers take no new ticket of that size (`pickUp`).

**The usage guards.** On the week's meter, each human use of the account (the front desk, the owner's own use) keeps room
left of the handle, in its colour. Under the meter each guard has a slider: its share of a whole week, from 0 % to 50 %
(`keep`). It keeps the part of that share for the time left.

On a touch screen a slider moves only after a hold of 0.3 s on its handle, so a scroll never moves one.

Also: **Sign in**, only while the account is signed out, and **Ping**. To change an account's login, remove the account
and add one. The last tile adds an account: a dialog asks for its name and email, and the
sign-in starts on this tab. The cross on a card removes an account that nothing uses: its login is signed out, and its
folder stays.

- **The sign-in** is `claude auth login`, run by the server. The page shows its link: open it on any device, sign in as
  that account (not your own: the browser may already be signed in), and paste the code it shows.
- **Ping:** one Haiku reply of one dot, with no tools, settings, plugins or `CLAUDE.md`, about 770 tokens. It starts the
  account's 5-hour window now. It is the only action here that uses tokens.

### History

Recent merges in every repo; recent runs with model, duration and cost.

### Details

The settings that are the same for all workers of a project, then the info text. An older address `#info` opens this
tab. No push opens it.

**The settings:** one block for each project, in the order of the projects. With one project on the PC the block has no
head. Each change saves at once in the project's `.queue/settings.json` ([QUEUE.md](QUEUE.md), Settings) and counts
from the next run. A run in progress or on hold keeps its model, its effort and its advisor. A block holds:

- **The head:** the project's mark and its colour (`color`). The colour field picks one; Default colour goes back to
  the colour from the project's name. The mark, a worker's project choice and the Queue's select, set to the project, show this colour.
- **A row for each complexity,** with its name and description:
  - **Model and effort** are two lists: the models and the efforts of [models.json](../models.json)
    (`complexities.<name>.model`; [QUEUE.md](QUEUE.md), Models, The owner's pick). A pick that is not the base's shows
    the base's under it as Default. Pick the default pair again, and the project follows `models.json` and
    `scriptorium.json` again.
  - **Compacts near** is the compact size of the complexity in thousands of tokens (`complexities.<name>.compactAt`;
    [CONFIG.md](CONFIG.md), The compact size).
  - **Advisor** is a switch (`complexities.<name>.advisor`), and the list beside it is the effort of a run that has
    no advisor left (`complexities.<name>.advisorFallback`): an effort, or the same effort. A value that differs from
    the files shows theirs under it as Default. A complexity that runs on the advisor's own model has no advisor: the
    row says so.
- **The advisor's model** (`advisor.model`): a list of the models of `models.json`, with the default under it when the
  pick differs.
- **A line when the settings set `model`:** that model goes over every pick of the block, for every run.

On a phone a complexity has three lines: its name and compact size, its model and effort, then its advisor.

**The info:** what the queue does and what to expect, for someone who does not know it, in plain sections: In short,
What needs you, How a ticket goes through, Who builds what, Complexities, Plugins (each active plugin's title, version
and description, or "None: a plain git repo"), Limits, In the background, GitHub and The tabs. Each value the owner sets
links to the tab that sets it. Every setting and reading comes from the snapshot; none is typed into the text, and no
environment is named in it. **A change to a queue rule changes this text in the same pull request.** The settings and
the text are drawn last, each on its own, and a fault in one shows one line, not a broken page.

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

One page shows every project that Scriptorium runs on the PC, with no switch between them. Each project keeps its own
queue and page server ([README.md](../README.md), Limits); the page loads them all and shows them together.

- **Workers:** the workers of every project stand side by side, in the order of their numbers.
- **Questions, Queue and History:** one list of every project. In the Queue a project's own order stays, and between
  the projects the priority decides. The Queue and History have a select with All and each project, each with its count
  of queued tickets or merged PRs: a project shows that project's lists and totals. The two tabs share the choice, and it
  stays on the device.
- **The mark:** while the PC has two projects or more, each worker, question, ticket and history row carries its
  project's name, in its project's colour (Details). A worker's mark is its project choice (Workers, The project
  choice).
- **Accounts** are the PC's: one list, with the workers of every project on it. **Details** has the settings of each
  project in a block of its own, and one info text: the common part once, and the plugins for each project.
- **How:** the page stays at its address and loads each other project's state, steps and pictures from that project's
  own server, and it sends each action to the server of the item's project. A page on the PC uses the project's
  address on the PC; a page on a Tailscale device uses its Tailscale address (Setup).
- **An item belongs to its project.** Two projects can have a ticket 12 or a question of the same key. The
  page draws, looks up and changes an item in its own project's snapshot only (`within`, `act`,
  [app.js](../app/web/app.js)), so nothing of one project reaches another.
- **The list** of projects is in every snapshot (`name`, `projects`): the server takes it from the logon tasks of the
  pages (`Get-PcProjects`, [tasks.ps1](../tasks.ps1)) and from Tailscale's mapping, at its start and every five minutes.
- **The guard:** a server answers the page of another address only when that address is in its own list
  (`Get-PageOrigin`, [state.ps1](../app/state.ps1)): an exact match, never the asking page's own word. Every other
  site's page stays out, as before.
- **A push** opens the app on its tab, at the PC's plain Tailscale address when a project has it: the phone app is
  there. Without Tailscale it opens the project's own address on the PC.
- **A project that the page cannot load** keeps its last state on the page, and a line above the views names it: its
  server does not answer, or it has no Tailscale address and the page is on a Tailscale device.
- The last state on the device holds every project.
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
home screen is for the first project of a PC only: a later one shows in the same app, beside the first (Projects).

**The address on Tailscale.** A PC has one Tailscale name, and each project's page needs an address of its own. Setup
reads what Tailscale serves (`tailscale serve status --json`) and never changes an address that is there:

- The first project gets the plain address: `tailscale serve --bg <port>`, at `https://<name>`.
- A later project gets the first free port from 8443 up: `tailscale serve --bg --https=8443 <port>`, at
  `https://<name>:8443`. Not the page's own port: Windows keeps that port for the page's server alone.
- A page that has an address keeps it. Setup prints the address at its end.

The server reads the addresses from the same mapping (`Get-ServeUrl`, [project.ps1](../project.ps1)), at its start
and every five minutes. The one app uses them to show each project (Projects). To take an address away:
`tailscale serve --https=<its port> off` (443 for the plain one).
