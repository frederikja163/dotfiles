---
name: makepr
description: The full instructions for the /makepr command - checking the branch is committed and pushed, creating the pull request with gh, keeping the description short and ending it with the lines-changed table. Loaded by /makepr, not advertised on its own.
metadata:
  opencode/autoinvoke: false
---

## Before creating it

- Work out the branch (`git rev-parse --abbrev-ref HEAD`) and the base. The base
  is the repository's default branch (`git symbolic-ref refs/remotes/origin/HEAD`)
  unless I named another. Say both in one line.
- Check that the work is committed and that the branch is where I say it is,
  from local state only (`git status -sb`, `git log --oneline @{u}..`). Do not
  fetch or contact the remote to check; that is mine to do. If the tree is
  dirty, or commits are not on the upstream, stop and say which. For the first,
  the commit agent (`/commit`) makes the commit; for the second, give me the
  exact `git push` command to run. Do not push, and do not set up a remote, a
  token or HTTPS to get round it.
- Read the commits and the diff against the base (`git log --oneline BASE..`,
  `git diff BASE...`) so the description says why, which is what the diff does
  not.

## Create it

Use `gh pr create --base BASE --head BRANCH --title ... --body-file ...`, with
the title and body given outright so nothing prompts. Never let `gh` push the
branch for you. Where the repository has a pull request template, keep its
sections; the rules below still apply to what goes in them. Report the URL
afterwards, and nothing else about it.

The title is one line, in the style of the project's recent commit subjects.

## Keep the description short

A PR description is read in seconds, by someone who can open the diff. Write
the least that lets them review it:

- One or two sentences on what changed and why. The why matters more than the
  what, since the diff already shows the what.
- At most a few bullets, and only for things a reviewer could not guess: a
  behaviour change, a migration, something deliberately left out. Skip it
  when there is nothing like that.
- No file-by-file walkthrough, no restating the commit list, no "Summary",
  "Changes", "Testing" or "Notes" headings, and no checklist of what you
  verified. Mention testing only when it was unusual or is missing.
- If it runs past about ten lines before the table, cut it.

## Line counts

End the body with the output of `lines-changed --require-clean`, run from the
branch the PR is made from:

    lines-changed --require-clean                  # against the repository's default branch
    lines-changed --require-clean BASE:<branch>    # against another base branch

| Category | Added | Removed | Change |
|----------|------:|--------:|-------:|
| Code     | 120 | 45 | +75 |
| Comments | 14 | 3 | +11 |
| Docs     | 38 | 40 | -2 |
| Tests    | 85 | 0 | +85 |
| Total    | 257 | 88 | +169 |

- Paste the table as it prints; do not recount or adjust it by hand. It counts
  only lines added and removed from the merge base to `HEAD` (`BASE`, which is
  what a pull request shows), so the work has to be committed first.
  `--require-clean` is what holds you to that: with uncommitted work it prints
  no table and exits with status 3. Stop and ask me to run `/commit`, then run
  it again; do not drop the flag to get a number out of it.
- Pass the PR's real base as `BASE:<branch>` if it is not the default branch.
  A bare branch name means that branch's tip, which also counts whatever it
  gained after the PR branched off. Change is added minus removed.
- A bare `lines-changed` counts uncommitted work too, untracked files included,
  which is right for checking your size while you work and wrong for a PR; do
  not paste that one. `--committed` leaves uncommitted work out, and
  `--require-clean` is the form that refuses rather than leave it out.
- Put it last, after everything else in the description.
- A note on stderr such as "no comment rules for .conf; counted as code" means
  that language's comments are in the Code row. Add one line under the table
  saying so, so the number is not read as exact. A note that generated files
  (lockfiles, minified bundles) were left out needs nothing.

`lines-changed` is on `PATH` from `~/dotfiles/bin`, and runs on `dotnet-script`.
If it is not there -- a machine without these dotfiles -- say that the table is
missing rather than estimating one.
