# Working in this repo

**This repo is the running system.** `install.sh` installs the packages and
symlinks every directory into place, so editing a file here changes the live
machine immediately. `hypr/` is
read by the compositor the user is sitting in right now, and `zsh/` by their
open shells.

That has one consequence worth holding on to: **a mistake here is not a failing
test, it is the user's desktop.** Prefer the sandbox to the live session, and
prefer asking to guessing when a change is hard to undo.

- Verify with `./tests/run.sh` — stubbed Lua tests plus
  `Hyprland --verify-config`, safe at any time.
- Anything needing a real compositor goes in `./tests/sandbox.sh`, which hides a
  nested Hyprland in a special workspace. Never start one on a visible desktop:
  it becomes a tiled window and rearranges everything the user has open.
- Never run `pkill` or `killall` on a pattern that matches system-wide. They
  reach the user's own programs, and a pattern matching the running command line
  kills the shell executing it. Kill by pid.
- `hyprctl` with no `-i` talks to the live session. Reading it is fine;
  dispatching to it is not, unless asked.

**Never commit unless asked for a commit in so many words.** A feature here is
often built across many prompts, and several turns of work belong in one commit
rather than one each. A dirty working tree is the normal state between them, not
something to tidy away — finishing a change is not a reason to commit it. Say
what is left uncommitted and wait. Commits are made by the `commit` agent, which
plans the split, shows it as a table for approval and only then commits, and is
the one mode where `git commit` runs without a prompt. plan refuses it outright;
build asks, so a commit it is told to make costs one confirmation, but switching
agent is still the better answer because the split and the table come with it.
`opencode.json` keeps its commit rule ask as a backstop for any agent that is
not one of those three.

**No agent pushes, in any mode.** Every mode denies `git push` outright rather
than asking, because running one needs the user's SSH key or an HTTPS token and
there is no approval that avoids handing it over. When work should be
published, say so, give the exact command, and stop; the user pushes and tells
you to carry on.

`roadmap.md` is the user's own notes. `opencode.json` denies reading and editing
it; that is deliberate, not an obstacle to route around.

Nothing secret belongs in this repo — it is public on GitHub. Credentials stay
in `~/.local/share/opencode/auth.json`, which is outside the config directory
and is not tracked. opencode's global config *is* tracked, as `opencode/`,
linked to `~/.config/opencode` — it carries the model and the agents and
nothing private. Keep it that way: an API key belongs in `auth.json`, not in
a `provider` block here.

The reasoning for anything non-obvious lives in a comment at the top of the file
it concerns, and is expected to say what was tried and rejected. `README.md` is
only an index. See `.opencode/skills/` for the compositor API's silent
failures, the testing harnesses, and the repo's conventions.

Skip the numbered comment table from `~/.config/opencode/comments.md` in this
repo; the rules on when to write a comment still apply.
