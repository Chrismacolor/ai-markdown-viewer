# AI Markdown Viewer (macOS)

Lightweight native Markdown viewer for macOS (SwiftUI, no third-party dependencies).

## Requirements

- macOS 13+
- Xcode command line tools (`xcode-select --install`)

## Build

```bash
./scripts/build_app.sh
```

This creates:

- `build/AIMarkdownViewer.app`

## Run

```bash
open build/AIMarkdownViewer.app
```

## Install To Applications

Build and replace the app in `/Applications`:

```bash
./scripts/install_app.sh
```

Options:

- `--skip-build` to install the existing build without rebuilding
- `--target <dir>` to install to a different Applications folder (example: `~/Applications`)

## Open Markdown From Finder

1. In Finder, right-click a `.md` file.
2. Click `Open With` and choose `AIMarkdownViewer`.
3. Optional: use `Get Info` -> `Open with` -> `Change All...` to make it default for Markdown files.

The app also supports drag-and-drop of files onto the window.

## Reader Style

- Centered reading column for cleaner scanning
- Serif text style for long-form Markdown readability
- Font size slider and line spacing slider in the top-right
- Block-aware Markdown formatting for headers, lists, fenced code blocks, and clean pipe-table rendering
- Wide content (like tables) keeps line integrity and can scroll horizontally without wrapping
