#!/bin/bash

# Implemented as seperate while loops for on and off as they have different sleep times. It takes longer for the headset to turn on.
while true; do
	# Headset is on.
	pactl set-default-sink alsa_output.usb-Logitech_Logitech_G933_Gaming_Wireless_Headset-00.analog-stereo
	while headsetcontrol -b > /dev/null 2>&1; do
		sleep 3s
	done
	# Headset is off.
	pactl set-default-sink alsa_output.pci-0000_00_1f.3.analog-stereo
	until headsetcontrol -b > /dev/null 2>&1; do
		sleep 5s
	done
done
