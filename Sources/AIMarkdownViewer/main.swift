import AppKit
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class ViewerModel: ObservableObject {
    @Published var fileURL: URL?
    @Published var markdownSource = "Open a Markdown file to preview it."

    func openFile(_ url: URL) {
        do {
            markdownSource = try String(contentsOf: url, encoding: .utf8)
            fileURL = url
        } catch {
            markdownSource = "Could not open \(url.lastPathComponent).\n\n\(error.localizedDescription)"
            fileURL = nil
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

private struct MarkdownRenderer {
    private enum ListItem {
        case unordered(indentLevel: Int, text: String)
        case ordered(indentLevel: Int, number: String, text: String)
    }

    private enum TableAlignment {
        case left
        case center
        case right
    }

    static func render(markdown: String, baseFontSize: Double) -> AttributedString {
        let normalized = markdown
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let lines = normalized.components(separatedBy: "\n")

        var index = 0
        var output = AttributedString()

        func appendBlock(_ block: AttributedString) {
            guard !block.characters.isEmpty else { return }
            if !output.characters.isEmpty {
                output.append(AttributedString("\n\n"))
            }
            output.append(block)
        }

        while index < lines.count {
            while index < lines.count, lines[index].trimmingCharacters(in: .whitespaces).isEmpty {
                index += 1
            }

            if index >= lines.count {
                break
            }

            let trimmed = lines[index].trimmingCharacters(in: .whitespaces)

            if trimmed.hasPrefix("```") {
                let (codeBlock, nextIndex) = parseCodeBlock(from: lines, start: index, baseFontSize: baseFontSize)
                appendBlock(codeBlock)
                index = nextIndex
                continue
            }

            if let (level, text) = parseHeader(trimmed) {
                var header = styledInline(text, fontSize: headerSize(for: level, baseFontSize: baseFontSize), weight: .bold)
                header.foregroundColor = Color(nsColor: .labelColor)
                appendBlock(header)
                index += 1
                continue
            }

            if let (tableBlock, nextIndex) = parseTableBlock(from: lines, start: index, baseFontSize: baseFontSize) {
                appendBlock(tableBlock)
                index = nextIndex
                continue
            }

            if parseListItem(lines[index]) != nil {
                let (listBlock, nextIndex) = parseListBlock(from: lines, start: index, baseFontSize: baseFontSize)
                appendBlock(listBlock)
                index = nextIndex
                continue
            }

            let (paragraph, nextIndex) = parseParagraph(from: lines, start: index, baseFontSize: baseFontSize)
            appendBlock(paragraph)
            index = nextIndex
        }

        if output.characters.isEmpty {
            output = styledInline("Open a Markdown file to preview it.", fontSize: baseFontSize)
        }

        return output
    }

    private static func parseHeader(_ line: String) -> (level: Int, text: String)? {
        let level = line.prefix { $0 == "#" }.count
        guard (1...6).contains(level) else { return nil }

        let remainder = line.dropFirst(level)
        guard remainder.first == " " else { return nil }

        return (level, String(remainder.trimmingCharacters(in: .whitespaces)))
    }

    private static func headerSize(for level: Int, baseFontSize: Double) -> Double {
        switch level {
        case 1: return max(baseFontSize * 2.0, 30)
        case 2: return max(baseFontSize * 1.65, 25)
        case 3: return max(baseFontSize * 1.4, 22)
        case 4: return max(baseFontSize * 1.25, 20)
        case 5: return max(baseFontSize * 1.12, 18)
        default: return max(baseFontSize * 1.05, 17)
        }
    }

    private static func parseCodeBlock(from lines: [String], start: Int, baseFontSize: Double) -> (AttributedString, Int) {
        var index = start
        let openingFence = lines[index].trimmingCharacters(in: .whitespaces)
        let language = String(openingFence.dropFirst(3)).trimmingCharacters(in: .whitespaces)
        index += 1

        var codeLines: [String] = []
        while index < lines.count {
            let trimmed = lines[index].trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") {
                index += 1
                break
            }
            codeLines.append(lines[index])
            index += 1
        }

        var block = AttributedString()

        if !language.isEmpty {
            var label = AttributedString(language.uppercased() + "\n")
            label.font = .system(size: max(11, baseFontSize - 4), weight: .semibold, design: .monospaced)
            label.foregroundColor = .secondary
            block.append(label)
        }

        let indentedCode = codeLines.map { "    \($0)" }.joined(separator: "\n")
        var code = AttributedString(indentedCode.isEmpty ? "    " : indentedCode)
        code.font = .system(size: max(12, baseFontSize - 1), weight: .regular, design: .monospaced)
        code.foregroundColor = Color(nsColor: .labelColor)
        block.append(code)

        return (block, index)
    }

    private static func parseTableBlock(from lines: [String], start: Int, baseFontSize: Double) -> (AttributedString, Int)? {
        guard start + 1 < lines.count else {
            return nil
        }

        guard
            let headerCells = splitTableRow(lines[start]),
            let separatorAlignments = parseTableSeparatorRow(lines[start + 1])
        else {
            return nil
        }

        let columnCount = max(headerCells.count, separatorAlignments.count)
        guard columnCount > 0 else {
            return nil
        }

        let normalizedHeader = normalizeCells(headerCells, toCount: columnCount)
        var alignments = separatorAlignments
        if alignments.count < columnCount {
            alignments.append(contentsOf: Array(repeating: .left, count: columnCount - alignments.count))
        }

        var rows: [[String]] = [normalizedHeader]
        var index = start + 2

        while index < lines.count {
            let trimmed = lines[index].trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty {
                break
            }

            guard let row = splitTableRow(lines[index]) else {
                break
            }

            rows.append(normalizeCells(row, toCount: columnCount))
            index += 1
        }

        var widths = Array(repeating: 3, count: columnCount)
        for row in rows {
            for (column, value) in row.enumerated() {
                widths[column] = max(widths[column], value.count)
            }
        }

        let tableFontSize = max(12, baseFontSize - 1)
        var block = AttributedString()

        appendMonospacedLine(
            to: &block,
            text: tableBorder(left: "┌", middle: "┬", right: "┐", widths: widths),
            fontSize: tableFontSize,
            weight: .regular,
            color: .secondary
        )
        appendMonospacedLine(
            to: &block,
            text: tableRowLine(cells: rows[0], widths: widths, alignments: alignments),
            fontSize: tableFontSize,
            weight: .semibold,
            color: Color(nsColor: .labelColor)
        )
        appendMonospacedLine(
            to: &block,
            text: tableBorder(left: "├", middle: "┼", right: "┤", widths: widths),
            fontSize: tableFontSize,
            weight: .regular,
            color: .secondary
        )

        if rows.count > 1 {
            for row in rows.dropFirst() {
                appendMonospacedLine(
                    to: &block,
                    text: tableRowLine(cells: row, widths: widths, alignments: alignments),
                    fontSize: tableFontSize,
                    weight: .regular,
                    color: Color(nsColor: .labelColor)
                )
            }
        }

        var bottomBorder = AttributedString(tableBorder(left: "└", middle: "┴", right: "┘", widths: widths))
        bottomBorder.font = .system(size: tableFontSize, weight: .regular, design: .monospaced)
        bottomBorder.foregroundColor = .secondary
        block.append(bottomBorder)

        return (block, index)
    }

    private static func splitTableRow(_ line: String) -> [String]? {
        var trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.contains("|") else {
            return nil
        }

        if trimmed.hasPrefix("|") {
            trimmed.removeFirst()
        }
        if trimmed.hasSuffix("|") {
            trimmed.removeLast()
        }

        return trimmed
            .split(separator: "|", omittingEmptySubsequences: false)
            .map { String($0).trimmingCharacters(in: .whitespaces) }
    }

    private static func parseTableSeparatorRow(_ line: String) -> [TableAlignment]? {
        guard let cells = splitTableRow(line), !cells.isEmpty else {
            return nil
        }

        var alignments: [TableAlignment] = []
        for cell in cells {
            let trimmed = cell.trimmingCharacters(in: .whitespaces)
            guard trimmed.range(of: #"^:?-{3,}:?$"#, options: .regularExpression) != nil else {
                return nil
            }

            let isLeftAligned = trimmed.hasPrefix(":")
            let isRightAligned = trimmed.hasSuffix(":")
            if isLeftAligned && isRightAligned {
                alignments.append(.center)
            } else if isRightAligned {
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

    private static func tableBorder(left: String, middle: String, right: String, widths: [Int]) -> String {
        let segments = widths.map { String(repeating: "─", count: $0 + 2) }
        return left + segments.joined(separator: middle) + right
    }

    private static func tableRowLine(cells: [String], widths: [Int], alignments: [TableAlignment]) -> String {
        let columns = cells.enumerated().map { index, value in
            let width = widths[index]
            let alignment = alignments[index]
            return " " + pad(value, toWidth: width, alignment: alignment) + " "
        }
        return "│" + columns.joined(separator: "│") + "│"
    }

    private static func pad(_ value: String, toWidth width: Int, alignment: TableAlignment) -> String {
        let missing = max(0, width - value.count)
        switch alignment {
        case .left:
            return value + String(repeating: " ", count: missing)
        case .right:
            return String(repeating: " ", count: missing) + value
        case .center:
            let leftPadding = missing / 2
            let rightPadding = missing - leftPadding
            return String(repeating: " ", count: leftPadding) + value + String(repeating: " ", count: rightPadding)
        }
    }

    private static func appendMonospacedLine(
        to block: inout AttributedString,
        text: String,
        fontSize: Double,
        weight: Font.Weight,
        color: Color
    ) {
        var line = AttributedString(text + "\n")
        line.font = .system(size: fontSize, weight: weight, design: .monospaced)
        line.foregroundColor = color
        block.append(line)
    }

    private static func parseParagraph(from lines: [String], start: Int, baseFontSize: Double) -> (AttributedString, Int) {
        var index = start
        var parts: [String] = []

        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if
                trimmed.isEmpty ||
                trimmed.hasPrefix("```") ||
                parseHeader(trimmed) != nil ||
                parseListItem(line) != nil ||
                parseTableBlock(from: lines, start: index, baseFontSize: baseFontSize) != nil
            {
                break
            }

            parts.append(trimmed)
            index += 1
        }

        let paragraphText = parts.joined(separator: " ")
        return (styledInline(paragraphText, fontSize: baseFontSize), index)
    }

    private static func parseListBlock(from lines: [String], start: Int, baseFontSize: Double) -> (AttributedString, Int) {
        var index = start
        var block = AttributedString()
        var needsLineBreak = false

        while index < lines.count {
            guard let item = parseListItem(lines[index]) else {
                break
            }

            if needsLineBreak {
                block.append(AttributedString("\n"))
            }

            switch item {
            case let .unordered(indentLevel, text):
                block.append(listPrefix(indentLevel: indentLevel, marker: "• ", fontSize: baseFontSize))
                block.append(styledInline(text, fontSize: baseFontSize))
            case let .ordered(indentLevel, number, text):
                block.append(listPrefix(indentLevel: indentLevel, marker: "\(number). ", fontSize: baseFontSize))
                block.append(styledInline(text, fontSize: baseFontSize))
            }

            index += 1
            needsLineBreak = true
        }

        return (block, index)
    }

    private static func listPrefix(indentLevel: Int, marker: String, fontSize: Double) -> AttributedString {
        let spaces = String(repeating: "    ", count: max(0, indentLevel))
        var prefix = AttributedString(spaces + marker)
        prefix.font = .system(size: fontSize, weight: .regular, design: .serif)
        prefix.foregroundColor = Color(nsColor: .labelColor)
        return prefix
    }

    private static func parseListItem(_ line: String) -> ListItem? {
        let indentWidth = line.prefix { $0 == " " || $0 == "\t" }.reduce(0) { partialResult, char in
            partialResult + (char == "\t" ? 2 : 1)
        }
        let indentLevel = max(0, indentWidth / 2)
        let trimmed = line.trimmingCharacters(in: .whitespaces)

        if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") || trimmed.hasPrefix("+ ") {
            let text = String(trimmed.dropFirst(2)).trimmingCharacters(in: .whitespaces)
            return .unordered(indentLevel: indentLevel, text: text)
        }

        guard let range = trimmed.range(of: #"^\d+\.\s+"#, options: .regularExpression) else {
            return nil
        }

        let prefix = String(trimmed[range]).trimmingCharacters(in: .whitespaces)
        let number = prefix.split(separator: ".").first.map(String.init) ?? "1"
        let text = String(trimmed[range.upperBound...]).trimmingCharacters(in: .whitespaces)
        return .ordered(indentLevel: indentLevel, number: number, text: text)
    }

    private static func styledInline(_ text: String, fontSize: Double, weight: Font.Weight = .regular) -> AttributedString {
        var options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        options.failurePolicy = .returnPartiallyParsedIfPossible

        var inline = (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
        inline.font = .system(size: fontSize, weight: weight, design: .serif)
        inline.foregroundColor = Color(nsColor: .labelColor)

        let runs = inline.runs.compactMap { run -> (Range<AttributedString.Index>, InlinePresentationIntent)? in
            guard let intent = run.inlinePresentationIntent else {
                return nil
            }
            return (run.range, intent)
        }

        for (range, intent) in runs {
            if intent.contains(.code) {
                inline[range].font = .system(size: max(12, fontSize - 1), weight: .regular, design: .monospaced)
                continue
            }

            if intent.contains(.stronglyEmphasized) {
                inline[range].font = .system(size: fontSize, weight: .semibold, design: .serif)
            } else if intent.contains(.emphasized) {
                inline[range].font = .system(size: fontSize, weight: weight, design: .serif).italic()
            }
        }

        return inline
    }
}

struct ContentView: View {
    @ObservedObject var model: ViewerModel
    @AppStorage("readerFontSize") private var readerFontSize = 17.0
    @AppStorage("readerLineSpacing") private var readerLineSpacing = 7.0
    private let readingWidth: CGFloat = 980
    @State private var renderedMarkdown = AttributedString("Open a Markdown file to preview it.")

    private var preferredDocumentWidth: CGFloat {
        let normalized = model.markdownSource
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let longestLineLength = normalized
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(\.count)
            .max() ?? 0

        let estimatedCharacterWidth = max(7.0, readerFontSize * 0.62)
        let estimatedWidth = CGFloat(longestLineLength) * CGFloat(estimatedCharacterWidth) + 72
        return min(max(readingWidth, estimatedWidth), 2200)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Button("Open Markdown File") {
                    model.pickFileFromDisk()
                }

                if let fileURL = model.fileURL {
                    Text(fileURL.lastPathComponent)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Spacer()

                HStack(spacing: 8) {
                    Image(systemName: "textformat.size")
                        .foregroundStyle(.secondary)
                    Slider(value: $readerFontSize, in: 14...24, step: 1)
                        .frame(width: 110)
                    Text("\(Int(readerFontSize)) pt")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }

                HStack(spacing: 8) {
                    Text("Spacing")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Slider(value: $readerLineSpacing, in: 3...12, step: 1)
                        .frame(width: 90)
                }
            }

            Divider()

            ScrollView([.vertical, .horizontal]) {
                Text(renderedMarkdown)
                    .lineSpacing(readerLineSpacing)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: true, vertical: false)
                    .frame(minWidth: preferredDocumentWidth, alignment: .leading)
                    .padding(.horizontal, 34)
                    .padding(.vertical, 30)
                    .background(Color(nsColor: .textBackgroundColor))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .strokeBorder(Color.secondary.opacity(0.16), lineWidth: 1)
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .shadow(color: .black.opacity(0.06), radius: 8, y: 2)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 20)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: .underPageBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .padding(16)
        .frame(minWidth: 680, minHeight: 480)
        .onAppear {
            refreshRenderedMarkdown()
        }
        .onChange(of: model.markdownSource) { _ in
            refreshRenderedMarkdown()
        }
        .onChange(of: readerFontSize) { _ in
            refreshRenderedMarkdown()
        }
        .onDrop(of: [UTType.fileURL.identifier], isTargeted: nil) { providers in
            guard let provider = providers.first else { return false }
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { data, _ in
                guard
                    let data = data as? Data,
                    let url = URL(dataRepresentation: data, relativeTo: nil)
                else {
                    return
                }

                Task { @MainActor in
                    model.openFile(url)
                }
            }
            return true
        }
    }

    private func refreshRenderedMarkdown() {
        renderedMarkdown = MarkdownRenderer.render(markdown: model.markdownSource, baseFontSize: readerFontSize)
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
