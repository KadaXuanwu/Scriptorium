# Plugins

The base knows git, GitHub and Claude Code. It knows no engine, no build tool and no test runner. A plugin teaches it
one environment: Unity, a web stack, a mobile toolchain. A project with no plugin is a plain git repo, and that works.

This page is the contract between the base and a plugin. It is version **1**.

## What a plugin is

A plugin is a folder, normally a git repo of its own:

| File | Needed | What |
| ---- | ------ | ---- |
| `plugin.json` | yes | the manifest |
| `plugin.ps1` | yes | the hooks |
| `PLAYBOOK.md` | no | the rules a run follows in this environment: how it builds, tests and checks its work |
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

- `name`: lower case letters, digits and hyphens. It is the key in `scriptorium.json` and the folder name.
- `api`: the version of this contract the plugin was written for. The base refuses a plugin with another number and
  names both numbers.
- `requires`: commands that must be on the PATH. `setup.ps1` names each one that is missing.
- The page shows `title`, `version` and `description` on its Info tab.

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
      AllowedTools = @('mcp__Docs', 'Bash(unity command:*)')
      Env = @{ UNITY_PROJECT_PATH = 'D:/Work/App-w1/Client' }
      Prompt = 'Your editor is ...'
  }
  ```

  `McpServers` has the shape of `mcpServers` in a Claude Code MCP config. `AllowedTools` holds Claude Code tool rules.
  `Env` holds environment variables for the run's process, so each command that the run starts has them. `Prompt` is
  one or two sentences that the base adds to the run's first message. The base merges the answers of all plugins:
  servers and variables by name, tools as a union, prompts in order.
- **`EndRun`** leaves the environment clean for the next run: it leaves play mode, stops a server.

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
- `EndRun`: the worker writes the error to its log and goes on.

## The playbook

A run reads three playbooks in this order: the base's `PLAYBOOK.md`, then the `PLAYBOOK.md` of each plugin, then the
project's own (`playbook` in `scriptorium.json`). Where two differ, the later one wins. A plugin's playbook holds only
what its environment adds: the order of its checks, its tools, its traps.

## What changes the version

A new hook, a new context field or a new key in `GetRun`'s answer does not change the version: a plugin ignores what
it does not know. A hook or field that goes away or changes its meaning makes version 2. Open an issue before a pull
request that does this.

## Publish a plugin

1. Make a public repo with the files above and a licence.
2. Say in its README what it needs on the PC and what each hook does to it.
3. Test it on a project of your own with a `source` entry.
4. To have it listed by name, open a pull request here that adds one entry to `plugins.json`:
   `"<name>": { "source": "<git URL>", "description": "<one line>" }`. [CONTRIBUTING.md](../CONTRIBUTING.md) gives
   the checks for it.
5. Add `"detect"` to the entry, a list of file patterns from the repo root (`"*/ProjectSettings/ProjectVersion.txt"`),
   and `setup.ps1` puts the plugin in a new `scriptorium.json` when a pattern matches a file of the project.

A listed plugin stays its author's: its issues and pull requests go to its own repo.
