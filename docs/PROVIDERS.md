# Providers

Why the base runs coding tools through provider plugins, and what is still open. The contract is in
[PLUGINS.md](PLUGINS.md), A provider. [plugins.json](../plugins.json) lists the providers, and each provider's README
says what its tool needs and what was proven with it.

## Terms

- **Provider:** the coding tool that runs a session: Claude Code, Codex, Antigravity. Not the model behind it.
- **Provider plugin:** a plugin ([PLUGINS.md](PLUGINS.md)) that teaches the base one provider.
- **Environment plugin:** a plugin for what a project is built with: Unity, a web stack.
- **Window:** a stretch of time in which a plan allows a share of usage: 5 hours, a week, a month.

## The goal

1. The base has no provider. It knows git, GitHub and the queue: tickets, dispatching, areas, the merger, the page,
   notifications and the budget arithmetic.
2. Each provider is a plugin.
3. An owner who buys another tool's subscription adds its plugin and signs an account in. Workers on that account
   build tickets like any other worker. An account is one provider's, and a worker runs on its account's coding tool,
   in any project ([QUEUE.md](QUEUE.md), Settings, `accounts.<name>.provider`). The owner's picks of models are each
   worker's, on any tool ([QUEUE.md](QUEUE.md), Models, A worker's mapping).

## Decided, and built

- **A base with no provider, and one plugin for each provider.**
- **The base is built around what every provider can do.** What only some can do is a hook that a provider plugin
  has or leaves out ([PLUGINS.md](PLUGINS.md), Its hooks).
- **Windows are a list that the provider gives,** in its `models.json`. Each tool's plans have windows of their own,
  and a window may cover some models only.
- **Environment plugins speak no tool's language.** They hand over commands and MCP servers in a neutral form
  (`Commands`, `McpServers`). The older `AllowedTools` still passes one provider's own rules through.
- **Pick-up limits** by ticket size: the account's shortest window has them, the provider's (`pickUp`) or else the
  base's when the account has a longer window too, so the owner sets them on the page with any provider that has two
  windows. A provider can give them to a longer window too. A window with none, as an account's only window, holds a
  new ticket back only at its ceiling.
- **The kept share** for the owner's own use: the provider marks one window to hold it (`keep`), and the share is
  spread over that window's length.
- **No usage reading:** the workers run until the plan refuses, and large tickets are cut off at the limit. The base
  keeps no estimate of its own.
- **The rules file:** the base names none. The provider's playbook says which file its tool loads.

## Why the base drives a tool and does not call a model

- **A subscription works only through its vendor's tool.** A request sent to the model directly needs an API key,
  billed for each token. That ends "your Claude plan, never an API key".
- **A model alone does not code.** Reading files, running commands, editing and checking is a loop that the tool runs,
  with tool permissions, MCP servers, compaction, resume and caching. The base would have to build all of it.
- **An API key has no windows.** There is only a bill, so stop lines and holds would become a spending limit.

## Open decisions

1. **Which tickets go to which provider.** A worker runs on its account's provider, and a project can have workers on
   two. A ticket then goes to the tool whose idle worker looks first; the owner keeps a complexity from a tool with
   the switches of its workers ([QUEUE.md](QUEUE.md), Dispatching). A rule of its own (a label, a share for each
   tool) is not built.
2. **Models for every provider in `scriptorium.json`.** The file names models for the project's default provider
   only. A worker on another tool takes that provider's `models.json`, under the owner's picks.

## What the real Antigravity does

This moved to the README of [Scriptorium for Antigravity](https://github.com/KadaXuanwu/Scriptorium-Antigravity).
