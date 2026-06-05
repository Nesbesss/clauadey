# Claudey

A tiny macOS menubar launcher for [Claude Code](https://claude.com/claude-code).
Click the icon — a terminal opens, already running `claude`.

**[Landing page →](https://nesbesss.github.io/clauadey/)**

## Features

- **Left-click** → new Terminal window running `claude` in your home folder.
- **Right-click** → open any folder, recent projects, resume a past session, or settings.
- **Spaces** → spawn 2+ terminals and they group into one glassy Claudey window, tiled in a grid.
- **Resume** → reopen any past Claude Code session in its original folder.
- **Custom icon** → pick a built-in preset or any image (animated GIFs animate, in the menubar *and* the Dock).
- **Caveman** → optionally auto-installs the [Caveman](https://github.com/JuliusBrussee/caveman) plugin on first launch.

## Install

1. Download `Claudey.dmg`, drag **Claudey** to **Applications**.
2. First launch is blocked by Gatekeeper (signed, not notarized). Clear it once:
   - Right-click `Claudey.app` → **Open** → **Open**, or:
     ```bash
     xattr -dr com.apple.quarantine /Applications/Claudey.app
     ```
3. On first click, approve **"Claudey wants to control Terminal"**.

Requires macOS 13+ and `claude` on your shell `PATH`.

## Build

```bash
./build.sh      # SwiftPM build + assemble + sign Claudey.app
./package.sh    # build + make ~/Downloads/Claudey.dmg
```

Needs Xcode (Swift 5.9+). First build pulls [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm)
(used for the in-app terminal panes).

## How it works

- Menubar item via `NSStatusItem`; no Dock icon until a space window opens.
- Single terminal → drives **Terminal.app** over AppleScript.
- Multiple → a Swift window of **SwiftTerm** panes, each a real PTY running `claude`.
- Folder paths are shell-quoted and AppleScript-escaped (command injection blocked).
- No network, no telemetry. Hardened runtime; only entitlement is Apple Events (to control Terminal).

## License

MIT
