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

Agents can manage connections without opening a settings window:

```sh
peek remote add user@server --name "Build server" --wait --json
peek remote list --json
peek remote command "Build server"
peek remote disconnect "Build server"
peek remote connect "Build server" --wait
peek remote remove "Build server"
```

Run these on the receiving Mac. Select a host by name, SSH address, or connection ID. `--wait` waits for installation and connection; `--timeout <seconds>` sets a limit (default 60, maximum 300). JSON errors return a nonzero exit status. The `command` subcommand prints the remote sender command with the current Mac's target UUID.

To connect manually:

1. Open the Peek menu bar icon → **Remote Machines…** (*远程机器…*), or run `peek --remote-settings`.
2. Enter an SSH alias, `user@host`, or `user@host:port` and click **Connect**. Unknown host fingerprints and passwords use native macOS verification dialogs; passwords are never stored.
3. Click **Copy Command**, paste it on the remote machine, and append file paths:

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
- Received originals are saved to `~/Downloads/Peek/<host>/<timestamp>_<title>_<id>/`; card snapshots follow the 24-hour cache lifecycle while Downloads copies are kept.
- Extended Chinese reference: [local-usage.md](local-usage.md) · [remote-forwarding.md](remote-forwarding.md).

## Cards & Viewer Interactions

- **Card gestures** — Click to open the first file · `⌥`-Click to reveal in Finder · Drag files directly off a card into other apps · Two-finger swipe right to dismiss · Right-click for context actions (*Open, Reveal in Finder, Copy, Tuck, Close*). Cards from local Rex sessions also offer *Jump to Session*.
- **Styles & layout** — Choose between *Rich* (`大图`), *Compact* (`简洁`), and *Photo* (`照片`) card styles, and toggle **Stacked Deck** vs **Vertical List** from the menu bar.
- **Tuck away** — Collapse the card stack into a right-edge handle that peeks out on hover.
- **Lifecycle** — Unread cards are marked with an accent dot. If the newest unread card stays unopened for 5 minutes, the stack tucks into the right-edge handle. Hover over the handle to see the cards again. Viewed cards auto-dismiss after 5 minutes of inactivity. Up to 3 cards show at once with extras queued. Snapshots in `~/Library/Caches/Peek/` are cleaned up after 24 hours.
- **Viewer** — Double-click an image to toggle between fit and actual pixels. On a trackpad, spread or pinch two fingers to zoom continuously. Double-tap with two fingers to zoom at the pointer, then double-tap again to fit the whole image. Use `⌘±` to zoom, the scroll wheel or a two-finger horizontal swipe to cycle files, and `⌘D` for side-by-side comparison. In wide windows, swipe up with two fingers over the preview to go to the next file, or down to go back. For long documents, scroll to the corresponding edge before swiping again. Scroll the sidebar to browse thumbnails. Click a thumbnail or comparison image to view that file. `⌘C` shows a brief confirmation after copying. External web links in Markdown/HTML open in your default browser.

## Keyboard Shortcuts

Global shortcuts use Carbon hotkeys and require no Accessibility permission:

| Shortcut | Scope | Action |
| --- | --- | --- |
| `⌥⌘P` | Global | Open the newest card in the viewer |
| `⌥4` | Global | Open the six most recent Peeks. Press again in the overview to close it |
| Arrow keys / `↩` / `Esc` | Recent Peeks | Select a card / open its preview / close the overview. Unread cards are marked until opened |
| `⌘W` | Recent Peeks | Close the overview and dismiss all floating cards. History and unread status are preserved |
| `⌃⌥H` | Global | Tuck or restore card stack |
| `⌃⌥X` | Global | Dismiss all cards |
| `⎋` / `Space` | Viewer | Close the detail. Previews opened from Recent Peeks return to the overview with the same card selected |
| `⌘W` / `⌘⌫` | Viewer | Close viewer and dismiss the current card |
| `←` `→` / Swipe | Viewer | Previous / next file in card |
| `↑` `↓` | Viewer | Previous / next file (card for single-file items) |
| `⌥↑` `⌥↓` | Viewer | Previous / next card |
| `⌘D` | Viewer | Toggle side-by-side comparison |
| `⌘0` / `⌘1` / `⌘±` | Viewer | Fit to window / 1:1 pixels / zoom |
| `⌘` + mouse wheel | Image, PDF, Markdown, HTML | Zoom in or out at the pointer |
| `⌘C` / `⌘R` / `↩` | Viewer | Copy / reveal in Finder / jump to the originating local Rex session |
| `?` | Viewer | Toggle shortcut cheat sheet |

The default is **Always Open Overview**. To open a single unread card directly, choose **Recent Cards Shortcut → Open the Only Unread Card** in the Peek menu. If none or several of the six recent cards are unread, the shortcut opens the overview. The **Recent Peeks** menu item always opens the overview.

## Preferences (`defaults`)

```sh
defaults write com.terryops.peek hotkeyOpen "opt+cmd+p"    # "" disables a global shortcut
defaults write com.terryops.peek hotkeyRecent "opt+4"
defaults write com.terryops.peek recentShortcutBehavior overview    # overview | singleUnread
defaults write com.terryops.peek hotkeyTuck "ctrl+opt+h"
defaults write com.terryops.peek hotkeyCloseAll "ctrl+opt+x"
defaults write com.terryops.peek lingerSeconds -float 300
defaults write com.terryops.peek maxCards -int 3
defaults write com.terryops.peek style rich                # rich | compact | photo
defaults write com.terryops.peek stacking deck             # deck | list
defaults write com.terryops.peek language en               # zh | en (defaults to macOS language)
```

## Build from Source & Test

Requires macOS 14+, Swift 6.0+ (Xcode), and Go 1.24+ (cross-compiles the dependency-free `peek-remote` helper for `darwin` & `linux` on `amd64` & `arm64`).

```sh
./Scripts/install.sh                        # build, self-test, install ~/Applications/Peek.app + LaunchAgent + ~/bin/peek
./Scripts/install.sh --prebuilt /path/Peek.app
./Scripts/build.sh                          # build build/Peek.app only
PEEK_UNIVERSAL=1 ./Scripts/build.sh         # build arm64 + x86_64 universal Mac binary
PEEK_HOME="$(mktemp -d)" swift test
(cd Remote && go test -race ./... && go vet ./...)
```
