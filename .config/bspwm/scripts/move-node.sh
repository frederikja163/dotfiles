#!/bin/bash
selected=$(bspc query -D -d .active --names)
selected_mon=$(~/.config/bspwm/scripts/get-monitor.sh)
a="a"
b="b"

selected_node=$(bspc query -N -n)
if [ "$1$a" == $selected ]; then
	bspc node -d "$1$b"
else
	bspc node -d "$1$a"
fi
bspc node -f $selected_node
