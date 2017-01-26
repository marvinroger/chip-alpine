#!/bin/sh

set -eo pipefail

CWD=$(cd "$(dirname "$0")"; pwd -P)

apk update
apk add bash

"${CWD}/build.sh"
