# Rando — offline hiking companion (iOS)

Personal iPhone app: follow a GPX trace on offline IGN/OpenTopoMap tiles, live position vs trace,
elevation profile (km × elevation) with two-point measurements, off-track shown by dot color.
v1 is foreground-only Core Location; recording/stats and GPX editing are v2.

## Hard rules

- **Never install anything on this machine without explicit approval** (no Homebrew — it isn't installed).
  Approved tooling lives repo-local in `tools/` (git-ignored).
- The `.xcodeproj` is generated — never edit it, never commit it. Change `project.yml` and regenerate.

## Layout

- `project.yml` — XcodeGen project definition (source of truth)
- `App/` — SwiftUI and MapLibre adapters, navigation session, import use case, persistence,
  location/elevation/tile services
- `Packages/RandoKit/` — pure-Swift domain package: GPX parse/write, canonical segment-aware
  geometry, projection, and stats. No UIKit/MapLibre imports allowed here. Fast native tests.
- `Tests/RandoTests/` — iOS integration/unit tests for app-layer actors and sessions
- `tools/xcodegen/` — repo-local XcodeGen binary (git-ignored)

## Commands

```sh
# Domain tests (fast, native macOS, no simulator needed)
swift test --package-path Packages/RandoKit

# Regenerate the Xcode project after adding/removing files or editing project.yml
./tools/xcodegen/bin/xcodegen generate

# App-layer tests (build once, then run on a booted simulator)
xcodebuild -project Rando.xcodeproj -scheme Rando \
  -destination 'platform=iOS Simulator,name=iPhone 16' build-for-testing
xcodebuild -project Rando.xcodeproj -scheme Rando \
  -destination 'platform=iOS Simulator,name=iPhone 16' test-without-building

# Build for simulator
xcodebuild -project Rando.xcodeproj -scheme Rando \
  -destination 'platform=iOS Simulator,name=iPhone 16' build

# Run in simulator
xcrun simctl boot "iPhone 16" || true
xcrun simctl install booted DerivedData/.../Rando.app
xcrun simctl launch booted dev.seb.Rando

# Deploy to Seb's iPhone (needs signing set up in Local.xcconfig, device in Developer Mode)
xcrun devicectl list devices
xcrun devicectl device install app --device <UDID> <path to Rando.app>
```

Simulator GPS: `simctl location <device> start|set` or a GPX-driven scenario — use for testing
position-on-trace behavior headlessly.

## Offline tiles

All map tiles flow through `rando-tile://<source>/{z}/{x}/{y}` → `TileURLProtocol` →
`TileStore` (SQLite, MBTiles-like, permanent) with network fallback that persists
every fetched tile. Inspect it:

```sh
DB="$(xcrun simctl get_app_container 'iPhone 16' dev.seb.Rando data)/Library/Application Support/tiles.sqlite"
sqlite3 "$DB" 'SELECT source, z, COUNT(*) FROM tiles GROUP BY source, z;'
```

DEBUG env hooks (prefix with SIMCTL_CHILD_ for simctl launch): `AUTO_DOWNLOAD=1` starts the
corridor download at launch, `OFFLINE_ONLY=1` disables tile networking (offline proof),
`PRESET_SELECTION="0.8-1.8"` presets a profile selection in km.
