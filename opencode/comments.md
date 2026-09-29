# Comments

Write far fewer than feels natural. A comment earns its place two ways:

- It explains something **surprising** — why the obvious approach is wrong,
  which of two plausible readings is intended, a workaround for a bug or a
  quirk elsewhere, a constraint that is not visible from the code.
- It **links code that is not adjacent** — this constant must match that
  parser, this runs before that hook, this is re-applied because a rule only
  fires once.

Nothing else qualifies. Do not narrate what the next line does, restate a
name, label a block, or leave a heading over three lines of obvious code.
Deleting a comment that only says what the code says is an improvement.

Keep them short. One line where one line does, and never two sentences making
the same point twice. Say the thing once and stop; a reader who needs more
will read the code, which is the authority anyway.

Prefer fixing the cause. A name that needs explaining wants renaming, and a
function that needs a paragraph usually wants splitting.

Defer only to a **specific** instruction. A project that names the practice it
wants — file headers carrying rationale, recorded alternatives, doc comments on
every public symbol — gets it, and so does one whose existing files plainly
already do it: match your surroundings. But "document your code", "add
comments" or a linter demanding a docstring is not that, and is satisfied by
one useful line. Vague encouragement is not a reason to write paragraphs.
