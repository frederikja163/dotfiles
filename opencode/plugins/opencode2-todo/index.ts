// Vendored from opencode2-todo@0.2.1 (MIT, see LICENSE). Upstream is archived.
//
// Why vendored: OpenCode 2.0.12 compiles JSX in TUI plugins with Bun's default
// React transform when the plugin is loaded from `node_modules`, because its
// Solid transform skips any path containing `node_modules/`. The published
// package ships `src/tui.tsx` as raw JSX and declares `tui: true`, so the TUI
// half always fails to load with "Cannot find package 'react'". There is no
// config switch to drop just the TUI half, and OpenCode rejects a file path in
// `plugins` (it requires a directory).
//
// This copy is the server half only, so the `todowrite` tool loads and the
// broken sidebar is never requested. It is two changes from upstream
// `src/index.ts`:
//   1. `tui: true` is removed.
//   2. The `@opencode-ai/plugin` value import is removed. `Plugin.define` is the
//      identity function (`dist/promise/plugin.js`), so a plain object is
//      equivalent and the vendored plugin needs no `node_modules`.
import type { Plugin } from "@opencode-ai/plugin"
import { registerTodoWrite } from "./tool"
import { formatTodos } from "./tool/format"
import { loadTodos } from "./tool/store"

export default {
  id: "opencode2.todo",
  async setup(ctx: Plugin.Context) {
    if (ctx.options.enabled === false) return
    await ctx.tool.transform((draft) => draft.add(registerTodoWrite(ctx)))
    if (ctx.options.injectEveryRound === false) return
    await ctx.session.hook("context", async (event) => {
      const todos = await loadTodos(ctx, event.sessionID)
      if (todos.length === 0) return
      event.system.push({ type: "text", text: formatTodos(todos) })
    })
  },
}
