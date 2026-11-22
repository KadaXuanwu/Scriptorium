# Playbook: answered and rebase jobs

A part of `PLAYBOOK.md`, in its folder: steps 8 and 9 of The steps. Read it when your job is one of them. A number or
a name in brackets is a step or a part of `PLAYBOOK.md`.

8. **Answered job** (PR `#M`): branch (1), and read the PR's and the ticket's comments (Comments: every unread one gets
   👀 and a reply, or the merger sends it back again). Apply the answers and corrections, run the checks the change
   needs, rebase (5), push, write the answers into the PR body's Held questions, and run
   `gh pr edit <M> --remove-label answered`. An answer that raises a new blocking question: hold again, and comment it (never while the owner is away:
   `PLAYBOOK.md`, Away).
9. **Rebase job** (PR `#M`): branch (1), rebase (5), `git push --force-with-lease`, then
   `gh pr edit <M> --remove-label needs-rebase`. If it cannot be resolved: comment why on the PR, and add `needs-owner`.
