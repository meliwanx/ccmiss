#!/bin/bash
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="$PROJECT_DIR/.build"
APP_PATH="$PROJECT_DIR/dist/ccmiss.app"
DEPS_DIR="$PROJECT_DIR/.deps/darwin-arm64"
NODE_PATH="${ACCOUNT_PROXY_NODE:-$DEPS_DIR/node}"
SIGN_IDENTITY="${ACCOUNT_PROXY_SIGN_IDENTITY:-}"
TEAM_ID="${ACCOUNT_PROXY_TEAM_ID:-}"
BUNDLE_ID="io.ccmiss.app"
if [[ "$(uname -s)" != Darwin || "$(uname -m)" != arm64 ]]; then
  printf '%s\n' 'The current app build supports Apple Silicon macOS only.' >&2
  exit 1
fi
if [[ -z "$SIGN_IDENTITY" || ! "$TEAM_ID" =~ ^[A-Z0-9]{10}$ ]]; then
  printf '%s\n' 'A Developer ID Application identity and its 10-character team ID are required.' \
    'Set ACCOUNT_PROXY_SIGN_IDENTITY and ACCOUNT_PROXY_TEAM_ID explicitly.' \
    'For unsigned, offline source validation, run: ./Tools/verify.sh' >&2
  exit 1
fi
SDK_PATH="$(xcrun --sdk macosx --show-sdk-path)"
mkdir -p "$BUILD_DIR"
"$PROJECT_DIR/Tools/fetch-dependencies.sh" --verify-only
python3 - "$PROJECT_DIR" "$DEPS_DIR" "$NODE_PATH" <<'PY'
import hashlib, json, pathlib, sys
project, deps, node = map(pathlib.Path, sys.argv[1:])
manifest = json.loads((project / 'Tools/dependencies.json').read_text())
if not (deps / 'SHA256SUMS').is_file():
    raise SystemExit('Run ./Tools/fetch-dependencies.sh before building.')
if json.loads((deps / 'provenance.json').read_text()) != manifest:
    raise SystemExit('Dependency manifest changed; fetch dependencies again.')
for line in (deps / 'SHA256SUMS').read_text().splitlines():
    digest, name = line.split('  ', 1)
    if pathlib.PurePath(name).name != name or hashlib.sha256((deps / name).read_bytes()).hexdigest() != digest:
        raise SystemExit('Dependency checksum mismatch; fetch dependencies again.')
if hashlib.sha256((deps / 'mihomo').read_bytes()).hexdigest() != manifest['mihomo']['binarySHA256']:
    raise SystemExit('Pinned Mihomo checksum mismatch.')
if hashlib.sha256(node.read_bytes()).hexdigest() != manifest['node']['binarySHA256']:
    raise SystemExit('Node.js binary does not match the pinned official release.')
if hashlib.sha256((project / 'Resources/js-yaml.cjs').read_bytes()).hexdigest() != manifest['js-yaml']['vendoredSHA256']:
    raise SystemExit('Vendored js-yaml checksum mismatch.')
PY
# This stage is a build output only; it never replaces an installed application.
rm -rf "$APP_PATH"
mkdir -p "$APP_PATH/Contents/MacOS" "$APP_PATH/Contents/Resources/docs" \
  "$APP_PATH/Contents/Library/HelperTools" "$APP_PATH/Contents/Library/LaunchDaemons"
for RESOURCE in standalone-engine.js network-engine.js coexist-engine.js engine.js claude-tools.js js-yaml.cjs js-yaml-LICENSE.txt; do
  cp "$PROJECT_DIR/Resources/$RESOURCE" "$APP_PATH/Contents/Resources/$RESOURCE"
done
for RESOURCE in node-LICENSE.txt mihomo mihomo-LICENSE.txt mihomo-source-v1.19.32.tar.gz; do
  cp "$DEPS_DIR/$RESOURCE" "$APP_PATH/Contents/Resources/$RESOURCE"
done
cp -L "$NODE_PATH" "$APP_PATH/Contents/Resources/node"
cp "$PROJECT_DIR/Resources/mihomo-provenance.json" "$APP_PATH/Contents/Resources/mihomo-provenance.json"
cp "$PROJECT_DIR/THIRD_PARTY_NOTICES.md" "$APP_PATH/Contents/Resources/THIRD_PARTY_NOTICES.md"
cp "$PROJECT_DIR/LICENSE" "$APP_PATH/Contents/Resources/LICENSE"
cp "$PROJECT_DIR/README.md" "$APP_PATH/Contents/Resources/使用说明.md"
for DOCUMENT in "$PROJECT_DIR"/docs/*.md; do
  [[ -f "$DOCUMENT" ]] && cp "$DOCUMENT" "$APP_PATH/Contents/Resources/docs/"
done
for DOCUMENT in README.zh-CN.md SECURITY.md; do
  [[ -f "$PROJECT_DIR/$DOCUMENT" ]] && cp "$PROJECT_DIR/$DOCUMENT" "$APP_PATH/Contents/Resources/$DOCUMENT"
done
chmod 755 "$APP_PATH/Contents/Resources/node" "$APP_PATH/Contents/Resources/mihomo"
cat > "$BUILD_DIR/node-entitlements.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict><key>com.apple.security.cs.allow-jit</key><true/></dict></plist>
PLIST
codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" \
  --entitlements "$BUILD_DIR/node-entitlements.plist" \
  --identifier "$BUNDLE_ID.runtime" "$APP_PATH/Contents/Resources/node"
codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" \
  --identifier "$BUNDLE_ID.core" "$APP_PATH/Contents/Resources/mihomo"
# Refuse an ad-hoc or mismatched signing identity before producing a helper.
python3 - "$APP_PATH" "$BUILD_DIR/CoreBuildIdentity.swift" "$TEAM_ID" <<'PY'
import hashlib, json, pathlib, plistlib, subprocess, sys
app, output, team = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2]), sys.argv[3]
for binary in [app / 'Contents/Resources/node', app / 'Contents/Resources/mihomo']:
    info = subprocess.run(['/usr/bin/codesign', '-dvv', str(binary)], capture_output=True, text=True, check=True).stderr
    if f'TeamIdentifier={team}\n' not in info or 'Authority=Developer ID Application:' not in info:
        raise SystemExit('Signing requires a matching Developer ID Application identity; helper validation was not relaxed.')
digest = hashlib.sha256((app / 'Contents/Resources/mihomo').read_bytes()).hexdigest()
output.write_text('enum CoreBuildIdentity {\n static let sha256 = ' + json.dumps(digest) + '\n static let version = "1.19.32"\n static let teamIdentifier = ' + json.dumps(team) + '\n}\n')
info = {'CFBundleIdentifier':'io.ccmiss.app','CFBundleName':'ccmiss','CFBundleDisplayName':'ccmiss','CFBundleExecutable':'AccountProxySwitcher','CFBundlePackageType':'APPL','CFBundleShortVersionString':'2.6.1','CFBundleVersion':'21','LSMinimumSystemVersion':'13.5','LSApplicationCategoryType':'public.app-category.utilities','NSHighResolutionCapable':True,'NSPrincipalClass':'NSApplication','CFBundleIconFile':'AppIcon'}
(app / 'Contents/Info.plist').write_bytes(plistlib.dumps(info))
PY
cp "$PROJECT_DIR/Sources/AccountProxyService/io.ccmiss.app.network-service.plist" \
  "$APP_PATH/Contents/Library/LaunchDaemons/io.ccmiss.app.network-service.plist"
HELPER_SOURCES=()
for SOURCE in "$PROJECT_DIR"/Sources/AccountProxyService/*.swift; do
  if [[ "$(basename "$SOURCE")" != CoreBuildIdentity.swift ]]; then HELPER_SOURCES+=("$SOURCE"); fi
done
xcrun swiftc -swift-version 5 -module-name AccountProxyService -O -whole-module-optimization \
  -target arm64-apple-macosx13.5 -sdk "$SDK_PATH" \
  -framework Foundation -framework Security -framework SystemConfiguration \
  "${HELPER_SOURCES[@]}" "$BUILD_DIR/CoreBuildIdentity.swift" \
  -o "$APP_PATH/Contents/Library/HelperTools/AccountProxyService"
codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" \
  --identifier "$BUNDLE_ID.network-service" "$APP_PATH/Contents/Library/HelperTools/AccountProxyService"
xcrun swiftc -swift-version 5 -module-name AccountProxySwitcher -O -whole-module-optimization \
  -target arm64-apple-macosx13.5 -sdk "$SDK_PATH" \
  -framework SwiftUI -framework AppKit -framework ServiceManagement \
  "$PROJECT_DIR"/Sources/AccountProxySwitcher/*.swift \
  -o "$APP_PATH/Contents/MacOS/AccountProxySwitcher"
xcrun swift "$PROJECT_DIR/Tools/generate-icon.swift" "$PROJECT_DIR/Resources/Brand/ccmiss-logo.png" "$BUILD_DIR/ccmiss.iconset"
/usr/bin/iconutil -c icns "$BUILD_DIR/ccmiss.iconset" -o "$BUILD_DIR/AppIcon.icns"
cp "$BUILD_DIR/AppIcon.icns" "$APP_PATH/Contents/Resources/AppIcon.icns"
codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" --identifier "$BUNDLE_ID" "$APP_PATH"
codesign --verify --deep --strict "$APP_PATH"
printf 'Built signed app: %s\nNo application was installed and no network settings were changed.\n' "$APP_PATH"
