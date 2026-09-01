Github integration
Desktop extension + monitor setups
Auto update config with notification
Machine specific settings

# Work laptop
fredandr
Fingeprint
Add user to screen
Auto login to wifi
Keyboard drivers when unlocking the disc

# Desktop setup
Each desktop should consist of 0 or more columns.
New windows always open in the currently focused column, at the bottom.
M+n takes the focused window out into a new column of its own, so creating a
column is M+q then M+n rather than the other way round. (This replaced the
earlier placeholder-column idea, which is no longer needed.)
Adding a new window to a column uses a similar sizing algorithm to the columns.
New column algorithm
```
if allColumnsSameWidth(desktop.columns) then
    # Even width across all columns
    column = desktop.addColumn()
    resizeColumnsToBeEvenWidth(desktop.column)
else
    # Width = half of selected columns width
    column = desktop.addColumn()
end
```
M+n = move the focused window into a new column

M+m = cycle windows through the main slot (the widest column). If the focused
window is outside it, it moves in; otherwise each press pulls in the next
window. Focus follows the main slot so the big window stays highlighted.
M+[hjkl] = focus, wrapping within the desktop (never crosses monitors, so the
config does not care how they are arranged)
M+S+[jk] = move window up/down inside its column
M+S+[hl] = move window into the neighbouring column
M+A+[hl] = swap the whole column with its neighbour
M+C+[hl] = resize the column
M+C+[jk] = resize the window inside its column

Each monitor has a number associated with it, [1-0]
\#n = Any monitor
\#f = focused monitor
M+#n = focus
M+S+#n = move window
M+C+#n = toggle extend/duplicate with focused monitor (works both ways: a
duplicating monitor vanishes from Hyprland's monitor list, so deskbinds.lua
remembers it in order to switch it back, and refreshes waybar)
M+#f = next desktop on monitor (loops back to first desktop, or creates a second
one if the monitor only has a single desktop)
M+s+#f = move window to next desktop on monitor
M+C+#f = add new desktop to monitor and focus it (gets removed when empty and not focused)

Desktops are numbered per monitor. Hyprland ids are global, so each desktop is
named "<monitor>.<desktop>" (1.1, 2.1, 2.2) and waybar displays just the second
number. The names have to stay unique across monitors because waybar highlights
every button whose name matches the focused workspace.
