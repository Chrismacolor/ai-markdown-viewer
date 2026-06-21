# Margins

A native Markdown reader for macOS. It opens `.md` files instantly, renders them
with clean typography, and does nothing else. No web view, no bundled
JavaScript, no plugins, no setup.

- **100% native** — SwiftUI/AppKit rendering. No embedded browser, no Chromium,
  no WebKit. Markdown is parsed and drawn natively.
- **Tiny** — no vendored engines or JS payloads; the app bundle stays small.
- **Private & offline** — your files never leave your machine; no analytics.
- **Dark / light** — follows the macOS appearance, with a manual override.
- **Live reload** — edits on disk update the view instantly (toggle in the header).

Margins is deliberately minimal. If you want Mermaid diagrams, LaTeX, PDF export,
and a dozen themes, other viewers do that — Margins is for people who just want
to read Markdown, cleanly and natively.

## Install

> **Requires:** macOS 13 (Ventura) or later, on Apple Silicon.

Pick one of the two options below.

### Option A — Homebrew (recommended)

1. If you don't already have [Homebrew](https://brew.sh), install it first.
2. Install Margins:
   ```bash
   brew install --cask Chrismacolor/tap/margins
   ```
3. Launch **Margins** from Spotlight or `/Applications`.

To update later: `brew upgrade`.

### Option B — Direct download

1. Download the latest `Margins-x.y.z.dmg` from the
   [Releases](https://github.com/Chrismacolor/margins/releases) page.
2. Double-click the `.dmg` to open it.
3. Drag **Margins** into the **Applications** folder.
4. Eject the disk image, then launch **Margins** from `/Applications`.

The app is signed and notarized, so it opens without Gatekeeper warnings. To
update, download a newer `.dmg` and repeat.

## Open Markdown

- Right-click a `.md` file in Finder → **Open With → Margins**
  (or **Get Info → Open with → Change All…** to make it the default).
- Or drag a file onto the window.

Supported extensions: `.md`, `.markdown`, `.mdown`.

## Build from source

Requirements: macOS 13+ and the Xcode command line tools
(`xcode-select --install`).

```bash
./scripts/build_app.sh      # build/Margins.app (optimized, Apple Silicon)
./scripts/install_app.sh    # build + copy to /Applications (uses sudo)
./scripts/test.sh           # run parser tests + parse benchmark
./scripts/release.sh        # sign + notarize + package a DMG (needs Developer ID)
```

`build_app.sh` honors `SWIFT_OPT=-Onone` for faster debug builds and stamps the
version from the latest git tag.

## Performance

Margins launches and opens typical documents (well under 100 KB) in a few
milliseconds. Larger files parse on a background task so the window never
freezes; files are capped at 20 MB (truncated with a notice) to keep memory
bounded. Parser benchmark (`scripts/test.sh`, Apple Silicon, release build):

| Document size | Parse time |
|:--------------|-----------:|
| 100 KB        | ~50 ms     |
| 1 MB          | ~0.4 s     |
| 10 MB         | ~3.9 s     |

## Architecture

Two Swift files compiled into one binary:

- `Sources/Margins/MarkdownRenderer.swift` — a SwiftUI-free Markdown parser that
  produces theme-independent blocks (unit-testable standalone, and a theme switch
  never re-parses).
- `Sources/Margins/main.swift` — the SwiftUI app, theme, and views that apply
  colors/fonts at render time.

Tests live in `Tests/` and run via `swiftc` (no Swift Package Manager).

## Distribution / CI

- `.github/workflows/ci.yml` builds and runs tests on every push/PR.
- `.github/workflows/release.yml` signs, notarizes, and publishes a DMG when a
  `v*` tag is pushed (see the file for the required secrets).
- `homebrew/margins.rb` is the cask; copy it into the tap repo and bump
  `version` + `sha256` (printed by `release.sh`) for each release.
