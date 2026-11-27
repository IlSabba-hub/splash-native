import AppKit
import SwiftUI

public struct UserBubble: View {
    private let text: String
    @Environment(\.nativePalette) private var palette

    public init(_ text: String) {
        self.text = text
    }

    public var body: some View {
        HStack {
            Spacer(minLength: Space.xxl * 2)
            Text(verbatim: text)
                .font(Typo.body)
                .textSelection(.enabled)
                .padding(.horizontal, Space.l)
                .padding(.vertical, Space.m)
                .background(palette.surfaceRaised.color, in: .rect(cornerRadius: Radius.bubble))
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(tr("chat.a11y.user", text))
    }
}

public struct AssistantHeader: View {
    private let model: String
    @Environment(\.nativePalette) private var palette

    public init(_ model: String) {
        self.model = model
    }

    public var body: some View {
        Text(verbatim: model)
            .font(Typo.code)
            .foregroundStyle(palette.textSecondary.color)
            .lineLimit(1)
            .truncationMode(.middle)
            .textSelection(.enabled)
    }
}

public struct ThoughtDisclosure<Label: View, Content: View>: View {
    @Binding private var expanded: Bool
    private let canToggle: Bool
    private let label: Label
    private let content: Content
    @Environment(\.nativePalette) private var palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(expanded: Binding<Bool>, canToggle: Bool, @ViewBuilder label: () -> Label, @ViewBuilder content: () -> Content) {
        _expanded = expanded
        self.canToggle = canToggle
        self.label = label()
        self.content = content()
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            Button {
                withNativeAnimation(.settle, reduceMotion: reduceMotion) { expanded.toggle() }
            } label: {
                HStack(spacing: Space.xs) {
                    if canToggle {
                        Image(systemName: "chevron.right")
                            .font(Typo.caption.weight(.semibold))
                            .rotationEffect(.degrees(expanded ? 90 : 0))
                            .accessibilityHidden(true)
                    }
                    label
                }
                .font(Typo.callout)
                .foregroundStyle(palette.textSecondary.color)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .disabled(!canToggle)
            .accessibilityHint(canToggle ? tr(expanded ? "chat.a11y.hideReasoning" : "chat.a11y.showReasoning") : "")
            if expanded, canToggle {
                content
                    .font(Typo.callout)
                    .foregroundStyle(palette.textSecondary.color)
                    .padding(.leading, Space.m)
                    .overlay(alignment: .leading) { Rectangle().fill(palette.separator.color).frame(width: 2) }
                    .transition(NativeMotion.comingAndGoing(reduceMotion: reduceMotion))
            }
        }
    }
}

public struct CodeBlock: View {
    private let language: String?
    private let code: String
    @State private var copied = false
    @Environment(\.nativePalette) private var palette

    public init(language: String?, code: String) {
        self.language = language
        self.code = code
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: Space.s) {
                Text(verbatim: language ?? "")
                    .font(Typo.code)
                    .foregroundStyle(palette.textSecondary.color)
                Spacer()
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(code, forType: .string)
                    copied = true
                } label: {
                    Label(tr(copied ? "code.copied" : "code.copy"), systemImage: copied ? "checkmark" : "doc.on.doc")
                        .font(Typo.caption)
                        .foregroundStyle((copied ? palette.ready : palette.textSecondary).color)
                        .padding(.horizontal, Space.s)
                        .padding(.vertical, Space.xxs + 1)
                        .background(palette.surfaceRaised.color, in: .rect(cornerRadius: Radius.small))
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, Space.m)
            .padding(.vertical, Space.xs + 1)
            .background(palette.surface.color)
            Rectangle().fill(palette.separator.color).frame(height: 1)
            ScrollView(.horizontal) {
                Text(SyntaxHighlighter.highlight(code, language: language, palette: palette))
                    .font(Typo.codeBlock)
                    .lineSpacing(2)
                    .fixedSize(horizontal: true, vertical: true)
                    .textSelection(.enabled)
                    .padding(Space.m)
            }
            .background(palette.column.color)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .clipShape(.rect(cornerRadius: Radius.control))
        .overlay(RoundedRectangle(cornerRadius: Radius.control).strokeBorder(palette.separator.color, lineWidth: 1))
        .onChange(of: code) { copied = false }
        .task(id: copied) {
            guard copied else { return }
            try? await Task.sleep(for: .seconds(2))
            copied = false
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(tr("a11y.codeBlock", language ?? ""))
    }
}

public enum SyntaxHighlighter {
    public enum Kind: Sendable, Equatable {
        case plain, keyword, string, number, comment, tag, attribute
    }

    public struct Token: Sendable, Equatable {
        public let kind: Kind
        public let text: String
    }

    static let keywords: [String: Set<String>] = {
        let c: Set<String> = ["if", "else", "for", "while", "do", "switch", "case", "default", "break", "continue", "return", "struct",
                              "enum", "union", "typedef", "static", "const", "void", "int", "char", "float", "double", "long", "unsigned",
                              "sizeof", "include", "define", "class", "public", "private", "protected", "namespace", "template", "new",
                              "delete", "true", "false", "nullptr", "auto", "virtual", "using"]
        let js: Set<String> = ["function", "const", "let", "var", "if", "else", "for", "while", "do", "return", "class", "extends", "new",
                               "this", "import", "export", "from", "default", "async", "await", "try", "catch", "finally", "throw",
                               "typeof", "instanceof", "in", "of", "true", "false", "null", "undefined", "switch", "case", "break",
                               "continue", "interface", "type", "enum", "implements", "public", "private", "readonly"]
        let python: Set<String> = ["def", "class", "return", "if", "elif", "else", "for", "while", "in", "not", "and", "or", "is",
                                   "import", "from", "as", "with", "try", "except", "finally", "raise", "lambda", "yield", "pass",
                                   "break", "continue", "True", "False", "None", "async", "await", "global", "nonlocal", "self"]
        let swift: Set<String> = ["func", "let", "var", "if", "else", "guard", "for", "in", "while", "return", "struct", "class", "enum",
                                  "protocol", "extension", "import", "public", "private", "internal", "static", "self", "Self", "true",
                                  "false", "nil", "switch", "case", "default", "try", "throws", "async", "await", "some", "any",
                                  "init", "where", "break", "continue", "defer", "do", "catch", "final", "override", "mutating"]
        let rust: Set<String> = ["fn", "let", "mut", "if", "else", "for", "in", "while", "loop", "return", "struct", "enum", "impl",
                                 "trait", "pub", "use", "mod", "match", "self", "Self", "true", "false", "const", "static", "async",
                                 "await", "move", "ref", "where", "type", "crate", "super", "dyn", "unsafe"]
        let go: Set<String> = ["func", "var", "const", "if", "else", "for", "range", "return", "type", "struct", "interface", "package",
                               "import", "go", "defer", "chan", "map", "switch", "case", "default", "break", "continue", "true",
                               "false", "nil", "select"]
        let shell: Set<String> = ["if", "then", "else", "elif", "fi", "for", "while", "do", "done", "case", "esac", "in", "function",
                                  "return", "export", "local", "echo", "set", "unset"]
        let json: Set<String> = ["true", "false", "null"]
        return ["c": c, "cpp": c, "c++": c, "h": c, "javascript": js, "js": js, "typescript": js, "ts": js, "jsx": js, "tsx": js,
                "python": python, "py": python, "swift": swift, "rust": rust, "rs": rust, "go": go, "bash": shell, "sh": shell,
                "shell": shell, "zsh": shell, "json": json, "css": [], "html": [], "xml": []]
    }()

    static let hashComments: Set<String> = ["python", "py", "bash", "sh", "shell", "zsh", "yaml", "yml", "toml", "ruby", "rb"]
    static let markup: Set<String> = ["html", "xml", "svg"]

    public static func tokens(_ code: String, language: String?) -> [Token] {
        let language = language?.lowercased() ?? ""
        let words = keywords[language] ?? keywords["javascript"] ?? []
        let hash = hashComments.contains(language)
        let isMarkup = markup.contains(language)
        let characters = Array(code)
        var tokens: [Token] = []
        var plain = ""
        var index = 0
        func emit(_ kind: Kind, _ end: Int) {
            if !plain.isEmpty { tokens.append(Token(kind: .plain, text: plain)); plain = "" }
            tokens.append(Token(kind: kind, text: String(characters[index ..< end])))
            index = end
        }
        func starts(_ text: String) -> Bool {
            let needle = Array(text)
            return index + needle.count <= characters.count && Array(characters[index ..< index + needle.count]) == needle
        }
        func find(_ text: String, from start: Int) -> Int? {
            let needle = Array(text)
            var cursor = start
            while cursor + needle.count <= characters.count {
                if Array(characters[cursor ..< cursor + needle.count]) == needle { return cursor + needle.count }
                cursor += 1
            }
            return nil
        }
        func lineEnd(from start: Int) -> Int {
            var cursor = start
            while cursor < characters.count, characters[cursor] != "\n" { cursor += 1 }
            return cursor
        }
        while index < characters.count {
            let c = characters[index]
            if isMarkup, starts("<!--") {
                emit(.comment, find("-->", from: index + 4) ?? characters.count)
            } else if isMarkup, c == "<" {
                var end = index + 1
                if end < characters.count, characters[end] == "/" || characters[end] == "!" { end += 1 }
                while end < characters.count, characters[end].isLetter || characters[end].isNumber || characters[end] == "-" { end += 1 }
                emit(.tag, end)
            } else if isMarkup, c == ">" || (c == "/" && index + 1 < characters.count && characters[index + 1] == ">") {
                emit(.tag, c == ">" ? index + 1 : index + 2)
            } else if !isMarkup, !hash, starts("//") {
                emit(.comment, lineEnd(from: index))
            } else if !isMarkup, starts("/*") {
                emit(.comment, find("*/", from: index + 2) ?? characters.count)
            } else if hash, c == "#" {
                emit(.comment, lineEnd(from: index))
            } else if c == "\"" || c == "'" || c == "`" {
                var end = index + 1
                while end < characters.count, characters[end] != c, !(c != "`" && characters[end] == "\n") {
                    end += characters[end] == "\\" ? 2 : 1
                }
                emit(.string, min(end + 1, characters.count))
            } else if c.isNumber, plain.last.map({ !($0.isLetter || $0 == "_") }) ?? true {
                var end = index
                while end < characters.count, characters[end].isHexDigit || "._xX".contains(characters[end]) { end += 1 }
                emit(.number, end)
            } else if c.isLetter || c == "_" {
                var end = index
                while end < characters.count, characters[end].isLetter || characters[end].isNumber || characters[end] == "_" || (isMarkup && characters[end] == "-") {
                    end += 1
                }
                let word = String(characters[index ..< end])
                if isMarkup, end < characters.count, characters[end] == "=" {
                    emit(.attribute, end)
                } else if !isMarkup, words.contains(word) {
                    emit(.keyword, end)
                } else {
                    plain += word
                    index = end
                }
            } else {
                plain.append(c)
                index += 1
            }
        }
        if !plain.isEmpty { tokens.append(Token(kind: .plain, text: plain)) }
        return tokens
    }

    public static func highlight(_ code: String, language: String?, palette: Palette) -> AttributedString {
        var result = AttributedString()
        for token in tokens(code, language: language) {
            var part = AttributedString(token.text)
            part.foregroundColor = color(token.kind, palette).color
            result += part
        }
        return result
    }

    static func color(_ kind: Kind, _ palette: Palette) -> RGB {
        switch kind {
        case .plain: palette.text
        case .keyword: palette.accent
        case .string: palette.ready
        case .number: palette.starting
        case .comment: palette.textTertiary
        case .tag: palette.foundOutside
        case .attribute: palette.starting
        }
    }
}

#Preview("Pezzi della chat") {
    @Previewable @State var expanded = true
    VStack(alignment: .leading, spacing: Space.l) {
        UserBubble(tr("preview.chat.question"))
        AssistantHeader("nativ-community/Inkling-2-Mini-nvfp4")
        ThoughtDisclosure(expanded: $expanded, canToggle: true) {
            Text(tr("chat.line.thought"))
        } content: {
            Text(tr("preview.chat.reasoning"))
        }
        CodeBlock(language: "python", code: "def kv_bytes(layers, heads, dim, tokens):\n    # chiavi e valori, int8\n    return 2 * layers * heads * dim * tokens\n")
    }
    .padding(Space.xl)
    .frame(width: 640)
    .background(Palette.standard.background.color)
    .nativeTheme()
}
