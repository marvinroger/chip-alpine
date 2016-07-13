#!/usr/bin/env bash

LATEST_BASEBUILD_URL="http://opensource.nextthing.co/chip/buildroot/stable/latest"

#####
# Get the latest base buildroot image
#####

echo "Getting latest base buildroot image..."

LATEST_BASEBUILD="$(wget -q -O- ${LATEST_BASEBUILD_URL})" || (echo "ERROR: cannot reach ${LATEST_BASEBUILD_URL}" && exit 1)
if [[ -z "${LATEST_BASEBUILD}" ]]; then
  echo "error: could not get URL for latest build from ${LATEST_BASEBUILD_URL}"
  exit 1
fi

BASEBUILD_ROOTFS_URL="${LATEST_BASEBUILD}/images/rootfs.ubi"

mkdir basebuild

if ! wget -P "basebuild" "${BASEBUILD_ROOTFS_URL}"; then
  echo "download of base build failed!"
  exit $?
fi

#####
# Extract the ubi file to get the kernel
#####

echo "Extracting buildroot image to get the kernel..."

apt-get install -y liblzo2-dev python-lzo
wget https://bootstrap.pypa.io/ez_setup.py -O - | python
git clone https://github.com/jrspruitt/ubi_reader
cd ubi_reader
python setup.py install
cd ~

cd basebuild
mkdir extracted
cd extracted
ubireader_extract_files ../rootfs.ubi
cd ubifs-root
cd $(ls -d */|head -n 1)
cd rootfs
cp -R boot ../../../
cp -R lib/modules ../../../

cd ~

#####
# Get and set-up Alpine
#####

echo "Getting and setting-up Alpine..."

mkdir alpine
cd alpine
mkdir rootfs
wget http://dl-cdn.alpinelinux.org/alpine/latest-stable/main/armhf/apk-tools-static-2.6.7-r0.apk
tar -xzf apk-tools-static-2.6.7-r0.apk
./sbin/apk.static -X http://dl-cdn.alpinelinux.org/alpine/latest-stable/main -U --allow-untrusted --root ./rootfs --initdb add alpine-base alpine-mirrors

cp /etc/resolv.conf rootfs/etc/
mount -t proc none rootfs/proc
mount -o bind /sys rootfs/sys
mount -o bind /dev rootfs/dev

# Install packages needed for wireless networking
sbin/apk.static -X http://dl-cdn.alpinelinux.org/alpine/latest-stable/main -U --allow-untrusted --root ./rootfs add wpa_supplicant wireless-tools

chroot rootfs /bin/sh

### Now in the context of Alpine

rc-update add devfs sysinit
rc-update add dmesg sysinit
rc-update add mdev sysinit

rc-update add modules boot
rc-update add sysctl boot
rc-update add hostname boot
rc-update add bootmisc boot
rc-update add syslog boot

rc-update add mount-ro shutdown
rc-update add killprocs shutdown
rc-update add savecache shutdown

# Make root's home directory
mkdir /root

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

exit

### Now out of the context of Alpine

umount rootfs/proc
umount rootfs/sys
umount rootfs/dev

#####
# Prepare rootfs
#####

echo "Preparing rootfs..."
cp -R ~/basebuild/extracted/boot rootfs/boot
cp -R ~/basebuild/extracted/modules rootfs/lib/modules

apt-get install -y mtd-utils
mkfs.ubifs -d rootfs -o rootfs.ubifs -e 0x1f8000 -c 2000 -m 0x4000 -x lzo
ubinize -o rootfs.ubi -m 0x4000 -p 0x200000 -s 16384 ~/ubinize.cfg