# Gastty

[![CI](https://github.com/hampusaberg/Gastty/actions/workflows/ci.yml/badge.svg)](https://github.com/hampusaberg/Gastty/actions/workflows/ci.yml)
[![Release](https://img.shields.io/github/v/release/hampusaberg/Gastty?sort=semver)](https://github.com/hampusaberg/Gastty/releases)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

A fast, GPU-accelerated macOS terminal built on [libghostty](https://github.com/ghostty-org/ghostty) with a native Swift/AppKit shell. Tabs, splits, a saved-connections sidebar with folders, SSH jumphost support, theme-aware chrome — all the daily-driver pieces, none of the Electron weight.

**Download:** grab the latest DMG from [Releases](https://github.com/hampusaberg/Gastty/releases). Or build from source — see below.

## Run (Debug build)

After [building](#build), launch the debug `.app` directly:

```sh
open build/Build/Products/Debug/Gastty.app
```

Or double-click `build/Build/Products/Debug/Gastty.app` from Finder. The build is unsigned — macOS will prompt the first time; right-click → Open to bypass Gatekeeper, then it'll launch normally afterwards.

For rapid iteration: open `Gastty.xcodeproj` in Xcode and hit `⌘R`. Xcode rebuilds and launches automatically.

## Build

Requires: macOS 13+, Homebrew, Xcode 15+.

```sh
brew install zig@0.15 xcodegen
git clone --recursive git@github.com:hampusaberg/Gastty.git
cd Gastty
./scripts/build-libghostty.sh      # ~5 min first run, cached after
xcodegen                            # generates Gastty.xcodeproj
xcodebuild -project Gastty.xcodeproj -scheme Gastty -configuration Debug \
           -derivedDataPath build/ -destination 'platform=macOS' build
open build/Build/Products/Debug/Gastty.app
```

The build script:
1. Builds `libghostty` as an xcframework via Ghostty's own `zig build`
2. Copies it to `Frameworks/GhosttyKit.xcframework/`
3. Copies the terminfo file, shell-integration scripts, and themes into `Resources/`

## Status

Daily-driver feature-complete. The small / medium polish items from the original plan have all shipped — what's left is the bigger-features bucket in the [Roadmap](#roadmap) below.

### Terminal & layout
| Feature | Status |
|---|---|
| GPU-accelerated terminal (Metal via libghostty) | ✅ |
| Tabs — rename, drag-reorder, per-tab close, +, ⌘1–⌘9, middle-click close | ✅ |
| Scrollable tab strip with chevron-left/right buttons when tabs overflow; drag-to-edge auto-scrolls | ✅ |
| Split panes — ⌘D / ⌘⇧D, ⌘[ / ⌘], click-to-focus | ✅ |
| Custom split view — 8pt grab area, hover highlight, double-click to equalize, smooth proportional resize | ✅ |
| Drag-to-resize splits with a per-pane minimum so dividers can't squash a pane into a sliver | ✅ |
| Nested splits balanced correctly at any depth | ✅ |
| Divider positions persist across tab switches *and* app relaunch | ✅ |
| Find in scrollback (⌘F) | ✅ |

### SSH & connections
| Feature | Status |
|---|---|
| Saved SSH connections + ⌘K Quick Connect palette (dismisses on click outside) | ✅ |
| Connections sidebar (⌘S) — folders, drag-reorder, double-click to open as new tab | ✅ |
| SSH jumphost / ProxyJump support per connection (with the `env`-prefix workaround for libghostty's `exec -l` argv[0] mangling) | ✅ |
| A single connection can opt into multiple workspaces — manage memberships from the Connections settings | ✅ |

### Workspaces
| Feature | Status |
|---|---|
| Workspace switcher pill in the tab bar's trailing edge (current SF Symbol + name) | ✅ |
| Per-workspace saved connections, folders, and open tabs/splits | ✅ |
| Picker grid of 24 curated SF Symbols when creating or renaming a workspace | ✅ |
| Window frame preserved across workspace switches | ✅ |
| Bootstrap "Default" workspace can be renamed + re-iconed but never deleted | ✅ |
| Connections settings has "This Workspace / All Connections" view modes with workspace badges per connection | ✅ |

### Appearance & settings
| Feature | Status |
|---|---|
| Settings panel — font, size, cursor, opacity, blur | ✅ |
| Theme browser — searchable across **all 512 bundled themes**, with per-row colour preview swatches parsed from the theme file | ✅ |
| Theme-aware chrome — tab bar, sidebar, and onboarding tint to match the active theme + opacity + blur | ✅ |
| First-run onboarding — recommended-theme tile picker, opacity + blur preset, keybindings tour | ✅ |
| Bundled app icon + custom About panel | ✅ |

### Lifecycle & UX
| Feature | Status |
|---|---|
| Command-finished notifications when the user isn't looking (≥ 5 s threshold, suppressed when the pane is focused) | ✅ |
| OSC tab-title updates from the shell (debounced 80 ms so zsh-theme bursts don't cause flicker) | ✅ |
| **Session restore** — windows, tabs, splits, divider ratios, and working directories survive relaunch | ✅ |

## Layout

```
project.yml                       XcodeGen config
.github/workflows/                CI + Release pipelines
.github/dependabot.yml            Auto-PRs for actions & submodule bumps
.swiftlint.yml                    Lint rules (enforced in CI)
scripts/build-libghostty.sh       Builds the xcframework + resources
vendor/ghostty/                   Submodule pinned to ghostty-org/ghostty
Frameworks/                       Generated xcframework (gitignored)
Resources/
  default.conf                    Bundled defaults loaded before user config
  terminfo/                       Build-script generated (gitignored)
  ghostty/                        Build-script generated (gitignored)
Sources/TerminalApp/
  TerminalApp.swift               @main + Settings scene
  AppDelegate.swift               Menu bar, window/tab lifecycle, app icon, onboarding launch
  TerminalWindowController.swift  Per-window: tab bar + surface + sidebar + chrome
  GhosttyRuntime.swift            Singleton libghostty app + callbacks (incl. command-finished)
  SurfaceHostView.swift           NSView hosting a ghostty_surface_t
  SurfaceInput.swift              Mouse + keyboard forwarding (PUA function-key carve-out)
  Session.swift                   Tab model (owns a SplitNode tree)
  Splits/SplitNode.swift          Binary tree of surfaces + custom NSView split view (hover, equalize, ratio persistence)
  TabBar/                         Custom tab bar (drag-reorder, rename, per-tab close)
  SavedConnections/               Connection store (global + per-workspace refs), folders, sidebar (⌘S), Quick Connect (⌘K)
  Settings/                       AppSettings, settings window, searchable theme browser
  Onboarding/                     First-run welcome flow
  Workspaces/                     Workspace store + per-workspace persistence, switcher pill, icon/name editor
  Search/SearchBar.swift          ⌘F find bar
  Persistence/AppPersistence.swift Session-restore state schema + IO
```

## Distribution

`Release` builds are produced automatically by [`.github/workflows/release.yml`](.github/workflows/release.yml) when a tag like `v0.1.0` is pushed. The workflow:

1. Builds the universal Release `.app`
2. (Optionally) code-signs it with a Developer ID certificate
3. (Optionally) submits to Apple notarization and staples the result
4. Wraps the `.app` in a DMG and attaches it to a GitHub release

Signing + notarization require the following repository secrets — without them the workflow still produces an unsigned DMG.

| Secret | Purpose |
|---|---|
| `MACOS_CERTIFICATE` | base64-encoded `.p12` Developer ID Application cert |
| `MACOS_CERTIFICATE_PWD` | password for the `.p12` |
| `MACOS_KEYCHAIN_PASSWORD` | scratch password for the temp keychain |
| `MACOS_NOTARIZATION_USER` | Apple ID for `notarytool` |
| `MACOS_NOTARIZATION_PWD` | app-specific password |
| `MACOS_NOTARIZATION_TEAM` | Team ID |

## Contributing

Branch off `main`, run `xcodegen` after pulling, and submit a PR. The project layout uses `project.yml` (no checked-in `.xcodeproj`) specifically so new source files don't cause merge conflicts. Every PR runs the CI workflow above; the build must pass before merge.

## Roadmap

Open items live in [Issues](https://github.com/hampusaberg/Gastty/issues). PRs welcome (see [CONTRIBUTING.md](CONTRIBUTING.md)).

The original Phase-1 plan is done. Everything that started life as a "would be nice" — pane minimums + depth-3 nesting fix, divider persistence, command-finished notifications, searchable 512-theme browser, workspaces with cross-workspace connections, scrollable tab strip, and the custom split view — has shipped. What's left is a single deferred item:

### Nice-to-have / deferred
- **Full `NSTextInputClient` (IME)** — proper CJK composition, dead keys, emoji-picker integration. Required for typing in Chinese / Japanese / Korean and for the press-and-hold accent menu. ASCII / Latin typing already works perfectly without it, so this is deferred unless a non-ASCII user shows up needing it. The full implementation pattern (mirroring Ghostty's `NSTextInputClient` extension on `SurfaceView_AppKit.swift`) is ~300 lines plus careful per-IME testing.

## License

Built on libghostty (MIT). Application source code under MIT.
