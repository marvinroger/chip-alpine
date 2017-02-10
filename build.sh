#!/bin/bash

set -eo pipefail

readonly ALPINE_CHROOT_INSTALL_VERSION="0.1.3"
readonly ALPINE_VERSION="latest-stable"
readonly LATEST_BUILDROOT_URL="http://opensource.nextthing.co/chip/buildroot/stable/latest"

readonly GITHUB_REPO="marvinroger/chip-alpine"
readonly GITHUB_LOGIN_USERNAME="marvinroger"
# secure readonly GITHUB_ACCESS_TOKEN

die () {
	printf '\033[1;31mERROR:\033[0m %s\n' "$@" >&2  # bold red
	exit 1
}

einfo () {
	printf '\n\033[1;36m> %s\033[0m\n' "$@" >&2  # bold cyan
}

ewarn () {
	printf '\033[1;33m> %s\033[0m\n' "$@" >&2  # bold yellow
}

install_apt_dependencies () {
  apt-get install -y git liblzo2-dev python-lzo mtd-utils
}

install_ubi_reader () {
  local temp_dir
  temp_dir=$(mktemp -d -p /tmp ubi_reader.XXXXXX)
  git clone https://github.com/jrspruitt/ubi_reader "${temp_dir}"
  pushd "${temp_dir}"
  python setup.py install
  popd
  rm --recursive "${temp_dir}"
}

install_alpine_chroot_install () {
  local version="${1}"

  wget --quiet --output-document /usr/local/bin/alpine-chroot-install "https://raw.githubusercontent.com/jirutka/alpine-chroot-install/v${version}/alpine-chroot-install"
  chmod +x /usr/local/bin/alpine-chroot-install
}

get_latest_buildroot () {
  local latest_buildroot_url="${1}"
  local buildroot_dir="${2}"
  
  local _latest_buildroot # _ because else conflict with latest_buildroot in main scope
  _latest_buildroot=$(wget --quiet -O- "${latest_buildroot_url}")
  eval "${3}=\"${_latest_buildroot}\""
  local buildroot_rootfs_url
  buildroot_rootfs_url="${_latest_buildroot}/images/rootfs.ubi"
  
  local temp_dir
  temp_dir=$(mktemp -d -p /tmp buildroot.XXXXXX)
  
  # download buildroot
  wget --quiet --output-document "${temp_dir}/rootfs.ubi" "${buildroot_rootfs_url}"
  
  # extract ubi
  pushd "${temp_dir}"
  mkdir extracted
  pushd extracted
  ubireader_extract_files "../rootfs.ubi"
  pushd ubifs-root
  pushd "$(find . -maxdepth 1 ! -path .|head -n 1)"
  pushd rootfs
  cp --archive ./. "${buildroot_dir}"
  popd
  popd
  popd
  popd
  popd
  rm --recursive "${temp_dir}"
}

prepare_alpine () {
  local alpine_version="${1}"
  local alpine_dir="${2}"

  CHROOT_KEEP_VARS="" ALPINE_PACKAGES="wpa_supplicant wireless-tools bkeymaps tzdata nano" alpine-chroot-install -d "${alpine_dir}" -a armhf -b "${alpine_version}"
  
  "${alpine_dir}/enter-chroot" root <<-EOF
    set -e
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
EOF
  
  umount -l "${alpine_dir}/proc"
  umount -l "${alpine_dir}/sys"
  umount -l "${alpine_dir}/dev"
  umount -l "${alpine_dir}$(pwd)"
  
  rm "${alpine_dir}/usr/bin/qemu-arm-static"
  rm "${alpine_dir}/etc/resolv.conf"
  rm "${alpine_dir}/enter-chroot"
}

prepare_rootfs () {
  local buildroot_dir="${1}"
  local alpine_dir="${2}"
  local ubi_dest="${3}"
  
  local temp_dir
  temp_dir=$(mktemp -d -p /tmp ubi.XXXXXX)
  
  cp --archive "${buildroot_dir}/boot/." "${alpine_dir}/boot"
  cp --archive "${buildroot_dir}/lib/modules/." "${alpine_dir}/lib/modules"
  
  pushd "${temp_dir}"
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
  mkfs.ubifs -d "${alpine_dir}" -o rootfs.ubifs -e 0x1f8000 -c 2000 -m 0x4000 -x lzo
  ubinize -o "${ubi_dest}" -m 0x4000 -p 0x200000 -s 16384 ubinize.cfg
  popd
  rm --recursive "${temp_dir}"
}

make_alpine_release () {
  local chip_build_dir="${1}"
  local latest_buildroot="${2}"
  local tar_dest="${3}"
  
  wget --quiet --output-document "${chip_build_dir}/alpine/images/sun5i-r8-chip.dtb" "${latest_buildroot}/images/sun5i-r8-chip.dtb"
  wget --quiet --output-document "${chip_build_dir}/alpine/images/sunxi-spl.bin" "${latest_buildroot}/images/sunxi-spl.bin"
  wget --quiet --output-document "${chip_build_dir}/alpine/images/sunxi-spl-with-ecc.bin" "${latest_buildroot}/images/sunxi-spl-with-ecc.bin"
  wget --quiet --output-document "${chip_build_dir}/alpine/images/uboot-env.bin" "${latest_buildroot}/images/uboot-env.bin"
  wget --quiet --output-document "${chip_build_dir}/alpine/images/zImage" "${latest_buildroot}/images/zImage"
  wget --quiet --output-document "${chip_build_dir}/alpine/images/u-boot-dtb.bin" "${latest_buildroot}/images/u-boot-dtb.bin"
  
  pushd "${chip_build_dir}"
  tar -zcv -C "${chip_build_dir}" -f "${tar_dest}" alpine
  popd
}

gather_rootfs_versions () {
  local buildroot_dir="${1}"
  local alpine_dir="${2}"
  
  # shellcheck source=/dev/null
  source "${buildroot_dir}/etc/os-release"
  eval "${3}=\"${VERSION_ID}\""
  
  # shellcheck source=/dev/null
  source "${alpine_dir}/etc/os-release"
  eval "${4}=\"${VERSION_ID}\""
  eval "${5}=\"${PRETTY_NAME}\""
}

release_github () {
  local repo="${1}"
  local username="${2}"
  local access_token="${3}"
  local tag_name="${4}"
  local release_name="${5}"
  local release_body="${6}"
  local tar_location="${7}"
  
  local release_json
  release_json=$(printf '{"tag_name": "%s","target_commitish": "master","name": "%s","body": "%s","draft": false,"prerelease": false}' "${tag_name}" "${release_name}" "${release_body}")
  local github_release_id
  github_release_id=$(curl -u "${username}:${access_token}" --data "${release_json}" -v --silent "https://api.github.com/repos/${repo}/releases" 2>&1 | sed -ne 's/^  "id": \(.*\),$/\1/p')
  
  curl -u "${username}:${access_token}" -X POST -H "Content-Type: application/gzip" --data-binary "@${tar_location}" "https://uploads.github.com/repos/${repo}/releases/${github_release_id}/assets?name=${tag_name}.tar.gz"
}

main () {
  local working_dir
  working_dir=$(mktemp -d -p /tmp chip-alpine.XXXXXX)
  local buildroot_dir="${working_dir}/buildroot"
  mkdir -p "${buildroot_dir}"
  local alpine_dir="${working_dir}/alpine"
  mkdir -p "${alpine_dir}"
  local chip_build_dir="${working_dir}/chip-build"
  mkdir -p "${chip_build_dir}/alpine/images"
  
  einfo "Installing dependencies..."
  install_apt_dependencies
  
  einfo "Installing ubi_reader..."
  install_ubi_reader
  
  einfo "Installing alpine-chroot-install..."
  install_alpine_chroot_install "${ALPINE_CHROOT_INSTALL_VERSION}"
  
  #####
  # Get the latest base buildroot image
  #####
  
  einfo "Getting latest buildroot..."
  local latest_buildroot=""
  get_latest_buildroot "${LATEST_BUILDROOT_URL}" "${buildroot_dir}" "latest_buildroot"
  
  #####
  # Get and set-up Alpine
  #####
  
  einfo "Getting and setting-up Alpine..."
  prepare_alpine "${ALPINE_VERSION}" "${alpine_dir}"
  
  #####
  # Prepare rootfs
  #####
  
  einfo "Preparing rootfs..."
  prepare_rootfs "${buildroot_dir}" "${alpine_dir}" "${chip_build_dir}/alpine/images/rootfs.ubi"
  
  #####
  # Make Alpine release
  #####
  
  einfo "Making Alpine release..."
  local temp_tar
  temp_tar=$(mktemp -p /tmp tar.XXXXXX)
  make_alpine_release "${chip_build_dir}" "${latest_buildroot}" "${temp_tar}"
  
  einfo "Gathering rootfs versions..."
  local buildroot_version_id=""
  local alpine_version_id=""
  local alpine_pretty_name=""
  gather_rootfs_versions "${buildroot_dir}" "${alpine_dir}" "buildroot_version_id" "alpine_version_id" "alpine_pretty_name"
  
  #####
  # Create GitHub release
  #####
  
  einfo "Releasing on GitHub..."
  release_github "${GITHUB_REPO}" "${GITHUB_LOGIN_USERNAME}" "${GITHUB_ACCESS_TOKEN}" \
    "alpine-${alpine_version_id}_buildroot-${buildroot_version_id}_$(date +%s)" \
    "${alpine_pretty_name} with Buildroot ${buildroot_version_id} built on $(date +%Y-%m-%d)" \
    "Daily build." \
    "${temp_tar}"
    
  rm "${temp_tar}"

  einfo "Done!"  
}

main

# tar zxvf alpine*.tar.gz && sudo BUILDROOT_OUTPUT_DIR=alpine/ ./chip-fel-flash.sh
