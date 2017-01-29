#!/bin/bash

set -eo pipefail

readonly ALPINE_VERSION="edge"
readonly LATEST_BASEBUILD_URL="http://opensource.nextthing.co/chip/buildroot/stable/latest"

readonly GITHUB_REPO="marvinroger/chip-alpine"
readonly GITHUB_LOGIN_USERNAME="marvinroger"
# secure readonly GITHUB_ACCESS_TOKEN

CWD=$(cd "$(dirname "${BASH_SOURCE[0]}")"; pwd -P)
WORKING_DIR=$(mktemp -d -p /tmp chip-alpine.XXXXXX)
mkdir -p "${WORKING_DIR}/basebuild/extracted"
BASEBUILD_DIR="${WORKING_DIR}/basebuild"
mkdir -p "${WORKING_DIR}/alpine"
ALPINE_DIR="${WORKING_DIR}/alpine"
mkdir -p "${WORKING_DIR}/alpine-build/images"
ALPINE_BUILD_DIR="${WORKING_DIR}/alpine-build"

#####
# Install dependencies
#####

echo "Installing dependencies..."

# apk dependencies
echo "http://dl-cdn.alpinelinux.org/alpine/edge/testing" >> /etc/apk/repositories
apk update
apk add ca-certificates wget build-base git python2 py2-pip python2-dev lzo-dev tar mtd-utils

update-ca-certificates

# python-lzo
pip install python-lzo

# ubi_reader
git clone https://github.com/jrspruitt/ubi_reader "${WORKING_DIR}/ubi_reader"
cd "${WORKING_DIR}/ubi_reader"
python setup.py install

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

# download basebuild
wget -q -P "${BASEBUILD_DIR}" "${BASEBUILD_ROOTFS_URL}/rootfs.ubi"

#####
# Extract the ubi file to get the kernel
#####

echo "Extracting buildroot image to get the kernel..."

cd "$BASEBUILD_DIR/extracted"
ubireader_extract_files ../rootfs.ubi
cd ubifs-root
cd "$(find . -maxdepth 1 ! -path .|head -n 1)"
cd rootfs
# shellcheck disable=SC1091
source etc/os-release
BUILDROOT_VERSION_ID=${VERSION_ID}
cp -R boot "$BASEBUILD_DIR/extracted"
cp -R lib/modules "$BASEBUILD_DIR/extracted"

#####
# Get and set-up Alpine
#####

echo "Getting and setting-up Alpine..."

cd "$ALPINE_DIR"
mkdir rootfs
apk -X "http://dl-cdn.alpinelinux.org/alpine/${ALPINE_VERSION}/main" -U --allow-untrusted --root ./rootfs --initdb add alpine-base alpine-mirrors || true
# Install packages needed for wireless networking + nano + tzdata and bkeymaps needed for setup-alpine
apk -X "http://dl-cdn.alpinelinux.org/alpine/${ALPINE_VERSION}/main" -U --allow-untrusted --root ./rootfs add wpa_supplicant wireless-tools bkeymaps tzdata nano || true

# shellcheck disable=SC1091
source rootfs/etc/os-release
ALPINE_VERSION_ID=${VERSION_ID}
ALPINE_PRETTY_NAME=${PRETTY_NAME}

cp /usr/bin/qemu-arm-static rootfs/usr/bin/
cp /etc/resolv.conf rootfs/etc/
mount -t proc none rootfs/proc
mount -o bind /sys rootfs/sys
mount -o bind /dev rootfs/dev

# Setup Alpine from the inside
cp "${CWD}/chroot_build.sh" rootfs/usr/bin
chmod +x rootfs/usr/bin/chroot_build.sh
chroot rootfs /usr/bin/chroot_build.sh

umount rootfs/proc
umount rootfs/sys
umount rootfs/dev

rm rootfs/usr/bin/qemu-arm-static
rm rootfs/etc/resolv.conf
rm rootfs/usr/bin/chroot_build.sh

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

cd "${ALPINE_BUILD_DIR}/images"
cp "${ALPINE_DIR}/rootfs.ubi" ./

wget "${BASEBUILD_ROOTFS_URL}/sun5i-r8-chip.dtb"
wget "${BASEBUILD_ROOTFS_URL}/sunxi-spl.bin"
wget "${BASEBUILD_ROOTFS_URL}/sunxi-spl-with-ecc.bin"
wget "${BASEBUILD_ROOTFS_URL}/uboot-env.bin"
wget "${BASEBUILD_ROOTFS_URL}/zImage"
wget "${BASEBUILD_ROOTFS_URL}/u-boot-dtb.bin"

tar -zcv -C "${WORKING_DIR}" -f "${WORKING_DIR}/alpine.tar.gz" alpine-build

#####
# Create GitHub release
#####

echo "Releasing on GitHub..."

TAG_NAME="alpine-${ALPINE_VERSION_ID}_buildroot-${BUILDROOT_VERSION_ID}_$(date +%s)"
RELEASE_NAME="${ALPINE_PRETTY_NAME} with Buildroot ${BUILDROOT_VERSION_ID} built on $(date +%Y-%m-%d)"
RELEASE_BODY="Nightly build."

RELEASE_JSON=$(printf '{"tag_name": "%s","target_commitish": "master","name": "%s","body": "%s","draft": false,"prerelease": false}' "$TAG_NAME" "$RELEASE_NAME" "$RELEASE_BODY")
GITHUB_RELEASE_ID=$(curl -u "${GITHUB_LOGIN_USERNAME}:${GITHUB_ACCESS_TOKEN}" --data "$RELEASE_JSON" -v --silent "https://api.github.com/repos/${GITHUB_REPO}/releases" 2>&1 | sed -ne 's/^  "id": \(.*\),$/\1/p')

curl -u "${GITHUB_LOGIN_USERNAME}:${GITHUB_ACCESS_TOKEN}" -X POST -H "Content-Type: application/gzip" --data-binary "@${WORKING_DIR}/alpine.tar.gz" "https://uploads.github.com/repos/${GITHUB_REPO}/releases/${GITHUB_RELEASE_ID}/assets?name=${TAG_NAME}.tar.gz"

echo "Done!"

# tar zxvf alpine.tar.gz && sudo BUILDROOT_OUTPUT_DIR=alpinebuild/ ./chip-fel-flash.sh
