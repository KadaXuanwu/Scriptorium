# Playbook: another repository

A part of `PLAYBOOK.md`, in its folder. Read it when the ticket has a `repo:<Name>` label. A number or a name in
brackets is a step or a part of `PLAYBOOK.md`.

**Another repository.** A ticket labelled `repo:<Name>` stays in this queue, but its work and its PR are in the owner's
repo `<Name>`. The worker script runs it in `<Name>-w<N>` beside its copy (cloned on first use, with the copy's GitHub
identity), with what the plugins give for that repo, and adds the copy to the run (`--add-dir`). The merger merges
worker PRs there too and closes the ticket. Such a repo needs the bots as collaborators and the PR labels (`repos` in
`scriptorium.json`; setup makes the labels). For the run, what differs from the steps of `PLAYBOOK.md`:

- The ticket and its comments are in this repo: `gh issue … -R <owner>/<this repo>`, reactions on
  `repos/<owner>/<this repo>/issues/<N>/comments`. The PR, its comments and its labels are in the other repo (your
  working folder's default).
- Branch `t<N>` from that repo's `main`. The queue folder that the job names is in your copy of this repo.
- This repo's `CLAUDE.md` (in your copy) still sets the response style and the rule on attribution; that repo's own
  README and code set its conventions. Read this repo's `CLAUDE.md` in step 2: your copy is an added folder, so it is
  not in your context. Update its docs. Anything this repo's docs need goes under **For this repo** in
  the PR body, for the front desk.
- The checks are that repo's own.
- The PR body: `Closes <owner>/<this repo>#<N>`.
