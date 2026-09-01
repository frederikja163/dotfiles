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
When a new column is added it should add a placeholder to the desktop and if the next key combination adds a new window it should be added to that column.
If the next key combination is either ESC or some other combination that does not add a new window (unlike M+Q or M+r) then it should close the placeholder column.
Normally adding a new window should add it to the bottom of the column, with a similar algorithm for sizing as the columns.
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
M+n = add new column

M+m = swap window with biggest window
M+[hjkl] = focus
M+S+[hjkl] = move window
M+C+[hjkl] = resize

Each monitor has a number associated with it, [1-0]
\#n = Any monitor
\#f = focused monitor
M+#n = focus
M+S+#n = move window
M+C+#n = toggle extend/duplicate with focused monitor
M+#f = next desktop on monitor (loops back to first desktop)
M+s+#f = move window to next desktop on monitor
M+C+#f = add new desktop to monitor and focus it (gets removed when empty and not focused)
