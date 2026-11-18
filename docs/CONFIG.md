# The project's config

Each project that Scriptorium works on holds one file at its repo root, `scriptorium.json`, in git. It says what is
true for the project on every PC. What is true for one PC only (the plan accounts, the workers, the limits, the
notification topic) is in `.queue/settings.json` of the main checkout, which git ignores.

`setup.ps1` writes a first `scriptorium.json` when the project has none.

```json
{
    "name": "MyGame",
    "plugins": { "unity": {} },
    "repos": ["MyGameTools"],
    "playbook": "Docs/RUN.md",
    "allowedTools": ["Bash(dotnet:*)"],
    "port": 8770,
    "complexities": {
        "medium": { "models": ["claude-opus-5-5@xhigh"] },
        "art": { "description": "a look to find", "models": ["claude-opus-5-5@high"], "advisor": true }
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
| `port` | no | The port of the page on this PC, 8770 when left out. Two projects on one PC need two ports |
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

`setup.ps1` makes the label of each complexity. The page shows every complexity with its model on the Info tab and in
each worker's Takes menu. A complexity of the project's own stands between `high` and `design`.
