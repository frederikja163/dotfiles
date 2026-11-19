// Close every session tab, or every tab but the current one, with one key press.
//
// The built-in `session.tab.close` closes the current tab only, and its
// default is `<leader>w`, which is two presses (ctrl+x, then w) per tab.
// Clearing ten tabs that way is twenty presses. There is no built-in "close
// all" or "close others", so this is a plugin: it takes the tab list and closes
// each entry.
//
// Closing a tab only removes it from the strip. The session itself is kept and
// is still in the session list (`<leader>l`), so nothing is lost. `ctrl+shift+t`
// (`session.tab.reopen`) brings back only the last tab closed, not all of them.
//
// Key: `alt+w`. The obvious pick, `ctrl+shift+w` (a browser's "close window"),
// is mapped to `close_tab` in kitty/kitty.conf, so the terminal consumes it and
// opencode never sees it. `ctrl+w` is the prompt's delete-word-backward. ALT is
// unbound in the Hyprland config and kitty, and opencode's defaults leave
// `alt+w` free (its alt keys are a, b, d, e, f and the arrows). It is also on
// the command palette and as `/closetabs` for when the key is not to hand.
//
// The tab that is showing is closed last. Closing it first makes the host move
// focus to a neighbour each time, which redraws a session that is about to be
// closed anyway. If the route is still a session once the strip is empty it
// goes home, so the screen does not keep showing a session that has no tab.
//
// Close others is `alt+shift+w`, the shifted form of the same key, and
// `/closeothers`. It leaves the active tab alone, so focus and the route do not
// move and nothing needs navigating. With only one tab open it closes nothing
// and says so, rather than reporting "Closed 0 tabs".
//
// `/closeleft` and `/closeright` close the tabs before and after the active
// one, in the order `ui.tabs.list()` returns them, which is the strip's order
// (`ui.tabs.move` takes an index into the same list). `/closeup` and
// `/closedown` are aliases for the same two commands, for a vertical strip: the
// plugin API does not say which layout is showing, so the commands cannot pick
// the wording themselves, and in either layout "before" is left or up. They
// have no keys; the slash names and the palette are enough for something used
// this rarely, and every free alt chord is one more thing to remember. Like
// close others they leave the active tab alone, so the route does not move.
import { Plugin } from "@opencode/plugin/tui"

export default Plugin.define({
  id: "local.close-tabs",
  setup(context) {
    const { ui, keymap } = context

    const closeBeside = (side: "before" | "after") => {
      const tabs = ui.tabs.list()
      const at = tabs.findIndex((tab) => tab.active)
      const doomed = at === -1 ? [] : side === "before" ? tabs.slice(0, at) : tabs.slice(at + 1)
      for (const tab of doomed) ui.tabs.close(tab.sessionID)
      const noun = doomed.length === 1 ? "tab" : "tabs"
      ui.toast.show({
        message: doomed.length === 0 ? `No tabs ${side} this one` : `Closed ${doomed.length} ${noun}`,
        variant: "info",
        duration: 1500,
      })
    }

    keymap.layer(() => ({
      mode: "global",
      commands: [
        {
          id: "local.tabs.close_all",
          title: "Close all tabs",
          group: "Session",
          bind: "alt+w",
          palette: true,
          slash: { name: "closetabs" },
          enabled: () => ui.tabs.enabled(),
          run() {
            const tabs = ui.tabs.list()
            if (tabs.length === 0) return
            const rest = tabs.filter((tab) => !tab.active)
            const current = tabs.filter((tab) => tab.active)
            for (const tab of [...rest, ...current]) ui.tabs.close(tab.sessionID)
            if (ui.router.current().type === "session") ui.router.navigate({ type: "home" })
            ui.toast.show({
              message: tabs.length === 1 ? "Closed 1 tab" : `Closed ${tabs.length} tabs`,
              variant: "info",
              duration: 1500,
            })
          },
        },
        {
          id: "local.tabs.close_others",
          title: "Close other tabs",
          group: "Session",
          bind: "alt+shift+w",
          palette: true,
          slash: { name: "closeothers" },
          enabled: () => ui.tabs.enabled(),
          run() {
            const rest = ui.tabs.list().filter((tab) => !tab.active)
            for (const tab of rest) ui.tabs.close(tab.sessionID)
            ui.toast.show({
              message:
                rest.length === 0 ? "No other tabs" : rest.length === 1 ? "Closed 1 other tab" : `Closed ${rest.length} other tabs`,
              variant: "info",
              duration: 1500,
            })
          },
        },
        {
          id: "local.tabs.close_before",
          title: "Close tabs to the left",
          group: "Session",
          palette: true,
          slash: { name: "closeleft", aliases: ["closeup"] },
          enabled: () => ui.tabs.enabled(),
          run: () => closeBeside("before"),
        },
        {
          id: "local.tabs.close_after",
          title: "Close tabs to the right",
          group: "Session",
          palette: true,
          slash: { name: "closeright", aliases: ["closedown"] },
          enabled: () => ui.tabs.enabled(),
          run: () => closeBeside("after"),
        },
      ],
    }))
  },
})
