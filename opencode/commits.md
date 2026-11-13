# Commits

Only the `commit` agent makes commits. The `build` and `plan` agents deny
`git commit`, and a denied command reports nothing more than
`Permission denied: shell`, which says neither why nor what to do.

## When a commit is denied

That is the expected setup, not a fault, a missing permission or something to
ask the user to loosen. Do not retry it, do not try another way to record the
commit (`git commit-tree`, `git stash`, `git am`, scripts that call git), and do
not offer to "allow shell commands".

Say it in two sentences, using the numbers the user can act on:

> `git commit` is denied in this mode; commits are made by the commit agent.
> Switch to it (Tab cycles agents) and say "commit"; the work is left
> uncommitted in the tree until then.

Then carry on with anything that does not need the commit.

## Before asking for the commit agent

- Finish the edits first. The commit agent cannot edit files.
- Say what is waiting to be committed in one line, so the user can correct it,
  and say which branch it is on.
- Anything that needs a clean tree, such as `lines-changed --require-clean` for
  a pull request description, waits for the commit. Say so rather than running
  the bare form.
