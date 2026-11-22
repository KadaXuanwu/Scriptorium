# Playbook: follow-ups

A part of `PLAYBOOK.md`, in its folder: the `## Follow-up` section of the PR body (Ship). Read it before you write a
`###` under Follow-up. A name in brackets is a part of `PLAYBOOK.md` or of this file.

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
**Start here:** what you found: the files (linked), the mechanism, what you ruled out. The next run starts here.
**Scope:** what it includes and what it leaves out.
**Done when:** a check the next run can do itself, with numbers.
**Decisions:** this ticket's rules that still apply, or None.
**Questions:** the banner's line (`PLAYBOOK-pictures.md`), then what only the owner can decide, numbered: the question,
the default the next run takes, the other choices and what each changes. Or None (Ask or queue).
```

The page shows the owner the Summary and the Questions as one question, the rest folded. The answer arrives as a
comment on the follow-up ticket (Comments) and overrides its defaults; with no comment, the owner took every
default.
