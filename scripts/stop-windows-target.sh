#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PROJECT_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)

UNIDROP_RUNTIME_DIR="$PROJECT_ROOT/.runtime/discovery-windows" \
UNIDROP_LAUNCHD_LABEL="com.windrop.gateway.discovery-windows" \
UNIDROP_SERVICE_NAME="UniDrop Windows AirDrop target" \
"$SCRIPT_DIR/stop-discovery-test.sh"
