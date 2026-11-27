import Foundation

public struct LinkedSplash: Sendable, Equatable {
    public let version: String
    public let root: URL

    public static func find(_ locations: InstallationLocations = InstallationLocations()) -> LinkedSplash? {
        InstallationScanner.scan(locations).first { $0.kind == .keg && $0.linked }
            .flatMap { installation in installation.version.map { LinkedSplash(version: $0, root: installation.root) } }
    }
}

enum ReleaseFile {
    static func version(in root: URL) -> String? {
        struct Release: Decodable { let version: String }
        guard let data = try? Data(contentsOf: root.appending(path: "release.json")) else { return nil }
        return (try? JSONDecoder().decode(Release.self, from: data))?.version
    }
}
