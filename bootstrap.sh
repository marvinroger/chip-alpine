#!/bin/sh

set -eo pipefail

CWD=$(cd "$(dirname "$0")"; pwd -P)

apk update
apk add bash

chmod +x "${CWD}/build.sh"
"${CWD}/build.sh"
