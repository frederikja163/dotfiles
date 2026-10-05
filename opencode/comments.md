# Comments

**The default is no comments.** Most changes should add none at all — expect
roughly four in five changes to add zero. If you are adding a comment on every
change, you are writing too many. Before you add one, assume the answer is no.

## Never

- Doc comments (docstrings, JSDoc, `///`, `---@param`, `"""..."""`) on
  internal, private, local or unexported functions, methods, classes or
  variables. Do not add them even when other functions in the file have them.
- Comments that narrate what the next line does, restate a name, label a
  block, or put a heading over a few lines of obvious code.
- Comments describing the change you just made ("now uses X", "fixed bug",
  "added for Y") — that belongs in your reply or the commit, not the code.
- Adding comments because the surrounding file is heavily commented. Matching
  the existing style means matching its formatting *when* a comment is
  warranted, not matching its density.

## The only reasons a comment may be added

- It explains something **surprising**: why the obvious approach is wrong, a
  workaround for a bug or quirk elsewhere, a constraint not visible from the
  code.
- It **links code that is not adjacent**: this constant must match that
  parser, this must run before that hook.
- The user or the project's instructions **explicitly** ask for it (e.g. "doc
  comments on every exported symbol"). Vague guidance like "document your
  code" or a linter wanting a docstring does not count.

Even then, prefer fixing the cause: a name that needs explaining wants
renaming. Keep any comment you do write to one line where one line does.

## Report every comment you added

If a change adds or rewrites any comment, end your reply with a numbered table
listing **every** one, so the user can approve them individually:

| # | Location | Comment | Justification |
|---|----------|---------|---------------|
| 1 | `src/foo.ts:42` | `// Retries twice: the API drops the first request after idle` | Workaround for an external quirk not visible in the code |

- Number from 1 in each reply; the numbers are how the user refers back.
- Location is `path:line`. Quote the comment (shorten long ones with `…`).
- Justification names which reason above applies. If you cannot name one,
  delete the comment instead of listing it.
- Leave the table out entirely when no comments were added — do not write
  "no comments added".

When the user answers with the numbers to keep (e.g. "keep 1 and 3"), remove
every other comment in the table and leave the code otherwise unchanged. If
they say "none", remove them all.
