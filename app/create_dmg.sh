#!/bin/bash
set -euo pipefail
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
if [ "$#" -ne 0 ]; then
    echo "Usage: ./create_dmg.sh (credentials must already be stored in Keychain)" >&2
    exit 2
fi
exec python3 "$SCRIPT_DIR/scripts/create_dmg.py"
