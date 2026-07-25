#!/bin/sh
set -eu
PATH=/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin
export PATH

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PROJECT_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)

UNIDROP_RUNTIME_DIR="$PROJECT_ROOT/.runtime/discovery-windows" \
UNIDROP_LAUNCHD_LABEL="com.windrop.gateway.discovery-windows" \
"$SCRIPT_DIR/status-discovery-test.sh"
