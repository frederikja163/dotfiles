// /aside: the built-in /btw, plus a key that keeps the answer.
//
// /btw answers from the session's context and throws the answer away on
// purpose, so there is no way to say "that was a good explanation, the main
// agent should know it". The usual case here is asking whether a feature is
// still needed: if the answer is "no", the follow-up is "remove it", and the
// agent doing the removal has never seen why.
//
// The built-in is itself a TUI plugin (`opencode.btw`) with nothing to hook
// into, so this is a copy of its flow rather than an extension of it: one
// transient `session.generate` call, shown in a dialog. The addition is `a`,
// which writes the question and answer into the session as a synthetic
// message with `resume: false`. That shows in the transcript at once as a
// pending item and is folded in ahead of the next prompt, so no turn starts
// and the "remove it" that follows runs with the reasoning in view. Checked
// against a live session: the model quoted the answer back on the next turn.
//
// Why a new command name instead of reusing `btw`: two commands claiming one
// slash name is behaviour nobody documents, and the built-in is still the right
// tool for a question whose answer is not worth keeping. Rename `slash.name`
// below if you would rather type something else.
//
// Copy (`c`) uses the terminal's OSC 52 clipboard escape, as the built-in does,
// and also pipes to `wl-copy`. OSC 52 alone reports success the moment the
// escape is written, whether or not the terminal honours it, so there is no way
// to know it landed; `wl-copy` is a local write that can be checked, and OSC 52
// is the one that still works over ssh. Writing both is harmless.
//
// While the question runs, "/aside" shows in the prompt footer with a spinner,
// as "/btw" does. The count and frame live in `storage.memory`, a reactive
// store, so nothing here imports `solid-js`; whether that resolves from this
// directory was never checked, since `@opencode/theme` did not.
//
// Colour: the answer is a `<markdown>` element, and every colour in it (headings,
// bold, inline code, code blocks) comes from the `SyntaxStyle` it is given. The
// built-in uses the host's own, built by `generateSyntax` in `@opencode/theme`.
// That package does not resolve from a plugin directory, and the first version
// of this plugin worked around it with a style holding only a default colour,
// which is why the answers came out monochrome. `highlightStyle` below is a copy
// of `generateSyntax` from @opencode/theme 2.0.14, minus the editor-only rules
// (prompt, extmark.*, spell), written against `@opentui/core`, which does
// resolve. It will drift if the host's mapping changes.
//
// Prop order on `<markdown>` matters, and `content` must come last. Props are
// applied in the order written, and the element builds its blocks as soon as
// `content` arrives. With `content` first, lists were built before the style
// existed and stayed uncoloured (bullet and text both plain white), while
// headings, bold and code blocks, which are re-highlighted afterwards, looked
// fine. Easy to miss, because it only shows on lists.
import { Plugin } from "@opencode/plugin/tui"
import { SyntaxStyle } from "@opentui/core"

// Same instruction the built-in sends, so an answer here reads the same as a /btw one.
const SIDE_QUESTION = [
  "The user is asking a quick side question about the conversation so far.",
  "Answer directly and concisely in markdown from what you already know.",
  "Do not call any tools and do not take any actions.",
].join(" ")

// Written for the model that reads it later. Without the framing it would see
// a bare question and answer in its own context and may treat the question as
// an instruction.
const transcriptText = (question: string, answer: string) =>
  [
    "The user asked a side question about this session and got the answer below.",
    "It is context for the conversation, not a new request. Do not act on it unless the user asks you to.",
    "",
    `Question: ${question}`,
    "",
    "Answer:",
    answer,
  ].join("\n")

const rule = (scope: string[], foreground: unknown, style: Record<string, unknown> = {}) => ({
  scope,
  style: { foreground, ...style },
})

const highlightStyle = (theme: any, owner: unknown) => {
  const { syntax, markdown } = theme
  const feedback = theme.text.feedback
  return (SyntaxStyle as any).fromTheme(
    [
      rule(["default"], theme.text.base),
      rule(["comment", "comment.documentation"], syntax.comment, { italic: true }),
      rule(["string", "symbol", "character.special", "character"], syntax.string),
      rule(["number", "boolean", "constant", "float"], syntax.number),
      rule(["keyword.return", "keyword.conditional", "keyword.repeat", "keyword.coroutine"], syntax.keyword, {
        italic: true,
      }),
      rule(["keyword.type"], syntax.type, { bold: true, italic: true }),
      rule(["keyword.function", "function.method"], syntax.function),
      rule(["keyword"], syntax.keyword, { italic: true }),
      rule(["keyword.import", "string.escape", "string.regexp", "tag.attribute", "keyword.export"], syntax.keyword),
      rule(["operator", "keyword.operator", "punctuation.delimiter", "keyword.conditional.ternary"], syntax.operator),
      rule(
        ["variable", "variable.parameter", "function.method.call", "function.call", "property", "parameter", "field"],
        syntax.variable,
      ),
      rule(["variable.member", "function", "constructor"], syntax.function),
      rule(["type", "module", "class", "namespace"], syntax.type),
      rule(["type.definition"], syntax.type, { bold: true }),
      rule(["punctuation", "punctuation.bracket"], syntax.punctuation),
      rule(
        ["variable.builtin", "type.builtin", "function.builtin", "module.builtin", "constant.builtin", "variable.super"],
        feedback.error.base,
      ),
      rule(["keyword.directive", "keyword.modifier", "keyword.exception"], syntax.keyword, { italic: true }),
      rule(["punctuation.special", "tag.delimiter"], syntax.operator),
      rule(
        ["markup.heading", "markup.heading.2", "markup.heading.3", "markup.heading.4", "markup.heading.5", "markup.heading.6"],
        markdown.heading,
        { bold: true },
      ),
      rule(["markup.heading.1"], markdown.heading, { bold: true, underline: true }),
      rule(["markup.bold", "markup.strong"], markdown.strong, { bold: true }),
      rule(["markup.italic"], markdown.emphasis, { italic: true }),
      rule(["markup.list"], markdown.listItem),
      rule(["markup.quote"], markdown.blockQuote, { italic: true }),
      rule(["markup.raw", "markup.raw.block"], markdown.code),
      rule(["markup.raw.inline"], markdown.code, { background: theme.background.base }),
      rule(["markup.link", "markup.link.url", "string.special", "string.special.url"], markdown.link, {
        underline: true,
      }),
      rule(["markup.link.label"], markdown.linkText, { underline: true }),
      rule(["label"], markdown.linkText),
      rule(["markup.underline"], theme.text.base, { underline: true }),
      rule(["comment.error"], feedback.error.base, { italic: true, bold: true }),
      rule(["comment.warning"], feedback.warning.base, { italic: true, bold: true }),
      rule(["comment.todo", "comment.note"], feedback.info.base, { italic: true, bold: true }),
      rule(["attribute", "annotation"], feedback.warning.base),
      rule(["tag"], feedback.error.base),
      rule(["markup.strikethrough", "markup.list.unchecked", "debug"], theme.text.muted),
      rule(["markup.list.checked"], feedback.success.base),
      rule(["error"], feedback.error.base, { bold: true }),
      rule(["warning"], feedback.warning.base, { bold: true }),
      rule(["info"], feedback.info.base),
    ],
    owner,
  )
}

const FRAMES = ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"]

export default Plugin.define({
  id: "local.aside",
  setup(context) {
    const { theme, ui, keymap, client } = context
    const surface = theme.surface("dialog")

    const [busy, setBusy] = context.storage.memory("aside", { initial: { pending: 0, frame: 0 } })
    let spinner: ReturnType<typeof setInterval> | undefined
    const track = (delta: number) => {
      setBusy((draft) => {
        draft.pending = Math.max(0, draft.pending + delta)
        draft.frame = 0
      })
      if (busy.pending > 0 && !spinner) {
        spinner = setInterval(() => setBusy((draft) => void (draft.frame = (draft.frame + 1) % FRAMES.length)), 80)
      } else if (busy.pending === 0 && spinner) {
        clearInterval(spinner)
        spinner = undefined
      }
    }

    const keep = async (sessionID: string, question: string, answer: string) => {
      try {
        // The TUI draws a synthetic message from its `description` alone, as one muted
        // "◈" notice that wraps but is never expandable; `text` is for the model and is
        // not shown. An earlier version put only a shortened question in the
        // description, which left a transcript line ending in "…" with the answer
        // invisible. So the description carries the whole question and answer. The
        // answer is markdown but a notice is drawn as plain text, so `**` and `-` show
        // as typed.
        await client.session.synthetic({
          sessionID,
          text: transcriptText(question, answer),
          description: `Side question: ${question}\n\n${answer}`,
          resume: false,
        })
        ui.toast.show({ message: "Added to the transcript", variant: "success" })
      } catch (error) {
        ui.toast.show({
          title: "Could not add to the transcript",
          message: error instanceof Error ? error.message : String(error),
          variant: "error",
        })
      }
    }

    const copy = async (text: string) => {
      const osc = (context.renderer as any).copyToClipboardOSC52?.(text) === true
      const local = await (async () => {
        try {
          const proc = (globalThis as any).Bun.spawn(["wl-copy"], { stdin: "pipe", stdout: "ignore", stderr: "ignore" })
          proc.stdin.write(text)
          await proc.stdin.end()
          return (await proc.exited) === 0
        } catch {
          return false
        }
      })()
      ui.toast.show(
        osc || local
          ? { message: "Copied the answer", variant: "success", duration: 1500 }
          : { message: "Could not reach the clipboard", variant: "error" },
      )
    }

    const Answer = (props: { sessionID: string; question: string; answer: string; syntax: unknown }) => {
      let scroll: any
      const page = () => Math.max(8, Math.floor(context.renderer.height * 0.6))
      const by = (lines: () => number) => () => scroll?.scrollBy(lines())

      keymap.layer(() => ({
        mode: "modal",
        commands: [
          {
            id: "local.aside.keep",
            bind: "a",
            title: "Add answer to transcript",
            group: "Dialog",
            run: async () => {
              ui.dialog.clear()
              await keep(props.sessionID, props.question, props.answer)
            },
          },
          {
            id: "local.aside.copy",
            bind: "c",
            title: "Copy answer",
            group: "Dialog",
            run: () => copy(props.answer),
          },
          { bind: "j", run: by(() => 1) },
          { bind: "down", run: by(() => 1) },
          { bind: "k", run: by(() => -1) },
          { bind: "up", run: by(() => -1) },
          { bind: "pagedown", run: by(page) },
          { bind: "pageup", run: by(() => -page()) },
          { bind: "home", run: () => scroll?.scrollTo(0) },
          { bind: "end", run: () => scroll?.scrollTo(scroll.scrollHeight) },
        ],
      }))

      return (
        <box gap={1} paddingBottom={1}>
          <box flexDirection="row" gap={2} paddingLeft={2} paddingRight={2}>
            <text flexShrink={0} fg={surface.text.base}>
              /aside
            </text>
            <text flexGrow={1} wrapMode="word" fg={surface.text.muted}>
              {props.question}
            </text>
            <text flexShrink={0} fg={surface.text.muted} onMouseUp={() => ui.dialog.clear()}>
              esc
            </text>
          </box>
          <scrollbox
            ref={(node: any) => (scroll = node)}
            maxHeight={page()}
            backgroundColor={context.theme.background.raised.high}
            contentOptions={{ minHeight: 0 }}
            scrollbarOptions={{ visible: false }}
          >
            <box paddingLeft={2} paddingRight={2} paddingTop={1} paddingBottom={1}>
              <markdown
                syntaxStyle={props.syntax as any}
                conceal={true}
                internalBlockMode="top-level"
                tableOptions={{ style: "grid", cellPaddingX: 1 }}
                fg={context.theme.markdown.text}
                bg={context.theme.background.raised.high}
                content={props.answer}
              />
            </box>
          </scrollbox>
          <box flexDirection="row" gap={3} paddingLeft={2} paddingRight={2}>
            <text fg={surface.text.base} onMouseUp={() => keymap.dispatch("local.aside.keep")}>
              <b>a</b>
              <span style={{ fg: surface.text.muted }}> add to transcript</span>
            </text>
            <text fg={surface.text.base} onMouseUp={() => keymap.dispatch("local.aside.copy")}>
              <b>c</b>
              <span style={{ fg: surface.text.muted }}> copy</span>
            </text>
            <text fg={surface.text.muted}>j/k ↑/↓ scroll</text>
          </box>
        </box>
      )
    }

    // The dialog and the keymap layer are both torn down together, but the
    // syntax style is a native resource the renderer may still be drawing, so
    // it is released only once the renderer is idle.
    const release = (syntax: any) => {
      const idle = (context.renderer as any).idle?.()
      Promise.resolve(idle).then(() => syntax.destroy?.())
    }

    ui.slot({
      append: "prompt.footer.status",
      render: () =>
        busy.pending > 0 ? (
          <box flexShrink={0}>
            <text fg={theme.hue.interactive[200]}>{FRAMES[busy.frame]} /aside</text>
          </box>
        ) : null,
    })

    ui.slot({
      append: "app",
      render: () => {
        keymap.layer(() => ({
          mode: "global",
          commands: [
            {
              id: "local.aside",
              title: "Ask a side question and keep the answer",
              description: "Like /btw, but the answer can be added to the conversation",
              group: "Session",
              palette: true,
              slash: { name: "aside", arguments: true },
              async run(input) {
                const route = ui.router.current()
                if (route.type !== "session") {
                  ui.toast.show({ message: "Open a session first", variant: "warning" })
                  return
                }
                const question = input?.trim() || (await ui.dialog.prompt({ title: "/aside", placeholder: "Ask anything" }))
                if (!question) return

                track(1)
                try {
                  const { text } = await client.session.generate({
                    sessionID: route.sessionID,
                    prompt: [SIDE_QUESTION, question].join("\n\n"),
                  })
                  const syntax = highlightStyle(theme, (context.renderer as any).nativeScene)
                  ui.dialog.show(
                    () => <Answer sessionID={route.sessionID} question={question} answer={text.trim()} syntax={syntax} />,
                    () => release(syntax),
                  )
                  ui.dialog.set({ size: "large", centered: true })
                } catch (error) {
                  ui.toast.show({
                    title: "Side question failed",
                    message: error instanceof Error ? error.message : String(error),
                    variant: "error",
                  })
                } finally {
                  track(-1)
                }
              },
            },
          ],
        }))
        return null
      },
    })
    return () => {
      if (spinner) clearInterval(spinner)
    }
  },
})
