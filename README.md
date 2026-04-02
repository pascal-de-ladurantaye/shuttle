# Shuttle

Shuttle is a native macOS terminal workspace app and companion CLI for project-centric development.

Shuttle v1 ships in a focused project-first model:
- auto-discovered projects, each with a default workspace
- a built-in global workspace for scratch sessions
- single-project sessions that open directly in the source checkout, plus global sessions that start in `~`
- live embedded libghostty terminals
- pane/tab layouts with saved presets
- a local control-plane CLI with launch-if-needed live session/pane/tab mutations
- best-effort relaunch restore
- agent-friendly session context, including optional `AGENTS.md` seeding for session roots

For deeper implementation details, see `docs/ARCHITECTURE.md`.
For GhosttyKit dependency and integration notes, see `docs/GHOSTTYKIT_SETUP.md`.

## Requirements

- macOS 14+
- Swift 6+
- Xcode / Command Line Tools
- git
- Ghostty.app installed (optional but recommended for resources and terminfo)

## Quick start

### 1. Install Shuttle into `/Applications`

Because I don't want the hassle to sign and notarize the app for distribution, the recommended workflow is to build from source and install a local copy:

```bash
# install the real app
make ghostty
swift test
make install
sudo ln -sf "/Applications/Shuttle.app/Contents/MacOS/shuttle" /usr/local/bin/shuttle

# install a separate Shuttle Dev.app alongside it if you want to make changes to the sources without impacting your real install yet
make install-dev
```

That install flow:
- builds release binaries with SwiftPM
- assembles the packaged app for the current profile
  - prod: `dist/macos/Shuttle.app`
  - dev: `dist/macos-dev/Shuttle Dev.app`
- copies the app into `/Applications`
  - prod: `/Applications/Shuttle.app`
  - dev: `/Applications/Shuttle Dev.app`
- opens the installed app by default
- bundles the `shuttle` CLI inside the app at `Contents/MacOS/shuttle`, so you can symlink the installed copy into your `PATH` (set `SHUTTLE_PROFILE=dev` when you want that CLI to operate on dev state)
- ad-hoc signs the bundle for local launch/verification

Under the hood, the packaged app flow also:
- copies Shuttle’s shell-integration resources into `Contents/Resources/shell-integration/`
- generates an `.icns` app icon from `Packaging/AppIcon.master.svg`
- auto-embeds Ghostty runtime resources from `/Applications/Ghostty.app` when available, so the packaged app can run without a separate Ghostty install on the destination machine
- creates a profile-specific zip artifact in the matching `dist/` directory

The uninstall script removes the installed app for the current profile and can optionally delete its app data.

Prod app data lives under:
- `~/Library/Application Support/Shuttle`
- `~/.config/shuttle`
- `~/Library/Preferences/com.pascaldeladurantaye.shuttle.plist`
- `~/Library/Saved Application State/com.pascaldeladurantaye.shuttle.savedState`
- `~/Library/Caches/com.pascaldeladurantaye.shuttle`

Dev app data lives under:
- `~/Library/Application Support/Shuttle Dev`
- `~/.config/shuttle-dev`
- `~/Library/Preferences/com.pascaldeladurantaye.shuttle.dev.plist`
- `~/Library/Saved Application State/com.pascaldeladurantaye.shuttle.dev.savedState`
- `~/Library/Caches/com.pascaldeladurantaye.shuttle.dev`

The uninstall flow intentionally does **not** remove session roots under the configured `session_root`.

Useful variants:

```bash
# install to ~/Applications instead of /Applications
make install INSTALL_APPLICATIONS_DIR="$HOME/Applications"
make install-dev INSTALL_APPLICATIONS_DIR="$HOME/Applications"

# install without auto-opening the app
make install OPEN_APP=0
make install-dev OPEN_APP=0

# same via direct script invocation
INSTALL_APPLICATIONS_DIR="$HOME/Applications" OPEN_APP=0 ./scripts/install-macos-app.sh
INSTALL_APPLICATIONS_DIR="$HOME/Applications" OPEN_APP=0 SHUTTLE_PROFILE=dev ./scripts/install-macos-app.sh

# symlink the installed CLI into your PATH
ln -sf /Applications/Shuttle.app/Contents/MacOS/shuttle /usr/local/bin/shuttle

# the CLI profile still comes from the environment
SHUTTLE_PROFILE=dev shuttle config path

# uninstall the installed app; the script will also prompt about deleting app data for that profile
make uninstall
make uninstall-dev

# uninstall from ~/Applications and immediately delete app data without prompting
make uninstall INSTALL_APPLICATIONS_DIR="$HOME/Applications" DELETE_APP_DATA=1
make uninstall-dev INSTALL_APPLICATIONS_DIR="$HOME/Applications" DELETE_APP_DATA=1

# same via direct script invocation
INSTALL_APPLICATIONS_DIR="$HOME/Applications" \
DELETE_APP_DATA=1 \
./scripts/uninstall-macos-app.sh
INSTALL_APPLICATIONS_DIR="$HOME/Applications" \
DELETE_APP_DATA=1 \
SHUTTLE_PROFILE=dev ./scripts/uninstall-macos-app.sh

# package only, without copying into /Applications
make package
make package-dev
open dist/macos/Shuttle.app
open "dist/macos-dev/Shuttle Dev.app"

# package + open the packaged app from dist/ in one step
make open-packaged
make open-packaged-dev

# package without the zip archive
make package CREATE_ZIP=0
make package-dev CREATE_ZIP=0

# skip ad-hoc signing if you only want an unsigned local bundle
make package ADHOC_SIGN=0
make package-dev ADHOC_SIGN=0

# require embedded Ghostty resources instead of falling back to Ghostty.app
make package EMBED_GHOSTTY_RESOURCES=1
make package-dev EMBED_GHOSTTY_RESOURCES=1

# sign + notarize for release
# - auto-detects the Developer ID identity when exactly one is installed
# - requires a notarytool keychain profile created ahead of time
make sign-notarize NOTARY_PROFILE="shuttle-notary"

# if multiple Developer ID Application certs are installed, choose one explicitly
make sign-notarize \
  SIGN_IDENTITY="Developer ID Application: Your Name" \
  NOTARY_PROFILE="shuttle-notary"
```

Release-signing prerequisites:
- a `Developer ID Application: ...` certificate installed in Keychain Access
- a working `xcrun notarytool` keychain profile (for example `shuttle-notary`)
- note: an `Apple Development: ...` certificate is not enough for notarized outside-the-App-Store distribution

The icon generation script uses `rsvg-convert` when available and falls back to ImageMagick `magick`.

## Terminal integration

Every Shuttle-spawned terminal receives context environment variables such as:

```text
SHUTTLE_WORKSPACE_ID    SHUTTLE_PROJECT_ID
SHUTTLE_WORKSPACE_NAME  SHUTTLE_PROJECT_NAME
SHUTTLE_SESSION_ID      SHUTTLE_PROJECT_PATH
SHUTTLE_SESSION_NAME    SHUTTLE_PROJECT_KIND
SHUTTLE_PANE_ID         SHUTTLE_SESSION_ROOT
SHUTTLE_TAB_ID
```

`SHUTTLE_SESSION_ID`, `SHUTTLE_PANE_ID`, and `SHUTTLE_TAB_ID` use Shuttle's scoped handle format (for example `workspace:5/session:3`, `workspace:5/session:3/pane:2`, and `workspace:5/session:3/tab:1`).

When scrollback replay is active during restore, Shuttle also uses an internal replay file environment variable:

```text
SHUTTLE_RESTORE_SCROLLBACK_FILE
```

Shuttle reuses Ghostty's standard config search order and auto-discovers Ghostty resources from `Ghostty.app` when available, so the embedded runtime typically works without extra manual setup once the xcframework has been downloaded.

## CLI commands

Current CLI surface:

```text
help
config path|init|show
project scan|list|show
workspace list|show|open
session list|show|context|open|reopen|new|ensure|rename|close|ensure-closed
layout list|show|apply|ensure-applied|save-current
pane list|show|split|resize
tab list|new|close|send|read|wait
control ping|capabilities|schema|socket-path
try new|new-session
app bootstrap-hint
```

`try new` and `try new-session` are Shuttle-native commands. They do not invoke the real `try` CLI; instead Shuttle reproduces the simple behavior it supports today for new try workspace creation: create a dated directory under `tries_root`, register it as a try project/workspace, and optionally bootstrap the first session there.

Public CLI/session-model handles now use scoped refs for sessions, panes, and tabs (for example `workspace:5/session:3`, `workspace:5/session:3/pane:2`, and `workspace:5/session:3/tab:1`), while raw refs like `session:12` are still accepted for compatibility. Workspace/session/pane/tab/layout mutations now prefer the app-owned local control socket when the app is running, with live open/runtime flows auto-launching Shuttle.app when needed; `SHUTTLE_APP_PATH` can override which `.app` bundle launch-if-needed targets. `--json` now emits a versioned snake_case success/error envelope (`schema_version`, `ok`, `type`, `data`, `error`) for machine-readable automation, `shuttle --help --json` / `shuttle control schema --json` expose the CLI schema, and runtime automation now returns cursor tokens so `tab read|wait --after-cursor <token>` can capture incremental output. For runtime automation, `tab send` inserts text by default; add `--submit` to press Return after inserting it.

## Documentation

- `README.md` — product overview, setup, packaging, and day-to-day usage
- `docs/ARCHITECTURE.md` — living implementation architecture, invariants, and current gaps
- `docs/GHOSTTYKIT_SETUP.md` — GhosttyKit dependency, integration, and upgrade notes

## Current implementation snapshot

### Foundation
Implemented today:
- Swift package with three targets:
  - `ShuttleKit` shared domain/config/persistence/runtime support
  - `shuttle` CLI
  - `ShuttleApp` native SwiftUI macOS app
- packaging scripts that assemble a Finder-launchable `Shuttle.app`, bundle the `shuttle` CLI at `Contents/MacOS/shuttle` for easy PATH symlinking, generate `Info.plist` + app icon, and produce a zipped release artifact from SwiftPM build output
- profile-specific JSON config bootstrap/loading (prod: `~/.config/shuttle/config.json`, dev: `~/.config/shuttle-dev/config.json`)
- profile-specific SQLite-backed persistence (prod: `~/Library/Application Support/Shuttle/state.sqlite`, dev: `~/Library/Application Support/Shuttle Dev/state.sqlite`)
- a profile-scoped Unix-socket control plane that the CLI prefers for live session/pane/tab inspection and mutation, with launch-if-needed for the mutating flows
- typed models for projects, workspaces, sessions, session projects, panes, and tabs, with scoped public refs for sessions/panes/tabs while raw SQLite IDs stay internal
- on-demand project discovery from configured roots with ignore globs and try-project classification
- automatic default workspace creation for every discovered project
- a built-in global workspace for scratch sessions that are not linked to any project

### Project and workspace management
Implemented today:
- project scan/list/show in the CLI
- automatic `normal` vs `try` classification
- git vs non-git detection plus default-branch detection
- automatic default workspace creation for every discovered project
- rescans prune default project workspaces whose source directories no longer exist on disk
- a built-in global workspace that is always available for scratch or setup sessions
- a simplified workspace model: workspaces are either the built-in global workspace or the internal per-project wrapper used to scope sessions, selection state, and public IDs
- `workspace list`, `workspace show`, and `workspace open` for inspecting or focusing those workspaces

### Session lifecycle
Implemented today:
- session creation from any default project workspace or from the built-in global workspace, with unique display names and slugs
- session roots created under a profile-specific default root (`~/Workspaces/<workspace-slug>/<session-slug>/` for prod, `~/Workspaces-Dev/<workspace-slug>/<session-slug>/` for dev)
- project-backed session creation uses the selected project directly from its source path
- global session creation starts new tabs in `~` and does not attach a project to the session
- Shuttle still creates a session root for metadata, restore state, and optional session-root guides
- creating a session does not create a Shuttle-managed symlink or worktree by default
- new project-backed sessions start directly in their lone source checkout
- `try new` and `try new-session` flows for simple try-project creation and first-session bootstrap; these are Shuttle-native flows, not wrappers around the real `try` CLI
- optional root-level `AGENTS.md` seeding for app-created sessions so agents can discover the active checkout and any project-specific guidance files

### Native app experience
Implemented today:
- SwiftUI app shell with a combined left navigator composed of:
  - a workspace column
  - a session column for the selected workspace
- workspace sidebar grouping:
  - `Global`
  - `Pinned`
  - `Recent`
  - searchable `Discovered Workspaces`
  - `Project Workspaces` grouped by configured project root when multiple roots are present
  - `Try Workspaces`
- discovered-workspace filtering scoped to `Project Workspaces` and `Try Workspaces`, plus session/project filtering in the session column
- session sidebar sections:
  - `Active`
  - `Recent`
  - collapsible `Restorable & Closed`
- context menus for workspaces, sessions, and projects
- richer native sheets for:
  - `New Session…`
  - `New Try Session…`
  - `Rename Session…`
  - `Delete Session…`
- session info popover showing workspace, layout, root, restore state, and checkout information
- top-right toast notifications for success/info/error states, including a rescan card when Shuttle removes workspaces whose source directories disappeared from disk, with per-toast dismissal and overflow summarization instead of the old bottom status strip
- a Settings window with tabs for:
  - General
  - Paths
  - Layouts
  - Advanced
- a dedicated Layout Builder window for editing custom layout presets
- stable main-window frame restoration across relaunches, with AppKit’s native window tabbing disabled so Shuttle only exposes its own pane/tab model

### Terminal, panes, and tabs
Implemented today:
- live embedded libghostty terminals via `GhosttyKit.xcframework`
- one persistent Ghostty runtime surface per Shuttle tab
- Ghostty config/theme/font/color reuse from Ghostty’s standard config search order (`config.ghostty` plus legacy `config` in macOS-specific and XDG locations)
- automatic `GHOSTTY_RESOURCES_DIR` and `TERMINFO` discovery from Ghostty.app when available
- focus-aware terminal embedding with persistent runtimes across SwiftUI view refreshes
- real persisted pane trees:
  - split right with `⌘D`
  - split down with `⇧⌘D`
  - draggable split dividers with persisted ratios
- real per-pane tab strips:
  - `⌘T` creates a new tab in the focused pane
  - `⌘W` closes the focused tab
  - add-tab button in every pane tab bar
  - live tab titles from terminal state
- tab/pane behavior:
  - closing the last tab in a non-final pane collapses that pane and simplifies the tree
  - closing the final tab in a session leaves an empty pane that can be reopened with a new tab
  - fallback tabs reopen at the lone checkout for a project-backed session or in `~` for a global session
- inactive-pane dimming and focused-tab/focused-pane tracking
- shell integration helpers for more reliable cwd/title checkpointing

### Restore and checkpointing
Implemented today:
- app launch marks previously active sessions as `restorable`
- Shuttle persists a versioned selected-session snapshot to a profile-specific Application Support location (`~/Library/Application Support/Shuttle/session-snapshot.json` for prod, `~/Library/Application Support/Shuttle Dev/session-snapshot.json` for dev)
- selected session restore includes:
  - workspace/session selection
  - pane tree
  - per-pane active tab selection
  - last focused tab
  - tab titles
  - checkpointed working directories
- per-tab checkpointing of title/cwd plus persisted scrollback files under Application Support
- best-effort scrollback restore with:
  - line/size retention limits
  - ANSI-safe truncation
  - replay through one-shot temp files
  - explicit restored-shell boundary messaging
- metadata-only autosave of restore state every 10 seconds while the app is running
- scrollback capture on prompt return plus lifecycle boundaries (backgrounding/termination), rather than on every autosave tick

### Session deletion and cleanup
Implemented today:
- a real `Delete Session…` flow in the app
- deletion previews for the session-local checkout Shuttle created under the session root
- session projects keep their source checkouts on disk
- cleanup behavior:
  - Shuttle removes session-root metadata and restore/checkpoint artifacts without touching the source checkout

### Layout presets
Implemented today:
- built-in presets:
  - `single`
  - `dev`
  - `agent`
- custom layout preset storage in a profile-specific Application Support layouts directory (`~/Library/Application Support/Shuttle/layouts/` for prod, `~/Library/Application Support/Shuttle Dev/layouts/` for dev)
- preset selection during app-driven session creation and try-session creation
- layout defaults for normal sessions and try sessions via app preferences
- layout builder support for custom presets:
  - duplicate built-ins to edit them
  - rename custom presets
  - edit description
  - split panes side-by-side or stacked
  - adjust split ratios
  - change tab counts
  - edit tab titles
  - edit per-tab startup commands (sent to the shell after the tab launches, so the real interactive PATH/init is available)

### Validation
Current automated coverage includes:
- discovery/default workspace creation
- concurrent store initialization without SQLite lock regressions
- control-socket ping round-trips plus command-service session/pane/tab mutations from scoped handles
- scoped session/pane/tab identifier generation
- unsupported single-project-mode guards for removed workspace/session-project mutation features
- try creation flows
- direct-source session creation and session-root guide seeding
- layout preset storage and application
- pane splitting/resizing
- tab create/close/collapse behavior
- session snapshot round-tripping
- relaunch restore and replay environment creation
- session deletion preview/cleanup flows

`swift test` currently passes locally.

## Still missing

Not implemented yet:
- external layout file import/validation for CLI-driven session creation
- broader restore across multiple windows/sessions beyond the selected session snapshot
- detached terminal execution after the app quits
- external notifications/agent hooks beyond the current in-app toast notifications, `AGENTS.md` seeding, and context env vars