#!/bin/bash
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
exec /bin/bash "$PROJECT_DIR/Tools/build-standalone.sh"
