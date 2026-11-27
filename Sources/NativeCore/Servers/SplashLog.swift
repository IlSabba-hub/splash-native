import Foundation

public enum SplashLog {
    public static func tail(_ file: URL, maximumBytes: Int = 256 * 1024) -> [String]? {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return nil }
        let start = size > UInt64(maximumBytes) ? size - UInt64(maximumBytes) : 0
        try? handle.seek(toOffset: start)
        guard let data = try? handle.readToEnd() else { return [] }
        var lines = String(decoding: data, as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        if start > 0, !lines.isEmpty { lines.removeFirst() }
        return lines
    }

    public struct RequestLine: Sendable, Equatable {
        public enum Kind: String, Sendable { case started = "Started", done = "Done" }
        public let kind: Kind
        public let clock: String
        public let request: Int
        public let input: Int?
        public let cached: Int?
        public let output: Int?
        public let ttftSeconds: Double?
        public let tokensPerSecond: Double?
        public let tokensPerCycle: Double?
    }

    public static func request(_ line: String) -> RequestLine? {
        let parts = line.components(separatedBy: " · ")
        guard parts.count >= 2, let head = parts.first, head.count > 9 else { return nil }
        let clock = String(head.prefix(8))
        guard clock.filter({ $0 == ":" }).count == 2, let kind = RequestLine.Kind(rawValue: String(head.dropFirst(9))) else { return nil }
        var fields: [String: String] = [:]
        var tokensPerSecond: Double?
        var tokensPerCycle: Double?
        for part in parts.dropFirst() {
            if part.hasSuffix(" tok/s") { tokensPerSecond = number(String(part.dropLast(6))); continue }
            if part.hasSuffix(" tok/cycle") { tokensPerCycle = number(String(part.dropLast(10))); continue }
            guard let space = part.firstIndex(of: " ") else { continue }
            fields[String(part[..<space])] = String(part[part.index(after: space)...])
        }
        guard let request = fields["request"].flatMap(integer) else { return nil }
        let ttft = fields["TTFT"].flatMap { $0.hasSuffix("s") ? number(String($0.dropLast())) : nil }
        return RequestLine(kind: kind, clock: clock, request: request, input: fields["input"].flatMap(integer),
                           cached: fields["cached"].flatMap(integer), output: fields["output"].flatMap(integer),
                           ttftSeconds: ttft, tokensPerSecond: tokensPerSecond, tokensPerCycle: tokensPerCycle)
    }

    public static func restoreSeconds(_ line: String) -> Double? {
        guard let range = line.range(of: "Weights restored in "), line.hasSuffix(" s") else { return nil }
        return number(String(line[range.upperBound...].dropLast(2)))
    }

    public static func lastRestore(in folder: URL, files: Int = 8) -> (seconds: Double, clock: String, file: URL)? {
        let logs = ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "log" }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
        for file in logs.prefix(files) {
            for line in (tail(file) ?? []).reversed() {
                if let seconds = restoreSeconds(line) { return (seconds, String(line.prefix(8)), file) }
            }
        }
        return nil
    }

    static func integer(_ text: String) -> Int? {
        Int(text.replacingOccurrences(of: ",", with: ""))
    }

    static func number(_ text: String) -> Double? {
        Double(text.replacingOccurrences(of: ",", with: ""))
    }
}
