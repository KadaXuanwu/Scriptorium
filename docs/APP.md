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
| Server | Reads both, serves the page and one snapshot (`/api/state`), does the owner's actions (`/api/action`), shows a run's steps (`/api/log?worker=N`) and what a worker's copy holds (`/api/copy?worker=N`), sends pushes. It listens on localhost only. It reads GitHub once a minute in a background job and the local files every 5 s. A ticket that a worker's state names as in work counts as claimed before GitHub's reading shows its label, so it leaves the queue within 5 s. An action's GitHub writes also run in a background job, so a slow GitHub delays only that action's answer, never the page | no |
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

**Names.** A double-click on a worker's name, or Enter while the name has focus, opens a field over it: Enter or a
click elsewhere saves, Escape keeps the name. A worker's name is the page's only (`workers.<id>.name`, the PC's, so it
stays with a move); an empty one gives back "Worker N". Comments, pushes and dialogs keep the number. An account's name
changes the same way (Accounts).

**The coding tool.** Beside its name, each card names the coding tool that runs the worker's sessions: the one of its
account ([QUEUE.md](QUEUE.md), Settings, `accounts.<name>.provider`), by the provider plugin's title without
"Scriptorium for", in the colour and with the icon of its plugin's manifest where it has them
([PLUGINS.md](PLUGINS.md), Its manifest). The account select shows the account's name and lists the accounts of every tool, in a group for
each tool while the PC has more than one. An account of another tool changes the worker's tool: it starts again on
that tool before its next job. The server refuses that while the worker has a run in flight. A worker keeps its
account, and so its tool, when it moves to another project.

**Order.** A press on a card's empty space (not on a control or on text) and a drag move the card among the others:
with a mouse at once, on a touch screen after a short hold. The order is the PC's (`order.workers`, `order.accounts`
in the settings), so every device shows the same; a new worker goes last, after the others in the order of their
numbers. Account cards move the same way, and a renamed account keeps its place.

**No blocking** is a switch in the tab's head, beside All active and Pause all, for the days when the owner is not
there ([QUEUE.md](QUEUE.md), No blocking). It is violet while it is on. It is the PC's (`away`), so it shows the same
for every project, and the page's own project saves it. While it is on, no question holds a PR or a ticket: each goes
on with the worker's default and waits under Not blocking on Questions, and a stuck run gets one more try. When a
blocking question or a stuck run waits at the click, the page asks first: what waits goes on at once, and that cannot
be taken back.

**Worker status.** A worker has one of three statuses, on a switch that is always clickable:

| Status | Means |
| ------ | ----- |
| Active | Takes tickets when it can. A worker at its usage limit, at its account's stop line or whose account is out stays active |
| Paused | Takes none, and keeps its ticket. A run that ended at its checkpoint for the pause keeps its session too, compacted ([QUEUE.md](QUEUE.md), The owner's pause) |
| Disabled | Takes none, and its ticket is free: other workers take its PRs, and its ticket without a PR goes back to the queue. Once its run has ended, its editors close |

Pause and Disable ask how the run in flight ends: **Now** (its process ends; work since the last checkpoint push is
lost), **Next checkpoint** (it saves its work, then stops; after a pause its session is kept and resumes) or **After the
ticket**. A worker with no run changes at once. A pause of a worker whose run is held (at a usage limit, at its account's
stop line, or for its account) also changes at once, as Next checkpoint: that run has already stopped, and the pause
keeps it from resuming. It keeps its session and its ticket. To let a held run finish first, leave the worker active. The status stays Active until the run has ended that way; the switch
marks the target, and a line says "Pauses after the ticket". Active discards a pause or a disable that has not happened
yet.

A passive worker's Active reads **Passive** ([QUEUE.md](QUEUE.md), A passive worker): it takes a new ticket only at the
arrow or a Now, and its plugins open its environment only for a run. The switch is in its Config.

What a worker does now is a line under its name: Working (or applying answers, rebasing), Usage limit with the reset
time, Resumes within a minute, Account at its stop line, Free, the words of a plugin while it makes the environment
ready (the worker's state `opening`, for example a first import), Its environment failed (a plugin's hook threw, or a
plugin that `scriptorium.json` names is not installed yet; the error is in Now), or Script silent (its state file is older than 15 minutes: the script is gone, even if its run still
works). When its account is out, the line names the cause and the next test: Account signed out, Subscription refused
or Runs do not start.

**Config,** beside Steps, opens the worker's config: a dialog with a switch for each complexity. The switch is this
worker's (`workers.<id>.complexity`) and saves at once. Press it to switch the complexity off or on again. Off: this
worker takes no new ticket of that complexity and leaves the answers and rebases of its PRs of it, and the switch
counts those PR jobs. A ticket already started goes on. While a complexity is off, the Config button counts the ones
the worker takes.

**Active or Passive,** the first row, is the worker's kind (`workers.<id>.passive`) and saves at once. On a passive
worker the complexity switches do not count, so they are names only.

**Dialogs** close at their cross, at Escape and at a press beside them.

**The mapping** is the rest of the config: how this worker runs each complexity ([QUEUE.md](QUEUE.md), Models, A
worker's mapping). Each change saves at once in the PC's settings (`workers.<id>.mapping`) and counts from the
worker's next run. A run in progress or on hold keeps its model, its effort and its advisor.

- **Mapping,** the list at the top: Its own, or Same as another worker on the same coding tool, in any project. A
  worker whose own links lead back to this one is not in the list. A link takes the worker's own picks for this tool
  away, with no question. Its own again, the worker starts from the picks it ran on.
- **A linked worker** shows the other worker's values as plain text, with no field to press. Its switches stay its
  own, and stay buttons.
- **A row for each complexity,** with its switch, its name and an (i) button that shows its description:
  - **Model and effort** are two lists: the models and the efforts of the coding tool's `models.json`
    (`complexities.<name>.model`). The Effort list is the picked model's own where it has one; a new model whose
    list lacks the effort shown takes its own default. A pick that is not the base's shows the base's under it as Default. Pick the
    default pair again, and the worker follows `models.json` and `scriptorium.json` again.
  - **Compacts near** is the compact size of the complexity in thousands of tokens (`complexities.<name>.compactAt`;
    [CONFIG.md](CONFIG.md), The compact size).
  - **Advisor** is a switch (`complexities.<name>.advisor`), and the list beside it is the effort of a run that has
    no advisor left (`complexities.<name>.advisorFallback`): an effort, or the same effort. A value that differs from
    the files shows theirs under it as Default. A complexity that runs on the advisor's own model has no advisor: the
    row shows none.
- **The advisor's model** (`advisor.model`): a list of the models of `models.json`, with the default under it when the
  pick differs.
- **Only what the worker's coding tool has:** with no efforts, no compact size or no advisor in its `models.json`,
  the rows show no field for it. A tool with none of the three has a model for each complexity and nothing else.
- **Two groups:** the rows the worker has in every project come first. A project's own complexities stand apart
  below them, under "Only in" and the project's mark: the worker has these rows only in this project, and their picks
  wait here when it moves away. When the worker follows a worker of another project, these rows stay its own.
- **A line when the settings set `model`:** that model goes over the mapping, for every run of the project on its
  default coding tool.

On a phone a complexity has three lines: its name and compact size, its model and effort, then its advisor.

Each card has two slots:

- **Now:** the ticket it holds, or Free. A run shows its tags and a progress bar: the time worked against the typical
  run of that size, with what is left and the typical cost. A run held at its usage limit keeps its bar, with a pause
  mark. Under it, the run's last checkpoint: done and next.
- **Next:** the ticket it takes when the slot is free, in the dispatcher's order: its own PR to answer or rebase, its
  own ticket, the ticket that **Queue next** gave it (Queue), then the first queued ticket whose area is free and
  whose size its account takes now, one ticket for each worker. If the queue holds it back, it still shows the best
  one, with a lock and the reason. A ticket of Queue next is tagged `queued next`, in a slot with a solid border.
  On a passive worker a new ticket says "waits for the arrow": the worker takes it only then.
- **Force** (the arrow in the Next slot) gives the worker that ticket past what holds it back: its blockers, the
  areas, the pick-up limits and the stop line ([QUEUE.md](QUEUE.md), Queue next).
  - A free worker takes it at its next poll, with no question, also a locked ticket: the card names the lock.
  - For a worker in a run the page asks: **After this run** (the run goes on, and the ticket is the worker's next
    job) or **Replace now** (the run ends for it at its next checkpoint: [QUEUE.md](QUEUE.md), Now). For a held
    run the first waits until that run resumes and ends. The second frees a run held at the workers' stop line within
    a minute; a run that a limit cut off gets only the first.
  - A PR's job is forced only into a free slot.
  - While the arrow is off, its tooltip says why: the worker is paused, its status is changing, it cannot run now, or
    its slot is not free.
  - The server writes a ticket to `.queue/next-<N>.json` with `force`, for Replace now to `.queue/force-<N>.json`
    with `now`, and a PR's job to the force file.
  - The slot then says when the worker takes the ticket. **Cancel** takes a Force or a Now back. On a ticket of Queue
    next the arrow stands in the slot's bottom right corner, and a small cross on the border at its top right corner takes the
    Queue next back, forced or not.

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
  place in each account's uses. Its copy stays: it may hold work that no checkpoint pushed, and a new worker of that
  number uses it again. The owner can delete it in the same dialog (Delete the copy).
- **Delete the copy.** The Remove dialog and the dialog of the project choice each have a box, not ticked: "Delete
  `<main>-w<N>` from the PC too". The delete is for good: nothing goes to the recycle bin.
  - **What the copy holds.** The text beside the box names what the copy holds that GitHub does not have
    (`/api/copy`; `Get-CopyWork` in [tasks.ps1](../tasks.ps1), checked by `tasks.test.ps1`): the files changed and not
    committed, the stashes, the commits on no branch, and each branch with commits that were not pushed. A branch
    whose GitHub branch is gone does not count: its PR is merged or closed. A commit whose change GitHub's branch has
    does not count: another worker rebased the branch. The check does not see a commit made after the last push of a
    branch that is gone on GitHub. The owner decides: the box works also when the copy holds work.
  - **What goes.** Only the worker's copy of its project, with the files that git ignores: its `.queue` with the run
    logs, and what a plugin added (a Unity `Library`). A link in the copy goes, never what it points at. The worker's
    checkouts of other repos (`<Name>-w<N>`; [PLAYBOOK-repo.md](../playbook/PLAYBOOK-repo.md)) stay.
  - **How.** The server deletes the copy last, when the worker is gone or has left the project (`Remove-Copy`). It
    first renames the copy to `<main>-w<N>.deleting-<time>`: the name is free at once for a new worker, and Windows
    refuses the rename while a program still uses a file in the copy. Then a background job deletes the folder; a copy
    of a large project takes minutes. The server does not restart on new code while the job runs. A server that
    starts deletes each folder of this name beside its main checkout: a restart or a shutdown cut that delete.
  - **When it fails.** If a program still uses the copy after five tries, a second apart, the copy stays as it is.
    The Remove or the move is done all the same, and the page says so in a dialog. If the job fails, the log has the
    reason and the owner gets a push.
  - **Limits.** The dialog shows no size: the count takes too long on a large copy. A copy whose worker is gone has no
    card, so the page cannot delete it: delete that folder by hand. After a move, the server of the new project
    deletes the old copy. If the server of the old project starts in that time, it deletes the same folder too, and
    one of the two can send a push that the delete failed though the folder is gone.

**The project choice.** While the PC has two projects or more, the project mark after "Worker N" is a choice. A pick
asks first, then moves the worker to that project with its number. Its account, its status (active, paused or
disabled), its complexity switches and its mapping stay. The account, `enabled`, the switches and the mapping are the PC's settings, and the
move does not change them; a pause is in the old project's `control.json`, and the server carries it over. Its copy
of the old project stays on the PC, unless the owner ticks the box in the dialog (Add and remove, Delete the copy). It
has no state file there, so the other workers of the old project take its open PRs, and its claimed tickets with no PR
go back to the queue (`Get-NextJob`, [worker.ps1](../worker.ps1)). The choice is greyed while the worker has a run or
a ticket, or its setup runs.

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
  worker, which makes its copy `<main>-w<N>` of the new project at its first move there. With the owner's tick, it
  deletes the copy of the old project last. If the worker cannot leave its old project, the server takes the state
  file here away again and says why.
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

**Pictures:** every question has a banner, a screenshot of what it is about: its first picture that stands alone on a
line. The card shows it on top, cut to 3:1 around its middle, square-cornered under two crop marks at its top (blue, red on a blocking question); its foot fades fast into the card, and the card's head sits on the faded part. A question about a look also carries a
screenshot of each choice: list lines that stand together and hold a picture show as rows, the picture whole (16:9) on
most of the row and the text beside it, or under it in a narrow card. The page lays this out for every count of
pictures; the question's text says nothing about layout (`PLAYBOOK-pictures.md`). A tap on a picture opens the viewer:
one picture at a time in one fixed box, and a tap, an arrow key or a swipe steps to the next choice, so two choices
compare in place. A question from before the rule has no banner, and its card starts with its head. The pictures live
on the branch `shots-t<N>`.
The repo may be private, so the server fetches each one once with the owner's `gh` login and keeps it in `.queue/shots`
(`/api/shot`, which serves nothing but a picture of a shots branch).

### Queue

- **What is left:** the count of queued tickets, the sum of their typical run hours and of their typical cost.
- **Stuck:** a run that ended with no PR and no question, or a PR its run could not finish. Each shows why, from the
  end of the run's log (`Get-StuckReason`), and **Retry**, which gives it back to its worker. Nothing retries alone.
- **Up next:** the unclaimed tickets in dispatch order, each with its areas, size, complexity, typical time and cost,
  why it waits, its priority and **Next**.
- **Next** (on a ticket of Up next, also a blocked one): one worker gets the ticket as its next new one
  ([QUEUE.md](QUEUE.md), Queue next). It forces nothing: the ticket waits there as it would in the queue, and the
  arrow on the worker's card forces it (Workers).
  - The server picks the worker (`Select-NextWorker`). It must be active or paused with no change of status to come, with a
    script that runs and an account that takes runs. Room on its account is no condition, nor are its complexity
    switches.
  - Of those, the active workers go first (a paused one keeps the ticket until the owner sets it active), then the
    workers with the ticket's complexity on. Among them the first is a worker whose ticket in
    work holds an area of this one. Then a free worker, then the
    account with the most room in its shortest window, then in its longest, then the run that started last.
  - The page asks first. Its text is the worker's status (free, the run it is in, a held run, or at its usage limit)
    and the areas that another ticket still holds.
  - With two such workers or more, the dialog lists them, the server's pick first, each with the model and effort it
    would run the ticket on (its own mapping). The owner can choose another one; the text is then that worker's.
  - With no such worker the button is off, and its tooltip says why.
  - A ticket that a worker has, by Queue next or by a Now, shows **Cancel** in the button's place.
  - A pause or a disable of the worker ends a Now that still waits, and a Queue next.
- **On hold:** a ticket labelled `needs-owner` with no question on it.
- **Parked:** no priority; a priority queues one.
  - **The cross** drops one. The page asks first, and names each open ticket whose `Blocked by` line names it: such a
    ticket stops waiting. The ticket gets the comment "Dropped by the owner." and closes as not planned. A reopen on
    GitHub parks it again.
  - A ticket that left Parked meanwhile (queued, claimed) is refused.

### Accounts

Per account: a status (Ready, At its stop line, Signed out, Subscription refused, Runs do not start, Not used), its
email (the first three letters of its name, the rest hidden) and plan, its coding tool, and a
meter for each of the provider's windows
([PLUGINS.md](PLUGINS.md), A provider). Under the last one stands each window of some models that the account has a
reading of ([QUEUE.md](QUEUE.md), A model's limit), with two handles: the one under a letter is the start line, the
other the stop line for those models as advisors ("Advisor stops at").

**The coding tool.** An account is one coding tool's ([QUEUE.md](QUEUE.md), Settings, `accounts.<name>.provider`),
and its card names the tool beside the plan, with that tool's windows. A project's page gives the accounts of every
tool it has a provider for (the snapshot's `tools`: each one's title, features and windows). The list is every
project's, each account once: the project that gave an account reads its login and takes its actions. Sign in and
Ping show only on the card of a tool that has them, and the last tile only where some tool has a sign-in. The add dialog
says how the picked tool signs in: from this page, or from a terminal with the tool's own command.

**The meter** shows where the workers stop. The fill is the share used. The handle is the **stop line**: drag it to set
the share where this account's workers stop (`stopAt`). The hatched part right of it is what they leave.

**The pick-up limits.** Above the meter of a window that has them stand three small handles, each under the letter of
a ticket size: L, M and S. Drag one to set the share from which this account's workers take no new ticket of that size (`pickUp`).

**The usage guards.** On the meter of the window that keeps a reserve (the provider marks it with `keep`), each human
use of the account (the front desk, the owner's own use) keeps room left of the handle, in its colour. Under the meter
each guard has a slider: its share of that whole window, from 0 % to 50 % (`keep`). It keeps the part of that share for the time left.

On a touch screen a slider moves only after a hold of 0.3 s on its handle, so a scroll never moves one.

Also: **Sign in**, only while the account is signed out, and **Ping**. To change an account's login, remove the account
and add one. A double-click on an account's name renames it (Workers, Names): lower-case letters, digits and dashes,
a name no other account has. Only its key in the register changes: its folder and its records stay, as the queue's
files know an account by its folder. A new account may not take the old name while the renamed account has the folder
of that name. The last tile adds an account: a dialog asks for its coding tool (a choice while the PC has more than
one; else the dialog names it), its name and its email, and the sign-in starts on this tab. An account of a tool with
no sign-in from the page is only added to the register: a worker can go on it, and the owner signs the tool in from a
terminal. The cross on a card removes an account that nothing uses: its login is signed out, and its
folder stays.

- **The sign-in** is the provider's sign-in command, run by the server ([PLUGINS.md](PLUGINS.md), SignIn). The page
  shows its link: open it on any device, sign in as that account (not your own: the browser may already be signed in),
  and paste the code it shows. With a provider that has no sign-in for the page, sign the folder in from a terminal.
- **Ping:** the provider's cheapest request (Probe). It starts the account's windows now and saves the usage that the
  request shows, so the meters show the account as it is. It is the only action here that uses tokens.

### History

Recent merges in every repo; recent runs with model, duration and cost.

### Details

Each project's colour, then the info text. An older address `#info` opens this tab. No push opens it.

**The colour:** one head for each project, in the order of the projects: the project's mark and its colour (`color`).
The colour field picks one, and saves at once in the project's `.queue/settings.json` ([QUEUE.md](QUEUE.md),
Settings); Default colour goes back to the colour from the project's name. The mark, a worker's project choice and
the Queue's select, set to the project, show this colour. With one project on the PC there is no head: nothing shows
a colour. The models of a complexity are each worker's, in its Config (Workers).

**The info:** what the queue does and what to expect, for someone who does not know it, in plain sections: In short,
What needs you, How a ticket goes through, Who builds what, Complexities, Limits, In the background, GitHub and The
tabs. It is an overview: what a tab already shows (each worker, each account's readings and lines, each project's
coding tool and plugins) is not repeated in it. Each value the owner sets
links to the tab that sets it. Every setting and reading comes from the snapshot; none is typed into the text, and no
environment is named in it. **A change to a queue rule changes this text in the same pull request.** The settings and
the text are drawn last, each on its own, and a fault in one shows one line, not a broken page.

**The GitHub link:** the last line of the page links to Scriptorium's own repository on GitHub (`Scriptorium on
GitHub`), in a new tab. It is not a project's.

**Estimates.** A typical run is the median of the finished whole-ticket runs of that size on that model, else of that
size on any model (`Get-Typical`): its wall time, and its cost in dollars at the API's price.

**An action shows at once.** The page changes the card as soon as the owner acts. The card then shows a turning ring
and its controls are greyed until a snapshot from the server confirms the action. If the server refuses, the page takes
the change back and says why. The 5 s refresh redraws a list only when its content changed and no box or menu in it has
focus.

**With the PC off** (or Tailscale disconnected) the page still opens: it is kept on the device (`web/sw.js`), with the
last state it reached, greyed out under a banner.

Actions need the `X-Queue: 1` header, so no other website open in a browser can trigger them: a browser asks the
server first, and the server says yes only to the pages of this PC's projects (Projects).

## Projects

One page shows every project that Scriptorium runs on the PC, with no switch between them. Each project keeps its own
queue and page server ([README.md](../README.md), Limits); the page loads them all and shows them together.

- **Workers:** the workers of every project stand side by side, in the owner's order (Workers, Order).
- **Questions, Queue and History:** one list of every project. In the Queue a project's own order stays, and between
  the projects the priority decides. Every tab has the same select at the right end of the title's line: All and each
  project, on Workers, Questions, Queue and History with its count of workers, questions, queued tickets or merged PRs.
  A project shows only that project's workers (All active and Pause all act on them), lists, totals, Details settings
  and info text. Accounts are the PC's, so the select changes nothing there. All tabs share the choice, and it stays on
  the device; the tab counters count the project shown (Accounts, the PC's, counts every project).
- **The mark:** while the PC has two projects or more, each worker, question, ticket and history row carries its
  project's name, in its project's colour (Details). A worker's mark is its project choice (Workers, The project
  choice).
- **Accounts** are the PC's: one list, with the workers of every project on it, each account from a project that
  has a provider for its coding tool. **Details** has the colour of each
  project, and one info text: the common part once, and the plugins for each project.
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
- **Force** (`.queue/force-<N>.json`): `{ticket}` for a forced run, `{ticket, now: true}` for Now. The server writes
  it for a PR's job and for a Now; the worker script, as it takes a forced Queue next. The worker script deletes it
  when the forced run ends, or when a Now ends without a run.
- **Next** (`.queue/next-<N>.json`, written by the server only): `{ticket}`, the ticket of a Queue next, with
  `force: true` once the owner forced it. The worker script deletes it when it takes the ticket or when the ticket left the queue.
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
