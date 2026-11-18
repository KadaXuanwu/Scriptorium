# Playbook

The rules of a run: one headless Claude session that does one job in a worker's copy of the repo. The worker script
starts it with a job: a ticket (branch `t<N>`), a held PR that is now `answered`, or a PR to rebase. The queue's parts,
labels, dispatching, models and settings are in [docs/QUEUE.md](docs/QUEUE.md). A run does not need them.

A run reads three playbooks in this order: this one, the `PLAYBOOK.md` of each plugin, and the project's own. Where two
differ, the later one wins.

**Nobody is there.** Never ask, never wait: no question prompts.

**What to ask.** Ask the owner only what the owner decides: a rule of the product, what a user sees or does, the UI, a
look or a sound. For example: "May a user delete a file that others share?" Never ask about the workflow: merge or
keep working, the order of tickets, run it now or later, run a check first. Decide those yourself and write the choice
in the PR. A bug fix, a technical fix, an optimization or a tool is never a question. A number is a placeholder, never
a question. Ask rarely: take a default from the project's docs and the ticket wherever they give one. Each question is
one of two kinds:

- **Open question** (the usual kind): the answer is easy to take, or it is cheap to change later (a small edit, at most
  `size:S`: a look, a wording, one setting, one small rule). Build the recommended answer so that it is easy to change,
  write it where the project keeps its decisions, and put the question under the PR's Open questions (Ship). The PR
  merges.
- **Blocking question:** a wrong answer is expensive to undo after the merge (a rule other work builds on, a data shape,
  much rework), and the choice is not easy. List it under Held questions and hold the PR (Hold or merge). If nothing
  can be built without the answer: push the branch, comment the question on the ticket (the options and what each
  changes), run `gh issue edit <N> --add-label needs-owner`, and stop.

**The owner's pick.** A new look (an icon, an effect, a layout) comes as three plain candidates that differ in something
worth choosing between, also for a placeholder. Build them, wire the first, and make the pick an open question with a
screenshot of each (Pictures). Polish nothing before the owner confirms the feature.

**Pictures.** A question that a picture makes clearer (a look, a layout, where a thing stands) carries screenshots. Save
each as a PNG in a folder git ignores, named for its choice (`header-a.png`). Then run
`powershell -NoProfile -File <the Scriptorium folder>/shots.ps1 -Ticket <N> <files>` in your copy. It puts them on the
branch `shots-t<N>`, never on `t<N>` or main, and prints one markdown line for each picture. Paste each line into the
question, beside the choice it shows (`- A, flat header (default): ![header-a](...)`). The page and GitHub show them.

**Writing.** Comments, questions, PR bodies, follow-up tickets and commit messages follow the style of the project's
`CLAUDE.md`, with its terms.

**Turns.** Each turn reads your whole context again, so the turn is the unit of cost. Send independent reads and
searches in one message. Read the part of a file that you need once, in one range. Keep a command's output short (`-q`,
`| head`, `| tail`).

**Comments.** Everything a run writes on GitHub starts `**Worker <id>:**`. Any other comment is the owner's (or the
front desk's for them), and it overrides the ticket. A comment is read when it carries your 👀. List a ticket's or a
PR's comments with `gh api repos/{owner}/{repo}/issues/<number>/comments` (`id`, `body`, `reactions.eyes`). For each
unread one, react (`gh api -X POST repos/{owner}/{repo}/issues/comments/<id>/reactions -f content=eyes`) and reply in
one line what you do with it (`**Worker 1:** Read. Moving the check to the server; redoing the form part.`). Never
@-mention the owner or request their review: the page tells their phone what waits on them.

**Checkpoints:** after reading the job, after each major part, and before shipping. At each:

1. Commit what you have and push it to `t<N>` (`git push --force-with-lease -u origin t<N>`; the merge squashes it), so
   nothing is lost if the run stops.
2. Read new comments (the PR's too, once there is one).
3. In the queue folder that the job names, write `progress.json`: `{"ticket": <N>, "done": "<the part just done>",
   "next": "<the next part>"}`, on one line, for the page.
4. Look for `limit.md`, `stop.md` and `comments.md` in the queue folder.

Claude Code compacts your context when it grows large: the checkpoint's commit and `progress.json` are what you find
again after it.

**Comment note.** `comments.md` in the queue folder means the owner commented on the ticket or the job's PR, and the run
has not read it. While a run works, the worker script checks every 2 minutes and writes the note, with each place and
its count. It deletes the note once each comment has 👀. At the checkpoint, read them (Comments).

**Stop.** `stop.md` in the queue folder means the owner paused or disabled your worker. Commit and push what you have,
post one handoff comment on the ticket (done, next), and end the run without a PR. It is not a failure. After a pause,
the worker script compacts your session and resumes it when the owner sets the worker active: checkpoint first, then
carry on where you stopped. After a disable, another worker starts the ticket fresh from your handoff comment. You
cannot tell the two apart, so always write it.

**Usage limit.** `limit.md` in the queue folder means the account reached the workers' usage limit. The worker script
writes it; it says which window and when it resets. End at your next checkpoint, with your work pushed, your questions
and one handoff comment on the ticket, and no PR. The script then compacts your session, holds it, and resumes it when
the account has room: checkpoint first, then carry on. It is not a failure. If the plan's own limit cuts you off first,
the script resumes the same session after the reset.

**Fable limit.** If your account reaches its weekly Fable limit while you run on Fable, the script resumes your session
on another model, and its message says what to do. If the decisions the ticket is on Fable for are made and written
down, finish on the other model and name both models in the PR body. If not, commit and push, post one handoff comment
(done, the decisions still open, next), write `handoff.md` in the queue folder, and end without a PR. A worker whose
account has Fable then starts the ticket fresh from your comment.

## The steps

1. **Branch.** `git fetch --prune`. Already on `t<N>` with uncommitted changes: they are this job's, from a run that
   was cut off. Commit them; do not reset. Otherwise the copy is yours: `git reset --hard` and `git clean -fd` (never
   `-x`) clear an old run. If `origin/t<N>` exists (a run before you, an answer, a rejected PR), run
   `git checkout -B t<N> origin/t<N>` and `git rebase origin/main`. Else run `git checkout -B t<N> origin/main`.
2. **Read** `gh issue view <N> --json title,body,comments` (plain `gh issue view` prints nothing headless) and the
   comments (Comments): the ticket, its decisions, any answers, why an earlier PR was closed. Then the project's
   `CLAUDE.md` and the docs it points to for this work.
3. **Build to done.** The code, its tests, and the docs the work makes wrong. Run the project's checks (the plugins'
   playbooks and the project's own say which) as far as the change needs. A change to docs alone needs none. Something
   broken that you did not touch: fix it and say so in the PR.
4. **Broken tools.** A tool or a server is gone: start it again and retry. If it stays down, carry on with what does not
   need it, and come back. A step that needs a permission you lack: find another way, or ask a held question.
5. **Rebase** (shipping, and the rebase job): `git fetch`, then `git rebase origin/main`. You know your ticket: read the
   other side's change (`git log origin/main`, its PR) and keep it whole. If it brought changes, run the checks again.
   A file that `.gitattributes` merges by union keeps both sides' lines: `git diff origin/main -- <file>` must show only
   your change. A line that both sides rewrote shows twice, and a line main deleted can come back. Fix it.
6. **Hold or merge.** Only a blocking question holds the PR (What to ask); open questions merge on their defaults. A
   hold keeps the ticket's areas busy until it is answered: weigh what waits on them (`gh issue list --label
   area:<x>`). **Done not reached** never holds. The ticket's Done line and Scope are the gate: work toward them while
   the plan has usage. If you cannot reach them (the approach runs out), merge the part. Say in the PR where it stands
   against Done (the numbers) and what you would try next, and put the rest of Done under Follow-up as one `###` with
   Questions None, so it is queued. If a rule in the way is the owner's, that rule is the question: open or blocking,
   by What to ask.
7. **Ship.** Commit (a one-line message), rebase (5), and read `git diff origin/main --stat`: nothing you did not mean.
   Read What to ask, Hold or merge and this step again before you write the body: the rules can change during a long
   run. Run `git push --force-with-lease -u origin t<N>`, then
   `gh pr create --base main --head t<N> --title "<the ticket's title>" --label worker:<id> --body-file <file>`, with
   `--label needs-owner` when you hold it. The body:
   - `Closes #<N>`
   - What it does for the user, then the cause.
   - **Decision:** only when you hold it: one line, at most 25 words, the choice the owner makes and its default
     (`**Decision:** May a user delete a shared file? Default: no.`), never a workflow choice. The page shows this line
     on the card and folds the Held questions away.
   - **Held questions:** the blocking questions, each with the default and what changes with the answer; or None.
   - **Verified:** which checks, and the test count.
   - **Model:** the model and effort the run started with (the job names them).
   - `## Open questions`: the open questions (What to ask), one `###` each, or None. When the PR merges, the merger files
     each as a ticket labelled `open-question`, shown under the page's Questions. The owner keeps the default (the
     ticket closes, and nothing runs) or changes it (the ticket is queued with the answer, and its run changes the built
     default). The next run has only this text:

     ```
     ### <title: the decision, in the product's words>
     **Summary:** one sentence the owner reads on a phone: the question.
     **Questions:** numbered: the question, the default built, the other choices and what each changes.
     **Where:** where the default lives: files, config fields, tests (linked). A changed answer starts here.
     ```

   - `## Follow-up`: work **outside this ticket** that the work turned up and the owner would want: a bug seen
     elsewhere, a cost measured, a limit found. None is the usual answer. Not a follow-up: anything the ticket's Scope
     or Done asked for (finish it, or file the rest: Hold or merge), the feature's own edge cases, or polish nobody asked
     for.

     **Generation:** the merger ends each follow-up with a `**Generation:**` line, one more than its ticket's. From 2
     the line is a soft cap, stricter in each generation: obey its note. What it holds back goes under `## Not filed`
     in the body, one line each; the merger files nothing from that section. When the PR merges, the merger files each
     `###` as a ticket. If it has no Questions, the merger queues it (P1). If it has Questions, it is a draft labelled
     `follow-up` and waits under the page's Questions until the owner answers it or takes its default.

     **Ask or queue.** A follow-up asks only when it changes what the owner decides (What to ask): a new feature or
     rule, a change the user sees beyond a fix, the UI. Then the first question is "Do this?", with your default
     written `Default: yes.` or `Default: no.` (a script reads the word: taking a "no" closes the ticket, and no run
     starts), the cost (size) and what is lost if it is dropped. A bug fix, a technical fix, an optimization or a tool
     never asks: Questions None. If an optimization changes what the user sees, ask about that change, or scope the
     work to avoid it. The next run has only this text, so write each as fully as the front desk writes a ticket (the
     ticket skill, Filing a ticket):

     ```
     ### <title: imperative, in the product's words>
     **Summary:** one sentence the owner reads on a phone: what the product does once it is done.
     **Now:** what happens today, with the numbers you measured.
     **Should:** what the user should see or be able to do.
     **Where:** the screen or the part, and how to see it (a command, a test, the clicks).
     **Repo:** only when the work is in another repo than this ticket's: that repo's name, or this one's.
     The merger gives the follow-up that repo's label (Another repository); without it, the run looks in the wrong repo.
     **Size:** one of S, M, L.
     **Complexity:** one of the project's complexities (low, medium, high, design, or its own).
     Decide size and complexity again for this work by the ticket skill's rules (Filing a ticket), never from this
     ticket's labels. The merger gives the follow-up those labels; without a line, M and medium.
     **Area:** the `area:*` names of the files it changes (ticket skill, Areas), also when they are this ticket's. The
     merger makes a new one. Without this line, the follow-up keeps this ticket's areas.
     **Cause:** what you found: the files (linked), the mechanism, what you ruled out. The next run starts here.
     **Scope:** what it includes and what it leaves out.
     **Done when:** a check the next run can do itself, with numbers.
     **Decisions:** this ticket's rules that still apply, or None.
     **Questions:** what only the owner can decide, numbered: the question, the default the next run takes, the
     other choices and what each changes. Or None (Ask or queue).
     ```

     The page shows the owner the Summary and the Questions as one question, the rest folded. The answer arrives as a
     comment on the follow-up ticket (Comments) and overrides its defaults; with no comment, the owner took every
     default.
8. **Answered job** (PR `#M`): branch (1), and read the PR's and the ticket's comments (Comments: every unread one gets
   👀 and a reply, or the merger sends it back again). Apply the answers and corrections, run the checks the change
   needs, rebase (5), push, write the answers into the PR body's Held questions, and run
   `gh pr edit <M> --remove-label answered`. An answer that raises a new blocking question: hold again, and comment it.
9. **Rebase job** (PR `#M`): branch (1), rebase (5), `git push --force-with-lease`, then
   `gh pr edit <M> --remove-label needs-rebase`. If it cannot be resolved: comment why on the PR, and add `needs-owner`.

**Another repository.** A ticket labelled `repo:<Name>` stays in this queue, but its work and its PR are in the owner's
repo `<Name>`. The worker script runs it in `<Name>-w<N>` beside its copy (cloned on first use, with the copy's GitHub
identity), with what the plugins give for that repo, and adds the copy to the run (`--add-dir`). The merger merges
worker PRs there too and closes the ticket. Such a repo needs the bots as collaborators and the PR labels (`repos` in
`scriptorium.json`; setup makes the labels). For the run, what differs from the steps above:

- The ticket and its comments are in this repo: `gh issue … -R <owner>/<this repo>`, reactions on
  `repos/<owner>/<this repo>/issues/<N>/comments`. The PR, its comments and its labels are in the other repo (your
  working folder's default).
- Branch `t<N>` from that repo's `main`. The queue folder that the job names is in your copy of this repo.
- This repo's `CLAUDE.md` (in your copy) still sets the response style and the rule on attribution; that repo's own
  README and code set its conventions. Update its docs. Anything this repo's docs need goes under **For this repo** in
  the PR body, for the front desk.
- The checks are that repo's own.
- The PR body: `Closes <owner>/<this repo>#<N>`.

**No AI attribution anywhere:** no `Co-Authored-By`, no "Generated with Claude Code" line, in commits, PR descriptions
or comments. The `**Worker <id>:**` prefix is the only signature.

**Stay in your lane:** only branch `t<N>`, your ticket and your PR. Never push or merge main, never touch another
checkout, never change labels beyond the steps above.
