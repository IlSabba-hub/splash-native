import Foundation

public struct SSDOffload: Sendable, Equatable {
    public enum Part: String, Sendable, Equatable, CaseIterable {
        case experts
        case pleTable
        case kvOnSSD
    }

    public let family: String
    public let parts: [Part]
    public static func flag(_ part: Part) -> String? {
        switch part {
        case .experts: "--expert-memory"
        case .pleTable: "--ple-memory"
        case .kvOnSSD: "--max-cache-disk"
        }
    }

    public var nothing: Bool { parts.isEmpty }

    public init(family: String, parts: [Part]) {
        self.family = family
        self.parts = parts
    }

    public static func of(_ geometry: FamilyGeometry) -> SSDOffload {
        var parts: [Part] = []
        if geometry.experts { parts.append(.experts) }
        if geometry.pleTable { parts.append(.pleTable) }
        if geometry.sparseKv { parts.append(.kvOnSSD) }
        return SSDOffload(family: geometry.family, parts: parts)
    }
}

extension NativeModel {
    public func ssdOffload(_ configuration: Configuration) -> SSDOffload? {
        guard let installation = configuration.installation(among: installations),
              let rules = SplashMemoryRules.of(version: installation.version),
              let geometry = FamilyGeometry.of(family: memoryFamily(of: configuration, in: installation), rules: rules) else { return nil }
        return .of(geometry)
    }
}

extension NativeModel {
    public func memoryFamily(of configuration: Configuration, in installation: SplashInstallation) -> String? {
        family(of: configuration, in: installation) ?? Self.waitingDraftFamily(configuration)
    }

    nonisolated public static func waitingDraftFamily(_ configuration: Configuration) -> String? {
        guard configuration.isLocal, ConfigurationFiles.missing(configuration).contains(where: { $0.flag == nil }),
              case .value(let draft)? = configuration.parameters["--draft-model"] else { return nil }
        return draftFamily(directory: URL(filePath: expandTilde(draft)))
    }

    nonisolated public static func draftFamily(directory: URL) -> String? {
        guard let text = try? String(contentsOf: directory.appending(path: "README.md"), encoding: .utf8) else { return nil }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
        guard lines.first == "---", let end = lines.dropFirst().firstIndex(of: "---") else { return nil }
        var bases: [String] = []
        var inBase = false
        for line in lines[1 ..< end] {
            if line.hasPrefix("base_model:") {
                let value = line.dropFirst("base_model:".count).trimmingCharacters(in: .whitespaces)
                if value.isEmpty { inBase = true } else { bases.append(value) }
            } else if inBase, line.hasPrefix("- ") {
                bases.append(String(line.dropFirst(2)).trimmingCharacters(in: .whitespaces))
            } else {
                inBase = false
            }
        }
        let families = Set(FamilyGeometry.splash173.map(\.family))
        return bases.lazy.compactMap { $0.split(separator: "/").last.map(String.init) }.first { families.contains($0) }
    }
}
