# Providers

**Status: the base has no provider, and two providers are plugins.** The contract is in [PLUGINS.md](PLUGINS.md), A
provider. The first provider is [Scriptorium for Claude Code](https://github.com/KadaXuanwu/Scriptorium-ClaudeCode).
The second is [Scriptorium for Antigravity](https://github.com/KadaXuanwu/Scriptorium-Antigravity): its hooks work
with the real tool, and no ticket has run through it yet. This page keeps the research.

The research is a snapshot of 2026-11-24, taken from each tool's own docs. The Claude Code column rests on running
code. The Antigravity column is the docs' too: where the real tool differs, [What the real Antigravity
does](#what-the-real-antigravity-does) says so. Nothing was run with the other tools.

## Terms

- **Provider:** the coding tool that runs a session: Claude Code, Codex, Antigravity. Not the model behind it.
- **Provider plugin:** a plugin ([PLUGINS.md](PLUGINS.md)) that teaches the base one provider.
- **Environment plugin:** a plugin as it is today: Unity, a web stack.
- **Window:** a stretch of time in which a plan allows a share of usage: 5 hours, a week, a month.

## The goal

1. The base has no provider. It knows git, GitHub and the queue: tickets, dispatching, areas, the merger, the page,
   notifications and the budget arithmetic. **Built.**
2. Each provider is a plugin. Claude Code is the first one. **Built.**
3. An owner who buys another tool's subscription adds its plugin and signs an account in. Workers on that account
   build tickets like any other worker. **Built:** an account is one provider's, and a worker runs on its account's
   coding tool, in any project ([QUEUE.md](QUEUE.md), Settings, `accounts.<name>.provider`). Not built: the page's
   Details sets the models of a project's default provider only.

## Decided, and built

- **A base with no provider, and one plugin for each provider.**
- **The base is built around what every provider can do.** What only some can do is a hook that a provider plugin
  has or leaves out ([PLUGINS.md](PLUGINS.md), Its hooks).
- **Windows are a list that the provider gives,** in its `models.json`. One provider has 5 hours and a week, another
  a week alone, another a month.
- **Environment plugins speak no tool's language.** They hand over commands and MCP servers in a neutral form
  (`Commands`, `McpServers`). The older `AllowedTools` still passes one provider's own rules through.

## What the base took from Claude Code

Before the split the base did not talk to a model: it drove the Claude Code program and read that program's details.
Each row is now a part of the provider's contract.

| Layer | What | Now |
| ----- | ---- | --- |
| Launch | The command line of a run, a probe and a compaction: flags, the settings file, the blocked tools, the MCP config, the environment variables. Sign-in, sign-out and Ping on the page | `GetCommand`, `Probe`, `Compact`, `SignIn`, `SignOut` |
| Log | Tokens, cost, the session to resume, what the run did last, why it ended | `ReadRun`, `ReadStep`, `ReadEnd` |
| Usage | Each window's share used and its reset. Stop lines, pick-up limits and holds until a reset all compute from it | `ReadUsage`, and `windows` in `models.json` |
| Refusals | Signed out, payment due, limit reached, model not in the plan: told apart by the wording of the error | the `Kind` that `ReadRun` and `Probe` return |
| Accounts | The plan size and the sign-in state, several accounts on one PC | `GetLogin`, and the `Login` of each call |
| Models | The model names, the effort levels, the advisor, the window of one model and the model after it | `models.json` |
| The run's rules | The tool's shell, its compaction and the rules file it loads. The front desk is a skill of the tool | the provider's `PLAYBOOK.md`, and `skills` in its manifest |
| Plugins | `GetRun` returned MCP servers and tool rules in Claude Code's shapes | `Commands` and `McpServers` |

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

The contract is [PLUGINS.md](PLUGINS.md), A provider: the hooks, the `Run` a provider starts from, the reading and the
end it returns, and `models.json` with its windows. It was drawn from Claude Code. Antigravity was then written
against it with no change to the hooks; what did not fit (usage read with a command of its own between runs, and one
login for each OS user) is in [The order of work](#the-order-of-work). The base's tests run it with two made-up
providers (`tests/provider`, with a log of plain lines, and `tests/bare`, with only the two hooks a provider must
have), which shows that the base does not need Claude Code's log or names, not that another real tool fits.

A new hook does not change the contract version ([PLUGINS.md](PLUGINS.md), What changes the version).

## Proposed

Not decided: when a provider answers, and which providers come first.

### When a provider answers

A provider answers for each account at run time, not once in its manifest. The same tool has other windows on
another plan, effort levels depend on the model, and a usage reading exists for subscribers only.

### The order of work

1. **Test Antigravity with a subscription** (below). An hour. It decides whether a second provider can have a budget.
   Not done.
2. **Move Claude Code behind the new hooks.** Done, together with step 4.
3. **Write the second provider** against those hooks, and change the hooks where it does not fit. A contract drawn
   from one provider is that provider's shape under a neutral name; only the second one shows what is common. Done
   for Antigravity, with no change to the hooks. What did not fit: a tool whose usage is read with a command of its
   own, not from a run's log, so the usage is read only between runs; and a tool with one login for each OS user.
4. **Move Claude Code to a plugin of its own.** Done. The contract is not fixed: step 3 may still change it.

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

### What the real Antigravity does

Found on 2026-11-25 with agy 1.5.17 on Windows and a free plan, while its plugin was written. Its README lists what
was proven and what was not.

| The table above says | The real tool |
| -------------------- | ------------- |
| Read the share used: not documented | `agy -p /usage --output-format stream-json` gives each window's share left and its reset as data, and asks the model nothing |
| Tool rules for one run: no | `--settings <file>` takes rules for one run and saves nothing. It is in the tool's help, not in its docs |
| Compact before a hold | `/compact` with `--conversation <id>` compacts that session |
| Model and effort: `--model` and `--effort` | A model's name holds its effort, and `--effort` beside it is refused |
| Know a limit refusal: not documented | Seen: the service's own shortage (error 503). The plan's limit was not reached |

Not in the docs at all: a run's commands start in a sandbox that cannot write to `.git` and has no network. A
command that an allow rule covers may start outside it, alone in its call.

### A smaller first step

A plugin that allows `agy` as a command, with a playbook line that says when a Claude Code run calls it (a second
review of the diff, for example). One small ticket and no change to the base. It adds no capacity: the run is still
Claude Code's, and nothing watches the other plan's usage.

## Open decisions

How each stands after the split. The owner can still decide otherwise before a second provider is built.

1. **Pick-up limits** by ticket size: the provider says which of its windows has them (`pickUp`). A window with none
   holds a new ticket back only at its ceiling.
2. **The kept share** for the owner's own use: the provider marks one window to hold it (`keep`), and the share is
   spread over that window's length, a month too.
3. **No usage reading:** the workers run until the plan refuses, and large tickets are cut off at the limit. The base
   keeps no estimate of its own.
4. **The rules file:** the base names none. The provider's playbook says which file its tool loads.
5. **Which tickets go to which provider:** open. A worker runs on its account's provider, and a project can have
   workers on two. A ticket then goes to the tool whose idle worker looks first; the owner keeps a complexity from a
   tool with the switches of its workers ([QUEUE.md](QUEUE.md), Dispatching). A rule of its own (a label, a share
   for each tool) is not built.

## Not checked

- Anything by running Codex, Antigravity, Cursor, Copilot CLI or OpenCode.
- The plans' prices and their limits in numbers, and Copilot's cost for each model.
- OpenCode on Windows, and whether a Claude plan signs in to it although its docs list none.
- Antigravity's permissions and credits pages.
- A whole ticket through the split base and the Claude Code plugin: the plugin's readings were compared with the old
  base's on 74 real run logs, and no run was started.

Three sources are thin: OpenCode's run flags come from a search result, and the Codex and Copilot reference pages
were cut off before their end.

## Sources

Read on 2026-11-24.

- Claude Code: [memory](https://code.claude.com/docs/en/memory), [headless](https://code.claude.com/docs/en/headless),
  [CLI reference](https://code.claude.com/docs/en/cli-reference), [skills](https://code.claude.com/docs/en/skills),
  [status line](https://code.claude.com/docs/en/statusline)
- Codex: [non-interactive mode](https://developers.openai.com/codex/noninteractive), which leads to
  `learn.chatgpt.com/docs`. On that site also: the command reference, the config reference, approvals and security,
  authentication, `AGENTS.md`, MCP, rules, subagents, skills, environment variables and pricing
- Antigravity: [headless](https://www.antigravity.google/docs/cli/headless),
  [CLI reference](https://www.antigravity.google/docs/cli/reference/),
  [plans](https://www.antigravity.google/docs/plans/), [usage](https://www.antigravity.google/docs/cli/commands/usage/),
  [MCP](https://www.antigravity.google/docs/mcp/), [rules](https://www.antigravity.google/docs/rules/),
  [settings](https://www.antigravity.google/docs/settings/), [install](https://www.antigravity.google/docs/install/),
  [compact](https://www.antigravity.google/docs/commands/compact/),
  [migration from Gemini CLI](https://www.antigravity.google/docs/cli/gcli-migration/),
  [the move from Gemini CLI](https://developers.googleblog.com/an-important-update-transitioning-gemini-cli-to-antigravity-cli)
- Gemini CLI: [session management](https://geminicli.com/docs/cli/session-management/),
  [quotas and pricing](https://geminicli.com/docs/resources/quota-and-pricing)
- Cursor: [headless](https://cursor.com/docs/cli/headless), [using the CLI](https://cursor.com/docs/cli/using),
  [parameters](https://cursor.com/docs/cli/reference/parameters),
  [output format](https://cursor.com/docs/cli/reference/output-format),
  [permissions](https://cursor.com/docs/cli/reference/permissions),
  [authentication](https://cursor.com/docs/cli/reference/authentication),
  [configuration](https://cursor.com/docs/cli/reference/configuration), [skills](https://cursor.com/docs/skills),
  [pricing](https://cursor.com/docs/models-and-pricing),
  [usage limits](https://cursor.com/help/models-and-usage/usage-limits)
- Copilot CLI: [run programmatically](https://docs.github.com/en/copilot/how-tos/copilot-cli/automate-copilot-cli/run-cli-programmatically),
  [programmatic reference](https://docs.github.com/en/copilot/reference/copilot-cli-reference/cli-programmatic-reference),
  [command reference](https://docs.github.com/en/copilot/reference/copilot-cli-reference/cli-command-reference),
  [config folder](https://docs.github.com/en/copilot/reference/copilot-cli-reference/cli-config-dir-reference),
  [MCP servers](https://docs.github.com/en/copilot/how-tos/copilot-cli/customize-copilot/add-mcp-servers),
  [custom agents](https://docs.github.com/en/copilot/how-tos/copilot-cli/customize-copilot/create-custom-agents-for-cli),
  [context](https://docs.github.com/en/copilot/concepts/prompting-and-context/context-management),
  [allowing tools](https://docs.github.com/en/copilot/how-tos/copilot-cli/use-copilot-cli/allowing-tools),
  [session limit](https://docs.github.com/en/copilot/how-tos/copilot-cli/use-copilot-cli/set-session-limit),
  [billing](https://docs.github.com/en/copilot/concepts/billing-and-usage/individuals/billing)
- OpenCode: [CLI](https://opencode.ai/docs/cli), [config](https://opencode.ai/docs/config),
  [permissions](https://opencode.ai/docs/permissions), [MCP servers](https://opencode.ai/docs/mcp-servers),
  [instructions](https://opencode.ai/docs/instructions), [skills](https://opencode.ai/docs/skills),
  [agents](https://opencode.ai/docs/agents), [models](https://opencode.ai/docs/models),
  [compaction](https://opencode.ai/docs/compaction), [providers](https://opencode.ai/docs/providers),
  [API](https://opencode.ai/docs/api)
