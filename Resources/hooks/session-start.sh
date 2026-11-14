#!/bin/sh
# Claude Code SessionStart hook：把 Peek 的 open / qlmanage 替身放到这个会话
# Bash 的 PATH 最前面。CLAUDE_ENV_FILE 会在每条 Bash 命令前被 source。
cat >/dev/null 2>&1   # 吃掉 stdin 里的 hook JSON
[ -n "$CLAUDE_ENV_FILE" ] || exit 0
SHIM="$HOME/Applications/Peek.app/Contents/Resources/shim"
[ -d "$SHIM" ] || exit 0
grep -qsF "$SHIM" "$CLAUDE_ENV_FILE" && exit 0
cat >> "$CLAUDE_ENV_FILE" <<ENV
case ":\$PATH:" in *":$SHIM:"*) ;; *) export PATH="$SHIM:\$PATH" ;; esac
ENV
exit 0
