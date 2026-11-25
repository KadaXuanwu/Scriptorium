# The project's config

Each project that Scriptorium works on holds one file at its repo root, `scriptorium.json`, in git. It says what is
true for the project on every PC. What is true for one PC only (the plan accounts, the workers, the limits, the
notification topic) is in `.queue/settings.json` of the main checkout, which git ignores, or in the PC's own
settings ([QUEUE.md](QUEUE.md), Settings).

`setup.ps1` writes a first `scriptorium.json` when the project has none.

```json
{
    "name": "MyGame",
    "plugins": { "claude": {}, "unity": {} },
    "repos": ["MyGameTools"],
    "playbook": "Docs/RUN.md",
    "commands": ["dotnet"],
    "port": 8770,
    "compactAt": 250000,
    "complexities": {
        "medium": { "models": ["<a model id>@xhigh"] },
        "art": { "description": "a look to find", "models": ["<a model id>@high"], "advisor": true, "compactAt": 400000 }
    }
}
```

| Field | Needed | What |
| ----- | ------ | ---- |
| `name` | yes | The project's name: letters, digits and hyphens. It is in the names of the logon tasks and of the notification topic, so two projects on one PC never meet |
| `plugins` | yes | The project's provider, the plugin of its coding tool, and its environments, each with its settings ([PLUGINS.md](PLUGINS.md)). The example's `claude` is the provider that [plugins.json](../plugins.json) lists. Without a provider no worker runs; with no environment the project is a plain git repo |
| `repos` | no | Other repos of the same owner that a ticket may name with a `repo:<Name>` label |
| `playbook` | no | The path of the project's own rules for a run. A run reads it from `origin/main`, after the base's and the plugins' playbooks |
| `commands` | no | Commands a run may start without asking, each by how it starts (`dotnet`, `npm run`), on top of `git`, `gh` and what the plugins give |
| `allowedTools` | no | Tool rules in the syntax of the provider's own tool, for what `commands` cannot say. Another provider leaves out a rule it cannot read |
| `port` | no | The port of the page on this PC, 8770 when left out. Two projects on one PC need two ports; setup gives each its own Tailscale address ([APP.md](APP.md), Setup) |
| `compactAt` | no | The compact size of every run, in tokens (The compact size, below). The provider's when left out |
| `complexities` | no | Changes to the complexities (below) |

## Complexities

A ticket's `complexity:<name>` label picks the model and effort of its run. Scriptorium has four: `low`, `medium`,
`high` and `design`. Their models are in the provider's `models.json` ([PLUGINS.md](PLUGINS.md), A provider).

An entry under `complexities` changes one of the four or adds one of the project's own:

| Key | What |
| --- | ---- |
| `description` | One line for the GitHub label and the page. Needed for a complexity of the project's own |
| `models` | The models its runs use, each as `model@effort`, the first that the account still has. Left out for a complexity of the project's own: the models of `medium` |
| `advisor` | `true`: its runs may ask the advisor model |
| `advisorFallback` | The effort its runs get when the account has no advisor left |
| `compactAt` | The compact size of its runs, where it is not the project's |

`setup.ps1` makes the label of each complexity. The page shows every complexity with its model on the Details tab.
There the owner can pick another model and effort for a complexity of the project, and the pick goes over `models`
([QUEUE.md](QUEUE.md), Models, The owner's pick). The owner's advisor switch and fallback effort go over `advisor` and
`advisorFallback` in the same way. A complexity of the project's own stands between `high` and `design`.

## The compact size

Each turn of a run reads its whole context again, so a long run costs more with each turn. When the context reaches
the compact size, the coding tool compacts it: it replaces the older part with a summary. A provider whose tool takes
no such size has none (no `compactAt` in its `models.json`), and this part does not apply.

`compactAt` is that size: whole tokens in plain digits, within the sizes the provider's tool takes (`compactRange` in
its `models.json`). Anything else stops the scripts with an error: a tool once read `250k` as its least without a
word. A run gets the compact size of its ticket's complexity, from the first of these that has one:

1. The owner's own size for the complexity in the project: the page's Details tab sets it, and saves it in
   `.queue/settings.json` ([QUEUE.md](QUEUE.md), Settings).
2. The complexity's `compactAt` in `scriptorium.json`.
3. The project's `compactAt` in `scriptorium.json`.
4. The `compactAt` of the provider's `models.json`.

A size above the model's own context window has no effect: the tool compacts before that window is full.

A larger size keeps more of the work in view and costs more for each turn. A smaller one compacts more often, and
each compaction loses detail. The page shows the compact size of each complexity on its Details tab, and the worker
script writes the size of each run into its log.

The worker script names the size to the provider for each run ([PLUGINS.md](PLUGINS.md), `Run`), which turns it
into what its tool takes.
