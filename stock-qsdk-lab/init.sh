#!/bin/sh
# Compatibility wrapper; new callers use: build.sh sources
set -eu
lab=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
exec "$lab/build.sh" sources "$@"
