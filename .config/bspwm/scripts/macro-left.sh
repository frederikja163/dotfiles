#!/bin/bash
window=$(xdotool getactivewindow)
echo $window
until [[ $key == 9 ]]
do
	xdotool click --repeat 10 --delay 1 1
	key=$(timeout 0.05 xev -id $window -event keyboard | awk -F'[ )]+' '/^KeyPress/ { a[NR+2] } NR in a { printf "%s", $5}')
	echo $key
done
