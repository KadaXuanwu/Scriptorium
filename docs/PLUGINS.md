# Plugins

The base knows git, GitHub and the queue. It knows no coding tool, no engine, no build tool and no test runner. A
plugin teaches it one of them. A **provider** teaches it one coding tool (A provider): a project has exactly one. An
environment plugin teaches it one environment: Unity, a web stack, a mobile toolchain. A project with no environment
plugin is a plain git repo, and that works.

This page is the contract between the base and a plugin. It is version **1**.

## What a plugin is

A plugin is a folder, normally a git repo of its own:

| File | Needed | What |
| ---- | ------ | ---- |
| `plugin.json` | yes | the manifest |
| `plugin.ps1` | yes | the hooks |
| `PLAYBOOK.md` | no | the rules a run follows in this environment: how it builds, tests and checks its work |
| `models.json` | a provider | its models and its usage windows (A provider) |
| `README.md`, `LICENSE` | to be listed | what the plugin does and what it needs on the PC |

A plugin is code that runs on your PC with your rights. Install only a plugin whose source you trust.

## Where a plugin comes from

A project names its plugins in `scriptorium.json` ([CONFIG.md](CONFIG.md)):

```json
"plugins": {
    "unity": {},
    "mine": { "source": "https://github.com/someone/scriptorium-mine" },
    "local": { "source": "D:/Work/my-plugin" }
}
```

- A name with no `source` comes from the list in [plugins.json](../plugins.json) at the root of this repo.
- A `source` is a git URL or a folder on the PC. Nobody has to approve it.
- `setup.ps1` clones a git source into `plugins/<name>` of the Scriptorium folder and pulls it on each later run. It
  uses a folder source where it is.
- Every other key of the entry is a setting of that plugin.

The plugins of a project run in the order the file gives them.

## The manifest

```json
{
    "name": "unity",
    "title": "Scriptorium for Unity",
    "version": "2.0.0",
    "api": 1,
    "description": "One Unity editor for each worker copy, driven with the Unity CLI.",
    "requires": ["unity"]
}
```

A provider's manifest has two more keys, `provider` and `skills` (A provider).

- `name`: lower case letters, digits and hyphens. It is the key in `scriptorium.json` and the folder name.
- `api`: the version of this contract the plugin was written for. The base refuses a plugin with another number and
  names both numbers.
- `requires`: commands that must be on the PATH. `setup.ps1` names each one that is missing.
- The page shows `title`, `version` and `description` on its Details tab.

## The hooks

`plugin.ps1` may define helper functions. Its last statement is one hashtable of script blocks:

```powershell
function Get-Something { ... }

@{
    Setup = { param($ctx) ... }
    PrepareCopy = { param($ctx) ... }
    Start = { param($ctx) ... }
    GetRun = { param($ctx) ... }
    EndRun = { param($ctx) ... }
    Close = { param($ctx) ... }
}
```

Every hook is optional. The base loads each plugin in a module of its own, so the helpers of two plugins never meet,
and a hook can call the helpers of its own file. `plugin.ps1` runs only its definitions when it loads: it starts
nothing and changes nothing.

| Hook | The base calls it | `$ctx.Copy` is | It returns |
| ---- | ----------------- | -------------- | ---------- |
| `Setup` | in `setup.ps1`, each time it runs | the main checkout | the files it added to the project, as paths from the repo root |
| `PrepareCopy` | in `setup.ps1` and Add a worker, for each worker copy | that worker copy | nothing |
| `Start` | in the worker script, before each look for a job, and before a run in a checkout of another repo | the worker copy, or that checkout | nothing |
| `GetRun` | before a run starts or resumes | the job's checkout | what the run gets (below) |
| `EndRun` | after a run, however it ended | the job's checkout | nothing |
| `Close` | in the worker script, once when the worker becomes disabled, after its run has ended | the worker copy, then each checkout of another repo it ran in | nothing |

- **`Setup`** checks the PC and adds what the project itself must hold (an editor script, a config file). The files
  reach the worker copies only through git, so setup commits the returned files or tells the owner to. It must be safe
  to run again.
- **`PrepareCopy`** makes a worker copy able to work: what git does not hold, and per-checkout git config. It must be
  safe to run again.
- **`Start`** makes the environment ready and returns when it is: it opens an editor, starts a server, or does
  nothing. It may wait for a long time (a first import). While it waits, it calls `$ctx.Report` at least every five
  minutes.
- **`GetRun`** returns a hashtable. Each key is optional:

  ```powershell
  @{
      McpServers = @{ Docs = @{ type = 'stdio'; command = '...'; args = @('...'); env = @{ } } }
      Commands = @('unity command', 'dotnet')
      Env = @{ UNITY_PROJECT_PATH = 'D:/Work/App-w1/Client' }
      Prompt = 'Your editor is ...'
  }
  ```

  `McpServers` gives each server by name: a `command` with `args` and `env`, or a `url` with `headers`. A run may use
  every tool of a server it is given. `Commands` holds the commands a run may start without asking, each by how it
  starts: `unity command` allows every command line that starts so. `Env` holds environment variables for the run's
  process, so each command that the run starts has them. `Prompt` is one or two sentences that the base adds to the
  run's first message. The base merges the answers of all plugins: servers and variables by name, commands as a union,
  prompts in order, and hands them to the provider, which writes them in its tool's own form.

  `AllowedTools` is the older key: tool rules in the syntax of one provider's tool, which the base hands on unread.
  Another provider leaves out a rule it cannot read, so a new plugin gives `Commands`.
- **`EndRun`** leaves the environment clean for the next run: it leaves play mode, stops a server.
- **`Close`** closes what `Start` opened in `$ctx.Copy`, to free the PC: an editor, a server. Never the main
  checkout's. An editor that the owner opens later in a disabled copy stays open.

A job can be in another repo of the owner (a `repo:` label). `$ctx.Copy` is then that repo's checkout, which may not
hold this environment at all. A hook checks what it finds in `$ctx.Copy` and does nothing when its environment is
not there.

### The context

| Field | What |
| ----- | ---- |
| `Api` | `1` |
| `Project` | the main checkout: the project's folder on this PC |
| `Copy` | the checkout this call is about (the table above) |
| `Worker` | the worker's number; `$null` in `Setup` |
| `QueueDir` | the worker copy's `.queue` folder, for files of the plugin's own; `$null` in `Setup` |
| `Settings` | the plugin's settings: its entry in `scriptorium.json`, then its entry under `plugins` in the PC's `.queue/settings.json` over it |
| `Report` | a script block that takes one string: what the worker does now, in words for the owner ("Opening its Unity editor"). The worker's card shows it |
| `Log` | a script block that takes one string: a line for the worker's log |

A plugin reads no other variable of the base and calls no function of it.

### When a hook throws

- `Setup`, `PrepareCopy`: the setup stops and shows the plugin's name and the error.
- `Start`, `GetRun`: the worker starts no run, shows the error on its card and tries again at its next look.
- `Close`: the worker writes the error to its log, and the other plugins still close.
- `EndRun`: the worker writes the error to its log and goes on.

## The playbook

A run reads three playbooks in this order: the base's `PLAYBOOK.md`, then the `PLAYBOOK.md` of each plugin, then the
project's own (`playbook` in `scriptorium.json`). Where two differ, the later one wins. A plugin's playbook holds only
what its environment adds: the order of its checks, its tools, its traps.

## A provider

A provider is the plugin that teaches the base one coding tool: how to start a run with it, what its log says, who is
signed in, and which usage windows its plans have. The base itself runs no tool and reads no log. A project has one
provider: the first of its plugins whose manifest says `"provider": true`. With none, the page still shows the queue,
and each worker's card says that the project has no provider.

A provider is a plugin like any other: it may also have `Setup`, `Start` and the other hooks above, and a
`PLAYBOOK.md` with what holds for its tool (its shell, the rules file it loads, how it compacts).

### Its hooks

Each gets the context above, with the fields of the call over it. `GetCommand` and `ReadRun` are needed. Every other
hook is a feature: the base runs without it, as the last column says.

| Hook | Fields of the call | It returns | Without it |
| ---- | ------------------ | ---------- | ---------- |
| `GetCommand` | `Run` (below); `Copy` is the job's checkout | `@{ FilePath; Arguments; Env }`: the program, its arguments as `Start-Process` takes them (the provider quotes one that holds a space) and environment variables for the run's process (one with no value is taken away). It may write files of its own into `QueueDir` | needed |
| `ReadRun` | `Text`: the run's whole log | the run's end (below) | needed |
| `ReadUsage` | `Text`; `First`: the first reading of the log, else the last | a usage reading (below), `$null` for a log with none | no budget: the workers run until the plan refuses, then wait |
| `Probe` | `Login`; `Dir`: a folder that holds no project | `@{ Usage; Answered; Kind; Text }` from the tool's cheapest request: a reading or `$null`, whether a reply came (a refusal too), the refusal's kind (`''` when the account answered) and its text | an idle account's usage is not read again, an account that is out is tested by its next run, and the page has no Ping |
| `Compact` | `Run` with the `Session` to compact; `Log`: a file for the tool's output | one line for the worker's log. It runs the tool itself and returns when it is done | a held session resumes whole |
| `GetLogin` | `Login` | `@{ SignedIn; Email; Plan; PlanSize; Stamp }`: the plan's name for the page, its size against the provider's smallest plan, and a text that changes when the login changes. It starts no process: the page asks every few seconds | every account counts as signed in, on a plan of size 1 |
| `SignIn` | `Login`; `Email` (may be `''`) | `@{ Command; Env }`: one shell command line that signs the folder in. The base starts it, keeps its output and writes the owner's code to its input | the page cannot sign an account in |
| `ReadSignIn` | `Text`: what the sign-in has printed | `@{ Url; Message }`: the link the owner opens, and the last line for a failure | the page shows no link |
| `SignOut` | `Login` | nothing | a removed account stays signed in |
| `ReadStep` | `Line`: one line of a log | what the run did there, as text; `$null` for a line that is no step | the page shows no steps |
| `ReadEnd` | `Text`: the end of a log | `@{ Error; Detail; Text }`, `$null` for a log with no end | a stuck run's reason is "ended with no result" |

`Login` is the folder of an account's login (`configDir` in the settings), `''` for the command-line login. The page
makes the folder of a new account: `~/.<the plugin's name>-<the account's name>`.

A hook that throws on a log never loses a run's end: the run then counts as one whose process died.

**`Run`**, what a run starts from:

| Field | What |
| ----- | ---- |
| `Prompt` | the run's first message |
| `Session` | the session to resume, `''` for a new one |
| `Model`, `Effort` | the run's model and effort (`''` with no efforts) |
| `Advisor` | the advisor's model, `''` for none |
| `CompactAt` | the context size at which the run compacts, 0 for none |
| `Cap` | the cap of one run, 0 for none |
| `Login` | the folder of the account's login, `''` for the command-line login |
| `Commands` | the commands the run may start without asking, each by how it starts: `git`, `gh`, `unity command` |
| `Tools` | tool rules in the provider's own syntax, from `allowedTools` in `scriptorium.json` and from the plugins. A provider leaves out a rule it cannot read |
| `McpServers` | the plugins' MCP servers by name. The provider gives the run these and no other, and allows each one's tools |
| `Dir` | the folder the run works in |
| `AddDirs` | more folders the run reads: the worker's copy, for a job in another repo |

**The run's end,** from `ReadRun`:

| Field | What |
| ----- | ---- |
| `Session` | the session, to resume it; `''` when the log names none |
| `Ended` | the log has a result. Not: the process died |
| `Error` | the result is an error |
| `Kind` | why an error is not the ticket's failure: `model` (the plan lacks the model), `subscription`, `login`, `limit` (the plan's usage limit), `window` (the limit of a window of some models, named in `Window`), `start` (the run did no work, for a cause the provider cannot name), or `''` for the run's own failure |
| `Capped` | the run reached its cap |
| `Worked` | the run did work. A run refused at its first request did none and starts fresh |
| `Text` | the result's words, for the page and for a comment |
| `Cost` | the session's cost so far, where the tool counts one |
| `Numbers` | the run's numbers for the history ([QUEUE.md](QUEUE.md), History), any of: `requests`, `toolCalls`, `commands`, `first`, `ctxMean`, `ctxMax`, `read`, `write`, `compactions`, `advisorCalls`, `advisorCost` |

**A usage reading,** from `ReadUsage` and `Probe`:
`@{ Windows = @{ <name> = @{ Used; ResetsAt } }; Refused; RefusedResetsAt }`. `Used` is the share of the window, from 0
to 1 and over; `ResetsAt` a Unix time. `Refused` is the name of the window whose limit refused the request, `''` for
none. A name that `models.json` does not give to a window of some models counts as the account's.

### Its models.json

Beside `plugin.json`. The base reads it again at each use, and the windows when a script starts: a change to the file
restarts the workers and the page between jobs, as a change to a `.ps1` does.

```json
{
  "models": { "big-2": { "title": "Big 2", "effort": "medium" }, "deep-1": { "title": "Deep 1", "effort": "high" } },
  "efforts": ["low", "medium", "high"],
  "effort": "high",
  "complexities": {
    "low": { "models": ["big-2@low"] },
    "medium": { "models": ["big-2@medium"], "advisor": true },
    "high": { "models": ["big-2@high"], "advisor": true },
    "design": { "models": ["deep-1@high"] }
  },
  "advisor": { "model": "deep-1" },
  "compactAt": 250000,
  "compactRange": [67000, 967000],
  "runCap": 60,
  "windows": {
    "five_hour": { "title": "5 hours", "seconds": 18000, "stopAt": 0.98, "pickUp": { "S": 0.9, "M": 0.75, "L": 0.5 } },
    "week": { "title": "Week", "seconds": 604800, "keep": true },
    "deep_week": { "title": "Deep week", "seconds": 604800, "stopAt": 0.98, "models": "deep-*", "pickUp": { "design": 0.9 }, "after": "big-2@high" }
  }
}
```

| Key | Needed | What |
| --- | ------ | ---- |
| `models` | yes | each model the page offers: its `effort` when a pick names none, and its `title` on the page |
| `complexities` | yes | for `low`, `medium`, `high` and `design` (the base's four, [QUEUE.md](QUEUE.md), Complexities) the candidate models, best first, each `model` or `model@effort`; `advisor` for the ones whose runs get the advisor. A complexity of the provider's own needs a `description` |
| `efforts` | no | the efforts a run can have. Left out: runs have no effort |
| `effort` | no | the effort of a model that `models` does not list |
| `advisor` | no | `model`: the advisor's model. Left out: no advisor |
| `compactAt`, `compactRange` | no | the default compact size, and the least and the most the tool takes ([CONFIG.md](CONFIG.md), The compact size). Left out: runs get no compact size |
| `runCap` | no | the cap of one run, in the tool's own count. Left out: no cap |
| `windows` | no | the usage windows of its plans, by the names its readings use. Left out: no budget |

A window:

| Key | What |
| --- | ---- |
| `seconds` | its length |
| `title` | its name on the page |
| `stopAt` | the default stop line, the share where the workers stop. Left out: 1 |
| `pickUp` | the default pick-up limits by ticket size, `S`, `M` and `L` ([QUEUE.md](QUEUE.md), The budget). Left out: only the ceiling holds a new ticket back |
| `keep` | this window holds the room kept for the owner's own use. One window at most |
| `models` | a wildcard of model names: the window holds those models only, and one that is used up stops them, not the account ([QUEUE.md](QUEUE.md), A model's limit). Its `pickUp` then has one limit, under a name of the provider's: the start line. Its `stopAt` is the line for those models as advisors |
| `after` | for a window with `models`: the pick a job goes on with when the window is used up |

The names of the windows are the keys of an owner's saved stop lines and pick-up limits and of the usage records, so a
provider keeps them.

### Its manifest

`"provider": true`, and `"skills"`: the folder of a project where the tool reads skills (`.agents/skills`). Setup puts
the ticket skill there. Left out: the project gets no ticket skill.

## What changes the version

A new hook, a new context field or a new key in `GetRun`'s answer does not change the version: a plugin ignores what
it does not know. A hook or field that goes away or changes its meaning makes version 2. Open an issue before a pull
request that does this.

## Publish a plugin

1. Make a public repo with the files above and a licence.
2. Say in its README what it needs on the PC and what each hook does to it.
3. Test it on a project of your own with a `source` entry.
4. To have it listed by name, open a pull request here that adds one entry to `plugins.json`:
   `"<name>": { "source": "<git URL>", "description": "<one line>" }`, with `"provider": true` for a provider.
   [CONTRIBUTING.md](../.github/CONTRIBUTING.md) gives the checks for it.
5. Add `"detect"` to the entry, a list of file patterns from the repo root (`"*/ProjectSettings/ProjectVersion.txt"`),
   and `setup.ps1` puts the plugin in a new `scriptorium.json` when a pattern matches a file of the project. A
   provider needs none: setup adds the listed provider to a project that names none, while the list has exactly one.

A listed plugin stays its author's: its issues and pull requests go to its own repo.
