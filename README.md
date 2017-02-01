Alpine Linux for C.H.I.P.
=========================

Nightly builds of Alpine Linux for the C.H.I.P. computer.
Thanks to [Akidan](https://bbs.nextthing.co/users/Akidan) for [the initial research/HOWTO](https://bbs.nextthing.co/t/c-h-i-p-now-runs-alpine-linux/5109).

## Installation

* Download [the latest release](https://github.com/marvinroger/chip-alpine/releases).
* Extract it: `tar zxvf alpine*.tar.gz`
* From within the C.H.I.P. SDK: `sudo BUILDROOT_OUTPUT_DIR=alpine/ ./chip-fel-flash.sh`

## Usage

Run `setup-alpine` to configure the hostname, Wi-Fi credentials (wlan0), apk repository, SSH and NTP.
