# GhosttyKit setup for Shuttle

This is maintainer-facing documentation for Shuttle's embedded terminal dependency.

Shuttle's Ghostty terminal embedding work was heavily inspired by [CMUX](https://github.com/manaflow-ai/cmux).

Shuttle uses `GhosttyKit.xcframework` (from the [manaflow-ai/ghostty](https://github.com/manaflow-ai/ghostty) fork) for GPU-accelerated terminal rendering via `libghostty`.

## Quick setup

```bash
./scripts/download-prebuilt-ghosttykit.sh
swift build
```

This downloads the pinned prebuilt `GhosttyKit.xcframework` (~132MB), verifies the checksum, extracts it to `Vendor/GhosttyKit.xcframework`, then post-processes the bundle to reduce warning noise during local SwiftPM builds (module-map excludes for unused VT headers plus stripped vendored archive debug info).

## Pinned version

| Field | Value |
|-------|-------|
| Ghostty SHA | `bc9be90a21997a4e5f06bf15ae2ec0f937c2dc42` |
| Archive SHA-256 | `6b83b66768e8bba871a3753ae8ffbaabd03370b306c429cd86c9cdcc8db82589` |
| Source | `manaflow-ai/ghostty` releases |
| Architecture | Universal (arm64 + x86_64) |

## What gets installed

```text
Vendor/
  GhosttyKit.xcframework/
    Info.plist
    macos-arm64_x86_64/
      Headers/
        ghostty.h           ← C embedding API
        module.modulemap    ← Swift module map
        ghostty/vt/...      ← additional headers
      libghostty.a          ← static library
    ios-arm64/              ← iOS (unused for now)
    ios-arm64-simulator/    ← iOS sim (unused for now)
```

The `Vendor/` directory is in `.gitignore` — it must be downloaded per machine.

Note: the download script strips debug info from the vendored static archives to avoid recurring `dsymutil` warnings from the prebuilt library. If you need to step through Ghostty internals in a debugger, build a fresh xcframework from source instead of relying on the post-processed prebuilt bundle.

## How it integrates

Shuttle's `Package.swift` declares a `.binaryTarget` for the xcframework:

```swift
.binaryTarget(
    name: "GhosttyKit",
    path: "Vendor/GhosttyKit.xcframework"
)
```

The `ShuttleApp` executable target depends on `GhosttyKit` and links the required system frameworks (Metal, QuartzCore, Carbon, etc.).

The bridge layer in `Sources/ShuttleApp/Ghostty/` provides:

| File | Purpose |
|------|---------|
| `GhosttyApp.swift` | Singleton that initializes `libghostty`, loads Ghostty config/default files, applies Shuttle-specific IPC isolation config, and creates the shared `ghostty_app_t` |
| `GhosttyNSView.swift` | AppKit NSView with CAMetalLayer, input forwarding, shell-integration bootstrapping, accessibility overrides, and scrollback capture |
| `GhosttyTabRuntimeRegistry.swift` | Persistent per-tab runtime ownership, live title/cwd tracking, and checkpoint-trigger wiring |
| `GhosttyCheckpointWriter.swift` | Debounced title/cwd/scrollback checkpoint writes into Shuttle restore state |
| `GhosttyTerminalView.swift` | SwiftUI `NSViewRepresentable` bridge for embedding terminals in the UI |

## Config compatibility

Shuttle lets Ghostty load its standard default-file search order, including both macOS-specific and XDG paths and both the current `config.ghostty` filename and the legacy `config` filename. In practice that means Shuttle reuses the same Ghostty theme/font/color settings you already have in files such as:

- `~/Library/Application Support/com.mitchellh.ghostty/config.ghostty`
- `~/Library/Application Support/com.mitchellh.ghostty/config`
- `${XDG_CONFIG_HOME:-~/.config}/ghostty/config.ghostty`
- `${XDG_CONFIG_HOME:-~/.config}/ghostty/config`

When Ghostty.app is installed, Shuttle also auto-discovers both `GHOSTTY_RESOURCES_DIR` and `TERMINFO` from the app bundle so the embedded runtime can find Ghostty resources and terminfo without extra manual setup.

## Building from source (alternative)

If you have `zig` installed and a ghostty checkout:

```bash
cd ghostty
zig build -Demit-xcframework=true -Dxcframework-target=universal -Doptimize=ReleaseFast
cp -R macos/GhosttyKit.xcframework ../Vendor/
```

## Updating the pinned version

1. Update `GHOSTTY_SHA` and `EXPECTED_SHA256` in `scripts/download-prebuilt-ghosttykit.sh`
2. Update the table above
3. Delete `Vendor/GhosttyKit.xcframework` and re-run the download script
4. Verify `swift build` passes
