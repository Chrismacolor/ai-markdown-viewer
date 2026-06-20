# AI Markdown Viewer (macOS)

A lightweight, native macOS Markdown viewer built with SwiftUI. No bells and
whistles — it opens Markdown fast, renders it cleanly, and stays out of the way.
Zero third-party dependencies; the whole app compiles against the system SDK.

- **Native & light** — no Electron, no embedded browser. Tiny app, low memory.
- **Fast** — Markdown is parsed once and rendered with SwiftUI; large files parse
  off the main thread so the UI never freezes.
- **Dark / light** — follows the macOS appearance with a manual override.
- **Live reload** — edits on disk update the preview instantly (toggle in the header).

## Install

### Homebrew (recommended)

```bash
brew tap Chrismacolor/tap
brew install --cask ai-markdown-viewer
```

Update with `brew upgrade`.

### Direct download

Grab the signed, notarized `.dmg` from the
[Releases](https://github.com/Chrismacolor/ai-markdown-viewer/releases) page and
drag the app to `/Applications`.

## Open Markdown

- Right-click a `.md` file in Finder → **Open With → AIMarkdownViewer**
  (or **Get Info → Open with → Change All…** to make it the default).
- Or drag a file onto the window.

Supported extensions: `.md`, `.markdown`, `.mdown`.

## Build from source

Requirements: macOS 13+ and the Xcode command line tools
(`xcode-select --install`).

```bash
./scripts/build_app.sh      # build/AIMarkdownViewer.app (optimized)
./scripts/install_app.sh    # build + copy to /Applications (uses sudo)
./scripts/test.sh           # run parser tests + parse benchmark
./scripts/release.sh        # sign + notarize + package a DMG (needs Developer ID)
```

`build_app.sh` honors `SWIFT_OPT=-Onone` for faster debug builds and stamps the
version from the latest git tag.

## Performance

Parser benchmark (`scripts/test.sh`, Apple Silicon, release build):

| Document size | Parse time |
|:--------------|-----------:|
| 100 KB        | ~50 ms     |
| 1 MB          | ~0.4 s     |
| 10 MB         | ~3.9 s     |

Typical documents (well under 100 KB) parse synchronously in a few milliseconds.
Anything larger parses on a background task, so the window stays responsive while
it loads. Files are capped at 20 MB (truncated with a notice) to keep memory
bounded.

## Architecture

The app is two Swift files compiled into one binary:

- `Sources/AIMarkdownViewer/MarkdownRenderer.swift` — a SwiftUI-free Markdown
  parser that produces theme-independent blocks (so it can be unit-tested
  standalone, and a theme switch never re-parses).
- `Sources/AIMarkdownViewer/main.swift` — the SwiftUI app, theme, and views that
  apply colors/fonts at render time.

Tests live in `Tests/` and run via `swiftc` (no Swift Package Manager).

## Distribution / CI

- `.github/workflows/ci.yml` builds and runs tests on every push/PR.
- `.github/workflows/release.yml` signs, notarizes, and publishes a DMG when a
  `v*` tag is pushed (see the file for the required secrets).
- `homebrew/ai-markdown-viewer.rb` is the cask; copy it into the tap repo and
  bump `version` + `sha256` (printed by `release.sh`) for each release.
