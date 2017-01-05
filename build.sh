#!/usr/bin/env bash

set -e

PATH=/usr/bin:/bin:/usr/local/bin:/usr/sbin
LATEST_BASEBUILD_URL="http://opensource.nextthing.co/chip/buildroot/stable/latest"

CWD=$(cd "$(dirname "${BASH_SOURCE[0]}")" || exit; pwd -P)
WORKING_DIR=$(mktemp -d --tmpdir=/tmp chip-alpine.XXXXXX)
mkdir -p "${WORKING_DIR}/basebuild/extracted"
BASEBUILD_DIR="${WORKING_DIR}/basebuild"
mkdir -p "${WORKING_DIR}/alpine"
ALPINE_DIR="${WORKING_DIR}/alpine"
mkdir -p "${WORKING_DIR}/alpine-build/images"
ALPINE_BUILD_DIR="${WORKING_DIR}/alpine-build"

#####
# Install dependencies
#####

echo "Checking and installing dependencies..."

dpkg-query -l git > /dev/null 2>&1
if [ $? -ne 0 ]
then
  sudo apt-get install -y git
fi

dpkg-query -l liblzo2-dev > /dev/null 2>&1
if [ $? -ne 0 ]
then
  sudo apt-get install -y liblzo2-dev
fi

dpkg-query -l python-lzo > /dev/null 2>&1
if [ $? -ne 0 ]
then
  sudo apt-get install -y python-lzo
fi

dpkg-query -l mtd-utils > /dev/null 2>&1
if [ $? -ne 0 ]
then
  sudo apt-get install -y mtd-utils
fi

hash easy_install > /dev/null 2>&1
if [ $? -ne 0 ]
then
  cd "${WORKING_DIR}" || exit
  wget https://bootstrap.pypa.io/ez_setup.py -O - | sudo python
fi

hash ubireader_extract_files > /dev/null 2>&1
if [ $? -ne 0 ]
then
  git clone https://github.com/jrspruitt/ubi_reader "${WORKING_DIR}/ubi_reader"
  cd "${WORKING_DIR}/ubi_reader" || exit
  python setup.py install
fi

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
  echo "error: download of base build failed!"
  exit $?
fi

#####
# Extract the ubi file to get the kernel
#####

echo "Extracting buildroot image to get the kernel..."

cd "$BASEBUILD_DIR/extracted" || exit
ubireader_extract_files ../rootfs.ubi
cd ubifs-root || exit
cd "$(find . -maxdepth 1 ! -path .|head -n 1)" || exit
cd rootfs || exit
# shellcheck disable=SC1091
source etc/os-release
BUILDROOT_VERSION_ID=${VERSION_ID}
cp -R boot "$BASEBUILD_DIR/extracted"
cp -R lib/modules "$BASEBUILD_DIR/extracted"

#####
# Get and set-up Alpine
#####

echo "Getting and setting-up Alpine..."

cd "$ALPINE_DIR" || exit
mkdir rootfs
wget http://dl-cdn.alpinelinux.org/alpine/latest-stable/main/armhf/apk-tools-static-2.6.7-r0.apk
tar -xzf apk-tools-static-2.6.7-r0.apk
sbin/apk.static -X http://dl-cdn.alpinelinux.org/alpine/latest-stable/main -U --allow-untrusted --root ./rootfs --initdb add alpine-base alpine-mirrors

# shellcheck disable=SC1091
source rootfs/etc/os-release
ALPINE_VERSION_ID=${VERSION_ID}

cp /etc/resolv.conf rootfs/etc/
mount -t proc none rootfs/proc
mount -o bind /sys rootfs/sys
mount -o bind /dev rootfs/dev

# Install packages needed for wireless networking + nano + tzdata and bkeymaps needed for setup-alpine
sbin/apk.static -X http://dl-cdn.alpinelinux.org/alpine/latest-stable/main -U --allow-untrusted --root ./rootfs add wpa_supplicant wireless-tools bkeymaps tzdata nano

# Workaround for BAD signature of libc-utils
wget http://nl.alpinelinux.org/alpine/latest-stable/main/armhf/libc-utils-0.7-r0.apk
cp libc-utils-0.7-r0.apk rootfs/home

# Setup Alpine from the inside
cp "${CWD}/chroot_build.sh" rootfs/usr/bin
chroot rootfs /usr/bin/chroot_build.sh

umount rootfs/proc
umount rootfs/sys
umount rootfs/dev

rm rootfs/etc/resolv.conf
rm rootfs/usr/bin/chroot_build.sh
rm rootfs/home/libc-utils-0.7-r0.apk

#####
# Prepare rootfs
#####

echo "Preparing rootfs..."

cp -R "${BASEBUILD_DIR}/extracted/boot" rootfs/boot
cp -R "${BASEBUILD_DIR}/extracted/modules" rootfs/lib/modules

cat <<EOF >ubinize.cfg
[ubifs]
mode=ubi
vol_id=0
vol_type=dynamic
vol_name=rootfs
vol_alignment=1
vol_flags=autoresize
image=rootfs.ubifs
EOF
mkfs.ubifs -d rootfs -o rootfs.ubifs -e 0x1f8000 -c 2000 -m 0x4000 -x lzo
ubinize -o rootfs.ubi -m 0x4000 -p 0x200000 -s 16384 ubinize.cfg

#####
# Make Alpine release
#####

echo "Making Alpine release..."

cd "${ALPINE_BUILD_DIR}/images" || exit
cp "${ALPINE_DIR}/rootfs.ubi" ./

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

tar -zcv -C "${WORKING_DIR}" -f "${WORKING_DIR}/alpine.tar.gz" alpine-build

#####
# Create GitHub release
#####

echo "Releasing on GitHub..."

TAG_NAME="alpine-${ALPINE_VERSION_ID}_buildroot-${BUILDROOT_VERSION_ID}_$(date +%s)"
RELEASE_NAME="Alpine ${ALPINE_VERSION_ID} with Buildroot ${BUILDROOT_VERSION_ID} built on $(date +%m/%d/%y)"
RELEASE_BODY="Nightly build."

RELEASE_JSON=$(printf '{"tag_name": "%s","target_commitish": "master","name": "%s","body": "%s","draft": false,"prerelease": false}' "$TAG_NAME" "$RELEASE_NAME" "$RELEASE_BODY")
UPLOAD_URL=$(curl -u "marvinroger:${GITHUB_ACCESS_TOKEN}" --data "$RELEASE_JSON" -v --silent "https://api.github.com/repos/marvinroger/chip-alpine/releases" 2>&1 | grep -Po '"upload_url": "\K([a-z0-9:/.-]+)')

curl -u "marvinroger:${GITHUB_ACCESS_TOKEN}" -X POST -H "Content-Type: application/gzip" --data-binary "@${WORKING_DIR}/alpine.tar.gz" "${UPLOAD_URL}?name=${TAG_NAME}.tar.gz"

echo "Done!"

# tar zxvf alpine.tar.gz && sudo BUILDROOT_OUTPUT_DIR=alpinebuild/ ./chip-fel-flash.sh
