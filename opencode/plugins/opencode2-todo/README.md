# opencode2-todo (vendored)

Vendored from `opencode2-todo@0.2.1` (MIT, see `LICENSE`). Upstream repo is
archived. This is the **server half only** — the `todowrite` tool — with the TUI
sidebar removed.

## Why this is vendored instead of installed from npm

OpenCode 2.0.12 compiles JSX in TUI plugins with Bun's default React transform
whenever the file lives under a `node_modules/` path, because OpenCode's own
Solid JSX transform deliberately skips those paths. The published package ships
its sidebar as raw JSX (`src/tui.tsx`) and declares `tui: true`, so the npm
install always fails its TUI half with:

```
Cannot find package 'react' imported from .../node_modules/opencode2-todo/src/tui.tsx
```

There is no way to keep the tool and drop just the TUI half through config:

- the `"-<id>"` disable directive does not cover TUI plugins (`-opencode2.todo.tui`
  was tried and the load still happened),
- `enabled: false` removes the tool as well,
- and 2.0.12 rejects a file path in `plugins` — it requires a directory.

Pointing `plugins` at this directory loads `index.ts` directly (outside
`node_modules`), so only the server half exists and the sidebar is never
requested.

## Changes from upstream `src/index.ts`

1. `tui: true` removed.
2. `import { Plugin } from "@opencode-ai/plugin"` removed; the default export is
   a plain object. `Plugin.define` is the identity function
   (`@opencode-ai/plugin/dist/promise/plugin.js`), so this is equivalent and
   leaves the plugin with no runtime dependency — no `node_modules` needed.

`tool/*.ts` are copied verbatim from upstream. They contain only `import type`
references to `@opencode-ai/plugin`, which the runtime strips.

`@opencode-ai/plugin` is still referenced for editor types; it is not required at
runtime.

## Removal

If OpenCode ships `todowrite` again, delete this directory and the `plugins`
entry in `../opencode.jsonc`.
