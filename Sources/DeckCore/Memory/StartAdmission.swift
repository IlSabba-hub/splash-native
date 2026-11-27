import Foundation

public enum StartAdmission {
    public static let current: Policy = .warnUnlessUnlimitedNeighbour

    public enum Policy: String, Codable, Sendable, Equatable, CaseIterable {
        case warnUnlessUnlimitedNeighbour
        case blockOverBudget
    }

    public struct Neighbour: Sendable, Equatable {
        public enum LimitSource: String, Sendable, Equatable {
            case status
            case commandLine
        }

        public let name: String
        public let port: Int
        public let limitBytes: UInt64?
        public let source: LimitSource

        public init(name: String, port: Int, limitBytes: UInt64?, source: LimitSource) {
            self.name = name
            self.port = port
            self.limitBytes = limitBytes
            self.source = source
        }

        public var unlimited: Bool { limitBytes == nil }

        public static func limit(status: StatusSnapshot?, arguments: [String]?) -> (UInt64?, LimitSource)? {
            if let configured = status?.budget?.configuredMemoryLimitBytes {
                return (configured > 0 ? UInt64(configured) : nil, .status)
            }
            guard let arguments else { return nil }
            let value = ProcessArguments(executable: "", argv: arguments).value(of: "--max-memory")
            guard let value, value != "auto" else { return (nil, .commandLine) }
            return (SizeText.bytes(value), .commandLine)
        }
    }

    public enum Decision: Sendable, Equatable {
        case admit
        case warn(excess: UInt64)
        case block(Block)

        public var blocks: Bool { if case .block = self { true } else { false } }
    }

    public enum Block: Sendable, Equatable {
        case unlimitedNeighbours([Neighbour])
        case overBudget(excess: UInt64)
    }

    public static func decide(_ verdict: MemoryGuard.Verdict, neighbours: [Neighbour], policy: Policy = current) -> Decision {
        switch policy {
        case .warnUnlessUnlimitedNeighbour:
            let unlimited = neighbours.filter(\.unlimited)
            if !unlimited.isEmpty { return .block(.unlimitedNeighbours(unlimited)) }
            return verdict.fits ? .admit : .warn(excess: verdict.excess)
        case .blockOverBudget:
            return verdict.fits ? .admit : .block(.overBudget(excess: verdict.excess))
        }
    }
}

public enum SizeText {
    public static func bytes(_ text: String) -> UInt64? {
        let trimmed = text.trimmingCharacters(in: .whitespaces).uppercased()
        let units: [Character: UInt64] = ["K": 1 << 10, "M": 1 << 20, "G": 1 << 30]
        if let last = trimmed.last, let unit = units[last] {
            return Double(trimmed.dropLast()).map { UInt64($0 * Double(unit)) }
        }
        return UInt64(trimmed)
    }
}
