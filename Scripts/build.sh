#!/bin/bash
# 编译并打包 build/Peek.app；默认 ad-hoc，可设 PEEK_SIGN_IDENTITY。
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
APP="$ROOT/build/Peek.app"
VERSION="${PEEK_VERSION:-1.4.7}"

echo "==> 编译"
if [[ "${PEEK_UNIVERSAL:-0}" == 1 ]]; then
    mkdir -p "$ROOT/build"
    for ARCH in arm64 x86_64; do
        swift build -c release --triple "$ARCH-apple-macosx14.0"
        # Xcode's SwiftPM backend may reuse one Products/Release path for both
        # triples, so retain each slice before building the next architecture.
        cp "$(swift build -c release --triple "$ARCH-apple-macosx14.0" --show-bin-path)/Peek" "$ROOT/build/Peek-$ARCH"
    done
    lipo -create "$ROOT/build/Peek-arm64" "$ROOT/build/Peek-x86_64" -output "$ROOT/build/Peek-universal"
    BIN="$ROOT/build/Peek-universal"
else
    swift build -c release --triple "$(uname -m)-apple-macosx14.0"
    BIN="$(swift build -c release --triple "$(uname -m)-apple-macosx14.0" --show-bin-path)/Peek"
fi
"$ROOT/Scripts/build-remote.sh"

echo "==> 自检"
TMP="$(mktemp -d /tmp/peek-selftest.XXXXXX)"
if ! PEEK_HOME="$TMP/store" "$BIN" --selftest > "$TMP/log" 2>&1; then
    grep "✗" "$TMP/log" | sed 's/^/    /'
    echo "✗ 自检没过，不打包"
    exit 1
fi
tail -1 "$TMP/log" | sed 's/^/    /'
rm -rf "$TMP"

echo "==> 打包"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Peek"
cp -R Resources/shim Resources/hooks Resources/web Resources/remote Resources/ssh-askpass "$APP/Contents/Resources/"
chmod 755 "$APP/Contents/Resources/ssh-askpass" "$APP/Contents/Resources/remote/"*
if [[ -f build/AppIcon.icns ]]; then
    cp build/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
elif [[ -f Resources/AppIcon.icns ]]; then
    cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
fi
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>Peek</string>
    <key>CFBundleIdentifier</key><string>com.terryops.peek</string>
    <key>CFBundleName</key><string>Peek</string>
    <key>CFBundleDisplayName</key><string>Peek</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$(date +%Y%m%d%H%M)</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST
SIGN_ARGS=(--force --sign "${PEEK_SIGN_IDENTITY:--}")
if [[ -n "${PEEK_SIGN_IDENTITY:-}" && "$PEEK_SIGN_IDENTITY" != - ]]; then
    SIGN_ARGS+=(--options runtime --timestamp)
else
    SIGN_ARGS+=(--timestamp=none)
fi
for HELPER in "$APP"/Contents/Resources/remote/peek-darwin-*; do
    codesign "${SIGN_ARGS[@]}" "$HELPER"
done
codesign "${SIGN_ARGS[@]}" "$APP"
codesign --verify --deep --strict "$APP"
CHECK="$(mktemp -d /tmp/peek-bundle-selftest.XXXXXX)"
trap 'rm -rf "$CHECK"' EXIT
PEEK_HOME="$CHECK/store" "$APP/Contents/MacOS/Peek" --selftest > "$CHECK/log" 2>&1 || { cat "$CHECK/log"; exit 1; }
tail -1 "$CHECK/log"
echo "    $APP"
