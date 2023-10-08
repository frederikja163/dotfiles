#!/bin/bash
selected=$(bspc query -M --names -m)
if [ $selected == $1 ]; then
	bspc desktop -f next.local
else
	bspc monitor -f $1
fi
