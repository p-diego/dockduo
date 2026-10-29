# dockduo

dockduo is a bar at the left or right edge of the screen, like the side strip of the iPhone Duo, or at the bottom like
the macOS Dock: your AeroSpace workspaces, a Dock of the open apps with their badges, widgets (Wi-Fi, battery, now
playing, clock…) and the state of your AI agents (Claude Code, Codex) on their apps. It runs next to
[Siigil](https://github.com/p-diego/siigil) without overlapping it.

dockduo is a fork of Siigil: it keeps only the side bar.

Settings › and the separator line's menu choose the edge (Left, Bottom, Right) and the size. The edge where the macOS
Dock sits is greyed out, with an item that moves the macOS Dock to a free edge. A new bar starts at the size of the
macOS Dock.

## Requirements

- macOS 26 or later.
- [AeroSpace](https://github.com/nikitabobko/AeroSpace) (`brew install --cask nikitabobko/tap/aerospace`) is
  recommended. dockduo widens only the outer gap on the bar's edge (`gaps.outer.left`, `.right` or `.bottom`) by the
  bar's size, on top of your own values (per-monitor values included), and puts them back when you quit it.
  Without AeroSpace, or when AeroSpace has no config file of its own or its gaps are in a form dockduo can't edit,
  nothing reserves room for the bar: it hides at the edge and slides out when you point there, and the menu says why.
  "Create AeroSpace Config" copies AeroSpace's default config to `~/.aerospace.toml` when there is none.

## Install

Download the DMG from [Releases](https://github.com/p-diego/dockduo/releases/latest) and drag dockduo to Applications.
It isn't notarized: the first time macOS blocks it, open it from System Settings › Privacy & Security › Open Anyway.

## Build and install

    make install

builds the app, copies it to `~/Applications` and launches it. See [DEVELOPMENT.md](DEVELOPMENT.md) for the other targets.

## Updates

dockduo checks for a new release once a day. When there is one, Settings shows "Update to …": it downloads the
release, checks that it is signed like the running copy, replaces itself and relaunches. Only a copy in Applications
updates itself.

## License

MIT, see [LICENSE](LICENSE).
