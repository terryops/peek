# Manual Usage, Shortcuts & Build Guide

English · [简体中文](manual-usage.zh-CN.md) · [Back to README](../README.md)

Peek also works standalone from any terminal or SSH session without an AI agent.

## Local CLI

Make sure `peek` is linked onto your `PATH`:

```sh
mkdir -p "$HOME/bin"
ln -sfn "/Applications/Peek.app/Contents/MacOS/Peek" "$HOME/bin/peek"
```

Push local images (`png`, `jpg`, `webp`, `gif`, `heic`, `svg`, `avif`, `tiff`, `bmp`), PDFs, Markdown, or HTML files:

```sh
peek screenshot.png
peek report.pdf
peek report.md
peek page.html
peek -t "Design diff" before.png after.png    # multiple files become one card
peek -c "Project" -t "Check" report.html      # custom header label and card title
```

When `-t` is omitted, single-file cards use `<title>` for HTML, the first `# ` heading for Markdown, or the filename. Relative CSS, JS, and images inside the document's folder are copied alongside the snapshot so later edits or overwrites never alter existing cards.

Manage active cards and the background app:

```sh
peek --remote-settings   # open the Remote Machines window
peek --list              # list cards from the last 24 hours
peek --clear             # remove all cards and cached snapshots
peek --quit              # quit the background menu bar app
```

## Remote over SSH

Push files from remote Linux or macOS machines (`amd64` / `arm64`) over your existing `/usr/bin/ssh` configuration (`~/.ssh/config`, keys, SSH agent, JumpHosts) with no relay service or inbound ports on your Mac:

1. Open the Peek menu bar icon → **远程机器…** (*Remote Machines*), or run `peek --remote-settings`.
2. Enter an SSH alias or `user@host` and click **连接** (*Connect*). Unknown host fingerprints and passwords use native macOS verification dialogs; passwords are never stored.
3. Click **拷贝命令** (*Copy Command*), paste it on the remote machine, and append file paths:

```sh
'/home/me/.local/bin/peek' --to '<target-uuid>' report.html chart.png
```

Additional remote commands:

```sh
peek -t 'Check Results' -c 'Service A' report.html screenshot.png
peek --list-targets
peek --to <target-uuid> report.md
PEEK_TARGET=<target-uuid> peek report.pdf
```

- `--to` can be omitted when only one Mac is connected to that remote host; when multiple Macs connect to the same host, select the target UUID or unique name explicitly.
- Referenced local HTML/Markdown assets transfer automatically (up to 300 files / 64 MiB total per push; symlinks never escape the document root).
- Received originals are saved to `~/Downloads/Peek/<host>/<request-uuid>/`; card snapshots follow the 24-hour cache lifecycle while Downloads copies are kept.
- Extended Chinese reference: [local-usage.md](local-usage.md) · [remote-forwarding.md](remote-forwarding.md).

## Cards & Viewer Interactions

- **Card gestures** — Click to open · `⌥`-Click to reveal in Finder · Drag files directly off a card into other apps · Two-finger swipe right to dismiss · Right-click for context actions (*Open, Back to Conversation, Reveal in Finder, Copy, Tuck, Close*).
- **Styles & layout** — Choose between *Rich* (`大图`), *Compact* (`简洁`), and *Photo* (`照片`) card styles, and toggle **Stacked Deck** vs **Vertical List** from the menu bar.
- **Tuck away** — Collapse the card stack into a right-edge handle that peeks out on hover.
- **Lifecycle** — Unread cards stay visible (marked with an accent dot); viewed cards auto-dismiss after 5 minutes of inactivity. Up to 3 cards show at once with extras queued. Snapshots in `~/Library/Caches/Peek/` are cleaned up after 24 hours.
- **Viewer** — Double-click images to toggle Fit ↔ 1:1 pixels, pinch or `⌘±` to zoom, scroll wheel or two-finger horizontal swipe to cycle files, and `⌘D` for side-by-side image comparison (enabled by default when opening multiple images on an external display). External web links in Markdown/HTML open in your default browser.

## Keyboard Shortcuts

Global shortcuts use Carbon hotkeys and require no Accessibility permission:

| Shortcut | Scope | Action |
| --- | --- | --- |
| `⌃⌥P` | Global | Open or close newest card |
| `⌃⌥H` | Global | Tuck or restore card stack |
| `⌃⌥X` | Global | Dismiss all cards |
| `⎋` / `Space` | Viewer | Close viewer (keep card) |
| `⌘W` / `⌘⌫` | Viewer | Close viewer and dismiss card |
| `←` `→` / Swipe | Viewer | Previous / next file in card |
| `↑` `↓` | Viewer | Previous / next card |
| `⌘D` | Viewer | Toggle side-by-side comparison |
| `⌘0` / `⌘1` / `⌘±` | Viewer | Fit to window / 1:1 pixels / zoom |
| `⌘C` / `⌘R` / `↩` | Viewer | Copy / reveal in Finder / back to conversation |
| `?` | Viewer | Toggle shortcut cheat sheet |

## Preferences (`defaults`)

```sh
defaults write com.terryops.peek hotkeyOpen "ctrl+opt+p"   # "" disables a global shortcut
defaults write com.terryops.peek hotkeyTuck "ctrl+opt+h"
defaults write com.terryops.peek hotkeyCloseAll "ctrl+opt+x"
defaults write com.terryops.peek lingerSeconds -float 300
defaults write com.terryops.peek maxCards -int 3
defaults write com.terryops.peek style rich                # rich | compact | photo
defaults write com.terryops.peek stacking deck             # deck | list
```

## Build from Source & Test

Requires macOS 26+, Swift 6.2+ (Xcode), and Go 1.24+ (cross-compiles the dependency-free `peek-remote` helper for `darwin` & `linux` on `amd64` & `arm64`).

```sh
./Scripts/install.sh                        # build, self-test, install ~/Applications/Peek.app + LaunchAgent + ~/bin/peek
./Scripts/install.sh --prebuilt /path/Peek.app
./Scripts/build.sh                          # build build/Peek.app only
PEEK_UNIVERSAL=1 ./Scripts/build.sh         # build arm64 + x86_64 universal Mac binary
PEEK_HOME="$(mktemp -d)" swift test
(cd Remote && go test -race ./... && go vet ./...)
```
