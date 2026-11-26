# Audit tasks

Tasks from the audit of Scriptorium and its three plugins on 2026-11-26, at commit `046cb3a` of the base. Each task
stands alone: do them one at a time, top to bottom. Tick a task in the list when its pull request is open.

Line numbers are those of `046cb3a`. They move as tasks land, so find the code by the function's name.

## What this is about

Scriptorium is a work queue for coding agents. The **base** (this repo) knows git, GitHub and the queue. It must know
no coding tool, no model and no environment. A **provider plugin** teaches it one coding tool, an **environment
plugin** one environment. The contract between them is [docs/PLUGINS.md](docs/PLUGINS.md).

The audit found the split sound. These tasks close what is left:

- one way a hung process can stop the whole queue (task 1),
- work that both provider plugins do twice and the base should do once (tasks 1 and 2),
- values that change (a model's name, a plan's name, a window's length) still written in code or docs
  (tasks 8, 10, 11, 12, 13, 17),
- checks, tests and docs that are missing (tasks 3 to 7, 9, 14 to 16).

## The repos

| Repo | On GitHub | Tasks |
| ---- | --------- | ----- |
| The base | `KadaXuanwu/Scriptorium` | every task with no letter, and the parts marked **a** |
| The Claude Code provider | `KadaXuanwu/Scriptorium-ClaudeCode` | 1b, 2b, 7b, 12 |
| The Antigravity provider | `KadaXuanwu/Scriptorium-Antigravity` | 1c, 2c, 7c, 8b, 10b, 13 |

## Rules for every task

1. **Never edit the live install.** `D:\Personal\Workflows\Scriptorium` runs the workers of several projects, and
   so do the plugin checkouts under its `plugins` folder. A changed `.ps1` there restarts every script.
   - For the base: make a git worktree outside that folder, in a folder whose name does not start with
     `Scriptorium-` (that name is for worker copies).
   - For a plugin: work in its own checkout outside the install (Antigravity: `D:\Personal\Workflows\Scriptorium-Antigravity`),
     or in a fresh clone.
2. **One task, one branch, one pull request.** Do not mix two tasks.
3. **Read [.github/CONTRIBUTING.md](.github/CONTRIBUTING.md) first.** The points that matter most here:
   - Windows PowerShell 5.1 syntax only: no `&&`, `||`, `?:`, `??`. New `.ps1` files in ASCII.
   - A change to a queue rule has a test (`*.test.ps1`) and its doc change in the same pull request.
   - No new dependency.
   - A hook or a context field that goes away or changes its meaning makes contract version 2 and needs an issue
     first. A new hook or a new field does not. Every task here is written to stay at version 1.
4. **Check before you push:** `powershell -NoProfile -ExecutionPolicy Bypass -File check.ps1` in the worktree. A
   plugin has its own `plugin.test.ps1`.
5. **This PC has no `pwsh`.** PowerShell 7 is checked only by the GitHub workflow. After the push, read the run
   (`gh run list --branch <branch>`, `gh run view <id> --log-failed`) before you call the task done.
6. **No value that can change in code or docs:** no model's name, no plan's name, no default line. Name the file and
   the key that hold it. A value inside an example is fine. Never drop a row of a "token savings" table.
7. **Docs and comments:** short sentences, active voice, one word for one meaning.
8. **Do not merge.** Open the pull request and stop. The owner merges.
9. **If the code no longer matches a task** (an earlier task changed it, or the finding is wrong), say so in the pull
   request and do the smallest thing that still meets "Done when".

## The list

Base:

- [x] 1a. The base runs the probe, with a time limit ([#25](https://github.com/KadaXuanwu/Scriptorium/pull/25))
- [x] 2a. The base runs the compaction ([#26](https://github.com/KadaXuanwu/Scriptorium/pull/26))
- [x] 3. The run cap can be set in `scriptorium.json` ([#27](https://github.com/KadaXuanwu/Scriptorium/pull/27))
- [x] 4. Check a provider's `models.json` when it loads ([#28](https://github.com/KadaXuanwu/Scriptorium/pull/28))
- [x] 5. Save the PC's record files in one way ([#29](https://github.com/KadaXuanwu/Scriptorium/pull/29))
- [x] 6. Test the rules for how a run ends ([#30](https://github.com/KadaXuanwu/Scriptorium/pull/30))
- [x] 7a. Say where a tool's own permission rules go ([#31](https://github.com/KadaXuanwu/Scriptorium/pull/31))
- [x] 8a. Delete `docs/PROVIDERS.md` ([#32](https://github.com/KadaXuanwu/Scriptorium/pull/32))
- [x] 9. Close four gaps in `docs/PLUGINS.md` ([#33](https://github.com/KadaXuanwu/Scriptorium/pull/33))
- [x] 10a. No window's name and no unstated currency in base wording ([#34](https://github.com/KadaXuanwu/Scriptorium/pull/34))
- [x] 11. The restart watch leaves out every dot folder ([#35](https://github.com/KadaXuanwu/Scriptorium/pull/35))
- [x] 14. The sign-in email check holds for every shell ([#36](https://github.com/KadaXuanwu/Scriptorium/pull/36))
- [ ] 15. A plugin's name must match its key
- [ ] 16. No default provider by folder name
- [ ] 17. The README states nothing that changes

Claude Code provider (after 1a and 2a are merged):

- [ ] 1b and 2b. Hand the probe and the compaction to the base
- [ ] 7b. Take permission rules as a setting of its own
- [ ] 12. No model's and no plan's name in code

Antigravity provider (after 1a and 2a are merged):

- [ ] 1c and 2c. Hand the probe and the compaction to the base
- [ ] 7c. Take permission rules as a setting of its own
- [ ] 8b. Take over "What the real Antigravity does"
- [ ] 10b. Give no cost where the tool counts none
- [ ] 13. Delete the window filter

Tasks 1a and 2a come first: 2a uses the helper that 1a adds, and the plugin tasks 1b, 1c, 2b and 2c need both. Every
other task is free of the others.

---

## 1a. The base runs the probe, with a time limit

**Why.** A probe is the cheapest request to a coding tool. It reads an account's usage and shows whether the account
takes requests. Today the plugin starts the tool itself, with no time limit
(`plugins/claude/plugin.ps1`, hook `Probe`; `plugins/antigravity/plugin.ps1`, hook `Probe`). A worker calls it while
it holds the lock that gives out tickets: `Get-NextJob` -> `Get-Candidates` -> `Get-FreshUsage` -> `Invoke-Probe`
([worker.ps1:1779](worker.ps1:1779)). If the tool hangs, that worker keeps the lock for ever and every other worker
of the project waits behind it. The page's Ping makes the same call on the server's only thread
([app/server.ps1:985](app/server.ps1:985)), so the page freezes too.

**Do.**

1. Add one helper to [plugins.ps1](plugins.ps1) that runs a command a provider gave: `@{ FilePath; Arguments; Env }`,
   the shape `GetCommand` returns today. It:
   - sets the `Env` variables for the process and puts the old ones back (a variable with no value is taken away),
     as `Invoke-Worker` does for a run,
   - starts the process in a folder the caller names, with nothing to read on its input,
   - waits up to a time limit, then ends the process and every process it started (`Stop-ProcessTree`),
   - returns what the process printed, and whether it ended in time.
2. Add two provider hooks to the contract:
   - `GetProbe`: fields `Login` and `Dir`. Returns `@{ FilePath; Arguments; Env }`.
   - `ReadProbe`: field `Text`, what the probe printed. Returns what `Probe` returns today:
     `@{ Usage; Answered; Kind; Text }`.
3. `Invoke-Probe` in [worker.ps1](worker.ps1) and the `ping` action in [app/server.ps1](app/server.ps1) use the two
   new hooks through the helper when the provider has both. A probe that passes the time limit counts as a probe
   that failed (`$null`), and the log says so.
4. The old `Probe` hook keeps working for a provider that has only that one: it stays in version 1. Such a provider
   has no time limit, and the doc says so.
5. One place answers "does this provider have a probe": every `Test-ProviderHook 'Probe'` (worker.ps1, server.ps1,
   budget's `Test-ProbeAfterRun` caller) and the `hooks` list the page gets ([app/state.ps1](app/state.ps1),
   `$ProviderFeatures`) say yes for either form, so the page's Ping button needs no change.
6. The time limit is one named constant in the base.
7. Give `tests/provider/plugin.ps1` the two new hooks, and keep one test that a provider with only `Probe` still
   answers.
8. Update [docs/PLUGINS.md](docs/PLUGINS.md), Its hooks: the two new rows, and `Probe` as the older form.

**Done when.**

- A test starts a command that never ends through the helper, and the helper returns after the limit with the
  process gone.
- A test shows the same reading from `GetProbe` plus `ReadProbe` as from `Probe`.
- `check.ps1` passes, and the GitHub run is green in PowerShell 7 on all three systems.

**Not in this task.** The plugins (1b, 1c). Moving the probe out of the ticket lock.

## 2a. The base runs the compaction

**Why.** Each hook gets a context field `Log`: a function that writes one line to the worker's log
([docs/PLUGINS.md:156](docs/PLUGINS.md:156)). The `Compact` hook gets a field of the same name that is a file path
([docs/PLUGINS.md:205](docs/PLUGINS.md:205)), and it replaces the function ([plugins.ps1:320](plugins.ps1:320)).
Antigravity's `Compact` builds its command with a function that calls `$ctx.Log` as a function when a plugin gives
an MCP server. It then throws, and the session is never compacted. Both providers also hold the same 15 lines that
start the tool, wait ten minutes, end it and read its output.

**Do.**

1. Add two provider hooks:
   - `GetCompact`: field `Run`, with the `Session` to compact. Returns `@{ FilePath; Arguments; Env }`.
   - `ReadCompact`: field `Text`, what the compaction printed. Returns one line for the worker's log, or nothing
     for a compaction that failed.
2. `Compress-Session` in [worker.ps1](worker.ps1) runs `GetCompact`'s command with the helper from task 1a, in
   `Run.Dir`, with the ten minutes the plugins use today as a named constant, and keeps the output in the log file
   it names today. It writes the same log lines as today, also for a time-out and for a failure.
3. The old `Compact` hook keeps working for a provider that has only that one. Its `Log` field stays a file path
   for that hook alone. Say in the doc that `Log` there is the older form's file, not the function.
4. "Does this provider compact" is yes for either form, as in task 1a, step 5.
5. Give `tests/provider/plugin.ps1` the two new hooks. Update [docs/PLUGINS.md](docs/PLUGINS.md).

**Done when.**

- A test shows `Compress-Session`'s log line for a compaction that worked, one that failed and one that timed out.
  If `Compress-Session` cannot be loaded by a test, move its body into a function in `plugins.ps1` that can.
- `check.ps1` and the GitHub run pass.

**Not in this task.** The plugins (2b, 2c).

## 3. The run cap can be set in `scriptorium.json`

**Why.** [README.md:95](README.md:95) tells the owner to set the cap of one run in the provider's `models.json`.
That file belongs to the plugin's git checkout. Setup updates a plugin with `git pull --ff-only`
([setup.ps1:215](setup.ps1:215)). When the plugin's author next changes `models.json`, git refuses the pull over the
owner's edit and setup stops. The owner must never have to edit a plugin's file.

**Do.**

1. A pure function in [project.ps1](project.ps1) gives the cap of a run: `runCap` of `scriptorium.json` when it has
   one, else `runCap` of the provider's `models.json`, else 0. Take the project's value from what
   `Get-ProviderConfig` gives, so it holds for the project's default provider only, as the models and the compact
   size do. A value that is no number of 0 or more throws with the key's name.
2. [worker.ps1](worker.ps1), `Invoke-Worker`, uses it in place of `[double](Read-Models).runCap`.
3. `Test-Outcome`'s comment on a capped run names both places, not only the provider's file.
4. Docs: the table in [docs/CONFIG.md](docs/CONFIG.md), "The cap of a run" in [docs/QUEUE.md](docs/QUEUE.md), and
   the sentence at [README.md:95](README.md:95), which must send the owner to `scriptorium.json`.

**Done when.** A test in `tests/project.test.ps1` shows all three sources and the throw. No doc tells the owner to
edit a plugin's file.

## 4. Check a provider's `models.json` when it loads

**Why.** Nothing checks the file. Seen with the base's own functions: a `models.json` whose `low` has no models gives
a run with an empty model name, and one with no `complexities` key throws "Key cannot be null". Neither names the
file, so the owner sees a worker that stops with an unclear reason.

**Do.**

1. One function checks a provider's `models.json` and throws `plugin <name>: models.json: <what is wrong>`:
   - it parses,
   - it has `models`,
   - each of the base's four complexities (`$BaseComplexities` in [project.ps1](project.ps1)) has at least one
     model,
   - each window has `seconds` above 0.
2. Call it where a provider is loaded (`Import-Plugin` in [plugins.ps1](plugins.ps1), for a plugin whose manifest
   says `provider`). The scripts restart when a `models.json` changes, so a later edit is checked too.
3. Setup already stops with the message of a plugin that does not load: make sure it shows this one.

**Done when.** `tests/plugins.test.ps1` has one case for each of the four checks and one for a good file. The two
test providers still load.

**Not in this task.** A pick that names a model which `models` does not list: the contract allows it.

## 5. Save the PC's record files in one way

**Why.** `usage.json`, `out.json` and `access.json` in the PC's folder are shared by the workers of every project.

- `Set-ModelRefused` ([worker.ps1:685](worker.ps1:685)) writes `access.json` with no lock and in place. Two workers
  that are refused a model in the same second make one of them throw in the middle of a run's end, and that run
  gets no history line. `Read-Access` has no error handling, so a half-written file costs a worker its poll.
- `Save-Reading` ([budget.ps1:93](budget.ps1:93)) and `Set-Out` ([worker.ps1:568](worker.ps1:568)) save with
  `Move-Item -Force`. The comment on `Save-JsonFile` ([pc.ps1:73](pc.ps1:73)) says that this way was measured to
  lose reads, which is why `Save-JsonFile` exists.

**Do.**

1. All three files are saved by `Save-JsonFile` under the `Usage` lock (`Enter-PcLock 'Usage'`, `Exit-PcLock`).
2. `Set-ModelRefused` reads and saves inside that lock.
3. `Read-Access` treats a missing or unreadable file as empty, as `Read-Out` does.
4. Delete `$usageMutex` in `worker.ps1` once nothing uses it: `Enter-PcLock 'Usage'` is the same lock.

**Done when.** No `Move-Item` and no bare `Set-Content` writes one of the three files. `tests/budget.test.ps1` still
passes. If you want a test for the access file, move its two functions to [budget.ps1](budget.ps1) with the file as a
parameter, as `Read-UsageFile` and `Save-Reading` are.

**Not in this task.** The workers' state files (`worker-<id>.json`).

## 6. Test the rules for how a run ends

**Why.** About 150 lines decide what happens to a run that ended: held with its session, back to the queue, parked
for the owner, or its account marked as out. They are in `Invoke-Worker` after the run's process ends
([worker.ps1:1367](worker.ps1:1367)) and in the main loop after `Invoke-Worker` returns
([worker.ps1:1799](worker.ps1:1799)). `worker.ps1` is a script that no test can load, so no test fails when one of
these branches breaks.

**Do.**

1. Move the decisions into pure functions in [limits.ps1](limits.ps1), beside `Get-Hold`. They take plain values
   (what the provider's `ReadRun` gave, the usage reading, the held run if any, the job's kind, the flags the
   script holds) and return what to do. The script keeps every side effect: the `gh` calls, the files, the log.
2. Change no rule. The pull request says so, and names any branch whose behaviour you could not keep.
3. A table test in `tests/budget.test.ps1` with at least one row for each branch: the plan's limit, a window of some
   models, a model the plan lacks, a login or subscription refusal, a start that failed once and twice, a handoff,
   the owner's pause, the owner's Now, a disabled worker, the cap, a clean end with and without a pull request.

**Done when.** Each branch has a row that fails when the branch is changed. `worker.ps1` holds no decision that the
functions also hold.

**Careful.** This is the queue's core. It is the largest task here: keep it to a move, and read
[docs/QUEUE.md](docs/QUEUE.md) for the rules before you start.

## 7a. Say where a tool's own permission rules go

**Why.** `allowedTools` in `scriptorium.json` holds rules in one coding tool's own syntax. The base hands them to
every provider ([plugins.ps1:189](plugins.ps1:189)), so a project with workers on two tools sends one tool's rules to
the other. This is the one place where a tool's syntax passes through the base. The plugin's own entry in
`scriptorium.json` (`plugins.<name>`) already reaches the plugin as `$ctx.Settings`, with no base code.

**Do.**

1. [docs/CONFIG.md](docs/CONFIG.md) and [docs/PLUGINS.md](docs/PLUGINS.md): a tool's own rules go in the provider's
   entry, under the key its README names. `allowedTools` at the top of the file, `AllowedTools` in `GetRun`'s answer
   and `Run.Tools` are the older form.
2. Write the text of an issue that proposes to take the older form out in contract version 2, and put it in the pull
   request's description. Do not open the issue.

**Done when.** The docs name the new home. No code changed.

**Not in this task.** Taking `allowedTools` out of the base: that makes contract version 2 and needs the issue first.

## 8a. Delete `docs/PROVIDERS.md`

**Why.** The file is 320 lines of research on six coding tools: their flags, plans and windows. That is the detail
the base stays free of. It names a model, and its status lines contradict each other (line 178 says "Not done",
line 227 reports the result). The owner decided on 2026-11-26 that the whole file is not needed any more: the
providers are built, and the contract is in [docs/PLUGINS.md](docs/PLUGINS.md).

**Do.**

1. Delete the file. Git keeps it: name the commit that holds its last version in the pull request.
2. Take its line out of the Docs list in the README ([README.md:225](README.md:225)).
3. Search the base for any other link to it and take each out. At `046cb3a` the README's line is the only one.

**Done when.** The file is gone and nothing in the base links to it. Docs only.

**Not in this task.** Moving a part of it elsewhere. The Antigravity plugin's task 8b takes its one section from
git.

## 9. Close four gaps in `docs/PLUGINS.md`

**Do.**

1. **A starting point.** Near the top of "A provider", point to [tests/bare/plugin.ps1](tests/bare/plugin.ps1) (the
   two hooks a provider must have) and [tests/provider/plugin.ps1](tests/provider/plugin.ps1) (every hook) as what
   to copy first.
2. **The card picture.** Line 321 says the page's server reads the picture once and shows a new one after a restart.
   The code reads it again when the file changes (`Get-CardArt`, [app/state.ps1:38](app/state.ps1:38)). Say what
   the code does.
3. **A provider's own keys.** Say that the base ignores a key of `models.json` that it does not know, so a provider
   may keep values of its own there.
4. **Totals of a session.** `Cost` is documented as the session's cost so far. `Numbers.advisorCost` is the same kind
   of total, and the base takes off the part from before a pause ([worker.ps1:1386](worker.ps1:1386)). Say so. Give
   `Window` a row of its own in the table of the run's end: today only the text of `Kind` names it.

**Done when.** The four edits are in. Docs only.

## 10a. No window's name and no unstated currency in base wording

**Why.** The windows are the provider's. The base still names one tool's:

- [setup.ps1:415](setup.ps1:415): the description of the `size:L` label says "5-hour room".
- [app/server.ps1:844](app/server.ps1:844): an error says a guard keeps a share "of the week". The window that keeps
  is the one a provider marks with `keep`.
- [docs/APP.md](docs/APP.md), The usage guards: "the week's meter", "a whole week".

And a cost has no unit in the contract ("the session's cost so far, where the tool counts one"), while the page
prints `$` before it ([app/web/app.js:103](app/web/app.js:103), [:533](app/web/app.js:533)).

**Do.**

1. Reword the three texts so that none names a window's length.
2. In [docs/PLUGINS.md](docs/PLUGINS.md), say which unit `Cost` and `runCap` have, and that a provider whose tool
   counts no cost leaves `Cost` out.
3. Check what the page shows for a run whose history line has a cost of 0. If it shows a price, show none.

**Done when.** A search of the base for "5-hour" and for "week" as a window's name finds only examples. A run with no
cost shows no price.

## 11. The restart watch leaves out every dot folder

**Why.** The scripts restart when a `.ps1` under the install changes. `Get-CodeStamp` ([restart.ps1:13](restart.ps1:13))
leaves out the install's `.claude` folder, because a coding tool keeps whole checkouts there. That is one tool's
folder name in base code, and another tool's folder would restart every worker.

**Do.** Leave out every folder directly under the install whose name starts with a dot. Compare the path from the
install's root, since the install itself may be inside a dot folder. Reword the two comments so they name no tool.
In `tests/restart.test.ps1`, keep the case there and add one with another dot folder.

**Done when.** The test passes with both folders, and `restart.ps1` names no tool.

## 14. The sign-in email check holds for every shell

**Why.** The page sends an email address to the provider's `SignIn` hook, which puts it into a shell command line.
The check at [app/server.ps1:920](app/server.ps1:920) blocks what the Windows shell reads. It lets `$(...)` and a
backtick through, which the macOS and Linux shell runs ([app/server.ps1:205](app/server.ps1:205)). Only the owner's
own page can send it, so this closes a gap, not an attack seen.

**Do.** Move the check into a small function in [app/state.ps1](app/state.ps1) that allows only what an email address
has: letters, digits, `.`, `_`, `+`, `-` before the `@`, and letters, digits, `.`, `-` after it. Use it in the `login`
action.

**Done when.** A test in `app/app.test.ps1` passes a plain address and refuses one with each of `$`, a backtick,
`(`, `;`, `&`, `"` and a space.

## 15. A plugin's name must match its key

**Why.** [docs/PLUGINS.md:73](docs/PLUGINS.md:73) says a plugin's `name` is its key in `scriptorium.json` and its
folder's name. Nothing checks it. An account names its provider by that name for the whole PC, so a project that
lists the same plugin under another key gets a second name for one tool, and other projects do not know its accounts.

**Do.** `Import-Plugin` ([plugins.ps1:48](plugins.ps1:48)) throws when the manifest's `name` differs from the name it
was loaded under, and names both. The base's tests load `tests/provider` as `test` and `tests/bare` as `bare`: those
match their manifests. Fix any other test that loads a plugin under a name its manifest does not have.

**Done when.** One new case in `tests/plugins.test.ps1`, and `check.ps1` passes.

## 16. No default provider by folder name

**Why.** `Get-Providers` ([plugins.ps1:205](plugins.ps1:205)) lists the project's providers first, then every other
one in the install's `plugins` folder by name. For a project whose `scriptorium.json` lists no provider, the first of
the list is the first folder by alphabet. `worker.ps1` (line 69) and `app/server.ps1` (line 57) then write that name
into old accounts that name no provider (`Update-AccountProviders`). Setup stops at a project with no provider, so
this needs a file edited by hand.

**Do.** Both scripts call `Update-AccountProviders` only with the first provider that the project itself lists
(`Get-Provider` on the project's plugins), and not at all when it lists none.

**Done when.** A test shows that a project with no provider of its own changes no account. If neither call can be
reached by a test, put the choice into a small function in `plugins.ps1` and test that.

## 17. The README states nothing that changes

**Why.** [README.md:118](README.md:118) names the plans a provider needs. [README.md:213](README.md:213) says "Two
providers are listed" and how far the Antigravity provider has been tested. Each goes stale with the next plugin or
plan.

**Do.** Say that a provider's README names what its tool needs, and that [plugins.json](plugins.json) lists the
providers. Take out the count and the status. Keep the "Built-in token savings" table whole.

**Done when.** The README names no plan, no count of providers and no test status of a plugin. Docs only.

---

## Claude Code provider: 1b and 2b. Hand the probe and the compaction to the base

**Needs.** Tasks 1a and 2a merged in the base. Say so in the pull request: this plugin then needs that base.

**Do.**

1. Replace the `Probe` hook with `GetProbe` (the command it runs today, with the login's variables as `Env`) and
   `ReadProbe` (what it makes of the output today, the rule that a window's refusal counts as the plan's limit for
   a probe too).
2. Replace the `Compact` hook with `GetCompact` (`Get-RunCommand $ctx -Compact`) and `ReadCompact` (the line it
   builds from the output today).
3. Delete what nothing uses after that. `Invoke-WithEnv` stays only if `SignOut` still needs it.
4. Update `plugin.test.ps1` and the README's list of hooks.

**Done when.** The plugin starts no process for a probe or a compaction. Its tests pass. One real Ping from the
page, on a project of this PC, still reads the account's usage (ask the owner before any real run).

## Claude Code provider: 7b. Take permission rules as a setting of its own

**Do.** The run's rules also take the list under a key of the plugin's own settings (`$ctx.Settings`, the plugin's
entry in `scriptorium.json`). Name the key in the README, and say that rules in this tool's syntax go there, not in
the project-wide `allowedTools`. Add a test.

**Done when.** A rule in the plugin's entry reaches the run's settings file.

## Claude Code provider: 12. No model's and no plan's name in code

**Why.** `plugin.ps1` names values that change with the tool's models and plans:

- line 23: the probe's model,
- lines 10 and 179: the name of one model's usage window and the wording of its refusal,
- lines 111 to 118: a table of plan sizes by the plan's tier.

**Do.**

1. The probe's model comes from a key of the plugin's own in its `models.json` (the base ignores keys it does not
   know).
2. A window of some models carries the wording of its refusal as a key of the plugin's own in its entry under
   `windows`. `Get-Refusal` finds the window by that wording, so no window's and no model's name is left in the code.
3. The plan's size is the number in the tier's name, which `Get-PlanName` already reads with one pattern. Delete the
   table.
4. Reword the comments that name a model. Document the two new keys in the README.

**Done when.** A search of `plugin.ps1` finds no model's name and no plan's name. The tests pass, with the same
readings as before for the logs they hold.

## Antigravity provider: 1c and 2c. Hand the probe and the compaction to the base

**Needs.** Tasks 1a and 2a merged in the base.

**Do.** As 1b and 2b: `GetProbe` and `ReadProbe` for `Probe`, `GetCompact` and `ReadCompact` for `Compact`. The
function that builds the run's command calls `$ctx.Log` when a plugin gives an MCP server: with `GetCompact` that is
the log function again, so the call works. Update the tests and the README.

**Done when.** The plugin starts no process for a probe or a compaction, and its tests pass. Real runs cost this
account's small weekly quota: ask the owner before one, and read the week with `agy -p /usage --output-format
stream-json` from PowerShell, which costs nothing.

## Antigravity provider: 7c. Take permission rules as a setting of its own

**Do.** As 7b, for rules in this tool's syntax.

## Antigravity provider: 8b. Take over "What the real Antigravity does"

**Do.** Take the section of that name from the base's `docs/PROVIDERS.md` as it is at commit `046cb3a`
(`git show 046cb3a:docs/PROVIDERS.md` in the base; task 8a deletes the file). Put into this plugin's README, beside
what it says is proven, each finding that the README does not hold yet. A finding with its date and the tool's
version may stay as it is.

## Antigravity provider: 10b. Give no cost where the tool counts none

**Needs.** Task 10a, which says in the contract that such a provider leaves `Cost` out.

**Do.** `ReadRun` leaves `Cost` out. Update the test.

## Antigravity provider: 13. Delete the window filter

**Why.** `Read-UsageText` ([plugin.ps1:160](plugins/antigravity/plugin.ps1:160)) keeps only the usage windows whose
name starts with one model family's name. The base already keeps only the windows that the plugin's `models.json`
names (`ConvertTo-Reading`, [budget.ps1:64](budget.ps1:64)), so the filter says the same thing a second time, in
code.

**Do.** Delete the filter and reword the comment above the function. Keep the handling of a reset time in the year
1970. Update the test: a window that `models.json` does not name may now be in the hook's answer.

**Done when.** `plugin.ps1` filters by no model's name, and the tests pass.

---

## Left out of this list

Two small things the audit saw and did not make tasks of:

- `/api/log` in `app/server.ps1` does not check that the worker's number is digits, as `/api/copy` does.
- The page's server keeps "the provider in use now" in one shared variable (`Select-Provider`), which works only as
  long as every entry sets it first.

## Not checked by the audit

Most of `app/state.ps1`, all of `app/web/app.js`, `tasks.ps1`, `uninstall.ps1`, `followup.ps1`, `away.ps1`,
`areas.ps1`, `shots.ps1`, and the plugins' tests. `docs/QUEUE.md` and `docs/APP.md` were only searched. A task that
touches one of these must read it first.
