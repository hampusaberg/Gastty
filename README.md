# Gastty

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
| 18 curated themes + 500 more loadable via user config | ✅ |
| OSC tab-title updates from the shell | ✅ |
| Find in scrollback (⌘F) | ✅ |
| Custom about panel + app icon | ✅ |

## Layout

```
project.yml                       XcodeGen config
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
```

## Contributing

Branch off `main`, run `xcodegen` after pulling, and submit a PR. The project layout uses `project.yml` (no checked-in `.xcodeproj`) specifically so new source files don't cause merge conflicts.

## License

Built on libghostty (MIT). Application source code under MIT.
