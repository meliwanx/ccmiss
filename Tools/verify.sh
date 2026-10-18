#!/bin/bash
# Offline fixtures and compilation only. Never run this as root.
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
WITH_CORE=false
case "${1:-}" in
  '') ;;
  --with-core) WITH_CORE=true ;;
  *) printf '%s\n' 'Usage: ./Tools/verify.sh [--with-core]' >&2; exit 1 ;;
esac
if [[ "$(id -u)" == 0 ]]; then
  printf '%s\n' 'Run verification as an ordinary user, never with sudo.' >&2
  exit 1
fi
if [[ "$(uname -s)" != Darwin ]]; then
  printf '%s\n' 'Swift/AppKit validation requires macOS and Xcode Command Line Tools.' >&2
  exit 1
fi
if [[ -n "${ACCOUNT_PROXY_NODE:-}" ]]; then
  NODE_PATH="$ACCOUNT_PROXY_NODE"
elif [[ -x "$PROJECT_DIR/.deps/darwin-arm64/node" ]]; then
  "$PROJECT_DIR/Tools/fetch-dependencies.sh" --verify-only
  NODE_PATH="$PROJECT_DIR/.deps/darwin-arm64/node"
else
  NODE_PATH="$(command -v node || true)"
fi
if [[ -z "$NODE_PATH" ]]; then
  printf '%s\n' 'Node.js 24 is required; install it or run ./Tools/fetch-dependencies.sh.' >&2
  exit 1
fi
python3 - "$PROJECT_DIR/Tools/dependencies.json" "$NODE_PATH" <<'PY'
import hashlib, json, pathlib, sys
manifest = json.loads(pathlib.Path(sys.argv[1]).read_text())
if hashlib.sha256(pathlib.Path(sys.argv[2]).read_bytes()).hexdigest() != manifest['node']['binarySHA256']:
    raise SystemExit('Node.js binary does not match the pinned official release; run ./Tools/fetch-dependencies.sh.')
PY
SDK_PATH="$(xcrun --sdk macosx --show-sdk-path)"
VERIFY_DIR="$(mktemp -d "${TMPDIR:-/tmp}/ccmiss-verify.XXXXXX")"
trap 'rm -rf "$VERIFY_DIR"' EXIT
mkdir -p "$VERIFY_DIR/home" "$VERIFY_DIR/Resources"
# A temporary HOME provides an additional barrier against accidental user-data reads.
for SOURCE in "$PROJECT_DIR"/Resources/*.js "$PROJECT_DIR"/Resources/*.cjs; do
  cp "$SOURCE" "$VERIFY_DIR/Resources/"
  "$NODE_PATH" --check "$SOURCE"
done
for TEST in network-engine-selftest.cjs claude-tools-selftest.cjs coexist-ownership-selftest.cjs engine-selftest.cjs engine-setup-selftest.cjs; do
  HOME="$VERIFY_DIR/home" "$NODE_PATH" "$VERIFY_DIR/Resources/$TEST"
done
HOME="$VERIFY_DIR/home" "$NODE_PATH" "$VERIFY_DIR/Resources/coexist-engine-selftest.cjs" --fixtures-only
HOME="$VERIFY_DIR/home" "$NODE_PATH" "$VERIFY_DIR/Resources/standalone-engine-selftest.cjs" --system-proxy-only
HOME="$VERIFY_DIR/home" "$NODE_PATH" "$VERIFY_DIR/Resources/standalone-engine-selftest.cjs" --upstream-summary-only

swift_test() {
  local NAME="$1"
  shift
  xcrun swiftc -swift-version 5 -sdk "$SDK_PATH" "$@" -o "$VERIFY_DIR/$NAME"
  "$VERIFY_DIR/$NAME"
}
swift_test setup-policy "$PROJECT_DIR/Sources/AccountProxySwitcher/EnvironmentSetupModels.swift" \
  "$PROJECT_DIR/Tools/app-setup-policy-selftest.swift"
swift_test browser-environment -framework AppKit "$PROJECT_DIR/Sources/AccountProxySwitcher/BrowserEnvironment.swift" \
  "$PROJECT_DIR/Sources/AccountProxySwitcher/BrowserLauncher.swift" \
  "$PROJECT_DIR/Tools/browser-environment-selftest.swift"
swift_test claude-exit-probe "$PROJECT_DIR/Sources/AccountProxySwitcher/ClaudeExitProbe.swift" \
  "$PROJECT_DIR/Tools/claude-exit-probe-selftest.swift"

# Generate synthetic helper input without starting a core or making a request.
HOME="$VERIFY_DIR/home" "$NODE_PATH" - "$VERIFY_DIR/Resources" "$VERIFY_DIR/helper-fixture.json" <<'JS'
const fs = require('node:fs');
const engine = require(process.argv[2] + '/standalone-engine.js');
const prepared = engine.buildConfiguration({id:'fixture',name:'Offline fixture',socksURL:'socks5://fixture:placeholder@192.0.2.10:1080'});
fs.writeFileSync(process.argv[3], JSON.stringify(prepared.configuration));
JS
xcrun swiftc -swift-version 5 -sdk "$SDK_PATH" -framework Foundation -framework SystemConfiguration \
  "$PROJECT_DIR/Sources/AccountProxyService/SecureFiles.swift" \
  "$PROJECT_DIR/Sources/AccountProxyService/ServiceProtocol.swift" \
  "$PROJECT_DIR/Sources/AccountProxyService/DNSController.swift" \
  "$PROJECT_DIR/Tools/helper-safety-selftest.swift" -o "$VERIFY_DIR/helper-safety"
"$VERIFY_DIR/helper-safety" "$VERIFY_DIR/helper-fixture.json"

# Typecheck all production sources, including privileged code, without executing it.
xcrun swiftc -typecheck -swift-version 5 -module-name AccountProxySwitcher -sdk "$SDK_PATH" \
  -framework SwiftUI -framework AppKit -framework ServiceManagement \
  "$PROJECT_DIR"/Sources/AccountProxySwitcher/*.swift
xcrun swiftc -typecheck -swift-version 5 -module-name AccountProxyService -sdk "$SDK_PATH" \
  -framework Foundation -framework Security -framework SystemConfiguration \
  "$PROJECT_DIR"/Sources/AccountProxyService/*.swift

if "$WITH_CORE"; then
  CORE_PATH="$PROJECT_DIR/.deps/darwin-arm64/mihomo"
  if [[ ! -x "$CORE_PATH" ]]; then
    printf '%s\n' 'Run ./Tools/fetch-dependencies.sh before --with-core.' >&2
    exit 1
  fi
  python3 - "$PROJECT_DIR/Tools/dependencies.json" "$CORE_PATH" <<'PY'
import hashlib, json, pathlib, sys
manifest = json.loads(pathlib.Path(sys.argv[1]).read_text())
if hashlib.sha256(pathlib.Path(sys.argv[2]).read_bytes()).hexdigest() != manifest['mihomo']['binarySHA256']:
    raise SystemExit('Pinned core checksum mismatch; refusing to execute it.')
PY
  cp "$CORE_PATH" "$VERIFY_DIR/Resources/mihomo"
  chmod 755 "$VERIFY_DIR/Resources/mihomo"
  printf '%s\n' 'Running isolated core fixtures: loopback only; TUN and DNS are disabled.'
  for TEST in standalone-engine-selftest.cjs coexist-engine-selftest.cjs engine-session-selftest.cjs; do
    HOME="$VERIFY_DIR/home" "$NODE_PATH" "$VERIFY_DIR/Resources/$TEST"
  done
fi
printf '%s\n' 'Verification passed. No application installation, helper registration, live proxy, TUN or DNS changes were performed.'
