import SwiftUI
import AppKit

/// Pretty-printed markdown preview shown when the user ⌘-clicks an `.md` file
/// in the terminal output. Headings, lists, inline code, links, bold/italic
/// render via SwiftUI's built-in AttributedString markdown parser.
///
/// Long form documents stream into a ScrollView with selectable text. A "Reveal
/// in Finder" button + a copy-path button live in the header for quick handoff.
struct MarkdownPreviewSheet: View {
    let path: String
    let markdown: String
    let onClose: () -> Void

    /// Pretty filename for the header (last path component).
    private var fileName: String {
        URL(fileURLWithPath: path).lastPathComponent
    }

    private var prettyPath: String {
        let home = NSHomeDirectory()
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.3)
            content
        }
        .frame(width: 760, height: 640)
    }

    private var header: some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.accentColor.opacity(0.18))
                    .frame(width: 30, height: 30)
                Image(systemName: "doc.richtext")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(fileName)
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                Text(prettyPath)
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(path, forType: .string)
            } label: {
                Image(systemName: "doc.on.doc")
            }
            .buttonStyle(.borderless)
            .help("Copy path")
            Button {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
            } label: {
                Image(systemName: "folder")
            }
            .buttonStyle(.borderless)
            .help("Reveal in Finder")
            Button {
                NSWorkspace.shared.open(URL(fileURLWithPath: path))
            } label: {
                Image(systemName: "arrow.up.right.square")
            }
            .buttonStyle(.borderless)
            .help("Open in default editor")
            Button {
                onClose()
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
            .keyboardShortcut(.cancelAction)
            .help("Close")
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
    }

    @ViewBuilder
    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                    renderBlock(block)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 28)
            .padding(.vertical, 22)
            .textSelection(.enabled)
        }
        .background(Color(nsColor: .textBackgroundColor))
    }

    // MARK: - Block-level rendering
    //
    // Apple's AttributedString markdown parser only handles inline markdown —
    // headings, lists, code blocks need block-level segmentation. We split the
    // source on common patterns and render each segment with the right SwiftUI
    // primitive, falling through to AttributedString for inline.

    private enum Block {
        case heading(level: Int, text: String)
        case codeBlock(language: String?, text: String)
        case unorderedList(items: [String])
        case orderedList(items: [String])
        case paragraph(String)
        case horizontalRule
        case table(headers: [String], rows: [[String]])
    }

    /// Heuristic: a line is a table row if it has at least two `|` characters
    /// and contains at least one non-pipe cell. We further require the line
    /// AFTER it to be a separator (`| --- | --- |`) before treating it as a
    /// table — paragraphs that just happen to mention `|` shouldn't promote.
    private static func isTableRow(_ line: String) -> Bool {
        line.contains("|") && line.split(separator: "|").contains { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
    }
    private static func isTableSeparator(_ line: String) -> Bool {
        // Each cell is dashes (optionally surrounded by colons for alignment).
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.contains("-") else { return false }
        let stripped = trimmed
            .replacingOccurrences(of: " ", with: "")
        let body = stripped.hasPrefix("|") ? String(stripped.dropFirst()) : stripped
        let tail = body.hasSuffix("|") ? String(body.dropLast()) : body
        guard !tail.isEmpty else { return false }
        let cells = tail.split(separator: "|", omittingEmptySubsequences: false)
        return cells.allSatisfy { cell in
            let c = cell.replacingOccurrences(of: ":", with: "")
            return !c.isEmpty && c.allSatisfy { $0 == "-" }
        }
    }
    private static func splitTableRow(_ line: String) -> [String] {
        var trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("|") { trimmed.removeFirst() }
        if trimmed.hasSuffix("|") { trimmed.removeLast() }
        return trimmed.split(separator: "|", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
    }

    private var blocks: [Block] {
        var result: [Block] = []
        let lines = markdown.components(separatedBy: "\n")
        var i = 0
        while i < lines.count {
            let line = lines[i]
            // Fenced code block.
            if line.hasPrefix("```") {
                let lang = String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                var code: [String] = []
                i += 1
                while i < lines.count, !lines[i].hasPrefix("```") {
                    code.append(lines[i])
                    i += 1
                }
                i += 1  // closing fence
                result.append(.codeBlock(language: lang.isEmpty ? nil : lang,
                                         text: code.joined(separator: "\n")))
                continue
            }
            // Heading.
            if line.hasPrefix("#") {
                let hashes = line.prefix(while: { $0 == "#" })
                let level = min(hashes.count, 6)
                let text = String(line.dropFirst(level)).trimmingCharacters(in: .whitespaces)
                result.append(.heading(level: level, text: text))
                i += 1
                continue
            }
            // Horizontal rule.
            let trimmedLine = line.trimmingCharacters(in: .whitespaces)
            if trimmedLine == "---" || trimmedLine == "***" || trimmedLine == "___" {
                result.append(.horizontalRule)
                i += 1
                continue
            }
            // Table — only promote if a separator row follows immediately.
            if Self.isTableRow(line),
               i + 1 < lines.count,
               Self.isTableSeparator(lines[i + 1]) {
                let headers = Self.splitTableRow(line)
                i += 2  // consume header + separator
                var rows: [[String]] = []
                while i < lines.count, Self.isTableRow(lines[i]) {
                    rows.append(Self.splitTableRow(lines[i]))
                    i += 1
                }
                result.append(.table(headers: headers, rows: rows))
                continue
            }
            // Unordered list.
            if line.range(of: #"^\s*[-*+]\s"#, options: .regularExpression) != nil {
                var items: [String] = []
                while i < lines.count,
                      let r = lines[i].range(of: #"^\s*[-*+]\s"#, options: .regularExpression) {
                    items.append(String(lines[i][r.upperBound...]))
                    i += 1
                }
                result.append(.unorderedList(items: items))
                continue
            }
            // Ordered list.
            if line.range(of: #"^\s*\d+\.\s"#, options: .regularExpression) != nil {
                var items: [String] = []
                while i < lines.count,
                      let r = lines[i].range(of: #"^\s*\d+\.\s"#, options: .regularExpression) {
                    items.append(String(lines[i][r.upperBound...]))
                    i += 1
                }
                result.append(.orderedList(items: items))
                continue
            }
            // Paragraph — gather consecutive non-empty lines.
            var para: [String] = []
            while i < lines.count,
                  !lines[i].trimmingCharacters(in: .whitespaces).isEmpty,
                  !lines[i].hasPrefix("#"),
                  !lines[i].hasPrefix("```") {
                if lines[i].range(of: #"^\s*[-*+]\s"#, options: .regularExpression) != nil { break }
                if lines[i].range(of: #"^\s*\d+\.\s"#, options: .regularExpression) != nil { break }
                if Self.isTableRow(lines[i]),
                   i + 1 < lines.count,
                   Self.isTableSeparator(lines[i + 1]) { break }
                para.append(lines[i])
                i += 1
            }
            if !para.isEmpty {
                result.append(.paragraph(para.joined(separator: " ")))
            }
            i += 1
        }
        return result
    }

    @ViewBuilder
    private func renderBlock(_ block: Block) -> some View {
        switch block {
        case .heading(let level, let text):
            Text(text)
                .font(.system(size: headingSize(level), weight: .semibold, design: .rounded))
                .padding(.top, level == 1 ? 4 : 8)
                .padding(.bottom, 2)
        case .codeBlock(let language, let text):
            VStack(alignment: .leading, spacing: 6) {
                if let language, !language.isEmpty {
                    Text(language)
                        .font(.system(size: 9.5, weight: .bold))
                        .foregroundStyle(.secondary)
                        .textCase(.uppercase)
                }
                Text(text)
                    .font(.system(size: 12.5, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Color.primary.opacity(0.06))
                    )
            }
        case .unorderedList(let items):
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .top, spacing: 8) {
                        Text("•").foregroundStyle(.secondary)
                        renderInline(item)
                    }
                }
            }
        case .orderedList(let items):
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(items.enumerated()), id: \.offset) { idx, item in
                    HStack(alignment: .top, spacing: 8) {
                        Text("\(idx + 1).")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                        renderInline(item)
                    }
                }
            }
        case .paragraph(let text):
            renderInline(text)
        case .horizontalRule:
            Divider().padding(.vertical, 4)
        case .table(let headers, let rows):
            renderTable(headers: headers, rows: rows)
        }
    }

    @ViewBuilder
    private func renderTable(headers: [String], rows: [[String]]) -> some View {
        // Equal-width columns keep the layout predictable; if a single cell
        // overflows it just wraps. The header row is tinted; body rows alternate.
        let columnCount = max(headers.count, rows.map { $0.count }.max() ?? 0)
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                ForEach(0..<columnCount, id: \.self) { col in
                    Text(col < headers.count ? headers[col] : "")
                        .font(.system(size: 12, weight: .semibold))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                    if col < columnCount - 1 {
                        Rectangle().fill(Color.primary.opacity(0.10)).frame(width: 1)
                    }
                }
            }
            .background(Color.primary.opacity(0.06))
            Rectangle().fill(Color.primary.opacity(0.10)).frame(height: 1)
            ForEach(Array(rows.enumerated()), id: \.offset) { rowIdx, row in
                HStack(spacing: 0) {
                    ForEach(0..<columnCount, id: \.self) { col in
                        let cell = col < row.count ? row[col] : ""
                        renderInline(cell)
                            .font(.system(size: 12))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                        if col < columnCount - 1 {
                            Rectangle().fill(Color.primary.opacity(0.08)).frame(width: 1)
                        }
                    }
                }
                .background(rowIdx % 2 == 0 ? Color.clear : Color.primary.opacity(0.025))
                if rowIdx < rows.count - 1 {
                    Rectangle().fill(Color.primary.opacity(0.08)).frame(height: 1)
                }
            }
        }
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }

    /// Inline markdown — bold, italic, code spans, links — handed off to
    /// AttributedString. Plain text falls through unchanged.
    @ViewBuilder
    private func renderInline(_ text: String) -> some View {
        if let attr = try? AttributedString(
            markdown: text,
            options: AttributedString.MarkdownParsingOptions(
                interpretedSyntax: .inlineOnlyPreservingWhitespace
            )
        ) {
            Text(attr)
        } else {
            Text(text)
        }
    }

    private func headingSize(_ level: Int) -> CGFloat {
        switch level {
        case 1:  return 24
        case 2:  return 20
        case 3:  return 17
        case 4:  return 15
        case 5:  return 13.5
        default: return 12.5
        }
    }
}
