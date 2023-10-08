#!/bin/bash
selected=$(bspc query -M --names -m)
selectednode=$(bspc query -N -n)
if [ $selected == $1 ]; then
	bspc node -d next.local
else
	bspc node -m $1
fi
bspc node -f $selectednode
