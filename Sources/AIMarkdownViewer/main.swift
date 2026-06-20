import AppKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Theme

/// Color palette ported verbatim from md-viewer-py's CSS custom properties
/// (`01-base.css` dark `:root` and `07-theme.css` `body.light`).
struct Theme {
    let bg: Color
    let surface: Color
    let card: Color
    let hover: Color
    let border: Color
    let text: Color
    let textMuted: Color
    let textHeading: Color
    let accent: Color
    let green: Color
    let amber: Color
    let red: Color
    let cyan: Color

    static let dark = Theme(
        bg: Color(hex: 0x0f1117),
        surface: Color(hex: 0x161922),
        card: Color(hex: 0x1c1f2e),
        hover: Color(hex: 0x242838),
        border: Color(hex: 0x2a2e3f),
        text: Color(hex: 0xe1e4ed),
        textMuted: Color(hex: 0x8b90a5),
        textHeading: Color(hex: 0xf5f7fb),
        accent: Color(hex: 0x7c8aff),
        green: Color(hex: 0x4ade80),
        amber: Color(hex: 0xfbbf24),
        red: Color(hex: 0xf87171),
        cyan: Color(hex: 0x22d3ee)
    )

    static let light = Theme(
        bg: Color(hex: 0xffffff),
        surface: Color(hex: 0xf6f8fa),
        card: Color(hex: 0xf0f2f5),
        hover: Color(hex: 0xe8eaed),
        border: Color(hex: 0xd0d7de),
        text: Color(hex: 0x24292f),
        textMuted: Color(hex: 0x57606a),
        textHeading: Color(hex: 0x1c2128),
        accent: Color(hex: 0x0969da),
        green: Color(hex: 0x1a7f37),
        amber: Color(hex: 0x9a6700),
        red: Color(hex: 0xcf222e),
        cyan: Color(hex: 0x0550ae)
    )
}

extension Color {
    init(hex: UInt) {
        let r = Double((hex >> 16) & 0xff) / 255
        let g = Double((hex >> 8) & 0xff) / 255
        let b = Double(hex & 0xff) / 255
        self.init(.sRGB, red: r, green: g, blue: b, opacity: 1)
    }
}

// MARK: - Model

/// Watches a single file for on-disk changes and reports them after a short
/// debounce. Re-establishes the watch when the file is replaced via an atomic
/// save (editors that write-then-rename invalidate the original descriptor).
final class FileWatcher {
    private let url: URL
    private let onChange: () -> Void
    private let queue = DispatchQueue(label: "com.disanto.aimarkdownviewer.filewatcher")
    private var source: DispatchSourceFileSystemObject?
    private var fileDescriptor: CInt = -1
    private var pendingNotify: DispatchWorkItem?

    init?(url: URL, onChange: @escaping () -> Void) {
        self.url = url
        self.onChange = onChange
        guard start() else { return nil }
    }

    deinit { stop() }

    @discardableResult
    private func start() -> Bool {
        fileDescriptor = open(url.path, O_EVTONLY)
        guard fileDescriptor >= 0 else { return false }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fileDescriptor,
            eventMask: [.write, .extend, .delete, .rename, .link],
            queue: queue
        )

        source.setEventHandler { [weak self] in
            guard let self, let source = self.source else { return }
            let flags = source.data
            if flags.contains(.delete) || flags.contains(.rename) {
                self.restart()
            }
            self.scheduleNotify()
        }

        source.setCancelHandler { [weak self] in
            guard let self, self.fileDescriptor >= 0 else { return }
            close(self.fileDescriptor)
            self.fileDescriptor = -1
        }

        self.source = source
        source.resume()
        return true
    }

    /// An atomic save replaced the file at this path; rebuild the watch on it.
    private func restart() {
        source?.cancel()
        source = nil
        queue.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            self?.start()
        }
    }

    /// Coalesce bursts of write events into a single reload.
    private func scheduleNotify() {
        pendingNotify?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.onChange() }
        pendingNotify = item
        queue.asyncAfter(deadline: .now() + 0.08, execute: item)
    }

    func stop() {
        pendingNotify?.cancel()
        pendingNotify = nil
        source?.cancel()
        source = nil
    }
}

@MainActor
final class ViewerModel: ObservableObject {
    @Published var fileURL: URL?
    @Published var markdownSource = "" {
        didSet { reparse() }
    }
    /// Theme-independent parsed blocks. Colors/fonts are applied later in the
    /// views, so a theme switch never triggers a re-parse.
    @Published var blocks: [RenderedBlock] = []

    private var watcher: FileWatcher?
    private var liveReloadEnabled = true
    private var parseGeneration = 0

    /// Re-parse markdown into theme-independent blocks. Small documents parse
    /// synchronously (instant); large ones parse on a background task so the UI
    /// never blocks. Stale async results are discarded via a generation token.
    private func reparse() {
        parseGeneration += 1
        let gen = parseGeneration
        let src = markdownSource
        if src.utf8.count < 100_000 {
            blocks = MarkdownRenderer.parse(src)
            return
        }
        Task.detached(priority: .userInitiated) {
            let parsed = MarkdownRenderer.parse(src)
            await MainActor.run { [weak self] in
                guard let self, gen == self.parseGeneration else { return }
                self.blocks = parsed
            }
        }
    }

    func openFile(_ url: URL) {
        do {
            markdownSource = try String(contentsOf: url, encoding: .utf8)
            fileURL = url
            if liveReloadEnabled { startWatching(url) }
        } catch {
            markdownSource = "Could not open \(url.lastPathComponent).\n\n\(error.localizedDescription)"
            fileURL = nil
            watcher = nil
        }
    }

    /// Turns live reload on or off, tearing down or rebuilding the watcher for
    /// the open file. Re-enabling catches up on any change missed while paused.
    func setLiveReload(_ enabled: Bool) {
        liveReloadEnabled = enabled
        if enabled {
            if let url = fileURL { startWatching(url) }
            reloadFromDisk()
        } else {
            watcher = nil
        }
    }

    private func startWatching(_ url: URL) {
        // Reassigning releases the previous watcher, which cancels its source.
        watcher = FileWatcher(url: url) { [weak self] in
            Task { @MainActor in self?.reloadFromDisk() }
        }
    }

    /// Re-reads the open file after a live change; no-op if the content matches.
    func reloadFromDisk() {
        guard let url = fileURL else { return }
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return }
        if text != markdownSource {
            markdownSource = text
        }
    }

    func pickFileFromDisk() {
        let panel = NSOpenPanel()
        let markdownType = UTType(filenameExtension: "md") ?? .plainText
        panel.allowedContentTypes = [markdownType, .plainText]
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false

        if panel.runModal() == .OK, let url = panel.url {
            openFile(url)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    var onOpenFiles: (([URL]) -> Void)?

    func application(_ application: NSApplication, openFiles filenames: [String]) {
        let urls = filenames.map { URL(fileURLWithPath: $0) }
        onOpenFiles?(urls)
        application.reply(toOpenOrPrint: .success)
    }
}

// MARK: - Renderer

enum HAlign {
    case left
    case center
    case right
}

enum CalloutKind {
    case note
    case tip
    case important
    case warning
    case caution
    case plain

    init(tag: String) {
        switch tag.uppercased() {
        case "NOTE": self = .note
        case "TIP", "HINT": self = .tip
        case "IMPORTANT": self = .important
        case "WARNING": self = .warning
        case "CAUTION", "DANGER": self = .caution
        default: self = .plain
        }
    }

    var title: String? {
        switch self {
        case .note: return "Note"
        case .tip: return "Tip"
        case .important: return "Important"
        case .warning: return "Warning"
        case .caution: return "Caution"
        case .plain: return nil
        }
    }

    func color(_ theme: Theme) -> Color {
        switch self {
        case .note: return theme.accent
        case .tip: return theme.green
        case .important: return theme.accent
        case .warning: return theme.amber
        case .caution: return theme.red
        case .plain: return theme.textMuted
        }
    }
}

/// A list item with its inline text already parsed (theme-independent).
struct ListItem: Identifiable {
    let id = UUID()
    let indent: Int
    let marker: String
    let inline: AttributedString
}

/// Theme-independent structural blocks. Inline `AttributedString`s carry
/// presentation intents and links but NO colors/fonts — applied in the views.
enum MarkdownBlock {
    case heading(level: Int, inline: AttributedString)
    case paragraph(inline: AttributedString)
    case list([ListItem])
    case code(language: String, rawLines: [String])
    case table(header: [AttributedString], rows: [[AttributedString]], alignments: [HAlign])
    case callout(kind: CalloutKind, inline: AttributedString)
    case rule
}

struct RenderedBlock: Identifiable {
    let id: Int
    let block: MarkdownBlock
}

/// Font sizes ported from md-viewer-py's `05-content.css`.
private enum FontSize {
    static let body: Double = 14
    static let h1: Double = 30
    static let h2: Double = 21
    static let h3: Double = 16
    static let h4: Double = 13.5
    static let h5: Double = 13
    static let h6: Double = 12.5
    static let inlineCode: Double = 12.5
    static let codeBlock: Double = 12.5
    static let tableHeader: Double = 11
    static let tableCell: Double = 13.5

    static func heading(_ level: Int) -> Double {
        switch level {
        case 1: return h1
        case 2: return h2
        case 3: return h3
        case 4: return h4
        case 5: return h5
        default: return h6
        }
    }
}

struct MarkdownRenderer {
    static func parse(_ markdown: String) -> [RenderedBlock] {
        let normalized = markdown
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let lines = normalized.components(separatedBy: "\n")

        var index = 0
        var blocks: [MarkdownBlock] = []

        while index < lines.count {
            while index < lines.count, lines[index].trimmingCharacters(in: .whitespaces).isEmpty {
                index += 1
            }
            if index >= lines.count { break }

            let trimmed = lines[index].trimmingCharacters(in: .whitespaces)

            if trimmed.hasPrefix("```") {
                let (block, next) = parseCodeBlock(from: lines, start: index)
                blocks.append(block); index = next; continue
            }
            if let (level, text) = parseHeader(trimmed) {
                blocks.append(.heading(level: level, inline: parseInline(text)))
                index += 1; continue
            }
            if isHorizontalRule(trimmed) {
                blocks.append(.rule); index += 1; continue
            }
            if trimmed.hasPrefix(">") {
                let (block, next) = parseBlockquote(from: lines, start: index)
                blocks.append(block); index = next; continue
            }
            if let (block, next) = parseTableBlock(from: lines, start: index) {
                blocks.append(block); index = next; continue
            }
            if parseListItem(lines[index]) != nil {
                let (block, next) = parseListBlock(from: lines, start: index)
                blocks.append(block); index = next; continue
            }
            let (block, next) = parseParagraph(from: lines, start: index)
            blocks.append(block); index = next
        }

        return blocks.enumerated().map { RenderedBlock(id: $0.offset, block: $0.element) }
    }

    // MARK: Cached regexes (compiled once, not per line)

    private static let hrRegex = try! NSRegularExpression(pattern: #"^(-{3,}|\*{3,}|_{3,})$"#)
    private static let tableSepCellRegex = try! NSRegularExpression(pattern: #"^:?-{3,}:?$"#)
    private static let orderedListRegex = try! NSRegularExpression(pattern: #"^\d+\.\s+"#)

    private static func matches(_ regex: NSRegularExpression, _ s: String) -> Bool {
        regex.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil
    }

    // MARK: Headers

    private static func parseHeader(_ line: String) -> (level: Int, text: String)? {
        let level = line.prefix { $0 == "#" }.count
        guard (1...6).contains(level) else { return nil }
        let remainder = line.dropFirst(level)
        guard remainder.first == " " else { return nil }
        return (level, String(remainder.trimmingCharacters(in: .whitespaces)))
    }

    // MARK: Horizontal rule

    private static func isHorizontalRule(_ trimmed: String) -> Bool {
        guard !trimmed.contains("|") else { return false }
        return matches(hrRegex, trimmed)
    }

    // MARK: Code blocks

    private static func parseCodeBlock(from lines: [String], start: Int) -> (MarkdownBlock, Int) {
        var index = start
        let openingFence = lines[index].trimmingCharacters(in: .whitespaces)
        let language = String(openingFence.dropFirst(3)).trimmingCharacters(in: .whitespaces)
        index += 1

        var codeLines: [String] = []
        while index < lines.count {
            if lines[index].trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                index += 1
                break
            }
            codeLines.append(lines[index])
            index += 1
        }

        return (.code(language: language, rawLines: codeLines), index)
    }

    // MARK: Blockquotes / callouts

    private static func parseBlockquote(from lines: [String], start: Int) -> (MarkdownBlock, Int) {
        var index = start
        var contentLines: [String] = []

        while index < lines.count {
            let trimmed = lines[index].trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix(">") else { break }
            var stripped = String(trimmed.dropFirst())
            if stripped.hasPrefix(" ") { stripped.removeFirst() }
            contentLines.append(stripped)
            index += 1
        }

        var kind = CalloutKind.plain
        // Runs once per blockquote (not a per-line hot path), so range(of:) is fine.
        if
            let first = contentLines.first,
            let match = first.range(of: #"^\[!\w+\]"#, options: .regularExpression)
        {
            let tag = String(first[match]).dropFirst(2).dropLast()
            kind = CalloutKind(tag: String(tag))
            // Drop the marker line; remaining lines form the body.
            let remainder = String(first[match.upperBound...]).trimmingCharacters(in: .whitespaces)
            contentLines.removeFirst()
            if !remainder.isEmpty { contentLines.insert(remainder, at: 0) }
        }

        let bodyText = contentLines
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (.callout(kind: kind, inline: parseInline(bodyText)), index)
    }

    // MARK: Tables

    private static func parseTableBlock(from lines: [String], start: Int) -> (MarkdownBlock, Int)? {
        guard start + 1 < lines.count else { return nil }
        guard
            let headerCells = splitTableRow(lines[start]),
            let alignments = parseTableSeparatorRow(lines[start + 1])
        else {
            return nil
        }

        let columnCount = max(headerCells.count, alignments.count)
        guard columnCount > 0 else { return nil }

        var resolvedAlignments = alignments
        if resolvedAlignments.count < columnCount {
            resolvedAlignments.append(contentsOf: Array(repeating: .left, count: columnCount - resolvedAlignments.count))
        }

        let header = normalizeCells(headerCells, toCount: columnCount).map { parseInline($0.uppercased()) }

        var rows: [[AttributedString]] = []
        var index = start + 2
        while index < lines.count {
            if lines[index].trimmingCharacters(in: .whitespaces).isEmpty { break }
            guard let row = splitTableRow(lines[index]) else { break }
            rows.append(normalizeCells(row, toCount: columnCount).map { parseInline($0) })
            index += 1
        }

        return (.table(header: header, rows: rows, alignments: resolvedAlignments), index)
    }

    private static func splitTableRow(_ line: String) -> [String]? {
        var trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.contains("|") else { return nil }
        if trimmed.hasPrefix("|") { trimmed.removeFirst() }
        if trimmed.hasSuffix("|") { trimmed.removeLast() }
        return trimmed
            .split(separator: "|", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
    }

    private static func parseTableSeparatorRow(_ line: String) -> [HAlign]? {
        guard let cells = splitTableRow(line), !cells.isEmpty else { return nil }
        var alignments: [HAlign] = []
        for cell in cells {
            let trimmed = cell.trimmingCharacters(in: .whitespaces)
            guard matches(tableSepCellRegex, trimmed) else { return nil }
            let left = trimmed.hasPrefix(":")
            let right = trimmed.hasSuffix(":")
            if left && right {
                alignments.append(.center)
            } else if right {
                alignments.append(.right)
            } else {
                alignments.append(.left)
            }
        }
        return alignments
    }

    private static func normalizeCells(_ cells: [String], toCount count: Int) -> [String] {
        var normalized = Array(cells.prefix(count))
        if normalized.count < count {
            normalized.append(contentsOf: Array(repeating: "", count: count - normalized.count))
        }
        return normalized
    }

    // MARK: Lists

    private enum ListKind {
        case unordered(indent: Int, text: String)
        case ordered(indent: Int, number: String, text: String)
    }

    private static func parseListBlock(from lines: [String], start: Int) -> (MarkdownBlock, Int) {
        var index = start
        var rows: [ListItem] = []

        while index < lines.count {
            guard let item = parseListItem(lines[index]) else { break }
            switch item {
            case let .unordered(indent, text):
                rows.append(ListItem(indent: indent, marker: "•", inline: parseInline(text)))
            case let .ordered(indent, number, text):
                rows.append(ListItem(indent: indent, marker: "\(number).", inline: parseInline(text)))
            }
            index += 1
        }

        return (.list(rows), index)
    }

    private static func parseListItem(_ line: String) -> ListKind? {
        let indentWidth = line.prefix { $0 == " " || $0 == "\t" }.reduce(0) { $0 + ($1 == "\t" ? 2 : 1) }
        let indent = max(0, indentWidth / 2)
        let trimmed = line.trimmingCharacters(in: .whitespaces)

        if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") || trimmed.hasPrefix("+ ") {
            let text = String(trimmed.dropFirst(2)).trimmingCharacters(in: .whitespaces)
            return .unordered(indent: indent, text: text)
        }

        guard
            let match = orderedListRegex.firstMatch(in: trimmed, range: NSRange(trimmed.startIndex..., in: trimmed)),
            let range = Range(match.range, in: trimmed)
        else { return nil }
        let prefix = String(trimmed[range]).trimmingCharacters(in: .whitespaces)
        let number = prefix.split(separator: ".").first.map(String.init) ?? "1"
        let text = String(trimmed[range.upperBound...]).trimmingCharacters(in: .whitespaces)
        return .ordered(indent: indent, number: number, text: text)
    }

    // MARK: Paragraphs

    private static func parseParagraph(from lines: [String], start: Int) -> (MarkdownBlock, Int) {
        var index = start
        var parts: [String] = []

        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if
                trimmed.isEmpty ||
                trimmed.hasPrefix("```") ||
                trimmed.hasPrefix(">") ||
                parseHeader(trimmed) != nil ||
                isHorizontalRule(trimmed) ||
                parseListItem(line) != nil ||
                looksLikeTableStart(lines, index)
            {
                break
            }

            parts.append(trimmed)
            index += 1
        }

        return (.paragraph(inline: parseInline(parts.joined(separator: " "))), index)
    }

    /// Cheap check to end a paragraph at a table without building the whole table
    /// on every line (avoids the previous O(n^2) look-ahead).
    private static func looksLikeTableStart(_ lines: [String], _ i: Int) -> Bool {
        guard i + 1 < lines.count, lines[i].contains("|") else { return false }
        return parseTableSeparatorRow(lines[i + 1]) != nil
    }

    // MARK: Inline parse (theme-independent)

    /// Parses inline markdown (bold/italic/code/links) into an AttributedString
    /// carrying presentation intents and links but no colors/fonts. Done once
    /// per content change; the views apply theme styling cheaply at render time.
    private static func parseInline(_ text: String) -> AttributedString {
        var options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        options.failurePolicy = .returnPartiallyParsedIfPossible
        return (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
    }
}

// MARK: - Block views

private func readingLineSpacing(for size: Double) -> Double {
    // Approximates the reference's `line-height: 1.65` on top of the default leading.
    max(3, size * 0.45)
}

/// Applies theme colors and fonts to parsed (theme-independent) inline text.
/// Cheap — runs at view time, so a theme switch restyles without re-parsing.
private func styledInline(
    _ raw: AttributedString,
    size: Double,
    weight: Font.Weight = .regular,
    baseColor: Color,
    theme: Theme
) -> AttributedString {
    var inline = raw
    inline.font = .system(size: size, weight: weight)
    inline.foregroundColor = baseColor

    for run in inline.runs {
        // Links render in the accent color (the reference uses `color: var(--accent)`).
        if run.link != nil {
            inline[run.range].foregroundColor = theme.accent
        }
        guard let intent = run.inlinePresentationIntent else { continue }
        if intent.contains(.code) {
            inline[run.range].font = .system(size: FontSize.inlineCode, weight: .regular, design: .monospaced)
            inline[run.range].foregroundColor = theme.cyan
            inline[run.range].backgroundColor = theme.card
        } else if intent.contains(.stronglyEmphasized) {
            inline[run.range].font = .system(size: size, weight: .bold)
        } else if intent.contains(.emphasized) {
            inline[run.range].font = .system(size: size, weight: weight).italic()
        }
    }
    return inline
}

private struct DashedRule: View {
    let color: Color
    let lineWidth: CGFloat

    var body: some View {
        GeometryReader { geo in
            Path { path in
                let y = lineWidth / 2
                path.move(to: CGPoint(x: 0, y: y))
                path.addLine(to: CGPoint(x: geo.size.width, y: y))
            }
            .stroke(color, style: StrokeStyle(lineWidth: lineWidth, dash: [4, 3]))
        }
        .frame(height: lineWidth)
    }
}

private struct HeadingView: View {
    let level: Int
    let inline: AttributedString
    let theme: Theme

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(styled)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            if level == 1 {
                DashedRule(color: theme.border, lineWidth: 2)
            } else if level == 2 {
                DashedRule(color: theme.border, lineWidth: 1)
            }
        }
        .padding(.top, topPadding)
    }

    private var styled: AttributedString {
        // h4+ render in the accent color per the reference CSS; rest use heading color.
        let weight: Font.Weight = level == 1 ? .heavy : (level == 2 ? .bold : .semibold)
        let color = level >= 4 ? theme.accent : theme.textHeading
        return styledInline(inline, size: FontSize.heading(level), weight: weight, baseColor: color, theme: theme)
    }

    private var topPadding: CGFloat {
        switch level {
        case 1: return 8
        case 2: return 28
        case 3: return 16
        default: return 12
        }
    }
}

private struct ListView: View {
    let rows: [ListItem]
    let theme: Theme

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach(rows) { row in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(row.marker)
                        .font(.system(size: FontSize.body))
                        .foregroundStyle(theme.textMuted)
                        .frame(minWidth: 14, alignment: .trailing)
                    Text(styledInline(row.inline, size: FontSize.body, baseColor: theme.text, theme: theme))
                        .lineSpacing(readingLineSpacing(for: FontSize.body))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.leading, CGFloat(row.indent) * 18)
            }
        }
    }
}

private struct CalloutView: View {
    let kind: CalloutKind
    let inline: AttributedString
    let theme: Theme

    var body: some View {
        HStack(spacing: 0) {
            Rectangle()
                .fill(kind.color(theme))
                .frame(width: 3)
            VStack(alignment: .leading, spacing: 4) {
                if let title = kind.title {
                    Text(title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(kind.color(theme))
                }
                Text(styledInline(inline, size: FontSize.body, baseColor: theme.text, theme: theme))
                    .lineSpacing(readingLineSpacing(for: FontSize.body))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            Spacer(minLength: 0)
        }
        .background(kind.color(theme).opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

private struct MarkdownTableView: View {
    let header: [AttributedString]
    let rows: [[AttributedString]]
    let alignments: [HAlign]
    let theme: Theme

    private var columnCount: Int { header.count }

    var body: some View {
        Grid(horizontalSpacing: 0, verticalSpacing: 0) {
            GridRow {
                ForEach(Array(header.enumerated()), id: \.offset) { index, cell in
                    cellView(cell, column: index, isHeader: true)
                        .background(theme.card)
                }
            }
            rowDivider
            ForEach(Array(rows.enumerated()), id: \.offset) { rowIndex, row in
                GridRow {
                    ForEach(0..<columnCount, id: \.self) { column in
                        cellView(column < row.count ? row[column] : AttributedString(""),
                                 column: column, isHeader: false)
                    }
                }
                if rowIndex < rows.count - 1 {
                    rowDivider
                }
            }
        }
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(theme.border, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private var rowDivider: some View {
        Rectangle()
            .fill(theme.border)
            .frame(height: 1)
            .gridCellColumns(max(1, columnCount))
    }

    private func cellView(_ raw: AttributedString, column: Int, isHeader: Bool) -> some View {
        let styled = isHeader
            ? styledInline(raw, size: FontSize.tableHeader, weight: .semibold, baseColor: theme.textMuted, theme: theme)
            : styledInline(raw, size: FontSize.tableCell, baseColor: theme.text, theme: theme)
        return Text(styled)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: alignment(for: column))
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
    }

    private func alignment(for column: Int) -> Alignment {
        guard column < alignments.count else { return .leading }
        switch alignments[column] {
        case .left: return .leading
        case .center: return .center
        case .right: return .trailing
        }
    }
}

private struct CodeBlockView: View {
    let language: String
    let rawLines: [String]
    let theme: Theme

    @State private var isHovering = false
    @State private var copied = false

    private var display: AttributedString {
        var s = AttributedString(rawLines.joined(separator: "\n"))
        s.font = .system(size: FontSize.codeBlock, weight: .regular, design: .monospaced)
        s.foregroundColor = theme.text
        return s
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !language.isEmpty {
                Text(language.uppercased())
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(theme.textMuted)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                Text(display)
                    .lineSpacing(readingLineSpacing(for: FontSize.codeBlock))
                    .textSelection(.enabled)
                    .padding(.trailing, 8)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .background(theme.card)
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(theme.border, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(alignment: .topTrailing) {
            if isHovering {
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(rawLines.joined(separator: "\n"), forType: .string)
                    withAnimation { copied = true }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                        withAnimation { copied = false }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: copied ? "checkmark" : "doc.on.doc")
                        Text(copied ? "Copied" : "Copy")
                    }
                    .font(.system(size: 11))
                    .foregroundStyle(copied ? theme.green : theme.textMuted)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 4)
                    .background(theme.bg.opacity(0.6), in: RoundedRectangle(cornerRadius: 6))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .strokeBorder(copied ? theme.green : theme.border, lineWidth: 1)
                    )
                }
                .buttonStyle(.plain)
                .padding(8)
                .transition(.opacity)
            }
        }
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) { isHovering = hovering }
        }
    }
}

// MARK: - Content

struct ContentView: View {
    @ObservedObject var model: ViewerModel
    @AppStorage("appTheme") private var appTheme = "system"
    @AppStorage("liveReload") private var liveReload = true
    @Environment(\.colorScheme) private var systemScheme

    private let contentWidth: CGFloat = 860

    private var activeScheme: ColorScheme {
        switch appTheme {
        case "light": return .light
        case "dark": return .dark
        default: return systemScheme
        }
    }

    private var theme: Theme {
        activeScheme == .dark ? .dark : .light
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle()
                .fill(theme.border)
                .frame(height: 1)
            documentArea
        }
        .background(theme.bg)
        .frame(minWidth: 680, minHeight: 480)
        .preferredColorScheme(preferredScheme)
        .onAppear {
            model.setLiveReload(liveReload)
        }
        .onChange(of: liveReload) { enabled in model.setLiveReload(enabled) }
        .onDrop(of: [UTType.fileURL.identifier], isTargeted: nil) { providers in
            guard let provider = providers.first else { return false }
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { data, _ in
                guard
                    let data = data as? Data,
                    let url = URL(dataRepresentation: data, relativeTo: nil)
                else { return }
                Task { @MainActor in model.openFile(url) }
            }
            return true
        }
    }

    private var preferredScheme: ColorScheme? {
        switch appTheme {
        case "light": return .light
        case "dark": return .dark
        default: return nil
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Button {
                model.pickFileFromDisk()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "folder")
                    Text("Open")
                }
            }
            .buttonStyle(.borderedProminent)
            .tint(theme.accent)

            if let fileURL = model.fileURL {
                Text(fileURL.lastPathComponent)
                    .font(.system(size: 12))
                    .foregroundStyle(theme.textMuted)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer()

            if model.fileURL != nil {
                liveToggle
            }
            themeToggle
        }
        .padding(.horizontal, 16)
        .frame(height: 56)
        .background(theme.surface)
    }

    private var liveToggle: some View {
        Button {
            liveReload.toggle()
        } label: {
            HStack(spacing: 5) {
                Image(systemName: liveReload ? "bolt.fill" : "bolt.slash")
                Text("Live")
            }
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(liveReload ? theme.accent : theme.textMuted)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(liveReload ? theme.accent.opacity(0.5) : theme.border, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .help(liveReload ? "Live reload on — preview updates when the file changes" : "Live reload off — click to resume")
    }

    private var themeToggle: some View {
        Menu {
            Button { appTheme = "system" } label: { Label("System", systemImage: "circle.lefthalf.filled") }
            Button { appTheme = "light" } label: { Label("Light", systemImage: "sun.max") }
            Button { appTheme = "dark" } label: { Label("Dark", systemImage: "moon") }
        } label: {
            Image(systemName: themeIcon)
                .foregroundStyle(theme.textMuted)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Theme")
    }

    private var themeIcon: String {
        switch appTheme {
        case "light": return "sun.max"
        case "dark": return "moon"
        default: return "circle.lefthalf.filled"
        }
    }

    @ViewBuilder
    private var documentArea: some View {
        if model.fileURL == nil && model.markdownSource.isEmpty {
            emptyState
        } else {
            ScrollView(.vertical) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(model.blocks) { rendered in
                        blockView(rendered.block)
                            .padding(.bottom, bottomSpacing(rendered.block))
                    }
                }
                .frame(maxWidth: contentWidth, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.horizontal, 40)
                .padding(.vertical, 32)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(theme.bg)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "doc.text")
                .font(.system(size: 52, weight: .light))
                .foregroundStyle(theme.textMuted)
            Text("Open a Markdown file to preview it")
                .font(.system(size: 15))
                .foregroundStyle(theme.textMuted)
            Button("Open Markdown File") { model.pickFileFromDisk() }
                .buttonStyle(.borderedProminent)
                .tint(theme.accent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.bg)
    }

    @ViewBuilder
    private func blockView(_ block: MarkdownBlock) -> some View {
        switch block {
        case let .heading(level, inline):
            HeadingView(level: level, inline: inline, theme: theme)
        case let .paragraph(inline):
            Text(styledInline(inline, size: FontSize.body, baseColor: theme.text, theme: theme))
                .lineSpacing(readingLineSpacing(for: FontSize.body))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        case let .list(rows):
            ListView(rows: rows, theme: theme)
        case let .code(language, rawLines):
            CodeBlockView(language: language, rawLines: rawLines, theme: theme)
        case let .table(header, rows, alignments):
            MarkdownTableView(header: header, rows: rows, alignments: alignments, theme: theme)
        case let .callout(kind, inline):
            CalloutView(kind: kind, inline: inline, theme: theme)
        case .rule:
            Rectangle()
                .fill(theme.border)
                .frame(height: 1)
                .padding(.vertical, 18)
        }
    }

    private func bottomSpacing(_ block: MarkdownBlock) -> CGFloat {
        switch block {
        case .heading(let level, _): return level <= 2 ? 10 : 8
        case .paragraph: return 14
        case .list: return 14
        case .code: return 16
        case .table: return 18
        case .callout: return 16
        case .rule: return 0
        }
    }
}

@main
struct AIMarkdownViewerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = ViewerModel()

    var body: some Scene {
        WindowGroup {
            ContentView(model: model)
                .onAppear {
                    appDelegate.onOpenFiles = { urls in
                        if let firstURL = urls.first {
                            model.openFile(firstURL)
                        }
                    }
                }
                .onOpenURL { url in
                    model.openFile(url)
                }
        }
    }
}
