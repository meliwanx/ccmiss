#!/bin/bash
# Package the built app only. Never reads user profiles or installs anything.
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_PATH="$PROJECT_DIR/dist/ccmiss.app"
OUTPUT_DIR="${1:-$PROJECT_DIR/release}"
SIGN_IDENTITY="${ACCOUNT_PROXY_SIGN_IDENTITY:-}"
if [[ $# -gt 1 || -z "$SIGN_IDENTITY" ]]; then
  printf '%s\n' 'Usage: ACCOUNT_PROXY_SIGN_IDENTITY=... ./Tools/package-release.sh [output-directory]' >&2
  exit 1
fi
if [[ "$(uname -s)" != Darwin || "$(uname -m)" != arm64 ]]; then
  printf '%s\n' 'Packaging requires Apple Silicon macOS.' >&2
  exit 1
fi
/usr/bin/codesign --verify --deep --strict "$APP_PATH"
VERSION="$(python3 - "$PROJECT_DIR" "$APP_PATH" <<'PY'
import pathlib, plistlib, re, subprocess, sys
project, app = map(pathlib.Path, sys.argv[1:])
info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
version = info['CFBundleShortVersionString']
if not re.fullmatch(r'\d+\.\d+\.\d+', version) or info['CFBundleIdentifier'] != 'io.ccmiss.app':
    raise SystemExit('Unexpected release identity.')
allowed = {
    'Contents/Info.plist', 'Contents/MacOS/AccountProxySwitcher',
    'Contents/Library/HelperTools/AccountProxyService',
    'Contents/Library/LaunchDaemons/io.ccmiss.app.network-service.plist',
    'Contents/_CodeSignature/CodeResources',
}
resources = {
    'standalone-engine.js', 'network-engine.js', 'coexist-engine.js', 'engine.js',
    'claude-tools.js', 'js-yaml.cjs', 'js-yaml-LICENSE.txt', 'node',
    'node-LICENSE.txt', 'mihomo', 'mihomo-LICENSE.txt',
    'mihomo-source-v1.19.32.tar.gz', 'mihomo-provenance.json',
    'THIRD_PARTY_NOTICES.md', 'LICENSE', '使用说明.md', 'README.zh-CN.md',
    'SECURITY.md', 'AppIcon.icns',
}
allowed.update('Contents/Resources/' + name for name in resources)
allowed.update('Contents/Resources/docs/' + p.name for p in (project / 'docs').glob('*.md'))
actual = set()
for p in app.rglob('*'):
    if p.is_symlink():
        raise SystemExit('Unexpected symlink in release app.')
    if p.is_file():
        actual.add(p.relative_to(app).as_posix())
if actual != allowed:
    raise SystemExit('Release bundle differs from the explicit package allowlist.')
team = None
for rel in ['Contents/MacOS/AccountProxySwitcher', 'Contents/Library/HelperTools/AccountProxyService',
            'Contents/Resources/node', 'Contents/Resources/mihomo']:
    details = subprocess.run(['/usr/bin/codesign', '-dvv', str(app / rel)],
                             capture_output=True, text=True, check=True).stderr
    match = re.search(r'^TeamIdentifier=([A-Z0-9]{10})$', details, re.M)
    if not match or 'Authority=Developer ID Application:' not in details or '(runtime)' not in details or 'Timestamp=' not in details:
        raise SystemExit('Release component lacks the required Developer ID signature.')
    if team is not None and team != match[1]:
        raise SystemExit('Release component signing teams differ.')
    team = match[1]
print(version)
PY
)"
mkdir -p "$OUTPUT_DIR"
OUTPUT_DIR="$(cd "$OUTPUT_DIR" && pwd)"
DMG_PATH="$OUTPUT_DIR/ccmiss-$VERSION-macos-arm64.dmg"
if [[ -e "$DMG_PATH" || -e "$OUTPUT_DIR/SHA256SUMS" ]]; then
  printf '%s\n' 'Release output already exists; choose a new output directory.' >&2
  exit 1
fi
STAGING="$(mktemp -d /private/tmp/ccmiss-dmg.XXXXXX)"
trap 'rm -rf "$STAGING"' EXIT
/usr/bin/ditto --norsrc --noextattr "$APP_PATH" "$STAGING/ccmiss.app"
ln -s /Applications "$STAGING/Applications"
cat > "$STAGING/Read Me.txt" <<'TEXT'
ccmiss for Apple Silicon / Apple Silicon 安装说明

Requires macOS 13.5 or later. Intel Macs are not supported.
Drag ccmiss.app into Applications, then open it from Applications.
Add your own SOCKS5 profile and prepare the Mac in Software Settings.
Standalone networking needs explicit macOS background-service approval.
The app interface is currently in Simplified Chinese. Clash is optional.

This package is Developer ID signed, but is NOT Apple notarized.
macOS may block the first launch. If you decide to trust the verified download,
use the per-app approval offered in System Settings > Privacy & Security.
Keep macOS security protections enabled.
https://support.apple.com/en-us/102445

将 ccmiss.app 拖到“应用程序”，再从“应用程序”打开。
需要 Apple Silicon（M1 或更新）及 macOS 13.5+，暂不支持 Intel Mac。
请添加自己的 SOCKS5，并在“软件设置”完成首次初始化。
独立网络服务需要用户主动批准；Clash 为可选项。
安装包已使用 Developer ID 签名，但尚未通过 Apple 公证。
首次打开如被拦截，在核对下载并决定信任后，可使用系统提供的单个应用批准入口。
请保持系统安全保护开启。 https://support.apple.com/zh-cn/102445

No accounts, proxy passwords, API keys, conversation backups or signing
private keys are bundled. The public signing certificate identifies the publisher.
没有预置账号、代理密码、API Key、对话备份或签名私钥；公开签名证书用于验证发布者。
Switches apply to new connections. No guarantee of avoiding account restrictions.
切换对新连接生效；不保证防封号。

Source, licenses and release checksums: https://github.com/meliwanx/ccmiss
TEXT
/usr/bin/xattr -cr "$STAGING/ccmiss.app"
/usr/bin/codesign --verify --deep --strict "$STAGING/ccmiss.app"
/usr/bin/hdiutil create -quiet -volname "ccmiss $VERSION" -srcfolder "$STAGING" \
  -fs HFS+ -format UDZO "$DMG_PATH"
/usr/bin/codesign --force --timestamp --sign "$SIGN_IDENTITY" "$DMG_PATH"
/usr/bin/codesign --verify --strict "$DMG_PATH"
/usr/bin/hdiutil verify "$DMG_PATH"
(cd "$OUTPUT_DIR" && /usr/bin/shasum -a 256 "$(basename "$DMG_PATH")" > SHA256SUMS)
printf 'Created %s\nNot Apple notarized. No application was installed or network settings changed.\n' "$DMG_PATH"
