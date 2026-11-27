import SwiftUI

struct MarkdownText: View {
    let text: String
    @Environment(\.deckPalette) private var palette

    indirect enum Block: Equatable {
        case paragraph(String)
        case heading(level: Int, text: String)
        case code(language: String?, text: String)
        case list([ListItem])
        case quote([Block])
        case table(header: [String], alignments: [TableAlignment], rows: [[String]])
        case rule
    }

    struct ListItem: Equatable {
        enum Marker: Equatable {
            case bullet
            case number(Int)
            case task(done: Bool)
        }

        var level: Int
        var marker: Marker
        var text: String
    }

    enum TableAlignment: Equatable { case leading, center, trailing }

    static func blocks(_ text: String) -> [Block] {
        blocks(lines: text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init))
    }

    static func blocks(lines: [String]) -> [Block] {
        var blocks: [Block] = []
        var paragraph: [String] = []
        var index = 0
        func flush() {
            let joined = paragraph.joined(separator: "\n").trimmingCharacters(in: .newlines)
            if !joined.isEmpty { blocks.append(.paragraph(joined)) }
            paragraph = []
        }
        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if let fence = fence(trimmed) {
                flush()
                let language = trimmed.dropFirst(3).trimmingCharacters(in: .whitespaces)
                var code: [String] = []
                index += 1
                while index < lines.count, !lines[index].trimmingCharacters(in: .whitespaces).hasPrefix(fence) {
                    code.append(lines[index])
                    index += 1
                }
                blocks.append(.code(language: language.isEmpty ? nil : language, text: code.joined(separator: "\n")))
                index += 1
                continue
            }
            if trimmed.isEmpty {
                flush()
                index += 1
                continue
            }
            if let level = headingLevel(trimmed) {
                flush()
                blocks.append(.heading(level: level, text: String(trimmed.dropFirst(level)).trimmingCharacters(in: .whitespaces)
                    .replacing(/\s#+$/, with: "")))
                index += 1
                continue
            }
            if !paragraph.isEmpty, trimmed.count >= 2, trimmed.allSatisfy({ $0 == "=" }) || trimmed.allSatisfy({ $0 == "-" }) {
                let title = paragraph.joined(separator: " ")
                paragraph = []
                blocks.append(.heading(level: trimmed.first == "=" ? 1 : 2, text: title))
                index += 1
                continue
            }
            if isRule(trimmed) {
                flush()
                blocks.append(.rule)
                index += 1
                continue
            }
            if trimmed.hasPrefix(">") {
                flush()
                var quoted: [String] = []
                while index < lines.count {
                    let inner = lines[index].trimmingCharacters(in: .whitespaces)
                    guard inner.hasPrefix(">") else { break }
                    var rest = inner.dropFirst()
                    if rest.first == " " { rest = rest.dropFirst() }
                    quoted.append(String(rest))
                    index += 1
                }
                blocks.append(.quote(Self.blocks(lines: quoted)))
                continue
            }
            if paragraph.isEmpty, index + 1 < lines.count, line.contains("|"), let alignments = tableSeparator(lines[index + 1]) {
                let header = cells(line)
                var rows: [[String]] = []
                index += 2
                while index < lines.count, lines[index].contains("|"), !lines[index].trimmingCharacters(in: .whitespaces).isEmpty {
                    var row = cells(lines[index])
                    row = Array(row.prefix(header.count)) + Array(repeating: "", count: max(0, header.count - row.count))
                    rows.append(row)
                    index += 1
                }
                let fitted = Array(alignments.prefix(header.count)) + Array(repeating: .leading, count: max(0, header.count - alignments.count))
                blocks.append(.table(header: header, alignments: fitted, rows: rows))
                continue
            }
            if listItem(line) != nil, paragraph.isEmpty {
                var items: [ListItem] = []
                var indents: [Int] = []
                while index < lines.count {
                    let current = lines[index]
                    if let item = listItem(current) {
                        while let last = indents.last, item.indent < last { indents.removeLast() }
                        if indents.last != item.indent { indents.append(item.indent) }
                        items.append(ListItem(level: indents.count - 1, marker: item.marker, text: item.text))
                        index += 1
                    } else if current.trimmingCharacters(in: .whitespaces).isEmpty {
                        if index + 1 < lines.count, listItem(lines[index + 1]) != nil || lines[index + 1].hasPrefix("  ") {
                            index += 1
                        } else {
                            break
                        }
                    } else if current.hasPrefix("  ") || current.hasPrefix("\t"), !items.isEmpty {
                        items[items.count - 1].text += "\n" + current.trimmingCharacters(in: .whitespaces)
                        index += 1
                    } else {
                        break
                    }
                }
                blocks.append(.list(items))
                continue
            }
            paragraph.append(line)
            index += 1
        }
        flush()
        return blocks
    }

    static func fence(_ trimmed: String) -> String? {
        if trimmed.hasPrefix("```") { return "```" }
        if trimmed.hasPrefix("~~~") { return "~~~" }
        return nil
    }

    static func headingLevel(_ line: String) -> Int? {
        let hashes = line.prefix { $0 == "#" }.count
        guard (1...6).contains(hashes), line.dropFirst(hashes).first == " " else { return nil }
        return hashes
    }

    static func isRule(_ trimmed: String) -> Bool {
        let marks = trimmed.filter { $0 != " " }
        guard marks.count >= 3, let first = marks.first, "-*_".contains(first) else { return false }
        return marks.allSatisfy { $0 == first }
    }

    static func listItem(_ line: String) -> (indent: Int, marker: ListItem.Marker, text: String)? {
        let indent = line.prefix { $0 == " " || $0 == "\t" }.reduce(0) { $0 + ($1 == "\t" ? 4 : 1) }
        let rest = line.drop { $0 == " " || $0 == "\t" }
        if let match = rest.wholeMatch(of: /([-*+])\s+(.*)/) {
            let text = String(match.output.2)
            if let task = text.wholeMatch(of: /\[([ xX])\]\s+(.*)/) {
                return (indent, .task(done: task.output.1 != " "), String(task.output.2))
            }
            return (indent, .bullet, text)
        }
        if let match = rest.wholeMatch(of: /(\d{1,9})[.)]\s+(.*)/), let number = Int(match.output.1) {
            return (indent, .number(number), String(match.output.2))
        }
        return nil
    }

    static func tableSeparator(_ line: String) -> [TableAlignment]? {
        let parts = cells(line)
        guard !parts.isEmpty, line.contains("-") else { return nil }
        var alignments: [TableAlignment] = []
        for part in parts {
            guard part.wholeMatch(of: /:?-+:?/) != nil else { return nil }
            alignments.append(part.hasPrefix(":") && part.hasSuffix(":") ? .center : part.hasSuffix(":") ? .trailing : .leading)
        }
        return alignments
    }

    static func cells(_ line: String) -> [String] {
        var trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("|") { trimmed.removeFirst() }
        if trimmed.hasSuffix("|"), !trimmed.hasSuffix("\\|") { trimmed.removeLast() }
        var cells: [String] = []
        var current = ""
        var escaped = false
        for character in trimmed {
            if escaped {
                current.append(character == "|" ? "|" : "\\\(character)")
                escaped = false
            } else if character == "\\" {
                escaped = true
            } else if character == "|" {
                cells.append(current.trimmingCharacters(in: .whitespaces))
                current = ""
            } else {
                current.append(character)
            }
        }
        cells.append(current.trimmingCharacters(in: .whitespaces))
        return cells
    }

    static let safeSchemes: Set<String> = ["http", "https", "mailto"]

    static func inline(_ text: String, accent: Color? = nil) -> AttributedString {
        var string = (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(text)
        let links = string.runs.compactMap { run in run.link.map { (run.range, $0) } }
        for (range, url) in links {
            if let scheme = url.scheme?.lowercased(), safeSchemes.contains(scheme) {
                string[range].underlineStyle = .single
                if let accent { string[range].foregroundColor = accent }
            } else {
                string[range].link = nil
            }
        }
        return string
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.m) {
            ForEach(Array(Self.blocks(text).enumerated()), id: \.offset) { _, block in
                BlockView(block: block)
            }
        }
        .textSelection(.enabled)
    }

    struct BlockView: View {
        let block: Block
        @Environment(\.deckPalette) private var palette

        var body: some View {
            switch block {
            case let .paragraph(text):
                Text(MarkdownText.inline(text, accent: palette.accent.color)).font(Typo.body).lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
            case let .heading(level, text):
                Text(MarkdownText.inline(text, accent: palette.accent.color))
                    .font(level == 1 ? Typo.figure : level == 2 ? Typo.headline : Typo.callout.weight(.semibold))
                    .padding(.top, level <= 2 ? Space.xs : 0)
                    .accessibilityAddTraits(.isHeader)
            case let .code(language, text):
                CodeBlock(language: language, code: text)
            case let .list(items):
                VStack(alignment: .leading, spacing: Space.xs) {
                    ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                        HStack(alignment: .firstTextBaseline, spacing: Space.s) {
                            marker(item.marker)
                            Text(MarkdownText.inline(item.text, accent: palette.accent.color)).font(Typo.body)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(.leading, CGFloat(item.level) * Space.l)
                    }
                }
            case let .quote(blocks):
                VStack(alignment: .leading, spacing: Space.s) {
                    ForEach(Array(blocks.enumerated()), id: \.offset) { _, inner in BlockView(block: inner) }
                }
                .foregroundStyle(palette.textSecondary.color)
                .padding(.leading, Space.m)
                .overlay(alignment: .leading) { Rectangle().fill(palette.separator.color).frame(width: 3) }
            case let .table(header, alignments, rows):
                MarkdownTable(header: header, alignments: alignments, rows: rows)
            case .rule:
                Rectangle().fill(palette.separator.color).frame(height: 1).padding(.vertical, Space.xs)
            }
        }

        @ViewBuilder
        private func marker(_ marker: ListItem.Marker) -> some View {
            switch marker {
            case .bullet:
                Text(verbatim: "•").font(Typo.body).foregroundStyle(palette.textSecondary.color).accessibilityHidden(true)
            case let .number(number):
                Text(verbatim: "\(DeckFormat.count(number)).").font(Typo.value).foregroundStyle(palette.textSecondary.color)
            case let .task(done):
                Image(systemName: done ? "checkmark.square.fill" : "square")
                    .font(Typo.callout)
                    .foregroundStyle((done ? palette.ready : palette.textSecondary).color)
                    .accessibilityLabel(tr(done ? "chat.markdown.taskDone" : "chat.markdown.taskOpen"))
            }
        }
    }
}

struct MarkdownTable: View {
    let header: [String]
    let alignments: [MarkdownText.TableAlignment]
    let rows: [[String]]
    @Environment(\.deckPalette) private var palette

    var body: some View {
        ScrollView(.horizontal) {
            Grid(alignment: .leading, horizontalSpacing: 0, verticalSpacing: 0) {
                GridRow {
                    ForEach(header.indices, id: \.self) { column in
                        cell(header[column], column: column).font(Typo.callout.weight(.semibold))
                    }
                }
                .background(palette.surface.color)
                ForEach(rows.indices, id: \.self) { row in
                    Rectangle().fill(palette.separator.color).frame(height: 1).gridCellUnsizedAxes(.horizontal)
                    GridRow {
                        ForEach(header.indices, id: \.self) { column in
                            cell(rows[row][column], column: column).font(Typo.callout)
                        }
                    }
                }
            }
            .overlay(RoundedRectangle(cornerRadius: Radius.control).strokeBorder(palette.separator.color, lineWidth: 1))
            .clipShape(.rect(cornerRadius: Radius.control))
        }
        .scrollIndicators(.automatic)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(tr("a11y.table", DeckFormat.count(header.count), DeckFormat.count(rows.count)))
    }

    private func cell(_ text: String, column: Int) -> some View {
        let alignment: Alignment = switch alignments[column] {
        case .leading: .leading
        case .center: .center
        case .trailing: .trailing
        }
        return Text(MarkdownText.inline(text, accent: palette.accent.color))
            .multilineTextAlignment(alignment == .trailing ? .trailing : alignment == .center ? .center : .leading)
            .fixedSize(horizontal: false, vertical: true)
            .frame(minWidth: 60, maxWidth: 320, alignment: alignment)
            .padding(.horizontal, Space.m)
            .padding(.vertical, Space.s)
            .gridColumnAlignment(alignment.horizontal)
    }
}
