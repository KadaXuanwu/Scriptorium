# Playbook: pictures

A part of `PLAYBOOK.md`, in its folder. Read it when you build a new look or ask a question with a picture. A name in
brackets is a part of `PLAYBOOK.md` or of this file.

**The owner's pick.** A new look (an icon, an effect, a layout) comes as three plain candidates that differ in something
worth choosing between, also for a placeholder. Build them, wire the first, and make the pick an open question with a
screenshot of each (Pictures). Polish nothing before the owner confirms the feature.

**Pictures.** A question that a picture makes clearer (a look, a layout, where a thing stands) carries screenshots. Save
each as a PNG in a folder git ignores, named for its choice (`header-a.png`). Then run
`powershell -NoProfile -File <the Scriptorium folder>/shots.ps1 -Ticket <N> <files>` in your copy. It puts them on the
branch `shots-t<N>`, never on `t<N>` or main, and prints one markdown line for each picture. Paste each line into the
question, beside the choice it shows (`- A, flat header (default): ![header-a](...)`). The page and GitHub show them.
