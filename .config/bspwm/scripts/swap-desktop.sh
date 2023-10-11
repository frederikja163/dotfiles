#!/bin/bash

selected=$(bspc query -D -d .active --names)
selected_mon=$(~/.config/bspwm/scripts/get-monitor.sh)
a="a"
b="b"

if [ "$1$a" == $selected ]; then
	bspc desktop -f "$selected_mon$b"
else
	bspc desktop -f "$1$a"
fi
