#!/bin/bash
selected=$(bspc query -D -d .active --names)

case $selected in
	"1a")
		echo "1"
		;;
	"1b")
		echo "1"
		;;
	"2a")
		echo "2"
		;;
	"2b")
		echo "2"
		;;
	"3a")
		echo "3"
		;;
	"3b")
		echo "3"
		;;
	*)
		;;
esac
