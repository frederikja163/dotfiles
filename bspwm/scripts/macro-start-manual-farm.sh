#!/bin/bash
window=$(xdotool getactivewindow)
echo $window
sleep 1s
xdotool mousedown 1
xdotool keydown w
