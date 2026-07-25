#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PROJECT_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)

UNIDROP_RUNTIME_DIR="$PROJECT_ROOT/.runtime/discovery-windows" \
UNIDROP_CONFIG_FILE="$PROJECT_ROOT/gateway-macos/config/discovery-windows.toml" \
UNIDROP_LAUNCHD_LABEL="com.windrop.gateway.discovery-windows" \
UNIDROP_SERVICE_NAME="UniDrop Windows AirDrop target" \
UNIDROP_STATUS_SCRIPT="$SCRIPT_DIR/status-windows-target.sh" \
"$SCRIPT_DIR/start-discovery-test.sh"
