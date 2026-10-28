# Developing dockduo

Notes for building, testing and releasing dockduo (a fork of Siigil, keeping only its side bar). The README is for people who use the app; working documents (specs,
plans, the roadmap) live in the private `siigil-docs` repository.

## Requirements

- macOS 26 and Xcode with Swift 6.2 or later (the package's tools version; developed with Xcode 27 and Swift 6.4); the
  package uses language mode 5.
- An Apple Development certificate in your keychain (Xcode creates one with your Apple ID; `make` finds it by itself).
  Without one the build is signed ad-hoc: macOS then ties permissions to the binary's hash, so Location must be
  granted again after every `make install` or update (remove dockduo from the list and add it back).
- AeroSpace (`brew install --cask nikitabobko/tap/aerospace`).

## Build and run

    make run        # build, assemble .build/dockduo.app and launch it (development)
    make cpu        # like run, then print the bar's average CPU at rest
    make test       # swift test; make release runs it before tagging
    make install    # copy to ~/Applications and launch (it registers itself as a login item)
    make uninstall  # remove the app
    make dist       # .build/dockduo-<version>.zip, for scripts
    make dmg        # .build/dockduo-<version>.dmg, for people (drag-to-Applications window)
    make release    # tests, zip and DMG, tag v<version>, GitHub release
    pkill -x dockduo

`swift build` alone does not update `.build/dockduo.app`: use `make run` to try a change. After `make run` the development
build is running; at the next login the last `make install` starts again (System Settings › General › Login Items).

Errors (discarded hooks, CLI timeouts, …) go to the unified log, not to stderr:
`/usr/bin/log stream --predicate 'subsystem == "com.dockduo.app"'` (full path: in zsh `log` is a builtin), or Console.app.

## Layout

One SwiftPM executable target, `Dockduo`, and one test target, `DockduoTests`.

| Area | Files |
|---|---|
| App, panels, the bar | `main.swift`, `SidePanel.swift`, `SideLayout.swift`, `BarState.swift`, `AerospaceGaps.swift`, `Views/SideBarView.swift`, `Views/SideRearrange.swift`, `Views/SideLabels.swift`, `Views/Pills.swift`, `Views/WorkspacePill.swift`, `Views/IconDrag.swift` |
| Refresh loop, AeroSpace | `Poller.swift`, `Aerospace.swift`, `Model.swift`, `Apps.swift`, `WindowEvents.swift` |
| Widgets | `Views/Widgets.swift`, `System.swift`, `WiFi.swift`, `NowPlaying.swift`, `ClockApp.swift` |
| AI agents and limits | `AgentServer.swift`, `Integrations.swift`, `Usage.swift`, `QuotaCache.swift`, `Resources/dockduo-hook` |
| Agent sounds | `Sounds.swift` |
| Edit mode and the section gallery | `Editing.swift`, `GalleryPanel.swift`, `Views/GalleryView.swift`, `Views/SectionCatalog.swift`, `Views/SectionMenu.swift`, `Views/EditBadge.swift` |
| Settings and Welcome | `Settings.swift`, `SettingsMenu.swift`, `AppDelegate.swift`, `Theme.swift`, `Setup.swift`, `Views/WelcomeView.swift` |
| Updates | `Updater.swift` |

Code comments are in Italian.

## Settings storage

Everything is in `defaults read com.dockduo.app`, keys `dockduo.*`; deleting them restores the defaults. The bar is
`dockduo.docks`: the Docks top to bottom, each with its zone and its sections (widget ids). A section is on when it is in a
Dock. `dockduo.mascots` (from the versions with mascots) is read once, for the first agent sound settings.

## Languages

English text is the localization key itself, written in the code (`String(localized:)`, `Text("…")`): there is no English
strings file. Italian lives in `Resources/it.lproj/Localizable.strings`; add every new key there (`plutil -lint` after
editing). `Credits.rtf` exists in both `en.lproj` and `it.lproj`. Dates and times follow the locale.

## AeroSpace

dockduo talks to AeroSpace over its documented socket (`/tmp/bobko.aerospace-$USER.sock`, AeroSpace 0.21 and later): one
connection for requests, one subscribed to events (focus, workspace, monitor, new window, binding). The bar refreshes on
every event, when an app quits and when the mouse is released, plus a check every 60 seconds; `~/.aerospace.toml` needs
nothing for dockduo. With AeroSpace older than 0.21 it uses the CLI every 5 seconds; without AeroSpace it shows the open
apps in a single pill.

The bar writes only `gaps.outer.left` and `gaps.outer.right` in the config AeroSpace loaded (bar side: base + edge
margin + width; other side: base = `gaps.outer.bottom`), saving the lines it replaces the first time and putting them
back when you quit from the menu; a launch after a crash writes them again without saving. `gaps.outer.top` is only
read, never written: the bar starts where the windows start (the visible area plus that gap, constant or per monitor
`[{ monitor."built-in" = 5 }, 43]`), never above the menu bar strip.

## Agents

Agent sessions report their state to a per-user Unix socket, `/tmp/dockduo-<uid>.sock`, one JSON line per event:

    {"agent": "claude" | "codex", "state": "working" | "waiting" | "done" | "end", "bundle": "<host app bundle id>",
     "payload": {"session_id": "…", "cwd": "…", …}}

`end` removes the session. `Resources/dockduo-hook <state>` builds the line from the hook's stdin and sends it with `nc`;
it never prints anything and always exits 0, and it only writes to a socket owned by the current user. The bundle is the
app hosting the terminal (`__CFBundleIdentifier`), or `$DOCKDUO_BUNDLE`.

**Claude Code** — Settings › AI Agents › Connect writes this block into `~/.claude/settings.json`, with the path of the app as
installed (here `~/Applications`), merged with your hooks, backup in `settings.json.bak`; "Update Connection" if the app moved:

```json
"hooks": {
  "UserPromptSubmit": [{"hooks": [{"type": "command", "command": "$HOME/Applications/dockduo.app/Contents/Resources/dockduo-hook working"}]}],
  "PreToolUse":       [{"hooks": [{"type": "command", "command": "$HOME/Applications/dockduo.app/Contents/Resources/dockduo-hook working"}]}],
  "PostToolUse":      [{"hooks": [{"type": "command", "command": "$HOME/Applications/dockduo.app/Contents/Resources/dockduo-hook working"}]}],
  "PermissionRequest":[{"hooks": [{"type": "command", "command": "$HOME/Applications/dockduo.app/Contents/Resources/dockduo-hook waiting"}]}],
  "Notification":     [{"matcher": "permission_prompt|idle_prompt|elicitation_dialog", "hooks": [{"type": "command", "command": "$HOME/Applications/dockduo.app/Contents/Resources/dockduo-hook waiting"}]}],
  "Elicitation":      [{"hooks": [{"type": "command", "command": "$HOME/Applications/dockduo.app/Contents/Resources/dockduo-hook waiting"}]}],
  "StopFailure":      [{"hooks": [{"type": "command", "command": "$HOME/Applications/dockduo.app/Contents/Resources/dockduo-hook waiting"}]}],
  "Stop":             [{"hooks": [{"type": "command", "command": "$HOME/Applications/dockduo.app/Contents/Resources/dockduo-hook done"}]}],
  "SessionEnd":       [{"hooks": [{"type": "command", "command": "$HOME/Applications/dockduo.app/Contents/Resources/dockduo-hook end"}]}]
}
```

`Elicitation` (a question from an MCP server) and `StopFailure` (a turn that ended in an error) are `waiting`: the agent
has stopped and it's your turn. `idle_prompt` (Claude idle for a minute) is not a wait: it only ends a session that is still
`working`, a turn interrupted with Esc that sent no `Stop`, silently. `PostToolUse` sends `working` again after an approved permission. It works in the
terminal and in the VS Code extension. With several windows of the same app, dockduo picks the one whose title contains
the working directory's name; otherwise the ring goes on that app's icon in every workspace.

**Codex** (the ChatGPT app's Work section and the CLI) — the same script in `~/.codex/hooks.json`, with
`DOCKDUO_AGENT=codex DOCKDUO_BUNDLE=com.openai.codex` in front, on `UserPromptSubmit`, `PreToolUse`, `PostToolUse`
(`working`), `PermissionRequest` (`waiting`), `Stop` (`done`), `SessionEnd` and `Interrupt` (`end`). Codex doesn't run a new
hook until you approve it once (`codex` → `/hooks` → Trust), and the app reads it only after a restart; Settings › AI
Agents has items for both. ChatGPT's Chat runs on OpenAI's servers and can't be followed.

**Usage limits** — Claude: the usage and profile endpoints of `api.anthropic.com/api/oauth`, with the token Claude Code keeps
in the Keychain (`Claude Code-credentials`, read with `/usr/bin/security`, so there is no password prompt). ChatGPT:
`chatgpt.com/backend-api/wham/usage` with the token in `~/.codex/auth.json`. Both endpoints are undocumented: if they
change, the menu says "Not available". They are read at launch and then every 5 minutes by default (5, 10, 15 or 30 in
Settings › AI Agents › Refresh limits every), for the accounts that have credentials on this Mac. "Session renewed" appears on the apps of
that agent for 30 s when an exhausted 5-hour window (≥ 95 %) resets.

## Network

Every outbound connection: the usage limits above (`api.anthropic.com`, `chatgpt.com`); the update check and download
(`api.github.com`, the release zip on GitHub, `Updater.swift`); the public IP shown in the Wi-Fi menu (`api.ipify.org`, on
opening the menu, remembered 5 minutes per network, `WiFi.swift`); Spotify's album artwork (the URL Spotify gives over
AppleScript, `NowPlaying.swift`). Keep this list up to date.

## Sounds

The two agent sounds (waits for you, done) are synthesized by the app the first time they're needed, in one voice; there
are no audio files. At most one sound every 5 s, only with Agent Sounds on in Settings › Sounds. Outside the app bundle (in
tests) sounds are always silent.

## Tests and image generators

    swift test

Some tests only write images, when an environment variable asks for them:

    GALLERY_SHOTS=<dir> swift test --filter galleryShots       # the section gallery, light and dark
    EDIT_SHOTS=<dir> swift test --filter editShots             # the Dock in edit mode, light and dark

## Releasing

1. Raise `CFBundleShortVersionString` in `Resources/Info.plist`.
2. Commit on `main`; the subject of this commit becomes the release notes.
3. `make release`: runs the tests, builds, tags `v<version>`, pushes the tag and publishes the release with the zip and
   the DMG on `p-diego/dockduo`, the notes being the commit subject; installed apps update from there. It stops on
   uncommitted changes, an existing tag or an ad-hoc signature (an ad-hoc release couldn't update itself).

For scripts, the zip without quarantine:

    gh release download -R p-diego/dockduo -p 'dockduo-*.zip'
    unzip dockduo-*.zip && xattr -dr com.apple.quarantine dockduo.app
    mv dockduo.app ~/Applications/ && open ~/Applications/dockduo.app

## Licenses

`LICENSE` is copied into the app as `Licenses/dockduo.txt`. The credits shown in dockduo › About dockduo are `Credits.rtf`; the copyright line comes from
`NSHumanReadableCopyright` in `Info.plist`.
