# Comments

**Default to no comments.** The only standing exception is the documentation
comment on a public method or function, described below, and only in a project
that already documents its public methods. Anything else needs the user to ask
for it, in that request or in the project's instructions. Vague guidance like
"document your code" does not count as asking.

A project can change the default. If its instructions say its files are
documented heavily, or a linter or build step enforces comments, follow that
project's style and density instead. Treat a heavily commented file as a hint
that this may be the case, not as permission: when the project has not said so,
fall back to the default and ask if unsure.

## What counts as a project

The rules apply per project, not per repository. In a monorepo, each project
(a `.csproj`, a package, a service, a crate) is judged on its own: one project
documenting its public methods says nothing about its neighbour, and one
project's instructions or linter settings do not carry over. Never bring the
commenting habits of one project into another.

## Doc comments

Add a doc comment to a public method or function **only if the rest of that
project's public methods already have them**. Look at the existing code before
writing one. If the project's public methods are mostly undocumented, add none,
even though the language has a doc-comment format.

When the project does document them, match its format and level of detail, and
document only the methods you write or change.

### C#

An XML documentation comment (`/// <summary>`, with `<param>`, `<returns>` and
`<exception>` where the project uses them) on each public method. Nothing else
gets one: not private, internal or protected methods, not fields, locals or
tests, and no `//` or `/* */` comments anywhere.

### Other languages

The same rule, in the language's own convention: a doc comment on public or
exported functions and methods only, and nothing else.

| Language | Doc comment |
|----------|-------------|
| TypeScript / JavaScript | TSDoc / JSDoc on exported functions |
| Python | docstring on public functions and methods |
| Java / Kotlin | Javadoc / KDoc on public methods |
| Go | doc comment on exported functions |
| Rust | `///` on `pub` functions |

Where a language has no such convention (shell, Lua, config files), add no
comments at all.

## Never, unless asked or the project says otherwise

- Comments that narrate what the next line does, restate a name, label a
  block, or put a heading over a few lines of code.
- Comments describing the change you just made ("now uses X", "fixed bug").
  That belongs in your reply or the commit.
- Explanatory comments for workarounds or non-obvious behaviour. Put the
  explanation in your reply instead, and let the user decide whether it
  belongs in the code.
- Doc comments on anything that is not a public method or function.

When editing existing code, do not add, rewrite or remove comments beyond what
the change itself requires.

## Report every other comment

Doc comments on public methods, added where the project already has them, need
no report. If you add any other comment because the user asked for one, end your
reply with a numbered table listing it:

| # | Location | Comment | Justification |
|---|----------|---------|---------------|
| 1 | `src/foo.ts:42` | `// Retries twice: the API drops the first request after idle` | User asked for it |

- Number from 1 in each reply; the numbers are how the user refers back.
- Location is `path:line`. Quote the comment (shorten long ones with `…`).
- Leave the table out when there is nothing to list.

When the user answers with the numbers to keep (e.g. "keep 1 and 3"), remove
every other comment in the table and leave the code otherwise unchanged. If
they say "none", remove them all.
