# dockduo

dockduo is a vertical bar at the left or right edge of the screen, like the side strip of the iPhone Duo: your
AeroSpace workspaces, a Dock of the open apps with their badges, widgets (Wi-Fi, battery, now playing,
clock…) and the state of your AI agents (Claude Code, Codex) on their apps. It runs next to
[Siigil](https://github.com/p-diego/siigil) without overlapping it.

dockduo is a fork of Siigil: it keeps only the side bar.

## Requirements

- macOS 26 or later.
- [AeroSpace](https://github.com/nikitabobko/AeroSpace) (`brew install --cask nikitabobko/tap/aerospace`). dockduo
  rewrites only `gaps.outer.left` and `gaps.outer.right` in the AeroSpace config, to make room for the bar, and puts
  them back when you quit it.

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
