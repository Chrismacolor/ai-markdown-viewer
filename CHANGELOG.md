# Changelog

All notable changes to Margins are documented here. The format is based on
[Keep a Changelog](https://keepachangelog.com/), and the project follows
[Semantic Versioning](https://semver.org/).

## [Unreleased]

### Added
- VoiceOver accessibility: labels on the toolbar and Find controls, and
  headings exposed as headers so the document is navigable by the rotor.

### Changed
- Find recompute is debounced on large documents so typing stays smooth.

### Internal
- Extracted the SwiftUI-free search core into `MarkdownSearch.swift` and added
  unit tests for it; bumped CI `actions/checkout` to v5.

## [1.0.2] - 2026-06-21

### Added
- In-document **Find** (⌘F): live, case-insensitive search across every block
  type, with match highlighting, keyboard navigation (⌘G / ⇧⌘G), and
  scroll-to-match.

### Fixed
- The Live and Copy toolbar pills are now clickable across their whole area,
  not just the icon/text.

## [1.0.1] - 2026-06-21

### Added
- Copy affordances: a "Copy document as Markdown" button + ⇧⌘C, and a per-block
  hover **Copy** on prose, lists, tables, callouts, and code blocks.

## [1.0.0] - 2026-06-21

### Added
- Initial release: a native, zero-dependency macOS Markdown reader with live
  reload, light/dark themes, robust file handling, and a signed + notarized DMG
  plus a Homebrew cask.

[Unreleased]: https://github.com/Chrismacolor/margins/compare/v1.0.2...HEAD
[1.0.2]: https://github.com/Chrismacolor/margins/compare/v1.0.1...v1.0.2
[1.0.1]: https://github.com/Chrismacolor/margins/compare/v1.0.0...v1.0.1
[1.0.0]: https://github.com/Chrismacolor/margins/releases/tag/v1.0.0
