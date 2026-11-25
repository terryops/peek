# Peek

English · [简体中文](README.zh-CN.md) · [Manual Usage & Shortcuts](docs/manual-usage.md)

Native macOS floating preview cards for AI Agents (Claude Code, Codex, Cursor, Windsurf, OpenClaw, etc.). Instead of popping up Preview or a browser and stealing your keyboard focus—or leaving bare file paths in chat—agents push **images, PDFs, Markdown, and HTML** to non-activating cards in the top-right corner of your screen. Click a card when you are ready to inspect it, press `Esc` to return right where you were typing, or press `↩` on a card from a local Rex session to return to that session.

[**Download for Apple Silicon**](https://github.com/terryops/peek/releases/latest) · macOS 14+ · Signed & Notarized · [Intel download (v1.3.0)](https://github.com/terryops/peek/releases/tag/v1.3.0) · [MIT License](LICENSE)

<p align="center">
  <img src="docs/screenshots/demo.gif" alt="Peek demo: an AI agent pushes files to a top-right floating card without stealing focus from the chat window, opens side-by-side comparison on click, and returns focus on Esc" width="840">
</p>

## 1. One-Time Setup

### On your Mac

1. On an Apple Silicon Mac, download `Peek-arm64.zip` from [GitHub Releases](https://github.com/terryops/peek/releases/latest), unzip it, move `Peek.app` into `/Applications`, and open it.
2. Click the Peek menu bar icon → **Install 'peek' Command** (and optionally enable **Launch at Login**), or link `~/.local`/`~/bin` manually:

```sh
mkdir -p "$HOME/bin"
ln -sfn "/Applications/Peek.app/Contents/MacOS/Peek" "$HOME/bin/peek"
```

Make sure `$HOME/bin` is in your shell `PATH` (for example, `export PATH="$HOME/bin:$PATH"` in `~/.zprofile`).

### On remote SSH servers *(optional)*

If your agents run on remote Linux or macOS machines (`amd64` / `arm64`), run `peek remote add user@host --wait --json`, or connect through **Remote Machines…** in the Peek menu. Peek installs `~/.local/bin/peek` on the remote host over your existing `/usr/bin/ssh` setup (`~/.ssh/config`, keys, SSH agent, JumpHosts) with no cloud relay or inbound ports—remote agents can then push cards straight to your Mac.

## 2. Add Rule to `CLAUDE.md` / `AGENTS.md`

Paste this rule into `~/.claude/CLAUDE.md`, `AGENTS.md`, or your editor's global instructions (works on both your Mac and connected SSH servers):

```markdown
## Visual Delivery (`peek`)

Whenever you generate screenshots, UI comparisons, charts, PDFs, or Markdown/HTML reports for me to inspect, push them to a floating card with `peek`:

- Run `peek -t "Short Title" <file…>` (on remote SSH hosts where `~/.local/bin` is not in `PATH`, run `~/.local/bin/peek -t "Short Title" <file…>`).
- Pass related images (such as before/after UI diffs or variants) in a single `peek` command to browse them together with thumbnails; press `⌘D` for side-by-side comparison.
- Keep CSS, JS, and images referenced by Markdown or HTML as relative paths inside the same folder—`peek` snapshots them with the card automatically, so overwriting files later will not affect earlier cards.
- Never run `open` or `qlmanage -p` on preview files (it steals window focus), and never leave bare file paths without pushing them via `peek`.
```

## 3. Agent Command Reference

```sh
# Push a Markdown or HTML report (relative images, CSS, and JS are bundled automatically)
peek -t "Auth Latency Audit" report.md

# Push before/after screenshots together; browse thumbnails or press ⌘D to compare
peek -t "Checkout Header Diff" before.png after.png

# Explicitly label a subagent or background task in the card header
peek -c "UI Subagent" -t "Dark Mode Check" settings-dark.png

# Remote SSH agent when multiple Macs are connected to the same host (omit --to when only one Mac is connected)
~/.local/bin/peek -t "Eval Report" --to "<target-uuid>" report.html
```

- **Supported formats** — Images (`png`, `jpg`, `webp`, `gif`, `svg`, `heic`, `avif`, `tiff`, `bmp`), `pdf`, `md` (GitHub Flavored Markdown), and `html` (sandboxed `WKWebView`; external web links open in the default browser).
- **Flexible flags** — Short (`-t`, `-c`, `-s`) and long (`--title`, `--conversation`, `--source`, `--flag=value`) options work anywhere before `--` on both local macOS `peek` and remote SSH `peek`. When `-t` is omitted, single-file cards use HTML `<title>`, the first Markdown `# ` heading, or the filename.
- **Safe to overwrite output paths** — Local files are cloned instantly on APFS with zero extra disk space; remote pushes bundle up to 300 referenced assets (64 MiB max) and save originals to `~/Downloads/Peek/<host>/<timestamp>_<title>_<id>/`. Agents can reuse fixed paths like `/tmp/check.png` or `build/report.md` across iterations without mutating earlier cards.
- **Multi-agent session attribution & jump-back (`↩`)** — When multiple local agents run in parallel, Peek automatically tags each card with its originating Claude Code session (`/rename` name or first prompt), Rex pane, or terminal app. Cards from local Rex sessions also offer **Jump to Session** (`↩`) to return to the originating Rex session or pane.

<p align="center">
  <img src="docs/screenshots/markdown-viewer.png" alt="Agent-pushed Markdown report rendered with bundled local chart assets" width="840">
</p>

<p align="center">
  <img src="docs/screenshots/image-compare.png" alt="Multi-image card pushed in a single peek command opened in side-by-side comparison mode" width="840">
</p>

## 4. Optional: Auto-Intercept `open` in Claude Code

If an agent or subagent still runs `open screenshot.png`, `open -a Preview …`, or `qlmanage -p …` out of habit, add Peek's [`session-start.sh`](Resources/hooks/session-start.sh) hook to `~/.claude/settings.json`. Supported preview files inside Claude Code Bash sessions are converted into Peek cards automatically, while URLs, folders, `open -R`, and other apps pass straight through to `/usr/bin/open` (set `PEEK_OFF=1` to bypass):

```json
{
  "hooks": {
    "SessionStart": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "/bin/sh -c 'for app in /Applications/Peek.app \"$HOME/Applications/Peek.app\"; do [ -x \"$app/Contents/Resources/hooks/session-start.sh\" ] && exec \"$app/Contents/Resources/hooks/session-start.sh\"; done; exit 0'",
            "timeout": 5
          }
        ]
      }
    ]
  }
}
```

## Manual Usage, Shortcuts & Build Guide

For standalone terminal usage (`--list`, `--clear`, `--quit`), manual SSH commands, card gestures & layout styles, keyboard shortcuts, `defaults` preferences, and building from source, see **[Manual Usage, Shortcuts & Build Guide](docs/manual-usage.md)**.

## License

[MIT License](LICENSE) · [Third-Party Notices](THIRD_PARTY_NOTICES.md)
