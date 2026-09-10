-- Standalone harness for desknames.lua: stubs the hl API and the two modules
-- it picks between, then asks the labeller what each desktop is called.
--
-- deskbinds.lua and quake.lua are stubbed rather than loaded, because what is
-- being tested is the choice between their answers, not the answers
-- themselves -- those have harnesses of their own.

local HYPR = os.getenv("HYPR_DIR") or "hypr"
package.path = HYPR .. "/?.lua;" .. package.path

local world, labeller, renumbers, hooked, mod

local function reset(w)
    world = w or { windows = {}, labels = {} }
    labeller, renumbers, hooked = nil, 0, {}

    _G.hl = {
        on = function(event, fn) hooked[event] = fn end,
        get_workspace_windows = function(id) return world.windows[id] or {} end,
    }

    package.loaded.deskbinds = {
        set_labeller = function(fn) labeller = fn end,
        schedule_renumber = function() renumbers = renumbers + 1 end,
    }
    -- quake answers "~" for a desktop it has nothing to say about, which is
    -- the gap this module fills.
    package.loaded.quake = {
        HOME_LABEL = "~",
        label_for = function(id) return world.labels[id] or "~" end,
    }

    package.loaded.desknames = nil
    mod = require("desknames")
end

-- A desktop holding the classes named, in that order.
local function desktop(id, ...)
    world.windows[id] = {}
    for _, class in ipairs({ ... }) do
        table.insert(world.windows[id], { class = class })
    end
end

local pass, fail = 0, 0
local function check(label, got, want)
    if got == want then
        pass = pass + 1
        print(("  ok   %-56s %s"):format(label, tostring(got)))
    else
        fail = fail + 1
        print(("  FAIL %-56s got %s want %s"):format(label, tostring(got), tostring(want)))
    end
end

local function name_of(id)
    return labeller({ id = id })
end

print("scenario: a desktop that is one program")
reset()
desktop(1, "firefox")
check("named after it", name_of(1), "firefox")

desktop(2, "firefox", "firefox")
check("two windows of it are still one program", name_of(2), "firefox")

desktop(3, "steam")
check("whatever the program is", name_of(3), "steam")

print("scenario: a desktop that is not one program")
reset()
desktop(1, "firefox", "kitty")
check("a browser beside a terminal is a desktop being worked on", name_of(1), nil)

desktop(2, "firefox", "steam")
check("two different programs say nothing between them", name_of(2), nil)

desktop(3)
check("and an empty desktop has nothing to be named after", name_of(3), nil)

-- The point of the exclusions: these are the programs whose desktop is about
-- the directory they are open on, which is the name it already has.
print("scenario: programs that keep the directory naming")
reset()
for id, class in ipairs({ "kitty", "jetbrains-rider", "code", "codium", "dolphin" }) do
    desktop(id, class)
    check(class .. " lends no name", name_of(id), nil)
end

-- nvim and opencode are windows of the terminal they run in and carry its
-- class, so they are covered by kitty rather than by a line of their own.
desktop(9, "kitty", "kitty")
check("two terminals are still terminals", name_of(9), nil)

print("scenario: the directory comes first")
-- Taking the terminal somewhere says what the desktop is for; the program on
-- it is only ever a guess, however good a one.
reset()
world.labels[1] = "runner"
desktop(1, "firefox")
check("so a browser on a checkout is the checkout", name_of(1), "runner")

world.labels[2] = "~"
desktop(2, "firefox")
check("while a terminal at home says nothing, and the program answers",
      name_of(2), "firefox")

world.labels[3] = "/"
desktop(3, "firefox")
check("the root is a directory like any other", name_of(3), "/")

print("scenario: classes that are not the program's name")
reset()
desktop(1, "org.gnome.Nautilus")
check("reverse-dns is the last part", name_of(1), "nautilus")

desktop(2, "org.telegram.desktop")
check("...unless that part is filler, and then the one before it",
      name_of(2), "telegram")

desktop(3, "Steam")
check("lower case throughout, beside the directory names", name_of(3), "steam")

print("scenario: windows with no class at all")
-- XWayland's drag surface is one of these (see windowrules.lua), as is the
-- odd splash screen. Counting one as a second program would take the
-- desktop's name off for as long as it was up.
reset()
desktop(1, "", "firefox")
check("skipped rather than counted", name_of(1), "firefox")

desktop(2, "")
check("and a desktop of nothing but those is unnamed", name_of(2), nil)

print("scenario: a desktop that does not exist yet")
-- deskbinds asks what to call a desktop before creating it, with nothing to
-- ask about.
reset()
check("nothing to say", labeller({}), nil)
check("...and nothing to crash on", labeller(nil), nil)

print("scenario: keeping up with the windows")
-- A name from here follows the windows, so every way they can change has to
-- reach the renumbering pass. move_to_workspace is the one with no other
-- signal: SUPER+M sends a window away without opening or closing anything and
-- without focus following it.
reset()
for _, event in ipairs({ "window.open", "window.close", "window.move_to_workspace" }) do
    local before = renumbers
    if hooked[event] then
        hooked[event]({ class = "firefox" })
    end
    check(event .. " renames", renumbers, before + 1)
end

print("")
print(("%d passed, %d failed"):format(pass, fail))
os.exit(fail == 0 and 0 or 1)
