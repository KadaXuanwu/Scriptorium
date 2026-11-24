# Providers (a plan)

**Status: a plan. Nothing on this page is built.** Today the base runs Claude Code and nothing else
([README](../README.md), Limits). This page holds what we found and what we decided, so the work can start from it.

The research is a snapshot of 2026-11-24, taken from each tool's own docs. Only the Claude Code column rests on
running code. Nothing was run with the other tools.

## Terms

- **Provider:** the coding tool that runs a session: Claude Code, Codex, Antigravity. Not the model behind it.
- **Provider plugin:** a plugin ([PLUGINS.md](PLUGINS.md)) that teaches the base one provider.
- **Environment plugin:** a plugin as it is today: Unity, a web stack.
- **Window:** a stretch of time in which a plan allows a share of usage: 5 hours, a week, a month.

## The goal

1. The base has no provider. It knows git, GitHub and the queue: tickets, dispatching, areas, the merger, the page,
   notifications and the budget arithmetic.
2. Each provider is a plugin. Claude Code becomes the first one.
3. An owner who buys another tool's subscription adds its plugin and signs an account in. Workers on that account
   build tickets like any other worker.

## Decided

- **A base with no provider, and one plugin for each provider.**
- **The base is built around what every provider can do.** What only some can do is a feature that a provider plugin
  switches on or off.
- **A provider answers for each account at run time, not once in its manifest.** The same tool has other windows on
  another plan, and effort levels depend on the model.
- **Windows are a list that the provider returns.** One provider has 5 hours and a week, another a week alone,
  another a month.
- **Environment plugins stop speaking Claude Code.** They hand over tool rules and MCP servers in a neutral form, and
  project rules go in `AGENTS.md`.

## What the base takes from Claude Code today

The base does not talk to a model. It drives the Claude Code program and reads that program's details. Nothing
separates "start a run" from "start Claude Code", because there was only ever one tool.

| Layer | What | Where |
| ----- | ---- | ----- |
| Launch | The command line of a run, a probe and a compaction: flags, the settings file, the blocked tools, the MCP config, the environment variables. Sign-in, sign-out and Ping on the page | `worker.ps1`, `app/server.ps1`, `limits.ps1` |
| Log | Tokens, cost, the session to resume, what the run did last, why it ended | `usage.ps1`, `worker.ps1`, `app/state.ps1`, the tests' fixtures |
| Usage | Each window's share used and its reset, from an event in the log. Stop lines, pick-up limits and holds until a reset all compute from it | `worker.ps1` (`Get-Usage`), `budget.ps1`, `limits.ps1` |
| Refusals | Signed out, payment due, limit reached, model not in the plan: told apart by the wording of the error | `limits.ps1` (`Get-Refusal`) |
| Accounts | The plan size and the sign-in state from the credentials, several accounts through one environment variable | `platform.ps1`, `app/state.ps1`, `worker.ps1` |
| Models | The model names, the effort levels, the advisor, the Fable window and the model after it | `models.json`, `limits.ps1`, `worker.ps1`, `app/web/app.js` |
| The run's rules | The playbooks name Claude Code's tools, its compaction and `CLAUDE.md`. The front desk is a Claude Code skill | `PLAYBOOK.md`, `templates/skills/ticket` |
| Plugins | `GetRun` returns MCP servers and tool rules in Claude Code's shapes | [PLUGINS.md](PLUGINS.md), `plugins.ps1` |

## Why the base drives a tool and does not call a model

- **A subscription works only through its vendor's tool.** A request sent to the model directly needs an API key,
  billed for each token. That ends "your Claude plan, never an API key".
- **A model alone does not code.** Reading files, running commands, editing and checking is a loop that the tool runs,
  with tool permissions, MCP servers, compaction, resume and caching. The base would have to build all of it.
- **An API key has no windows.** There is only a bill, so stop lines and holds would become a spending limit.

## What the tools share

Six tools: Claude Code, OpenAI Codex, Google Antigravity (`agy`), Cursor, GitHub Copilot CLI and OpenCode.

Gemini CLI is not in the list: since 2026-06-18 it no longer serves Google AI Pro and Ultra subscribers, who use
Antigravity now.

| Mark | Meaning |
| ---- | ------- |
| yes | The tool's docs describe it |
| (yes) | It works in Scriptorium today, and the tool's docs do not describe it |
| ? | The docs do not say |
| partly | See the note below the table |

### Common: the base is built around these

| Feature | Claude Code | Codex | Antigravity | Cursor | Copilot | OpenCode |
| ------- | ----------- | ----- | ----------- | ------ | ------- | -------- |
| Run a prompt with nobody there | yes | yes | yes | yes | yes | yes |
| Pick the model | yes | yes | yes | yes | yes | yes |
| Run without asking (approve all) | yes | yes | yes | yes | yes | yes |
| Allow commands by how they start | yes | yes | yes | yes | yes | yes |
| MCP servers | yes | yes | yes | yes | yes | yes |
| Reads `AGENTS.md` | yes | yes | yes | yes | yes | yes |
| A log of events, one JSON on each line | yes | yes | yes | yes | yes | ? |
| The session's id in the log | yes | yes | yes | yes | ? | ? |
| Resume a session with a new prompt | yes | yes | yes | ? | ? | ? |
| Skills as folders with a `SKILL.md` | yes | yes | ? | yes | yes | yes |
| Compacts on its own | yes | yes | yes | ? | yes | yes |
| Sign-in with a subscription | yes | yes | yes | yes | yes | partly |

The first six rows are documented for all six tools. The other six look common and have a gap in at least one
tool's docs: each needs a test before the base relies on it.

- **Resume:** every tool has a resume flag. A `?` means that no example shows it together with a prompt.
- **Skills:** Antigravity has a skills folder; its docs did not show the `SKILL.md` form.
- **OpenCode's sign-in:** its docs list a ChatGPT plan and GitHub Copilot. Anthropic is listed with an API key, and a
  Google subscription is not mentioned.

### Varies: a provider switches these on or off

| Feature | Claude Code | Codex | Antigravity | Cursor | Copilot | OpenCode |
| ------- | ----------- | ----- | ----------- | ------ | ------- | -------- |
| Effort levels | yes | yes | yes | ? | yes | yes |
| Tokens of a run in the log | yes | yes | yes | ? | ? | ? |
| Cost in money in the log | yes | ? | ? | ? | ? | ? |
| A cost cap for one run | yes | ? | ? | ? | yes | ? |
| A turn cap for one run | yes | ? | ? | ? | ? | yes |
| Compact on command, with nobody there | yes | ? | yes | ? | ? | yes |
| A compact size the owner sets | yes | yes | ? | ? | ? | yes |
| A second model inside a run | yes | yes | ? | ? | yes | yes |
| Several logins on one PC | yes | yes | ? | ? | yes | yes |
| Read the usage from a script | (yes) | ? | ? | ? | ? | ? |
| Tell a limit refusal from another error | (yes) | ? | ? | ? | ? | ? |

**The last two rows are the budget's only inputs, and no tool documents them.** Claude Code's docs describe the
usage numbers for the status line alone, not the log event that Scriptorium reads. So the budget is a feature like
the others. A provider with no usage reading runs until the plan refuses, then waits. Stop lines and pick-up limits
switch on where a provider delivers a reading.

### How each tool does it

| | Claude Code | Codex | Antigravity | Cursor | Copilot | OpenCode |
| - | ----------- | ----- | ----------- | ------ | ------- | -------- |
| Run | `claude -p` | `codex exec` | `agy -p` | `agent -p` | `copilot -p` | `opencode run` |
| Log | `--output-format stream-json` | `--json` | `--output-format stream-json` | `--output-format stream-json` | `--output-format=json` | `--format json` (1) |
| Session id | `session_id` | `thread_id` | `conversation_id` | `session_id` | ? | ? |
| Resume | `--resume <id>` | `codex exec resume <id>` | `--conversation <id>` | `--resume <id>` | `--resume=<id>` | `--session <id>` (1) |
| Rule for `git` | `Bash(git:*)` | `prefix_rule(pattern = ["git"])` | `command(git)` | `Shell(git)` | `shell(git:*)` | `{"action":"shell","resource":"git *"}` |
| Where rules go | a settings file for the run | `.rules` files | one settings file for the PC | `.cursor/cli.json` in the project | a flag for the run | the config file |
| MCP servers | `--mcp-config`, for the run | `config.toml`, `[mcp_servers.<name>]` | `.agents/mcp_config.json` | `.cursor/mcp.json` | `--additional-mcp-config`, for the run | `opencode.jsonc`, `mcp.servers` |
| Rules file | `CLAUDE.md`; `AGENTS.md` when there is none | `AGENTS.md` | `AGENTS.md`, `GEMINI.md` | `AGENTS.md`, `CLAUDE.md` | `AGENTS.md`, `CLAUDE.md`, `.github/copilot-instructions.md` | `AGENTS.md`; `CLAUDE.md` when there is none |
| Skill folders | `.claude/skills` | `.agents/skills` | `.agents/skills` | `.agents/skills`, `.cursor/skills`, `.claude/skills` | `~/.copilot/skills`; in a project ? | `.opencode/skills`, `.claude/skills`, `.agents/skills` |
| Folder of a login | `CLAUDE_CONFIG_DIR` | `CODEX_HOME` | ? (the OS keyring) | `CURSOR_CONFIG_DIR` (the login ?) | `COPILOT_HOME` | `OPENCODE_DB` |

(1) From a search result, not from the tool's reference page, which did not load.

### Windows

| Tool | Windows of a subscription |
| ---- | ------------------------- |
| Claude Code | 5 hours and a week, and a week for one model alone |
| Codex | 5 hours on Plus, none on Pro. Weekly limits "may apply" |
| Antigravity | 5 hours and a week, apart for each group of models |
| Cursor | A weekly pool. Older plans: a month |
| Copilot | Credits for a month, reset on the first day of the month |
| OpenCode | Those of the plan behind it |

A window that covers some models only is the usual case, not a special one: Claude Code's Fable window and
Antigravity's model groups are the same thing.

## The design

### What a provider plugin answers

| Part | What the base asks |
| ---- | ------------------ |
| Setup | Is the tool on the PC? |
| Accounts | Who is signed in, on which plan? How does the owner sign in and out? |
| Models | Which models, which effort levels, which prices? |
| Run | Start a run. Resume one. Compact one. Send the cheapest request that shows the account answers |
| Log | The session, the tokens and cost, what the run did last, and why it ended: done, limit, signed out, model refused, another error |
| Usage | The windows of this account: for each a name, a length, the share used, the reset and the models it covers |
| Rules | Where the project's rules file and the front desk skill go, and the provider's own part of the playbook |
| Features | Which of the features under Varies this account has now |

The plugin system carries this already: hooks, a playbook and settings for each plugin. New hooks do not change the
contract version ([PLUGINS.md](PLUGINS.md), What changes the version).

### Neutral forms

- **Tool rules:** a list of command starts (`git`, `gh`, `unity command`). Every tool in the table can say "allow
  commands that start with this". The provider writes them in its own syntax and place.
- **MCP servers:** a name with a command, arguments and environment, or with a URL and headers. Every tool takes
  that. The provider writes its own file or flag.
- **Project rules:** `AGENTS.md`. Every tool reads it; Claude Code only while the repo has no `CLAUDE.md`, from
  version 2.1.277.
- **Skills:** no folder is read by all six. The provider says where the front desk skill goes.

`AllowedTools` in `GetRun` holds Claude Code tool rules today. A new meaning for it makes plugin contract version 2
and needs an issue first ([CONTRIBUTING](../CONTRIBUTING.md)).

### Windows in the base

The windows are fixed names in the code today: `$WindowSeconds`, `$DefaultPickUp` and `$FableWindow` in
`limits.ps1`, `$windows` in `worker.ps1`, and the loops over `five_hour` and `seven_day` in `budget.ps1`,
`app/state.ps1` and `app/server.ps1`. The owner's settings (`stopAt`, `pickUp`) use the same names as keys.

With a list from the provider, a stop line belongs to a window of an account, the page draws one bar for each
window it gets, and the Fable rules become the rules of any window that covers some models.

## Proposed

Not decided: the order, and which providers come first.

### The order of work

1. **Test Antigravity with a subscription** (below). An hour. It decides whether a second provider can have a budget.
2. **Move Claude Code behind the new hooks,** still inside this repo. The largest and riskiest step, and it changes
   nothing an owner sees.
3. **Write the second provider** against those hooks, and change the hooks where it does not fit. A contract drawn
   from one provider is that provider's shape under a neutral name; only the second one shows what is common.
4. **Move Claude Code to a plugin of its own** and fix the contract.

Without a second provider in sight, do not start step 2.

A rough size, estimated from the code and the docs, not from trying: 6 to 8 tickets for the base and a second
provider, two of them `size:L` (step 2, and the windows with the budget).

### Which providers

| Provider | For |
| -------- | --- |
| Claude Code | A Claude plan |
| Antigravity | A Google AI plan |
| OpenCode | Models paid with an API key, and a ChatGPT or Copilot plan |

**Why not OpenCode alone:** its docs list no sign-in for a Claude or a Google plan, so both would be billed for each
token. It documents no reading of a provider's usage. The reference page of `opencode run` did not load, and the
JSON events, the exit codes and a limit refusal are not described. Its install page says that Windows package
managers are not supported.

### Antigravity as the second provider

| The base needs | Antigravity |
| -------------- | ----------- |
| A run with nobody there, with a JSON log | `agy -p` with `--output-format stream-json` |
| Resume the same session after a hold | `--conversation <id>` with `-p` |
| Compact before a hold | `/compact` works with `-p` |
| Model and effort for a run | `--model` and `--effort`, with the same effort names |
| A 5-hour and a weekly window | Yes, for each group of models |
| Read the share used | Not documented. No event carries it; `/usage` is a panel on the screen |
| Know a limit refusal | Not documented |
| Several accounts on one PC | Not documented: the login is in the OS keyring |
| Sign in from the page | No: the first sign-in needs a terminal |
| Tool rules for one run | No: one settings file for the PC |
| Cost in money, a cost cap, an advisor, a compact size | None documented |

The test, with a subscription signed in:

1. Run `agy -p /usage`. Can a script read the windows from what it prints?
2. Run `agy -p "Reply: ok" --output-format stream-json`. Does the log hold the session and the tokens?
3. Use a window up once, and keep what a run returns then: the text, the status, the exit code.

If the first step gives nothing a script can read, an Antigravity worker runs until refused, and large tickets are
cut off in the middle.

### A smaller first step

A plugin that allows `agy` as a command, with a playbook line that says when a Claude Code run calls it (a second
review of the diff, for example). One small ticket and no change to the base. It adds no capacity: the run is still
Claude Code's, and nothing watches the other plan's usage.

## Open decisions

The owner decides these before the windows are built.

1. **Pick-up limits** by ticket size sit on the 5-hour window. On a provider with a weekly or monthly window alone:
   do they apply to its shortest window, or not at all?
2. **The kept share** for the owner's own use is spread over the week. On a monthly window: spread over the month?
3. **No usage reading:** accept that large tickets are cut off at the limit, or have the base keep its own estimate
   from the tokens?
4. **The rules file:** `AGENTS.md` alone, or `CLAUDE.md` with one line that imports it?
5. **Which tickets go to which provider:** by the worker's account, by the ticket's complexity, or by a label?

## Not checked

- Anything by running Codex, Antigravity, Cursor, Copilot CLI or OpenCode.
- The plans' prices and their limits in numbers, and Copilot's cost for each model.
- OpenCode on Windows, and whether a Claude plan signs in to it although its docs list none.
- Antigravity's permissions and credits pages.
- How much of `app/state.ps1` and of the tests moves with Claude Code.

Three sources are thin: OpenCode's run flags come from a search result, and the Codex and Copilot reference pages
were cut off before their end.

## Sources

Read on 2026-11-24.

- Claude Code: [memory](https://code.claude.com/docs/en/memory), [headless](https://code.claude.com/docs/en/headless),
  [CLI reference](https://code.claude.com/docs/en/cli-reference), [skills](https://code.claude.com/docs/en/skills),
  [status line](https://code.claude.com/docs/en/statusline)
- Codex: [non-interactive mode](https://developers.openai.com/codex/noninteractive)
- Antigravity: [headless](https://www.antigravity.google/docs/cli/headless),
  [plans](https://www.antigravity.google/docs/plans/), [usage](https://www.antigravity.google/docs/cli/commands/usage/),
  [MCP](https://www.antigravity.google/docs/mcp/), [rules](https://www.antigravity.google/docs/rules/),
  [install](https://www.antigravity.google/docs/install/),
  [the move from Gemini CLI](https://developers.googleblog.com/an-important-update-transitioning-gemini-cli-to-antigravity-cli)
- Cursor: [headless](https://cursor.com/docs/cli/headless), [parameters](https://cursor.com/docs/cli/reference/parameters),
  [output format](https://cursor.com/docs/cli/reference/output-format),
  [permissions](https://cursor.com/docs/cli/reference/permissions),
  [configuration](https://cursor.com/docs/cli/reference/configuration), [skills](https://cursor.com/docs/skills),
  [pricing](https://cursor.com/docs/models-and-pricing)
- Copilot CLI: [run programmatically](https://docs.github.com/en/copilot/how-tos/copilot-cli/automate-copilot-cli/run-cli-programmatically),
  [programmatic reference](https://docs.github.com/en/copilot/reference/copilot-cli-reference/cli-programmatic-reference),
  [command reference](https://docs.github.com/en/copilot/reference/copilot-cli-reference/cli-command-reference),
  [billing](https://docs.github.com/en/copilot/concepts/billing-and-usage/individuals/billing)
- OpenCode: [CLI](https://opencode.ai/docs/cli), [permissions](https://opencode.ai/docs/permissions),
  [instructions](https://opencode.ai/docs/instructions), [skills](https://opencode.ai/docs/skills),
  [compaction](https://opencode.ai/docs/compaction), [providers](https://opencode.ai/docs/providers)
