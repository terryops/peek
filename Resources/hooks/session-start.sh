#!/bin/sh
# Claude Code SessionStart hook：把 Peek 的 open / qlmanage 替身放到这个会话
# Bash 的 PATH 最前面。CLAUDE_ENV_FILE 会在每条 Bash 命令前被 source。
cat >/dev/null 2>&1   # 吃掉 stdin 里的 hook JSON
[ -n "$CLAUDE_ENV_FILE" ] || exit 0
SELF_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" 2>/dev/null && pwd)"
SHIM=""
for candidate in \
    "${SELF_DIR:+$SELF_DIR/../shim}" \
    "/Applications/Peek.app/Contents/Resources/shim" \
    "$HOME/Applications/Peek.app/Contents/Resources/shim"
do
    if [ -n "$candidate" ] && [ -x "$candidate/open" ] && [ -x "$candidate/../../MacOS/Peek" ]; then
        SHIM="$(CDPATH= cd -- "$candidate" 2>/dev/null && pwd)"
        break
    fi
done
[ -n "$SHIM" ] || exit 0
grep -qsF "$SHIM" "$CLAUDE_ENV_FILE" && exit 0
cat >> "$CLAUDE_ENV_FILE" <<ENV
case ":\$PATH:" in *":$SHIM:"*) ;; *) export PATH="$SHIM:\$PATH" ;; esac
ENV
exit 0
