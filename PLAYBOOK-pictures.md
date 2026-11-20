# Playbook: pictures

A part of `PLAYBOOK.md`, in its folder. Read it when you build a new look or ask the owner a question: every question
has a picture. A name in brackets is a part of `PLAYBOOK.md` or of this file.

**The owner's pick.** A new look (an icon, an effect, a layout) comes as three plain candidates that differ in something
worth choosing between, also for a placeholder. Build them, wire the first, and make the pick an open question with a
screenshot of each (Pictures). Polish nothing before the owner confirms the feature.

**Banner.** Every question to the owner has one banner picture, whatever it asks: an open question, a held one, a
question on a ticket, a follow-up that asks. It is a screenshot that shows what the question is about, as close to it
as you can get: the screen, the object or the place the answer changes. A question about a rule shows the screen where
the rule acts (for "May a user delete a shared file?", the file's menu). A project with no screen shows the output the
question is about. Never a picture that only decorates. The page cuts the banner to a wide, low strip (3:1) around its
middle, so the subject stands in the middle third of the height; a tap shows it whole. Paste its line as a line of its
own, the first line of the question (under `**Questions:**`, under `**Held questions:**`, or first in the comment). A
question with no banner is not finished: take the screenshot before you write the question. The merger checks the
PR's Open questions and Follow-up, and sends a PR without a banner back to you as an answered job.

**Choices.** A question that a picture makes clearer (a look, a layout, where a thing stands) also carries one
screenshot for each choice, all from the same camera and at the same size, so that only the choice differs. Write each
choice as a list line and paste its picture's line at the end of it
(`- A, flat header (default): what it changes. ![header-a](...)`). A choice with no picture is a list line too.

**Layout.** The page lays the pictures out, the same for every count: the banner on top of the card, each choice a row
with its picture, and a viewer that steps through the choices. Write nothing for the layout: no table, no HTML, no
sizes, no order tricks.

**Upload.** Save each picture as a PNG in a folder git ignores, named for what it shows (`banner.png`, `header-a.png`).
Then run `powershell -NoProfile -File <the Scriptorium folder>/shots.ps1 -Ticket <N> <files>` in your copy. It puts them
on the branch `shots-t<N>`, never on `t<N>` or main, and prints one markdown line for each picture. The page and GitHub
show them.
