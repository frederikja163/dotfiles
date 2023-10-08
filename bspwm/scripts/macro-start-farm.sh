#!/bin/bash
window=$(xdotool getactivewindow)
echo $window
sleep 1s
xdotool mousedown 1
xdotool keydown w
sleep 1s
while [[ true ]]
do
	xdotool keydown d
	sleep 73s
	xdotool keyup d
	xdotool keydown a
	sleep 73s
	xdotool keyup a


	key=$(timeout 0.05 xev -id $window -event keyboard | awk -F'[ )]+' '/^KeyPress/ { a[NR+2] } NR in a { printf "%s", $5}')
	echo $key
done
