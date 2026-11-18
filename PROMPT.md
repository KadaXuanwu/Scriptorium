Scriptorium folder: <full path where Scriptorium goes, beside this project, for example D:\Work\Scriptorium>
Workers: <how many to start with, for example 1>

---

You set up Scriptorium for this project. Scriptorium is a work queue: headless Claude Code runs ("workers") build
GitHub issues in their own copies of this repo and open pull requests. I am the owner. Do every step yourself. Stop
only for a step that needs me, and say exactly what I must do. Its docs are at https://github.com/KadaXuanwu/Scriptorium.

## Steps

1. **Check the tools.** Run each and read its output:
   - `git --version`
   - `gh auth status`: the GitHub CLI must be signed in, with write access to this repo.
   - `claude --version`
   - `git remote get-url origin`: the origin must be on GitHub.
   - `powershell -NoProfile -Command '$PSVersionTable.PSVersion'`: Windows PowerShell 5.1.

   If one is missing or fails, stop and tell me which, and how to install or fix it.
2. **Clone Scriptorium** into the folder above, if it is not there:
   `git clone https://github.com/KadaXuanwu/Scriptorium "<Scriptorium folder>"`. If it is there, run `git pull` in it.
3. **See what setup will do.** Run, from this repo's root:

   ```powershell
   powershell -NoProfile -ExecutionPolicy Bypass -File "<Scriptorium folder>\setup.ps1" -Project . -Workers <Workers> -WhatIf
   ```

   Read the output. It names the plugins it detects for this project. If one is wrong, or one is missing, tell me before
   you go on. Run it again with `-Plugins <names>` when I name others.
4. **Run setup.** The same command without `-WhatIf`, with `-Commit -Start`. If it stops, do what its output says
   and run it again. Where it says to install a tool, tell me first.
5. **Check the commit.** Setup committed and pushed the files it added (`scriptorium.json`, `.gitignore`, the ticket
   skill, the plugins' files). Run `git log -1 --stat` and `git status`, and check that the push reached origin.
6. **Add a short section to `CLAUDE.md`** of this repo (make the file if there is none), and commit and push it:

   ```markdown
   ## Work queue

   Scriptorium runs the work queue of this repo (<Scriptorium folder>). Tickets are GitHub issues; workers build them
   and open PRs. To file a ticket, report the queue or pass on an answer, use the ticket skill
   (`.claude/skills/ticket`). The page: http://127.0.0.1:<port>. Never touch the worker copies (`<this folder>-w<N>`).
   ```

   Use the port from `scriptorium.json` (8770 when it has none).
7. **Check the page.** Run `curl -s http://127.0.0.1:<port>/api/state` and check that it lists the workers. A worker
   may show "Setting up" or the words of a plugin for a while.

## What only I can do

At the end, tell me in a short list what is set up, what you could not check, and these steps, which wait on me:

1. **Accounts.** One worker runs on my own Claude Code login. To add a plan account, open the page, Accounts, and use
   the last tile: I sign in in the browser and paste the code.
2. **Phone.** Sign in to Tailscale on the PC and on the phone. Open the link that `tailscale serve` printed, to allow
   Serve. Then open the page on the phone, at the address that setup printed ("On your Tailscale devices"), and add it
   to the home screen. If the PC already has a project, skip this: the new project shows in that app, beside the
   first.
3. **Pushes.** Install the ntfy app and subscribe to the topic that setup printed.
4. **Plugins.** Anything a plugin's README says a human must do (for example, install an editor).

## Rules for the setup

- Run setup again rather than doing one of its steps by hand: it is safe to run again.
- Never change Scriptorium's own files. A fault in it: tell me what it is, with the output.
- Do not report a step as done if you did not check it.
