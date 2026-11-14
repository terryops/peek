#!/bin/bash
# 编译 → 装到 ~/Applications/Peek.app → LaunchAgent 常驻（开机自启）→ ~/bin/peek
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [[ "${1:-}" == --prebuilt ]]; then
    [[ $# == 2 ]] || { echo "用法：$0 --prebuilt /path/Peek.app" >&2; exit 64; }
    SOURCE="$(cd "$2" && pwd)"
elif [[ $# == 0 ]]; then
    "$ROOT/Scripts/build.sh"
    SOURCE="$ROOT/build/Peek.app"
else
    echo "用法：$0 [--prebuilt /path/Peek.app]" >&2; exit 64
fi
[[ -x "$SOURCE/Contents/MacOS/Peek" && -x "$SOURCE/Contents/Resources/ssh-askpass" ]] || { echo "Peek.app 缺少可执行文件" >&2; exit 1; }
for OS in darwin linux; do
    for ARCH in amd64 arm64; do
        [[ -x "$SOURCE/Contents/Resources/remote/peek-$OS-$ARCH" ]] || { echo "Peek.app 缺少远程 helper" >&2; exit 1; }
    done
done
codesign --verify --deep --strict "$SOURCE"
CHECK="$(mktemp -d /tmp/peek-install-selftest.XXXXXX)"
trap 'rm -rf "$CHECK"' EXIT
PEEK_HOME="$CHECK/store" "$SOURCE/Contents/MacOS/Peek" --selftest > "$CHECK/log" 2>&1 || { cat "$CHECK/log"; exit 1; }
tail -1 "$CHECK/log"

LABEL=com.terryops.peek
DEST="$HOME/Applications/Peek.app"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
DOMAIN="gui/$(id -u)"

echo "==> 安装"
launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true
pkill -f "$DEST/Contents/MacOS/Peek --app" 2>/dev/null || true
mkdir -p "$HOME/Applications" "$HOME/bin" "$HOME/Library/LaunchAgents" "$HOME/Library/Logs"
rsync -a --delete "$SOURCE/" "$DEST/"
ln -sfn "$DEST/Contents/MacOS/Peek" "$HOME/bin/peek"

cat > "$PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>$LABEL</string>
    <key>ProgramArguments</key>
    <array><string>$DEST/Contents/MacOS/Peek</string><string>--app</string></array>
    <key>RunAtLoad</key><true/>
    <key>KeepAlive</key><dict><key>SuccessfulExit</key><false/></dict>
    <key>ProcessType</key><string>Interactive</string>
    <key>LimitLoadToSessionType</key><string>Aqua</string>
    <key>StandardErrorPath</key><string>$HOME/Library/Logs/Peek.log</string>
</dict>
</plist>
PLIST
sleep 0.3
launchctl bootstrap "$DOMAIN" "$PLIST"
sleep 0.5
launchctl print "$DOMAIN/$LABEL" | grep -E '^\s+(state|pid) =' | sed 's/^\s*/    /'
echo "    peek → $(readlink "$HOME/bin/peek")"
