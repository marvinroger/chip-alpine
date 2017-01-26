#!/bin/sh

# Needed services
rc-update add devfs sysinit
rc-update add dmesg sysinit
rc-update add mdev sysinit

rc-update add modules boot
rc-update add sysctl boot
rc-update add hostname boot
rc-update add bootmisc boot
rc-update add syslog boot
rc-update add wpa_supplicant boot # needed, otherwise does not connect after reboot

rc-update add mount-ro shutdown
rc-update add killprocs shutdown
rc-update add savecache shutdown

# Allow root login with no password.
passwd root -d

# Allow root login from serial.
echo ttyS0 >> /etc/securetty
echo ttyGS0 >> /etc/securetty

# Make sure the USB virtual serial device is available.
echo g_serial >> /etc/modules

# Make sure wireless networking is available.
echo 8723bs >> /etc/modules

# These enable the USB virtual serial device, and the standard serial
# pins to both be used as TTYs
echo ttyS0::respawn:/sbin/getty -L ttyS0 115200 vt102 >> /etc/inittab
echo ttyGS0::respawn:/sbin/getty -L ttyGS0 115200 vt102 >> /etc/inittab