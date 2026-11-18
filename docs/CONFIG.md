# The project's config

Each project that Scriptorium works on holds one file at its repo root, `scriptorium.json`, in git. It says what is
true for the project on every PC. What is true for one PC only (the plan accounts, the workers, the limits, the
notification topic) is in `.queue/settings.json` of the main checkout, which git ignores, or in the PC's own
settings ([QUEUE.md](QUEUE.md), Settings).

`setup.ps1` writes a first `scriptorium.json` when the project has none.

```json
{
    "name": "MyGame",
    "plugins": { "unity": {} },
    "repos": ["MyGameTools"],
    "playbook": "Docs/RUN.md",
    "allowedTools": ["Bash(dotnet:*)"],
    "port": 8770,
    "compactAt": 250000,
    "complexities": {
        "medium": { "models": ["claude-opus-5-5@xhigh"] },
        "art": { "description": "a look to find", "models": ["claude-opus-5-5@high"], "advisor": true, "compactAt": 400000 }
    }
}
```

| Field | Needed | What |
| ----- | ------ | ---- |
| `name` | yes | The project's name: letters, digits and hyphens. It is in the names of the logon tasks and of the notification topic, so two projects on one PC never meet |
| `plugins` | no | The environments of the project, each with its settings ([PLUGINS.md](PLUGINS.md)). None: a plain git repo |
| `repos` | no | Other repos of the same owner that a ticket may name with a `repo:<Name>` label |
| `playbook` | no | The path of the project's own rules for a run. A run reads it from `origin/main`, after the base's and the plugins' playbooks |
| `allowedTools` | no | Claude Code tool rules a run gets on top of `Bash(git:*)`, `Bash(gh:*)` and what the plugins give |
| `port` | no | The port of the page on this PC, 8770 when left out. Two projects on one PC need two ports; setup gives each its own Tailscale address ([APP.md](APP.md), Setup) |
| `compactAt` | no | The compact size of every run, in tokens (The compact size, below). 167000 when left out |
| `complexities` | no | Changes to the complexities (below) |

## Complexities

A ticket's `complexity:<name>` label picks the model and effort of its run. Scriptorium has four: `low`, `medium`,
`high` and `design`. Their models are in [models.json](../models.json).

An entry under `complexities` changes one of the four or adds one of the project's own:

| Key | What |
| --- | ---- |
| `description` | One line for the GitHub label and the page. Needed for a complexity of the project's own |
| `models` | The models its runs use, each as `model@effort`, the first that the account still has. Left out for a complexity of the project's own: the models of `medium` |
| `advisor` | `true`: its runs may ask the advisor model |
| `advisorFallback` | The effort its runs get when the account has no advisor left |
| `compactAt` | The compact size of its runs, where it is not the project's |

`setup.ps1` makes the label of each complexity. The page shows every complexity with its model on the Info tab and in
each worker's Config. There the owner can pick another model and effort for a complexity on this PC, and the pick goes
over `models` ([QUEUE.md](QUEUE.md), Models, The owner's pick). A complexity of the project's own stands between `high`
and `design`.

## The compact size

Each turn of a run reads its whole context again, so a long run costs more with each turn. When the context reaches
the compact size, Claude Code compacts it: it replaces the older part with a summary.

`compactAt` is that size: whole tokens in plain digits, from 67000 to 967000. Anything else stops the scripts with an
error: Claude Code once read `250k` as its minimum without a word. A run gets the compact size of its ticket's
complexity, from the first of these that has one:

1. The owner's own size for the complexity on this PC: a worker's Config on the page sets it, and saves it in
   `.queue/settings.json` ([QUEUE.md](QUEUE.md), Settings).
2. The complexity's `compactAt` in `scriptorium.json`.
3. The project's `compactAt` in `scriptorium.json`.
4. The 167000 of [models.json](../models.json).

A size above the model's own context window has no effect: Claude Code compacts before that window is full.

A larger size keeps more of the work in view and costs more for each turn. A smaller one compacts more often, and
each compaction loses detail. The page shows the compact size of each complexity on its Info tab, and the worker
script writes the size of each run into its log.

Claude Code itself takes a window (`CLAUDE_CODE_AUTO_COMPACT_WINDOW`, from 100000 to 1000000) and compacts 33k tokens
before it (measured with Claude Code 2.1.323). The worker script gives each run the window that compacts at its size
(`Get-CompactWindow` in [project.ps1](../project.ps1)).
