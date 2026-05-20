# Gastty

[![CI](https://github.com/icnswe/Gastty/actions/workflows/ci.yml/badge.svg)](https://github.com/icnswe/Gastty/actions/workflows/ci.yml)

A fast, GPU-accelerated macOS terminal built on [libghostty](https://github.com/ghostty-org/ghostty). Native Swift/AppKit shell on top of Ghostty's MIT-licensed Zig core.

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
git clone --recursive git@github.com:icnswe/Gastty.git
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

Working end-to-end. Daily-driver feature-complete with the polish list still ongoing.

| Feature | Status |
|---|---|
| GPU-accelerated terminal (Metal via libghostty) | ✅ |
| Tabs (rename, drag-reorder, close, +, ⌘1-⌘9, middle-click close) | ✅ |
| Split panes (⌘D / ⌘⇧D, ⌘[ / ⌘], focus via click) | ✅ |
| Saved SSH connections + ⌘K Quick Connect | ✅ |
| Settings (font, size, cursor, theme, opacity, blur) | ✅ |
| Theme-aware chrome (top bar matches theme) | ✅ |
| Themes — 18 in Settings dropdown, 512 bundled (rest loadable via `~/.config/ghostty/config`) | ✅ |
| OSC tab-title updates from the shell | ✅ |
| Find in scrollback (⌘F) | ✅ |
| Custom about panel + app icon | ✅ |
| **Session restore** — tabs, splits, working directories survive relaunch | ✅ |

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
  AppDelegate.swift               Menu bar, window/tab lifecycle, app icon
  TerminalWindowController.swift  Per-window: tab bar + surface + chrome
  GhosttyRuntime.swift            Singleton libghostty app + callbacks
  SurfaceHostView.swift           NSView hosting a ghostty_surface_t
  SurfaceInput.swift              Mouse + keyboard forwarding
  Session.swift                   Tab model (owns a SplitNode tree)
  Splits/SplitNode.swift          Binary tree of surfaces + NSSplitView
  TabBar/                         Custom tab bar (drag-reorder, rename, etc.)
  SavedConnections/               Connection store + Quick Connect ⌘K
  Settings/                       AppSettings + Settings window
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

## Recommendations (deferred to future iterations)

Pulled from earlier planning rounds — not done yet, parked here for later:

### Original feature asks
- **Word-highlight on selection** — double-click a word → all matches in the visible buffer light up (Xcode/VSCode style). This was on the Phase-1 plan and is the biggest crossed-out-but-never-built item.

### Quality of life
- **Divider position persistence** — drag a split divider, switch tabs, come back, current position is lost (HalfSplitView always opens 50/50). Add per-`SplitNode` ratio tracking restored on render.
- **Pane resize minimums** — currently you can drag a divider until a pane is a sliver. Add `setHoldingPriority` so panes resist below a minimum width.
- **Notifications when a long-running command finishes** — "your `make` finished" while you're in another tab.
- **Theme picker search** — 18 curated themes is fine; a search field would expose the full 512 nicely.

### Bigger features
- **Workspaces** — named bundle of tabs + connections persisted on disk; switch between "work", "homelab", "personal" with one shortcut.
- **Profiles** — multiple named configs (different fonts/themes per scope). Maps to Ghostty's `profile` concept.
- **Full `NSTextInputClient` (IME)** — proper CJK composition, dead keys, emoji picker integration.
- **Custom SplitView replacing NSSplitView** — Ghostty-style SwiftUI `GeometryReader` + manual divider with bigger hit area, double-click-to-equalize, configurable thickness. ~400 lines.

### Repo / project polish
- `CONTRIBUTING.md` with a step-by-step "how to add a feature" walkthrough.
- GitHub issue templates (bug report + feature request).

## License

Built on libghostty (MIT). Application source code under MIT.
