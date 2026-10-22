# Pull requests

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

Whenever you open or write the description for a pull request, end the body
with the output of `pr-line-counts`, run from the branch the PR is made from:

    pr-line-counts            # against the repository's default branch
    pr-line-counts <base>     # against another base branch

| Category | Added | Removed | Change |
|----------|------:|--------:|-------:|
| Code     | 120 | 45 | +75 |
| Comments | 14 | 3 | +11 |
| Docs     | 38 | 40 | -2 |
| Tests    | 85 | 0 | +85 |
| Total    | 257 | 88 | +169 |

- Paste the table as it prints; do not recount or adjust it by hand. It counts
  only lines added and removed from the merge base to `HEAD`, so commit first,
  and pass the PR's real base if it is not the default branch. Change is added
  minus removed. `pr-line-counts -u` also counts uncommitted work, untracked
  files included, to preview the numbers; do not paste that one into a PR.
- Put it last, after everything else in the description.
- A note on stderr such as "no comment rules for .lua; counted as code" means
  that language's comments are in the Code row. Add one line under the table
  saying so, so the number is not read as exact.
- Leave the table out when the PR is not yours to describe.

`pr-line-counts` is on `PATH` from `~/dotfiles/bin`. If it is not there -- a
machine without these dotfiles -- say that the table is missing rather than
estimating one.
