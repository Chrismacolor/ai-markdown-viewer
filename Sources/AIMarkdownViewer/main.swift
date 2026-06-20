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
    @Published var markdownSource = ""

    private var watcher: FileWatcher?
    private var liveReloadEnabled = true

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

struct ListRow: Identifiable {
    let id = UUID()
    let indent: Int
    let marker: String
    let content: AttributedString
}

enum MarkdownBlock {
    case heading(level: Int, text: AttributedString)
    case paragraph(AttributedString)
    case list([ListRow])
    case code(language: String, rawLines: [String], display: AttributedString)
    case table(header: [AttributedString], rows: [[AttributedString]], alignments: [HAlign])
    case callout(kind: CalloutKind, title: AttributedString?, content: AttributedString)
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
}

struct MarkdownRenderer {
    static func render(markdown: String, theme: Theme) -> [RenderedBlock] {
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
                let (block, next) = parseCodeBlock(from: lines, start: index, theme: theme)
                blocks.append(block)
                index = next
                continue
            }

            if let (level, text) = parseHeader(trimmed) {
                blocks.append(.heading(level: level, text: styledHeading(text, level: level, theme: theme)))
                index += 1
                continue
            }

            if isHorizontalRule(trimmed) {
                blocks.append(.rule)
                index += 1
                continue
            }

            if trimmed.hasPrefix(">") {
                let (block, next) = parseBlockquote(from: lines, start: index, theme: theme)
                blocks.append(block)
                index = next
                continue
            }

            if let (block, next) = parseTableBlock(from: lines, start: index, theme: theme) {
                blocks.append(block)
                index = next
                continue
            }

            if parseListItem(lines[index]) != nil {
                let (block, next) = parseListBlock(from: lines, start: index, theme: theme)
                blocks.append(block)
                index = next
                continue
            }

            let (block, next) = parseParagraph(from: lines, start: index, theme: theme)
            blocks.append(block)
            index = next
        }

        return blocks.enumerated().map { RenderedBlock(id: $0.offset, block: $0.element) }
    }

    // MARK: Headers

    private static func parseHeader(_ line: String) -> (level: Int, text: String)? {
        let level = line.prefix { $0 == "#" }.count
        guard (1...6).contains(level) else { return nil }
        let remainder = line.dropFirst(level)
        guard remainder.first == " " else { return nil }
        return (level, String(remainder.trimmingCharacters(in: .whitespaces)))
    }

    private static func headerSize(for level: Int) -> Double {
        switch level {
        case 1: return FontSize.h1
        case 2: return FontSize.h2
        case 3: return FontSize.h3
        case 4: return FontSize.h4
        case 5: return FontSize.h5
        default: return FontSize.h6
        }
    }

    private static func styledHeading(_ text: String, level: Int, theme: Theme) -> AttributedString {
        // h4 renders in the accent color per the reference CSS; the rest use the heading color.
        let weight: Font.Weight = level == 1 ? .heavy : (level == 2 ? .bold : .semibold)
        let color = level >= 4 ? theme.accent : theme.textHeading
        var heading = styledInline(text, size: headerSize(for: level), weight: weight, theme: theme, baseColor: color)
        heading.foregroundColor = color
        return heading
    }

    // MARK: Horizontal rule

    private static func isHorizontalRule(_ trimmed: String) -> Bool {
        guard !trimmed.contains("|") else { return false }
        return trimmed.range(of: #"^(-{3,}|\*{3,}|_{3,})$"#, options: .regularExpression) != nil
    }

    // MARK: Code blocks

    private static func parseCodeBlock(from lines: [String], start: Int, theme: Theme) -> (MarkdownBlock, Int) {
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

        var display = AttributedString(codeLines.joined(separator: "\n"))
        display.font = .system(size: FontSize.codeBlock, weight: .regular, design: .monospaced)
        display.foregroundColor = theme.text

        return (.code(language: language, rawLines: codeLines, display: display), index)
    }

    // MARK: Blockquotes / callouts

    private static func parseBlockquote(from lines: [String], start: Int, theme: Theme) -> (MarkdownBlock, Int) {
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
        let content = styledInline(bodyText, size: FontSize.body, theme: theme, baseColor: theme.text)

        var title: AttributedString?
        if let titleString = kind.title {
            var attributed = AttributedString(titleString)
            attributed.font = .system(size: 13, weight: .semibold)
            attributed.foregroundColor = kind.color(theme)
            title = attributed
        }

        return (.callout(kind: kind, title: title, content: content), index)
    }

    // MARK: Tables

    private static func parseTableBlock(from lines: [String], start: Int, theme: Theme) -> (MarkdownBlock, Int)? {
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

        let header = normalizeCells(headerCells, toCount: columnCount).map {
            styledTableCell($0.uppercased(), size: FontSize.tableHeader, weight: .semibold, theme: theme, color: theme.textMuted)
        }

        var rows: [[AttributedString]] = []
        var index = start + 2
        while index < lines.count {
            if lines[index].trimmingCharacters(in: .whitespaces).isEmpty { break }
            guard let row = splitTableRow(lines[index]) else { break }
            let cells = normalizeCells(row, toCount: columnCount).map {
                styledTableCell($0, size: FontSize.tableCell, weight: .regular, theme: theme, color: theme.text)
            }
            rows.append(cells)
            index += 1
        }

        return (.table(header: header, rows: rows, alignments: resolvedAlignments), index)
    }

    private static func styledTableCell(_ text: String, size: Double, weight: Font.Weight, theme: Theme, color: Color) -> AttributedString {
        var cell = styledInline(text, size: size, weight: weight, theme: theme, baseColor: color)
        cell.foregroundColor = color
        return cell
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
            guard trimmed.range(of: #"^:?-{3,}:?$"#, options: .regularExpression) != nil else { return nil }
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

    private enum ListItem {
        case unordered(indent: Int, text: String)
        case ordered(indent: Int, number: String, text: String)
    }

    private static func parseListBlock(from lines: [String], start: Int, theme: Theme) -> (MarkdownBlock, Int) {
        var index = start
        var rows: [ListRow] = []

        while index < lines.count {
            guard let item = parseListItem(lines[index]) else { break }
            switch item {
            case let .unordered(indent, text):
                rows.append(ListRow(indent: indent, marker: "•", content: styledInline(text, size: FontSize.body, theme: theme, baseColor: theme.text)))
            case let .ordered(indent, number, text):
                rows.append(ListRow(indent: indent, marker: "\(number).", content: styledInline(text, size: FontSize.body, theme: theme, baseColor: theme.text)))
            }
            index += 1
        }

        return (.list(rows), index)
    }

    private static func parseListItem(_ line: String) -> ListItem? {
        let indentWidth = line.prefix { $0 == " " || $0 == "\t" }.reduce(0) { $0 + ($1 == "\t" ? 2 : 1) }
        let indent = max(0, indentWidth / 2)
        let trimmed = line.trimmingCharacters(in: .whitespaces)

        if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") || trimmed.hasPrefix("+ ") {
            let text = String(trimmed.dropFirst(2)).trimmingCharacters(in: .whitespaces)
            return .unordered(indent: indent, text: text)
        }

        guard let range = trimmed.range(of: #"^\d+\.\s+"#, options: .regularExpression) else { return nil }
        let prefix = String(trimmed[range]).trimmingCharacters(in: .whitespaces)
        let number = prefix.split(separator: ".").first.map(String.init) ?? "1"
        let text = String(trimmed[range.upperBound...]).trimmingCharacters(in: .whitespaces)
        return .ordered(indent: indent, number: number, text: text)
    }

    // MARK: Paragraphs

    private static func parseParagraph(from lines: [String], start: Int, theme: Theme) -> (MarkdownBlock, Int) {
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
                parseTableBlock(from: lines, start: index, theme: theme) != nil
            {
                break
            }

            parts.append(trimmed)
            index += 1
        }

        let text = parts.joined(separator: " ")
        return (.paragraph(styledInline(text, size: FontSize.body, theme: theme, baseColor: theme.text)), index)
    }

    // MARK: Inline styling

    private static func styledInline(
        _ text: String,
        size: Double,
        weight: Font.Weight = .regular,
        theme: Theme,
        baseColor: Color
    ) -> AttributedString {
        var options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        options.failurePolicy = .returnPartiallyParsedIfPossible

        var inline = (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
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
}

// MARK: - Block views

private func readingLineSpacing(for size: Double) -> Double {
    // Approximates the reference's `line-height: 1.65` on top of the default leading.
    max(3, size * 0.45)
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
    let text: AttributedString
    let theme: Theme

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(text)
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
    let rows: [ListRow]
    let theme: Theme

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach(rows) { row in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(row.marker)
                        .font(.system(size: FontSize.body))
                        .foregroundStyle(theme.textMuted)
                        .frame(minWidth: 14, alignment: .trailing)
                    Text(row.content)
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
    let title: AttributedString?
    let content: AttributedString
    let theme: Theme

    var body: some View {
        HStack(spacing: 0) {
            Rectangle()
                .fill(kind.color(theme))
                .frame(width: 3)
            VStack(alignment: .leading, spacing: 4) {
                if let title {
                    Text(title)
                }
                Text(content)
                    .font(.system(size: FontSize.body))
                    .foregroundStyle(theme.text)
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
                    cellView(cell, column: index)
                        .background(theme.card)
                }
            }
            rowDivider
            ForEach(Array(rows.enumerated()), id: \.offset) { rowIndex, row in
                GridRow {
                    ForEach(0..<columnCount, id: \.self) { column in
                        cellView(column < row.count ? row[column] : AttributedString(""), column: column)
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

    private func cellView(_ text: AttributedString, column: Int) -> some View {
        Text(text)
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
    let display: AttributedString
    let theme: Theme

    @State private var isHovering = false
    @State private var copied = false

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

    @State private var renderedBlocks: [RenderedBlock] = []

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
            refreshRenderedMarkdown()
        }
        .onChange(of: model.markdownSource) { _ in refreshRenderedMarkdown() }
        .onChange(of: appTheme) { _ in refreshRenderedMarkdown() }
        .onChange(of: systemScheme) { _ in refreshRenderedMarkdown() }
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
                    ForEach(renderedBlocks) { rendered in
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
        case let .heading(level, text):
            HeadingView(level: level, text: text, theme: theme)
        case let .paragraph(text):
            Text(text)
                .lineSpacing(readingLineSpacing(for: FontSize.body))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        case let .list(rows):
            ListView(rows: rows, theme: theme)
        case let .code(language, rawLines, display):
            CodeBlockView(language: language, rawLines: rawLines, display: display, theme: theme)
        case let .table(header, rows, alignments):
            MarkdownTableView(header: header, rows: rows, alignments: alignments, theme: theme)
        case let .callout(kind, title, content):
            CalloutView(kind: kind, title: title, content: content, theme: theme)
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

    private func refreshRenderedMarkdown() {
        renderedBlocks = MarkdownRenderer.render(markdown: model.markdownSource, theme: theme)
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
