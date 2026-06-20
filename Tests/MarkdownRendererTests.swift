import Foundation

// Standalone test + benchmark runner for the Markdown parser. Compiled with
// Sources/AIMarkdownViewer/MarkdownRenderer.swift by scripts/test.sh (no SwiftPM,
// no SwiftUI). Exits non-zero on any failure.

private func plain(_ a: AttributedString) -> String { String(a.characters) }

private func blockKind(_ b: MarkdownBlock) -> String {
    switch b {
    case .heading: return "heading"
    case .paragraph: return "paragraph"
    case .list: return "list"
    case .code: return "code"
    case .table: return "table"
    case .callout: return "callout"
    case .rule: return "rule"
    }
}

@main
struct TestRunner {
    static var failures = 0

    static func check(_ condition: Bool, _ message: String) {
        if condition {
            print("  ok  \(message)")
        } else {
            print("  FAIL  \(message)")
            failures += 1
        }
    }

    static func main() {
        testHeadings()
        testParagraphInline()
        testCodeBlock()
        testTable()
        testCallout()
        testLists()
        testHorizontalRule()
        testParagraphTableBoundary()
        testEmpty()
        benchmark()

        if failures > 0 {
            print("\n\(failures) test(s) FAILED")
            exit(1)
        }
        print("\nAll tests passed")
    }

    static func testHeadings() {
        print("Headings")
        let blocks = MarkdownRenderer.parse("# Hello World\n\n### Sub")
        check(blocks.count == 2, "two heading blocks")
        if case let .heading(level, inline) = blocks[0].block {
            check(level == 1, "first is h1")
            check(plain(inline) == "Hello World", "h1 text")
        } else { check(false, "block 0 is a heading") }
        if case let .heading(level, _) = blocks[1].block {
            check(level == 3, "second is h3")
        } else { check(false, "block 1 is a heading") }
    }

    static func testParagraphInline() {
        print("Paragraph inline")
        let blocks = MarkdownRenderer.parse("Some **bold** and `code` text.")
        check(blocks.count == 1 && blockKind(blocks[0].block) == "paragraph", "single paragraph")
        if case let .paragraph(inline) = blocks[0].block {
            check(plain(inline) == "Some bold and code text.", "inline markers stripped to text")
        }
    }

    static func testCodeBlock() {
        print("Code block")
        let blocks = MarkdownRenderer.parse("```swift\nlet x = 1\nlet y = 2\n```")
        check(blocks.count == 1, "one block")
        if case let .code(language, rawLines) = blocks[0].block {
            check(language == "swift", "language captured")
            check(rawLines == ["let x = 1", "let y = 2"], "raw lines preserved")
        } else { check(false, "block is code") }
    }

    static func testTable() {
        print("Table")
        // Note: the parser requires 3+ dashes in the separator row.
        let md = "| A | B |\n|:---|---:|\n| 1 | 2 |\n| 3 | 4 |"
        let blocks = MarkdownRenderer.parse(md)
        check(blocks.count == 1, "one block")
        if case let .table(header, rows, alignments) = blocks[0].block {
            check(header.count == 2, "two header cells")
            check(rows.count == 2, "two body rows")
            check(alignments.count == 2, "two alignments")
            check(plain(header[0]) == "A", "header uppercased text retained")
        } else { check(false, "block is table") }
    }

    static func testCallout() {
        print("Callout")
        let blocks = MarkdownRenderer.parse("> [!WARNING]\n> Be careful.")
        check(blocks.count == 1, "one block")
        if case let .callout(kind, inline) = blocks[0].block {
            check(kind.title == "Warning", "warning kind")
            check(plain(inline) == "Be careful.", "callout body")
        } else { check(false, "block is callout") }
    }

    static func testLists() {
        print("Lists")
        let unordered = MarkdownRenderer.parse("- a\n- b\n- c")
        if case let .list(items) = unordered[0].block {
            check(items.count == 3, "three bullets")
            check(items.allSatisfy { $0.marker == "•" }, "bullet markers")
        } else { check(false, "unordered list block") }

        let ordered = MarkdownRenderer.parse("1. first\n2. second")
        if case let .list(items) = ordered[0].block {
            check(items.map(\.marker) == ["1.", "2."], "ordered markers")
        } else { check(false, "ordered list block") }
    }

    static func testHorizontalRule() {
        print("Horizontal rule")
        let blocks = MarkdownRenderer.parse("above\n\n---\n\nbelow")
        check(blocks.map { blockKind($0.block) } == ["paragraph", "rule", "paragraph"],
              "paragraph, rule, paragraph")
    }

    static func testParagraphTableBoundary() {
        print("Paragraph/table boundary (O(n^2) fix regression)")
        let md = "intro text\n| A | B |\n|---|---|\n| 1 | 2 |"
        let blocks = MarkdownRenderer.parse(md)
        check(blocks.map { blockKind($0.block) } == ["paragraph", "table"],
              "paragraph ends at table start")
    }

    static func testEmpty() {
        print("Empty input")
        check(MarkdownRenderer.parse("").isEmpty, "no blocks for empty string")
        check(MarkdownRenderer.parse("\n\n   \n").isEmpty, "no blocks for whitespace only")
    }

    static func benchmark() {
        print("\nBenchmark (parse time)")
        let chunk = """
        # Section

        Some **bold** paragraph with `inline code` and a [link](https://example.com)
        spanning a couple of lines of prose to be representative.

        - bullet one
        - bullet two

        | Col A | Col B |
        |:------|------:|
        | one   | two   |

        > [!NOTE]
        > A callout.

        ```swift
        let x = 42
        ```

        """
        for targetMB in [0.1, 1.0, 10.0] {
            let targetBytes = Int(targetMB * 1_000_000)
            var doc = ""
            doc.reserveCapacity(targetBytes + chunk.count)
            while doc.utf8.count < targetBytes { doc += chunk }
            let start = Date()
            let blocks = MarkdownRenderer.parse(doc)
            let ms = Date().timeIntervalSince(start) * 1000
            let label = targetMB < 1 ? "100 KB" : "\(Int(targetMB)) MB"
            print(String(format: "  %-7@  %7.1f ms  (%d blocks)", label as NSString, ms, blocks.count))
        }
    }
}
