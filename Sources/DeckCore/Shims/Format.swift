import Foundation

enum Format {
    static func size(_ bytes: Int64) -> String {
        let gigabytes = Double(bytes) / 1e9
        guard gigabytes >= 1 else { return bytes.formatted(.byteCount(style: .file)) }
        return "\(gigabytes.formatted(.number.precision(.fractionLength(gigabytes < 10 ? 1 : 0)))) GB"
    }

    static func gigabytes(_ count: Int) -> Int64 { Int64(count) * 1_000_000_000 }

    static func memory(_ bytes: Int64) -> String {
        let gigabytes = Double(bytes) / Double(1 << 30)
        guard gigabytes >= 1 else { return bytes.formatted(.byteCount(style: .memory)) }
        return "\(gigabytes.formatted(.number.precision(.fractionLength(0...1)))) GB"
    }

    static func count(_ value: Int) -> String {
        value.formatted(.number.notation(.compactName))
    }

    static func whole(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(0)))
    }

    static func latency(_ duration: Duration) -> (String, String) {
        let milliseconds = (Double(duration.components.seconds) * 1000 + Double(duration.components.attoseconds) / 1e15).rounded()
        return milliseconds < 1000 ? (whole(milliseconds), "ms")
            : ((milliseconds / 1000).formatted(.number.precision(.fractionLength(1))), "s")
    }

    static func parts(_ text: String) -> (String, String?) {
        guard let space = text.lastIndex(of: " ") else { return (text, nil) }
        return (String(text[..<space]), String(text[text.index(after: space)...]))
    }

    static func seconds(_ seconds: Double) -> String {
        let tenths = (seconds * 10).rounded() / 10
        if tenths < 10 { return "\(tenths.formatted(.number.precision(.fractionLength(1))))s" }
        let whole = Int(seconds.rounded())
        return whole < 60 ? "\(whole)s" : "\(whole / 60)m \(whole % 60)s"
    }
}
