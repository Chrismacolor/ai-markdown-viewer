# Contributing to Margins

Thanks for your interest! Margins is a small, deliberately minimal app, so the
most useful contributions are bug reports, small fixes, and polish that fit its
scope.

## Scope

Margins is a **native, zero-dependency macOS Markdown reader** — a viewer, not
an editor. Please keep changes aligned with that:

- **No new dependencies or package managers.** Everything compiles against the
  system SDK (AppKit, SwiftUI, Foundation, UniformTypeIdentifiers).
- **Reader-focused.** Editing, syncing, plugins, and embedded web views are out
  of scope by design.
- Intentionally unsupported Markdown (to stay minimal): nested-list nesting,
  image rendering, task-list checkboxes, setext headings, inline HTML.

If you want a larger feature, please open an issue to discuss it first.

## Develop

Requires macOS 13+ and the Xcode command line tools (`xcode-select --install`).

```bash
./scripts/build_app.sh      # build build/Margins.app (SWIFT_OPT=-Onone for faster debug builds)
./scripts/test.sh           # run parser + search unit tests and the parse benchmark
./scripts/install_app.sh    # build and copy to /Applications (uses sudo)
```

There's no Xcode project or SwiftPM — `build_app.sh` invokes `swiftc` directly.
See `CLAUDE.md` for an architecture overview.

## Guidelines

- **Match the surrounding style** rather than introducing new patterns; keep
  diffs focused on the change at hand.
- Keep the parser (`MarkdownRenderer.swift`) and search core
  (`MarkdownSearch.swift`) **SwiftUI-free** so they remain unit-testable, and
  add tests in `Tests/MarkdownRendererTests.swift` for parsing/search changes.
- Run `./scripts/test.sh` before opening a PR; CI runs the tests and an
  optimized build on every push and pull request.
- Update `CHANGELOG.md` (the `Unreleased` section) for user-facing changes.

## Reporting bugs

Open an issue with your macOS version, the Margins version (**Margins → About**
or the release tag), steps to reproduce, and a sample `.md` snippet if relevant.
