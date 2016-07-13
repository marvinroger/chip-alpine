#!/usr/bin/env bash

LATEST_BASEBUILD_URL="http://opensource.nextthing.co/chip/buildroot/stable/latest"

CWD=$(pwd)
mkdir basebuild
BASEBUILD_DIR="${CWD}/basebuild"
ALPINE_DIR="${CWD}/alpine"
ALPINE_IMAGES_DIR="${CWD}/alpine-images"

#####
# Get the latest base buildroot image
#####

echo "Getting latest base buildroot image..."

LATEST_BASEBUILD="$(wget -q -O- ${LATEST_BASEBUILD_URL})" || (echo "ERROR: cannot reach ${LATEST_BASEBUILD_URL}" && exit 1)
if [[ -z "${LATEST_BASEBUILD}" ]]; then
  echo "error: could not get URL for latest build from ${LATEST_BASEBUILD_URL}"
  exit 1
fi

BASEBUILD_ROOTFS_URL="${LATEST_BASEBUILD}/images"

if ! wget -P "${BASEBUILD_DIR}" "${BASEBUILD_ROOTFS_URL}/rootfs.ubi"; then
  echo "download of base build failed!"
  exit $?
fi

#####
# Extract the ubi file to get the kernel
#####

echo "Extracting buildroot image to get the kernel..."

sudo apt-get install -y liblzo2-dev python-lzo
wget https://bootstrap.pypa.io/ez_setup.py -O - | sudo python
git clone https://github.com/jrspruitt/ubi_reader
cd ubi_reader || exit
sudo python setup.py install

cd "$BASEBUILD_DIR" || exit
mkdir extracted
cd extracted || exit
ubireader_extract_files ../rootfs.ubi
cd ubifs-root || exit
cd "$(find . -maxdepth 1 ! -path .|head -n 1)" || exit
cd rootfs || exit
cp -R boot ../../../
cp -R lib/modules ../../../

cd ../../../../../ || exit

#####
# Install ARM emulator
#####

echo "Installing ARM emulator..."

sudo apt-get install -y qemu-user-static binfmt-support

#####
# Get and set-up Alpine
#####

echo "Getting and setting-up Alpine..."

mkdir alpine
cd alpine || exit
mkdir rootfs
wget http://dl-cdn.alpinelinux.org/alpine/latest-stable/main/armhf/apk-tools-static-2.6.7-r0.apk
tar -xzf apk-tools-static-2.6.7-r0.apk
sudo sbin/apk.static -X http://dl-cdn.alpinelinux.org/alpine/latest-stable/main -U --allow-untrusted --root ./rootfs --initdb add alpine-base alpine-mirrors

cp /etc/resolv.conf rootfs/etc/
mount -t proc none rootfs/proc
mount -o bind /sys rootfs/sys
mount -o bind /dev rootfs/dev

# Install packages needed for wireless networking
sudo sbin/apk.static -X http://dl-cdn.alpinelinux.org/alpine/latest-stable/main -U --allow-untrusted --root ./rootfs add wpa_supplicant wireless-tools

cp /usr/bin/qemu-arm-static rootfs/usr/bin/
cp ../chroot_build.sh rootfs/usr/bin

chroot rootfs /usr/bin/chroot_build.sh

umount rootfs/proc
umount rootfs/sys
umount rootfs/dev

rm rootfs/usr/bin/qemu-arm-static
rm rootfs/usr/bin/chroot_build.sh

exit

#####
# Prepare rootfs
#####

echo "Preparing rootfs..."

cp -R ../basebuild/extracted/boot rootfs/boot
cp -R ../basebuild/extracted/modules rootfs/lib/modules

apt-get install -y mtd-utils
mkfs.ubifs -d rootfs -o rootfs.ubifs -e 0x1f8000 -c 2000 -m 0x4000 -x lzo
ubinize -o rootfs.ubi -m 0x4000 -p 0x200000 -s 16384 ../ubinize.cfg

cd ../ || exit

#####
# Make Alpine release
#####

echo "Making Alpine release..."

mkdir -p alpinebuild/images
cd alpinebuild/images || exit
cp ../../alpine/rootfs.ubi ./

if ! wget "${BASEBUILD_ROOTFS_URL}/sun5i-r8-chip.dtb"; then
  echo "download of sun5i-r8-chip failed!"
  exit $?
fi

if ! wget "${BASEBUILD_ROOTFS_URL}/sunxi-spl.bin"; then
  echo "download of sunxi-spl.bin failed!"
  exit $?
fi

if ! wget "${BASEBUILD_ROOTFS_URL}/sunxi-spl-with-ecc.bin"; then
  echo "download of sunxi-spl-with-ecc.bin failed!"
  exit $?
fi

if ! wget "${BASEBUILD_ROOTFS_URL}/uboot-env.bin"; then
  echo "download of uboot-env.bin failed!"
  exit $?
fi

if ! wget "${BASEBUILD_ROOTFS_URL}/zImage"; then
  echo "download of zImage failed!"
  exit $?
fi

if ! wget "${BASEBUILD_ROOTFS_URL}/u-boot-dtb.bin"; then
  echo "download of u-boot-dtb.bin failed!"
  exit $?
fi

tar zcvf ~/alpine.tar.gz ~/alpinebuild

# tar zxvf alpine.tar.gz && sudo BUILDROOT_OUTPUT_DIR=alpinebuild/ ./chip-fel-flash.sh