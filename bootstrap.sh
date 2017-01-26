#!/bin/sh

set -eo pipefail

apk update
apk add bash
./build.sh
