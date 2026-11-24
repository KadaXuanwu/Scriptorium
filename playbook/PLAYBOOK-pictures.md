# Playbook: pictures

A part of `PLAYBOOK.md`, in its folder. Read it when you build a new look or ask the owner a question. A name in
brackets is a part of `PLAYBOOK.md` or of this file.

**The owner's pick.** A new look (an icon, an effect, a layout) comes as three plain candidates that differ in something
worth choosing between, also for a placeholder. Build them, wire the first, and make the pick an open question with a
screenshot of each (Choices). Polish nothing before the owner confirms the feature.

**Banner.** Every question to the owner starts with one banner picture, whatever it asks: a screenshot of what the
answer changes (the screen, the object, the place). A rule: the screen where it acts. No screen: the output it is
about. Never decoration. The page cuts it to a 3:1 strip around its middle: keep the subject in the middle third of
the height. Its line stands alone, first in the question (under `**Questions:**` or `**Held questions:**`, or first in
the comment). The merger sends a PR whose Open question or Follow-up lacks one back to you.

**Choices.** A question about a look, a layout or where a thing stands also has one screenshot for each choice, all
from the same camera at the same size. Each choice is a list line with its picture's line at its end
(`- A, flat header (default): what it changes. ![header-a](...)`); a choice with no picture is a list line too. The
page lays out every count of pictures: write nothing for the layout (no table, no HTML, no sizes).

**Upload.** Save each picture as a PNG in a folder git ignores, named for what it shows (`banner.png`, `header-a.png`).
Then run `powershell -NoProfile -File <the Scriptorium folder>/shots.ps1 -Ticket <N> <files>` in your copy. It puts them
on the branch `shots-t<N>`, never on `t<N>` or main, and prints one markdown line for each picture to paste.
