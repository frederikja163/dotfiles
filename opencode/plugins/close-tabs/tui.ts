// Close every session tab with one key press.
//
// The built-in `session.tab.close` closes the current tab only, and its
// default is `<leader>w`, which is two presses (ctrl+x, then w) per tab.
// Clearing ten tabs that way is twenty presses. There is no built-in "close
// all", so this is a plugin: it takes the tab list and closes each entry.
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
import { Plugin } from "@opencode/plugin/tui"

export default Plugin.define({
  id: "local.close-tabs",
  setup(context) {
    const { ui, keymap } = context

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
      ],
    }))
  },
})
