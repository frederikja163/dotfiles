-- Keyboard, mouse, touchpad and gestures.
-- See https://wiki.hypr.land/Configuring/Basics/Variables/#input

hl.config({
    input = {
        kb_layout  = "us",
        kb_variant = "",
        kb_model   = "",
        kb_options = "",
        kb_rules   = "",

        follow_mouse = 1,

        sensitivity = 0, -- -1.0 - 1.0, 0 means no modification.

        touchpad = {
            natural_scroll = false,
        },
    },
})

-- Resolving binds by symbol, in the test sandbox only.
--
-- Hyprland normally derives a bind's keysym from the *config's* layout, on an
-- xkb state that never has modifiers applied (KeybindManager.cpp builds it as
-- `xkb_state_new(keymap)`). That is what makes SUPER+SHIFT+Tab work at all:
-- Shift+Tab arrives as `Tab` rather than `ISO_Left_Tab`, so the binds in
-- modes.lua can be written the obvious way. Do not turn this on for real
-- keyboards -- it switches the lookup to the live modifier state and would
-- silently break every shifted bind.
--
-- A key injected by wtype (tests/sandbox.sh keys) is the one case where that
-- default gets in the way: wtype invents its own keymap and picks arbitrary
-- keycodes in it, which the config's layout then translates into the wrong
-- symbol, so named binds match nothing. Clients still receive the right
-- letters -- those are sent with the injecting keyboard's own keymap -- so
-- typing into a terminal works while every bind stays silent, which is a
-- confusing way to lose an afternoon.
--
-- Setting it per device (name = "hl-virtual-keyboard-wtype") looks tidier and
-- is unreliable: each wtype invocation is a new client, and a second keyboard
-- arriving before the first is cleaned up gets a de-duplicated name that the
-- rule no longer matches. The sandbox is the only place this is on, and it
-- already exports HYPR_SANDBOX for exactly this kind of test-only behaviour.
if os.getenv("HYPR_SANDBOX") == "1" then
    hl.config({ input = { resolve_binds_by_sym = true } })
end

-- Three-finger horizontal swipe switches workspace.
hl.gesture({
    fingers = 3,
    direction = "horizontal",
    action = "workspace"
})

-- Example per-device config
-- See https://wiki.hypr.land/Configuring/Advanced-and-Cool/Devices/ for more
hl.device({
    name        = "epic-mouse-v1",
    sensitivity = -0.5,
})
