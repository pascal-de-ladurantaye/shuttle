# Shuttle — Current Architecture

Status refresh: 2026-04-01.

This document describes the architecture that ships today.
Together with the repository `README.md`, it is intended to stay current as a living document for the shipped product.

## 1. Architectural summary

Shuttle today is:

- a native macOS app built with SwiftUI and AppKit (`ShuttleApp`)
- a shared domain, persistence, layout, restore, and control-plane library (`ShuttleKit`)
- a companion CLI (`shuttle`)
- backed by profile-scoped SQLite and JSON files
- intentionally simplified to a **project-first** product surface with one built-in global workspace
- using an **app-owned local control plane** for live session, pane, tab, layout, and terminal-runtime commands

The key architectural choice is that Shuttle kept `Workspace` as an internal compatibility layer, while removing the product surfaces that used to treat workspaces as user-managed multi-project containers.

### Current invariants

These invariants drive most of the codebase:

1. Every discovered project gets one default workspace automatically.
2. Shuttle also keeps one built-in global workspace for scratch sessions that are not linked to any project.
3. Sessions are created either inside that built-in global workspace or inside a workspace that resolves to exactly one project.
4. Project-backed session creation opens the project directly from its source path, while global sessions start new tabs in `~`; both still keep a separate session root for Shuttle-managed metadata.
5. Shuttle does **not** manage git worktree promotion or multi-project session mutation in the shipped surface.
6. Pane and tab state is persisted and restored best-effort.
7. Public session, pane, and tab IDs remain workspace-scoped even though workspaces are now mostly an internal wrapper.

### Why `Workspace` still exists

`Workspace` remains important internally even in single-project mode because it still provides:

- the stable parent scope for public IDs like `workspace:5/session:3`
- grouping for session history and sidebar selection
- a durable join point for snapshots, control-plane payloads, and terminal context env vars
- a compatibility layer that avoids rewriting the entire persistence and session model

This is the deliberate "Option A" architecture: simplify the product, not the underlying object graph.

---

## 2. Runtime shape

Shuttle ships as a Swift package with three main targets:

- `ShuttleKit` — shared models, config loading, discovery, SQLite persistence, layout presets, delete/restore logic, control-plane protocol, and git inspection helpers
- `shuttle` — command-line interface
- `ShuttleApp` — native macOS app with embedded Ghostty terminals

There is **no separate background daemon**.
The running app owns the live terminal runtime and the local control socket.
When the app is not running, many CLI commands still work by calling `ShuttleKit` directly in-process.

### Hybrid execution model

The current architecture is intentionally hybrid:

- **Local/in-process execution** is used for config, discovery, metadata inspection, and other flows that only need on-disk state.
- **Socket-backed execution** is used for live app-coupled commands such as opening sessions, mutating pane/tab state, or reading terminal output.
- **Launch-if-needed** is used for commands that require the app runtime but should still work from the CLI even when Shuttle is not already open.

In practice:

- the app owns a profile-scoped Unix-domain socket
- the CLI prefers that socket for live session/pane/tab/layout/runtime commands
- some read commands can use the socket when available and fall back to local store access otherwise
- config/discovery/project/most workspace inspection flows stay local

This lets Shuttle avoid inventing a full daemon architecture while still giving the CLI live control over the app.

---

## 3. Profiles, paths, and on-disk state

Shuttle has two fully separated profiles:

| Profile | Config dir | App Support dir | Default session root |
| --- | --- | --- | --- |
| `prod` | `~/.config/shuttle` | `~/Library/Application Support/Shuttle` | `~/Workspaces` |
| `dev` | `~/.config/shuttle-dev` | `~/Library/Application Support/Shuttle Dev` | `~/Workspaces-Dev` |

Both profiles default `tries_root` to:

```text
~/src/tries
```

### User-editable config

Config lives at:

```text
prod: ~/.config/shuttle/config.json
dev:  ~/.config/shuttle-dev/config.json
```

Current config fields are:

- `session_root`
- `tries_root`
- `project_roots`
- `ignored_paths`

Important current default:

- the generated default config scans only `tries_root` until the user adds more `project_roots`

### Application Support contents

Shuttle stores durable state under Application Support:

```text
state.sqlite
session-snapshot.json
terminal-restoration-scrollback/
  tab-<raw-id>.txt
layouts/
  <layout-id>.json
```

Current purpose of each file:

- `state.sqlite`
  - durable record of projects, workspaces, sessions, session-projects, panes, and tabs
  - current schema version: `5`
  - schema mismatch handling is destructive reset/rebuild, not in-place migration
- `session-snapshot.json`
  - selected-session relaunch snapshot
- `terminal-restoration-scrollback/tab-<raw-id>.txt`
  - persisted per-tab scrollback used for replay on restore
- `layouts/<layout-id>.json`
  - custom layout preset files

### Session roots

Session roots live under the configured `session_root`, not under Application Support.
The current default layout is:

```text
<session_root>/<workspace-slug>/<session-slug>/
```

For a normal app install this usually means:

```text
~/Workspaces/<workspace-slug>/<session-slug>/
```

Inside that root, Shuttle may write Shuttle-managed metadata such as a session guide.
App terminals for single-project sessions open directly in the source checkout.

### Control socket

The app control plane listens on a short profile-scoped socket path such as:

```text
/tmp/shuttle-prod-<uid>.sock
/tmp/shuttle-dev-<uid>.sock
```

The short `/tmp` path avoids Unix-socket path-length problems that would happen if the socket lived inside long Application Support directories.

---

## 4. Persistent domain model

The core persistent types live in `Sources/ShuttleKit/Models.swift`.

### Project

A discovered directory.

Relevant fields:

- `name`
- `path`
- `kind` (`normal` or `try`)
- `default_workspace_id`

### Workspace

An internal wrapper around a project and its sessions.

Relevant fields:

- `name`
- `slug`
- `created_from`
- `is_default`
- `source_project_id`
- `project_ids`

Current product rule:

- the shipped product exposes default single-project workspaces plus one built-in global workspace with no linked projects

The `WorkspaceSource.manual` enum still exists in the model for compatibility, but manual workspace flows are no longer part of the shipped product.

### Session

The primary unit of work.

Relevant fields:

- `workspace_id`
- `session_number`
- `name`
- `slug`
- `status` (`active`, `closed`, `restorable`)
- `session_root_path`
- `layout_name`
- timestamps

Public ID shape:

```text
workspace:<workspace-raw-id>/session:<session-number>
```

Raw SQLite IDs still exist internally and are used for persistence joins and runtime ownership.

### SessionProject

Per-project checkout state inside a session.

Relevant fields:

- `checkout_type`
- `checkout_path`
- `metadata_json`

Current behavior note:

- `checkout_type` is effectively `direct` only
- in shipped flows, that `direct` checkout points at the real source directory

### Pane and Tab

Shuttle persists a real pane tree and tab list.

`Pane` fields include:

- session/workspace/session-number scope
- `pane_number`
- `parent_pane_id`
- `split_direction`
- `ratio`
- `position_index`

`Tab` fields include:

- session/workspace/session-number scope
- `tab_number`
- `pane_id`
- `title`
- `cwd`
- `project_id`
- `command`
- `runtime_status`
- `position_index`

Public IDs are hierarchical scoped refs:

```text
workspace:5/session:3/pane:2
workspace:5/session:3/tab:1
```

### Aggregated read models

Two aggregate payloads are especially important in the app and CLI:

- `WorkspaceDetails`
  - one workspace plus its projects and sessions
- `SessionBundle`
  - one session plus its workspace, projects, session-projects, panes, and tabs

These aggregates are the main app/CLI boundary objects.

---

## 5. Core subsystems

### 5.1 `ConfigManager`

Responsibilities:

- ensure a default config file exists
- load partial JSON config onto defaults
- expand `~`
- normalize discovery roots and ignored patterns

Current default values:

- prod `session_root`: `~/Workspaces`
- dev `session_root`: `~/Workspaces-Dev`
- both profiles `tries_root`: `~/src/tries`
- both profiles default `project_roots`: `[~/src/tries]`

### 5.2 `DiscoveryManager`

Responsibilities:

- scan the immediate children of configured roots
- skip hidden entries and configured ignored globs
- classify tries using `tries_root`
- upsert project records
- ensure a default workspace exists for each discovered project

Discovery is intentionally conservative:

- immediate-child only
- no recursive indexing
- no monorepo-specific behavior

### 5.3 Discovery/session cleanup simplification

Shuttle no longer tracks git-specific project metadata during discovery or session creation.

Current implications:

- project scan only discovers directories and classifies tries
- sessions record direct source checkout paths only
- session deletion previews focus on Shuttle-managed artifacts, not branch/dirty state

### 5.4 `PersistenceStore`

`PersistenceStore` owns the SQLite schema and CRUD logic.

Current responsibilities:

- create/reset schema version `6`
- avoid unnecessary startup schema writes when the current version already matches
- normalize legacy session-local checkout paths back to source directories during startup/migration
- apply a SQLite busy timeout to reduce transient lock failures
- persist projects, workspaces, sessions, session-projects, panes, and tabs
- assign workspace-scoped session numbers and session-scoped pane/tab numbers
- persist pane split trees, tab ordering, tab metadata, and session lifecycle status

Current tables:

- `projects`
- `workspaces`
- `workspace_projects`
- `sessions`
- `session_projects`
- `panes`
- `tabs`

### 5.5 `LayoutPresetStore`

Layout presets live outside SQLite as JSON files under `layouts/`.

Current behavior:

- built-in presets: `single`, `dev`, `agent`
- custom presets stored as JSON files in Application Support
- supports save, rename, delete, and reload for custom presets
- preset schema describes pane/tree structure plus per-tab title/command
- presets do **not** encode project routing or multi-project cwd logic

### 5.6 `WorkspaceStore`

`WorkspaceStore` is the main orchestration actor.

Current responsibilities:

- config access
- project scan/list/show, including pruning stale default project workspaces for directories that disappeared from disk
- workspace list/show/open-level access
- session creation, ensure, rename, close, reopen activation
- layout apply / ensure-applied / save-current
- try-project and try-session creation
- session deletion preview and execution
- pane split / resize / tab create / tab close persistence mutations
- tab checkpoint writes

Important current rule:

- `createSession` explicitly rejects workspaces that resolve to more than one project

That means the single-project product model is enforced in the domain layer, not just hidden in UI/CLI.

#### Current session creation flow

```text
resolve workspace
-> require exactly one project
-> resolve optional layout preset
-> create unique session name + slug
-> create session root on disk
-> create session record in SQLite
-> record the project's direct source path as the session checkout
-> persist initial SessionProject
-> apply initial pane/tab layout
-> optionally seed session-root AGENTS.md
-> return SessionBundle
```

#### Current try-session flow

```text
create dated try directory under tries_root
-> upsert Project(kind: try)
-> ensure its default workspace
-> create the first session in that workspace
```

#### Current close / reopen model

- `session close` marks a session `closed` and preserves its on-disk data
- app launch marks previously active sessions `restorable`
- reopening a checkpointed closed/restorable session returns `wasRestored = true`
- restore still starts a fresh shell from saved state; it does not reattach the old process

#### Current session deletion model

Delete is session-root cleanup rather than worktree-aware cleanup:

- preview inspects each session project
- source directories stay on disk
- saved restore artifacts are removed
- the session record is deleted from SQLite
- the entire session root is removed

### 5.7 Control plane

`ShuttleKit/ControlPlane.swift` defines a local RPC layer used by the app and CLI.

Current architecture:

- protocol version `1`
- request/response JSON envelopes over a Unix-domain socket
- `ShuttleControlServer` lives in the app
- `ShuttleControlClient` lives in the CLI and other callers
- `ShuttleControlCommandService` bridges RPC requests onto `WorkspaceStore`

Current command coverage includes:

- workspace open
- session bundle/open/new/ensure/rename/close/ensure-closed
- layout apply/ensure-applied/save-current
- pane split/resize
- tab new/close/send/read/wait
- ping/capabilities

Launch-if-needed behavior:

- if a requested live command needs the app and the socket is unavailable, the CLI can launch Shuttle and retry
- `SHUTTLE_APP_PATH` can override the `.app` bundle used for that launch

### 5.8 Ghostty runtime layer

The live terminal runtime lives in `Sources/ShuttleApp/Ghostty/`.

Main pieces:

- `GhosttyRuntime`
- `GhosttyNSView`
- `GhosttyTerminalView`
- `GhosttyTabRuntimeRegistry`
- `GhosttyCheckpointWriter`
- `TerminalFocusCoordinator`

Current behavior:

- one persistent Ghostty runtime per Shuttle tab
- Ghostty config/theme/font reuse from Ghostty’s normal config search order
- auto-discovery of Ghostty resources and terminfo when available
- live tab title and cwd tracking
- shell-integration-assisted checkpointing
- accessibility and focus coordination between SwiftUI/AppKit and Ghostty

### 5.9 Snapshot and terminal restoration

Shuttle’s restore model is best-effort and selected-session-only.

Current pieces:

- `session-snapshot.json` stores the selected workspace/session plus a serialized session snapshot
- per-tab scrollback files store replayable output under Application Support
- scrollback is truncated to bounded line and character limits with ANSI-safe replay handling
- metadata-only autosave keeps the selected-session snapshot fresh while the app is running

What restore currently guarantees:

- selected workspace/session
- pane tree
- per-pane active tab selection
- focused tab
- tab title and cwd checkpoints
- optional scrollback replay

What it does **not** guarantee:

- detached PTY continuity
- long-running jobs continuing while Shuttle is quit
- whole-app or multi-window restoration

---

## 6. Session, pane, and layout behavior

### 6.1 Session roots and checkouts

For shipped sessions, Shuttle gives the user a visible coordination directory:

```text
<session_root>/<workspace-slug>/<session-slug>/
  <project-name> -> <source-checkout>
```

That means:

- the session root is stable and human-readable
- the project is reachable by a predictable relative path
- creating a session does not mutate git state

### 6.2 Pane tree behavior

Pane state is fully persisted.

Current rules:

- panes form a tree using `parent_pane_id`
- split containers store `split_direction` and `ratio`
- splitting a pane creates a new parent container and seeds/clones tab state into the new leaf
- resizing a split persists the new ratio
- closing the last tab in a non-final pane collapses redundant containers
- closing the final tab in a session leaves an empty pane so the session can reopen cleanly

### 6.3 Tab behavior

Current persisted tab behavior:

- tabs are ordered per pane by `position_index`
- each tab has a stable session-scoped public ID
- tabs remember title, cwd, optional startup command, and runtime status
- the live runtime is app-owned, but the tab model persists independently in SQLite

### 6.4 Layout behavior

Current layout behavior:

- new sessions start from a chosen preset or the built-in `single` fallback
- presets can be applied to an existing session from the CLI/control plane
- applying a layout replaces the persisted pane/tab tree for that session
- `layout save-current` snapshots the current persisted tree into a custom preset

---

## 7. CLI and machine-facing architecture

### 7.1 Handle formats

Shuttle accepts both raw and scoped references, but scoped refs are the intended public shape.

Examples:

```text
project:1
workspace:3
session:12
workspace:3/session:2
workspace:3/session:2/pane:1
workspace:3/session:2/tab:4
```

### 7.2 JSON output contract

The CLI emits a versioned success/error envelope when `--json` is used.

Current top-level shape:

- `schema_version` — currently `2`
- `ok`
- `type`
- `data`
- `error`

Conventions:

- success responses populate `data`
- failure responses populate `error.code`, `error.message`, and related usage/suggestion fields
- payload keys use `snake_case`
- list commands typically return `data.items[]`

### 7.3 Machine-readable schema and capabilities

The CLI exposes two important machine-facing discovery surfaces:

- `shuttle --help --json` or `shuttle control schema --json`
  - dumps the CLI schema, command list, enums, and error codes
- `shuttle control capabilities`
  - reports control-protocol version, socket path, profile, and supported command names

### 7.4 Runtime automation

Live terminal automation is intentionally explicit.

Current supported operations:

- `tab send`
- `tab read`
- `tab wait`

Current behavior:

- reads can target screen or scrollback
- read/wait responses include cursor tokens
- `--after-cursor <token>` allows incremental capture without rereading everything
- runtime access depends on the app-owned live terminal surface

---

## 8. Removed or intentionally unsupported product surfaces

The current architecture deliberately does **not** ship these older behaviors:

- manual workspace creation, rename, add/remove-project, ensure, or delete
- multi-project sessions
- adding a project to an existing session
- promoting a session project into a Shuttle-managed worktree
- project worktree hooks and worktree-specific config overrides
- a dedicated worktree command group
- detached session ownership outside the app

A few compatibility-oriented model fields and enums still exist, but the domain layer rejects these removed behaviors and the UI/CLI do not expose them.

---

## 9. Current limitations and open architecture gaps

The main architecture gaps that still remain are:

1. **Broader restore scope**
   - Shuttle restores the selected session, not the full app/window graph.
2. **Richer live runtime verbs**
   - send/read/wait exist, but there are no higher-level exec/interrupt/clear flows yet.
3. **App-side layout application UI**
   - layout apply/save-current exist in the CLI/control plane, while the app primarily exposes layout editing through Layout Builder and layout choice during creation.
4. **Further internal simplification**
   - the product surface is now fully single-project, but the compatibility-oriented workspace/session model is intentionally still broader than the shipped UX.

## 10. One-sentence summary

Shuttle today is a SQLite-backed native macOS terminal app plus companion CLI that uses default per-project workspaces as an internal compatibility layer, opens single-project sessions directly in the source checkout while keeping separate visible session roots for Shuttle-managed metadata, persists pane/tab state, and exposes live app control through a local Unix-socket control plane.
