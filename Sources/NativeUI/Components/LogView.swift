import SwiftUI

public struct LogLine: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        case done
        case phase
        case warning
        case error
        case plain
    }

    public let time: String?
    public let message: String
    public let kind: Kind

    public init(_ line: String) {
        if let match = line.prefixMatch(of: #/(?:\d{4}-\d{2}-\d{2} )?\d{2}:\d{2}:\d{2}(?:\.\d+)? /#) {
            time = String(match.output.dropLast())
            message = String(line[match.range.upperBound...])
        } else {
            time = nil
            message = line
        }
        kind = Self.classify(message)
    }

    static func classify(_ message: String) -> Kind {
        if message.localizedCaseInsensitiveContains("error") || message.localizedCaseInsensitiveContains("failed")
            || message.hasPrefix("Traceback") { return .error }
        if message.localizedCaseInsensitiveContains("warning") { return .warning }
        if message.hasPrefix("Ready") || message.hasPrefix("Done") { return .done }
        if message.hasPrefix("Loading") || message.hasPrefix("Warming") || message.hasPrefix("Started") || message.hasPrefix("Weights") {
            return .phase
        }
        return .plain
    }
}

public struct LogView: View {
    private let lines: [String]
    private let follow: Bool
    private let highlight: String
    @Environment(\.nativePalette) private var palette

    public init(_ lines: [String], follow: Bool = true, highlight: String = "") {
        self.lines = lines
        self.follow = follow
        self.highlight = highlight
    }

    public var body: some View {
        ScrollViewReader { proxy in
            ScrollView([.vertical]) {
                LazyVStack(alignment: .leading, spacing: 1) {
                    ForEach(lines.indices, id: \.self) { index in
                        Text(Self.attributed(LogLine(lines[index]), palette: palette, highlight: highlight))
                            .font(Typo.code)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .id(index)
                    }
                }
                .textSelection(.enabled)
                .padding(Space.m)
            }
            .background(palette.rail.color)
            .onAppear { if follow, !lines.isEmpty { proxy.scrollTo(lines.count - 1, anchor: .bottom) } }
            .onChange(of: lines.last) { if follow, !lines.isEmpty { proxy.scrollTo(lines.count - 1, anchor: .bottom) } }
        }
    }

    static func attributed(_ line: LogLine, palette: Palette, highlight: String = "") -> AttributedString {
        var result = AttributedString()
        if let time = line.time {
            var part = AttributedString(time + " ")
            part.foregroundColor = palette.ready.color.opacity(0.75)
            result += part
        }
        var message = AttributedString(line.message)
        message.foregroundColor = color(line.kind, palette).color
        if line.kind == .error || line.kind == .warning { message.font = Typo.code.weight(.semibold) }
        result += message
        let query = highlight.trimmingCharacters(in: .whitespaces)
        if !query.isEmpty {
            var searchRange = result.startIndex ..< result.endIndex
            while let found = result[searchRange].range(of: query, options: .caseInsensitive) {
                result[found].backgroundColor = palette.accent.color.opacity(0.35)
                result[found].foregroundColor = palette.text.color
                searchRange = found.upperBound ..< result.endIndex
            }
        }
        return result
    }

    static func color(_ kind: LogLine.Kind, _ palette: Palette) -> RGB {
        switch kind {
        case .done: palette.ready
        case .phase: palette.starting
        case .warning: palette.starting
        case .error: palette.error
        case .plain: palette.textSecondary
        }
    }
}
