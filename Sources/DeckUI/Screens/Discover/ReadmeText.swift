import Foundation
import Synchronization
import SwiftUI

struct ReadmeDocument {
    indirect enum Block: Equatable {
        case markdown(MarkdownText.Block)
        case table(Table)
        case details(summary: String, blocks: [Block])
    }

    struct Table: Equatable {
        struct Cell: Equatable {
            var text: String
            var span: Int = 1
            var alignment: MarkdownText.TableAlignment = .leading
        }

        struct Row: Equatable {
            var header: Bool
            var cells: [Cell]
        }

        var rows: [Row]

        var columns: Int { rows.map { $0.cells.reduce(0) { $0 + $1.span } }.max() ?? 0 }
    }

    struct Links: Equatable {
        var pages: URL?
        var files: URL?

        init(repo: String?) {
            guard let repo, !repo.isEmpty else { return }
            pages = URL(string: "https://huggingface.co/\(repo)/blob/main/")
            files = URL(string: "https://huggingface.co/\(repo)/resolve/main/")
        }
    }

    static func blocks(_ text: String, links: Links = Links(repo: nil)) -> [Block] {
        let lines = text.replacing("\r\n", with: "\n").split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        return Parser(links: links).blocks(lines)
    }

    static let blockTags: Set<String> = [
        "table", "div", "center", "details", "section", "article", "figure", "blockquote", "header", "footer", "main",
        "aside", "nav", "p", "h1", "h2", "h3", "h4", "h5", "h6", "ul", "ol", "pre", "hr", "script", "style", "svg",
        "iframe", "video", "audio", "picture", "dl", "form", "noscript", "summary", "thead", "tbody", "tr",
    ]

    static let containers: Set<String> = [
        "div", "center", "section", "article", "figure", "blockquote", "header", "footer", "main", "aside", "nav", "dl", "form",
    ]

    struct Parser {
        let links: Links

        func blocks(_ lines: [String]) -> [Block] {
            var blocks: [Block] = []
            var markdown: [String] = []
            var fence: String?
            func flush() {
                guard !markdown.isEmpty else { return }
                blocks += MarkdownText.blocks(lines: markdown).map { .markdown(sanitize($0)) }.flatMap(tables)
                markdown = []
            }
            var index = 0
            while index < lines.count {
                let line = lines[index]
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if let open = fence {
                    markdown.append(line)
                    if trimmed.hasPrefix(open) { fence = nil }
                    index += 1
                    continue
                }
                if let open = MarkdownText.fence(trimmed) {
                    fence = open
                    markdown.append(line)
                    index += 1
                    continue
                }
                if trimmed.hasPrefix("<!--") {
                    var end = index
                    while end < lines.count, !lines[end].contains("-->") { end += 1 }
                    if end < lines.count, let close = lines[end].range(of: "-->") {
                        let rest = String(lines[end][close.upperBound...])
                        if !rest.trimmingCharacters(in: .whitespaces).isEmpty { markdown.append(rest) }
                    }
                    index = end + 1
                    continue
                }
                if Self.onlyClosingTags(trimmed) {
                    flush()
                    index += 1
                    continue
                }
                if let tag = Self.openingTag(trimmed), ReadmeDocument.blockTags.contains(tag) {
                    flush()
                    let end = Self.end(of: tag, from: index, in: lines)
                    blocks += html(tag, lines[index...end].joined(separator: "\n"))
                    index = end + 1
                    continue
                }
                markdown.append(line)
                index += 1
            }
            flush()
            return blocks
        }

        static func openingTag(_ trimmed: String) -> String? {
            guard trimmed.hasPrefix("<"), let match = trimmed.prefixMatch(of: /<([A-Za-z][A-Za-z0-9]*)(?=[\s>\/])/) else { return nil }
            let name = match.output.1.lowercased()
            return HTML.elements.contains(name) ? name : nil
        }

        static func onlyClosingTags(_ trimmed: String) -> Bool {
            !trimmed.isEmpty && trimmed.wholeMatch(of: /(<\/[A-Za-z][A-Za-z0-9]*\s*>\s*)+/) != nil
        }

        static func end(of tag: String, from start: Int, in lines: [String]) -> Int {
            if HTML.void.contains(tag) { return start }
            var depth = 0
            var index = start
            while index < lines.count {
                for token in HTML.tokens(lines[index]) {
                    switch token {
                    case let .open(name, _, selfClosing) where name == tag && !selfClosing: depth += 1
                    case let .close(name) where name == tag: depth -= 1
                    default: break
                    }
                }
                if depth <= 0 { return index }
                index += 1
            }
            var blank = start
            while blank + 1 < lines.count, !lines[blank + 1].trimmingCharacters(in: .whitespaces).isEmpty { blank += 1 }
            return blank
        }

        func html(_ tag: String, _ source: String) -> [Block] {
            let root = HTML.tree(source)
            guard let element = root.children.first(where: { $0.name == tag }) else {
                return paragraph(Inline(links: links).html(root))
            }
            switch tag {
            case "table", "thead", "tbody", "tr":
                return [.table(table(tag == "table" ? element : root))]
            case "h1", "h2", "h3", "h4", "h5", "h6":
                let text = Inline(links: links).html(element)
                return text.isEmpty ? [] : [.markdown(.heading(level: Int(String(tag.last!))!, text: text))]
            case "ul", "ol":
                let items = list(element, level: 0)
                return items.isEmpty ? [] : [.markdown(.list(items))]
            case "pre":
                let code = HTML.decode(element.textContent).trimmingCharacters(in: .newlines)
                return code.isEmpty ? [] : [.markdown(.code(language: nil, text: code))]
            case "hr":
                return [.markdown(.rule)]
            case "script", "style", "svg", "noscript":
                return []
            case "iframe", "video", "audio":
                return paragraph(Inline(links: links).media(element))
            case "details":
                return [details(element, source: source)]
            case _ where ReadmeDocument.containers.contains(tag):
                return blocks(Self.inner(of: tag, in: source).split(separator: "\n", omittingEmptySubsequences: false).map(String.init))
            default:
                return paragraph(Inline(links: links).html(element))
            }
        }

        func details(_ element: HTML.Node, source: String) -> Block {
            var inner = Self.inner(of: "details", in: source)
            var summary = ""
            if let open = inner.range(of: "<summary", options: .caseInsensitive),
               let close = inner.range(of: "</summary>", options: .caseInsensitive, range: open.upperBound ..< inner.endIndex) {
                summary = Inline(links: links).html(HTML.tree(String(inner[open.lowerBound ..< close.upperBound])))
                inner.removeSubrange(open.lowerBound ..< close.upperBound)
            }
            let children = blocks(inner.split(separator: "\n", omittingEmptySubsequences: false).map(String.init))
            return .details(summary: summary.isEmpty ? tr("discover.readme.details") : summary, blocks: children)
        }

        static func inner(of tag: String, in source: String) -> String {
            guard let open = source.range(of: "<" + tag, options: .caseInsensitive),
                  let start = source.range(of: ">", range: open.upperBound ..< source.endIndex) else { return source }
            var depth = 1
            var cursor = start.upperBound
            let pattern = try! Regex("<(/?)\(tag)(?=[\\s>/])").ignoresCase()
            while let match = source[cursor...].firstMatch(of: pattern) {
                let closing = source[match.range].hasPrefix("</")
                depth += closing ? -1 : 1
                if depth == 0 { return String(source[start.upperBound ..< match.range.lowerBound]) }
                cursor = match.range.upperBound
            }
            return String(source[start.upperBound...])
        }

        func paragraph(_ text: String) -> [Block] {
            text.isEmpty ? [] : [.markdown(.paragraph(text))]
        }

        func list(_ element: HTML.Node, level: Int) -> [MarkdownText.ListItem] {
            var items: [MarkdownText.ListItem] = []
            var number = Int(element.attributes["start"] ?? "") ?? 1
            for item in element.children where item.name == "li" {
                let nested = item.children.filter { $0.name == "ul" || $0.name == "ol" }
                var own = item
                own.children.removeAll { $0.name == "ul" || $0.name == "ol" }
                let text = Inline(links: links).html(own)
                if !text.isEmpty {
                    items.append(MarkdownText.ListItem(level: level, marker: element.name == "ol" ? .number(number) : .bullet, text: text))
                    number += 1
                }
                for list in nested { items += self.list(list, level: level + 1) }
            }
            return items
        }

        func table(_ element: HTML.Node) -> Table {
            var rows: [Table.Row] = []
            func walk(_ node: HTML.Node, header: Bool) {
                for child in node.children {
                    switch child.name {
                    case "thead": walk(child, header: true)
                    case "tbody", "tfoot": walk(child, header: false)
                    case "tr":
                        let cells = child.children.filter { $0.name == "td" || $0.name == "th" }
                        guard !cells.isEmpty else { continue }
                        let all = cells.allSatisfy { $0.name == "th" }
                        rows.append(Table.Row(header: header || all, cells: cells.map { cell in
                            Table.Cell(text: Inline(links: links).html(cell), span: max(1, min(64, Int(cell.attributes["colspan"] ?? "") ?? 1)),
                                       alignment: Self.alignment(cell))
                        }))
                    default: break
                    }
                }
            }
            walk(element, header: false)
            return Table(rows: rows)
        }

        static func alignment(_ cell: HTML.Node) -> MarkdownText.TableAlignment {
            let style = (cell.attributes["style"] ?? "").lowercased().replacing(" ", with: "")
            let align = (cell.attributes["align"] ?? "").lowercased()
            if align == "center" || style.contains("text-align:center") { return .center }
            if align == "right" || style.contains("text-align:right") { return .trailing }
            return .leading
        }

        func tables(_ block: Block) -> [Block] {
            guard case let .markdown(.table(header, alignments, rows)) = block else { return [block] }
            let head = Table.Row(header: true, cells: header.indices.map { Table.Cell(text: header[$0], alignment: alignments[$0]) })
            let body = rows.map { row in
                Table.Row(header: false, cells: row.indices.map { Table.Cell(text: row[$0], alignment: alignments[$0]) })
            }
            return [.table(Table(rows: [head] + body))]
        }

        func sanitize(_ block: MarkdownText.Block) -> MarkdownText.Block {
            let inline = Inline(links: links)
            switch block {
            case let .paragraph(text): return .paragraph(inline.markdown(text))
            case let .heading(level, text): return .heading(level: level, text: inline.markdown(text))
            case .code, .rule: return block
            case let .list(items):
                return .list(items.map { MarkdownText.ListItem(level: $0.level, marker: $0.marker, text: inline.markdown($0.text)) })
            case let .quote(blocks): return .quote(blocks.map(sanitize))
            case let .table(header, alignments, rows):
                return .table(header: header.map(inline.markdown), alignments: alignments, rows: rows.map { $0.map(inline.markdown) })
            }
        }
    }

    struct Inline {
        let links: Links

        func html(_ node: HTML.Node) -> String {
            Self.tidy(render(node.children, markdown: false, inLink: false))
        }

        func markdown(_ text: String) -> String {
            var output = ""
            var rest = Substring(text)
            while let code = rest.firstMatch(of: /(`+)[^`]+?\1/) {
                output += render(HTML.tree(String(rest[..<code.range.lowerBound])).children, markdown: true, inLink: false)
                output += rest[code.range]
                rest = rest[code.range.upperBound...]
            }
            output += render(HTML.tree(String(rest)).children, markdown: true, inLink: false)
            return output.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        func media(_ node: HTML.Node) -> String {
            let source = node.attributes["src"] ?? node.children.first { $0.name == "source" }?.attributes["src"]
            let label = tr("discover.readme.media", node.attributes["title"] ?? source.map { URL(string: $0)?.lastPathComponent ?? $0 } ?? node.name)
            guard let url = source.flatMap({ resolve($0, base: links.files) }) else { return Self.escape(label) }
            return "[\(Self.escape(label))](\(Self.target(url)))"
        }

        func render(_ nodes: [HTML.Node], markdown: Bool, inLink: Bool) -> String {
            nodes.map { render($0, markdown: markdown, inLink: inLink) }.joined()
        }

        func render(_ node: HTML.Node, markdown: Bool, inLink: Bool) -> String {
            if let text = node.text {
                return markdown ? markdownText(text, inLink: inLink) : Self.escape(Self.collapse(HTML.decode(text)))
            }
            let inner = { (link: Bool) in render(node.children, markdown: markdown, inLink: link) }
            switch node.name {
            case "br": return "\n"
            case "b", "strong": return Self.wrap(inner(inLink), "**")
            case "i", "em": return Self.wrap(inner(inLink), "*")
            case "s", "del", "strike": return Self.wrap(inner(inLink), "~~")
            case "code", "kbd", "tt", "samp":
                let code = Self.collapse(HTML.decode(node.textContent))
                guard !code.trimmingCharacters(in: .whitespaces).isEmpty else { return "" }
                return code.contains("`") ? "`` \(code) ``" : "`\(code)`"
            case "a":
                let text = Self.tidy(inner(true))
                guard let href = node.attributes["href"], let url = resolve(href, base: links.pages), !inLink else { return text }
                return "[\(text.isEmpty ? Self.escape(url.host() ?? url.absoluteString) : text)](\(Self.target(url)))"
            case "img":
                let alt = Self.tidy(Self.escape(HTML.decode(node.attributes["alt"] ?? node.attributes["title"] ?? "")))
                let name = alt.isEmpty ? Self.escape(URL(string: node.attributes["src"] ?? "")?.lastPathComponent ?? "") : alt
                if inLink { return name }
                let label = tr("discover.readme.image", name)
                guard let source = node.attributes["src"], let url = resolve(source, base: links.files) else { return label }
                return "[\(label)](\(Self.target(url)))"
            case "p", "div", "li", "tr", "h1", "h2", "h3", "h4", "h5", "h6", "blockquote", "center", "summary", "section", "figure":
                return "\n" + inner(inLink) + "\n"
            case "td", "th": return inner(inLink) + " "
            case "ul", "ol":
                return "\n" + node.children.filter { $0.name == "li" }.map { "• " + Self.tidy(render($0.children, markdown: markdown, inLink: inLink)) }
                    .joined(separator: "\n") + "\n"
            case "script", "style", "svg", "noscript", "head", "title", "template": return ""
            case "iframe", "video", "audio": return media(node)
            default: return inner(inLink)
            }
        }

        func markdownText(_ text: String, inLink: Bool) -> String {
            guard text.contains("[") || text.contains("<") else { return text }
            var text = text.replacing(/<(https:\/\/[^>\s]+)>/) { "[\($0.output.1)](\($0.output.1))" }
            text = text.replacing(/\[!\[([^\]]*)\]\(([^)\s]*)[^)]*\)\]\(([^)\s]+)[^)]*\)/) { match in
                let alt = String(match.output.1)
                guard let url = resolve(String(match.output.3), base: links.pages), !inLink else { return alt }
                return "[\(alt.isEmpty ? (url.host() ?? url.absoluteString) : alt)](\(Self.target(url)))"
            }
            text = text.replacing(/!\[([^\]]*)\]\(([^)\s]*)[^)]*\)/) { match in
                let alt = String(match.output.1)
                let name = alt.isEmpty ? (URL(string: String(match.output.2))?.lastPathComponent ?? "") : alt
                if inLink { return name }
                let label = tr("discover.readme.image", name)
                guard let url = resolve(String(match.output.2), base: links.files) else { return label }
                return "[\(label)](\(Self.target(url)))"
            }
            text = text.replacing(/\[([^\]]+)\]\(([^)\s]+)(\s+"[^"]*")?\)/) { match in
                guard let url = resolve(String(match.output.2), base: links.pages), !inLink else { return String(match.output.1) }
                return "[\(match.output.1)](\(Self.target(url)))"
            }
            return text.replacing("<", with: "\\<")
        }

        func resolve(_ reference: String, base: URL?) -> URL? {
            let reference = HTML.decode(reference).trimmingCharacters(in: .whitespaces)
            guard !reference.isEmpty, !reference.hasPrefix("#") else { return nil }
            if let url = URL(string: reference), let scheme = url.scheme {
                return scheme.lowercased() == "https" && url.host() != nil ? url : nil
            }
            if reference.hasPrefix("//") { return URL(string: "https:" + reference).flatMap { $0.host() != nil ? $0 : nil } }
            if reference.firstMatch(of: /^[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)+\//) != nil { return nil }
            guard let base, let url = URL(string: reference.hasPrefix("/") ? String(reference.dropFirst()) : reference, relativeTo: base)
            else { return nil }
            return url.absoluteURL
        }

        static func target(_ url: URL) -> String {
            url.absoluteString.replacing(" ", with: "%20").replacing("(", with: "%28").replacing(")", with: "%29")
        }

        static func escape(_ text: String) -> String {
            var output = ""
            for character in text {
                if "\\`*_[]<&~".contains(character) { output.append("\\") }
                output.append(character)
            }
            return output
        }

        static func wrap(_ text: String, _ mark: String) -> String {
            let core = text.trimmingCharacters(in: .whitespaces)
            guard !core.isEmpty, !core.contains("\n") else { return text }
            let leading = text.hasPrefix(" ") ? " " : "", trailing = text.hasSuffix(" ") ? " " : ""
            return leading + mark + core + mark + trailing
        }

        static func tidy(_ text: String) -> String {
            var lines: [String] = []
            for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
                let clean = collapse(String(line)).trimmingCharacters(in: .whitespaces)
                if clean.isEmpty, lines.last?.isEmpty == true { continue }
                lines.append(clean)
            }
            return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        }

        static func collapse(_ text: String) -> String {
            var output = ""
            output.reserveCapacity(text.utf8.count)
            var space = false
            for character in text {
                if character.isWhitespace && character != "\u{00A0}" {
                    if !space { output.append(" ") }
                    space = true
                } else {
                    output.append(character)
                    space = false
                }
            }
            return output
        }
    }

    enum HTML {
        enum Token: Equatable {
            case text(String)
            case open(name: String, attributes: [String: String], selfClosing: Bool)
            case close(String)
        }

        struct Node: Equatable {
            var name: String
            var attributes: [String: String] = [:]
            var children: [Node] = []
            var text: String?

            var textContent: String { text ?? children.map(\.textContent).joined() }
        }

        static let elements: Set<String> = [
            "a", "abbr", "address", "article", "aside", "audio", "b", "big", "blockquote", "br", "button", "caption", "center",
            "cite", "code", "col", "colgroup", "dd", "del", "details", "dfn", "div", "dl", "dt", "em", "embed", "figcaption",
            "figure", "font", "footer", "form", "h1", "h2", "h3", "h4", "h5", "h6", "head", "header", "hr", "i", "iframe", "img",
            "input", "ins", "kbd", "label", "li", "main", "mark", "nav", "noscript", "ol", "p", "picture", "pre", "q", "s",
            "samp", "script", "section", "small", "source", "span", "strike", "strong", "style", "sub", "summary", "sup", "svg",
            "table", "tbody", "td", "template", "tfoot", "th", "thead", "time", "title", "tr", "tt", "u", "ul", "var", "video", "wbr",
        ]

        static let void: Set<String> = ["br", "img", "hr", "input", "source", "wbr", "col", "embed"]

        static func tokens(_ html: String) -> [Token] {
            let bytes = Array(html.utf8)
            var tokens: [Token] = []
            var textStart = 0
            var index = 0
            func string(_ range: Range<Int>) -> String { String(decoding: bytes[range], as: UTF8.self) }
            func flushText(upTo end: Int) {
                if textStart < end { tokens.append(.text(string(textStart ..< end))) }
            }
            func isLetter(_ byte: UInt8) -> Bool { (byte >= 0x61 && byte <= 0x7A) || (byte >= 0x41 && byte <= 0x5A) }
            func isNameByte(_ byte: UInt8) -> Bool { isLetter(byte) || (byte >= 0x30 && byte <= 0x39) }
            func isSpace(_ byte: UInt8) -> Bool { byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D || byte == 0x0C }
            while index < bytes.count {
                guard bytes[index] == 0x3C else { index += 1; continue }
                let start = index
                if bytes.count - index >= 4, bytes[index + 1] == 0x21, bytes[index + 2] == 0x2D, bytes[index + 3] == 0x2D {
                    flushText(upTo: start)
                    var end = index + 4
                    while end + 2 < bytes.count, !(bytes[end] == 0x2D && bytes[end + 1] == 0x2D && bytes[end + 2] == 0x3E) { end += 1 }
                    index = end + 2 < bytes.count ? end + 3 : bytes.count
                    textStart = index
                    continue
                }
                var cursor = index + 1
                let closing = cursor < bytes.count && bytes[cursor] == 0x2F
                if closing { cursor += 1 }
                guard cursor < bytes.count, isLetter(bytes[cursor]) else { index += 1; continue }
                let nameStart = cursor
                while cursor < bytes.count, isNameByte(bytes[cursor]) { cursor += 1 }
                let name = string(nameStart ..< cursor).lowercased()
                guard cursor < bytes.count, elements.contains(name),
                      isSpace(bytes[cursor]) || bytes[cursor] == 0x3E || bytes[cursor] == 0x2F else { index += 1; continue }
                if closing {
                    while cursor < bytes.count, isSpace(bytes[cursor]) { cursor += 1 }
                    guard cursor < bytes.count, bytes[cursor] == 0x3E else { index += 1; continue }
                    flushText(upTo: start)
                    tokens.append(.close(name))
                    index = cursor + 1
                    textStart = index
                    continue
                }
                var attributes: [String: String] = [:]
                var selfClosing = false
                var closed = false
                while cursor < bytes.count {
                    while cursor < bytes.count, isSpace(bytes[cursor]) { cursor += 1 }
                    guard cursor < bytes.count else { break }
                    if bytes[cursor] == 0x3E { closed = true; cursor += 1; break }
                    if bytes[cursor] == 0x2F {
                        if cursor + 1 < bytes.count, bytes[cursor + 1] == 0x3E { selfClosing = true; closed = true; cursor += 2; break }
                        cursor += 1
                        continue
                    }
                    if bytes[cursor] == 0x3C { break }
                    let keyStart = cursor
                    while cursor < bytes.count, !isSpace(bytes[cursor]), bytes[cursor] != 0x3D, bytes[cursor] != 0x3E, bytes[cursor] != 0x2F {
                        cursor += 1
                    }
                    let key = string(keyStart ..< cursor).lowercased()
                    var probe = cursor
                    while probe < bytes.count, isSpace(bytes[probe]) { probe += 1 }
                    var value = ""
                    if probe < bytes.count, bytes[probe] == 0x3D {
                        cursor = probe + 1
                        while cursor < bytes.count, isSpace(bytes[cursor]) { cursor += 1 }
                        if cursor < bytes.count, bytes[cursor] == 0x22 || bytes[cursor] == 0x27 {
                            let quote = bytes[cursor]
                            let valueStart = cursor + 1
                            cursor = valueStart
                            while cursor < bytes.count, bytes[cursor] != quote { cursor += 1 }
                            value = string(valueStart ..< cursor)
                            cursor += 1
                        } else {
                            let valueStart = cursor
                            while cursor < bytes.count, !isSpace(bytes[cursor]), bytes[cursor] != 0x3E { cursor += 1 }
                            value = string(valueStart ..< cursor)
                        }
                    }
                    if !key.isEmpty { attributes[key] = value }
                }
                guard closed else { index += 1; continue }
                flushText(upTo: start)
                tokens.append(.open(name: name, attributes: attributes, selfClosing: selfClosing))
                index = cursor
                textStart = index
            }
            flushText(upTo: bytes.count)
            return tokens
        }

        static func tree(_ html: String) -> Node {
            var stack = [Node(name: "#root")]
            func pop() {
                let node = stack.removeLast()
                stack[stack.count - 1].children.append(node)
            }
            func closeOpen(_ names: Set<String>, upTo limits: Set<String>) {
                while stack.count > 1, let last = stack.last?.name, !limits.contains(last) {
                    guard names.contains(last) else { return }
                    pop()
                }
            }
            for token in tokens(html) {
                switch token {
                case let .text(text):
                    stack[stack.count - 1].children.append(Node(name: "", text: text))
                case let .open(name, attributes, selfClosing):
                    switch name {
                    case "li": closeOpen(["li", "p"], upTo: ["ul", "ol"])
                    case "tr": closeOpen(["td", "th", "tr"], upTo: ["table", "thead", "tbody", "tfoot"])
                    case "td", "th": closeOpen(["td", "th", "p"], upTo: ["tr", "table"])
                    case "p", "div", "table", "ul", "ol", "h1", "h2", "h3", "h4", "h5", "h6", "pre", "details":
                        closeOpen(["p"], upTo: [])
                    default: break
                    }
                    let node = Node(name: name, attributes: attributes)
                    if selfClosing || void.contains(name) {
                        stack[stack.count - 1].children.append(node)
                    } else {
                        stack.append(node)
                    }
                case let .close(name):
                    guard stack.dropFirst().contains(where: { $0.name == name }) else { continue }
                    while let last = stack.last?.name, last != name { pop() }
                    pop()
                }
            }
            while stack.count > 1 { pop() }
            return stack[0]
        }

        static let entities: [String: String] = [
            "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": "\u{00A0}", "copy": "©", "reg": "®",
            "trade": "™", "hellip": "…", "mdash": "—", "ndash": "–", "laquo": "«", "raquo": "»", "times": "×", "middot": "·",
            "bull": "•", "rarr": "→", "larr": "←", "uarr": "↑", "darr": "↓", "deg": "°", "plusmn": "±", "le": "≤", "ge": "≥",
            "ne": "≠", "asymp": "≈", "ensp": " ", "emsp": " ", "thinsp": " ", "check": "✓", "lsquo": "‘", "rsquo": "’",
            "ldquo": "“", "rdquo": "”", "minus": "−", "divide": "÷", "infin": "∞", "sup2": "²", "frac12": "½",
        ]

        static func decode(_ text: String) -> String {
            guard text.contains("&") else { return text }
            return text.replacing(/&(#[0-9]{1,7}|#[xX][0-9A-Fa-f]{1,6}|[A-Za-z][A-Za-z0-9]{1,31});/) { match in
                let name = String(match.output.1)
                if name.hasPrefix("#") {
                    let digits = name.dropFirst()
                    let value = digits.first == "x" || digits.first == "X" ? UInt32(digits.dropFirst(), radix: 16) : UInt32(digits)
                    return value.flatMap(Unicode.Scalar.init).map { String(Character($0)) } ?? String(match.output.0)
                }
                return entities[name] ?? String(match.output.0)
            }
        }
    }

    private static let cache = Mutex<[Int: [Block]]>([:])

    static func cachedBlocks(_ text: String, repo: String?) -> [Block] {
        var hasher = Hasher()
        hasher.combine(text)
        hasher.combine(repo)
        hasher.combine(Strings.language)
        let key = hasher.finalize()
        if let found = cache.withLock({ $0[key] }) { return found }
        let blocks = blocks(text, links: Links(repo: repo))
        cache.withLock { cache in
            if cache.count > 32 { cache.removeAll() }
            cache[key] = blocks
        }
        return blocks
    }
}

struct ReadmeText: View {
    let text: String
    let repo: String?

    var body: some View {
        ReadmeBlocks(blocks: ReadmeDocument.cachedBlocks(text, repo: repo))
            .textSelection(.enabled)
    }
}

struct ReadmeBlocks: View {
    let blocks: [ReadmeDocument.Block]

    var body: some View {
        VStack(alignment: .leading, spacing: Space.m) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                ReadmeBlockView(block: block)
            }
        }
    }
}

struct ReadmeBlockView: View {
    let block: ReadmeDocument.Block
    @State private var expanded = false
    @Environment(\.deckPalette) private var palette

    var body: some View {
        switch block {
        case let .markdown(block):
            MarkdownText.BlockView(block: block)
        case let .table(table):
            ReadmeTable(table: table)
        case let .details(summary, blocks):
            DisclosureGroup(isExpanded: $expanded) {
                ReadmeBlocks(blocks: blocks).padding(.top, Space.s)
            } label: {
                Text(MarkdownText.inline(summary, accent: palette.accent.color)).font(Typo.body.weight(.semibold))
            }
        }
    }
}

struct ReadmeTable: View {
    let table: ReadmeDocument.Table
    @Environment(\.deckPalette) private var palette

    var body: some View {
        let columns = table.columns
        ScrollView(.horizontal) {
            Grid(alignment: .leading, horizontalSpacing: 0, verticalSpacing: 0) {
                ForEach(table.rows.indices, id: \.self) { index in
                    let row = table.rows[index]
                    if index > 0 {
                        Rectangle().fill(palette.separator.color).frame(height: 1).gridCellUnsizedAxes(.horizontal)
                    }
                    let used = row.cells.reduce(0) { $0 + $1.span }
                    let group = (row.cells.count == 1 && row.cells[0].span > 1)
                        || (row.cells.count > 1 && !row.cells[0].text.isEmpty && row.cells.dropFirst().allSatisfy(\.text.isEmpty))
                    GridRow {
                        ForEach(row.cells.indices, id: \.self) { column in
                            cell(row.cells[column], bold: row.header || group)
                                .gridCellColumns(row.cells[column].span)
                        }
                        if used < columns {
                            Color.clear.frame(height: 1).gridCellColumns(columns - used)
                        }
                    }
                    .background(row.header || group ? palette.surface.color : Color.clear)
                }
            }
            .overlay(RoundedRectangle(cornerRadius: Radius.control).strokeBorder(palette.separator.color, lineWidth: 1))
            .clipShape(.rect(cornerRadius: Radius.control))
        }
        .scrollIndicators(.automatic)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(tr("a11y.table", DeckFormat.count(columns), DeckFormat.count(table.rows.count)))
    }

    private func cell(_ cell: ReadmeDocument.Table.Cell, bold: Bool) -> some View {
        let alignment: Alignment = switch cell.alignment {
        case .leading: .leading
        case .center: .center
        case .trailing: .trailing
        }
        return Text(MarkdownText.inline(cell.text, accent: palette.accent.color))
            .font(bold ? Typo.callout.weight(.semibold) : Typo.callout)
            .multilineTextAlignment(cell.alignment == .trailing ? .trailing : cell.alignment == .center ? .center : .leading)
            .fixedSize(horizontal: false, vertical: true)
            .frame(minWidth: 48, maxWidth: cell.span > 1 ? .infinity : 280, alignment: alignment)
            .padding(.horizontal, Space.m)
            .padding(.vertical, Space.s)
    }
}
