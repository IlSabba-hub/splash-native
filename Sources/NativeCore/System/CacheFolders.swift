import Foundation

public struct CacheFolder: Sendable, Equatable, Identifiable {
    public enum Origin: Sendable, Equatable, Hashable {
        case splashDefault(version: String)
        case configuration(name: String)
    }

    public struct Namespace: Sendable, Equatable, Identifiable {
        public let name: String
        public let allocatedBytes: UInt64
        public let modified: Date?
        public var id: String { name }
    }

    public let url: URL
    public let written: String
    public let origins: [Origin]
    public let exists: Bool
    public let allocatedBytes: UInt64?
    public let namespaces: [Namespace]
    public let otherEntries: Int

    public var id: String { url.path }
}

public enum CacheFolders {
    public static func defaultRoot(in schema: ServeSchema) -> String? {
        schema.parameter("--cache-dir")?.helpDefault
    }

    public static func isNamespace(_ name: String) -> Bool {
        name.count == 32 && name.allSatisfy(\.isHexDigit)
    }

    public static func roots(schemas: [VersionSchema], configurations: [Configuration]) -> [(written: String, url: URL, origins: [CacheFolder.Origin])] {
        var order: [String] = []
        var found: [String: (written: String, url: URL, origins: [CacheFolder.Origin])] = [:]
        func add(_ written: String, _ origin: CacheFolder.Origin) {
            let url = URL(filePath: expandTilde(written)).standardizedFileURL
            if found[url.path] == nil {
                order.append(url.path)
                found[url.path] = (written, url, [])
            }
            if !found[url.path]!.origins.contains(origin) { found[url.path]!.origins.append(origin) }
        }
        for schema in schemas {
            if let root = defaultRoot(in: schema.serve) {
                add(root, .splashDefault(version: schema.installation.version ?? schema.serve.reportedVersion))
            }
        }
        for configuration in configurations {
            if case let .value(path)? = configuration.parameters["--cache-dir"] { add(path, .configuration(name: configuration.name)) }
        }
        return order.compactMap { found[$0] }
    }

    public static func measure(written: String, url: URL, origins: [CacheFolder.Origin]) -> CacheFolder {
        let manager = FileManager.default
        var isDirectory: ObjCBool = false
        guard manager.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return CacheFolder(url: url, written: written, origins: origins, exists: false, allocatedBytes: nil, namespaces: [], otherEntries: 0)
        }
        guard let entries = try? manager.contentsOfDirectory(at: url, includingPropertiesForKeys: [.contentModificationDateKey]) else {
            return CacheFolder(url: url, written: written, origins: origins, exists: true, allocatedBytes: nil, namespaces: [], otherEntries: 0)
        }
        var namespaces: [CacheFolder.Namespace] = []
        var other = 0
        var total: UInt64 = 0
        for entry in entries {
            let bytes = allocatedSize(entry)
            total += bytes
            if isNamespace(entry.lastPathComponent) {
                let modified = try? entry.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
                namespaces.append(.init(name: entry.lastPathComponent, allocatedBytes: bytes, modified: modified))
            } else {
                other += 1
            }
        }
        namespaces.sort { ($0.modified ?? .distantPast) > ($1.modified ?? .distantPast) }
        return CacheFolder(url: url, written: written, origins: origins, exists: true, allocatedBytes: total,
                           namespaces: namespaces, otherEntries: other)
    }

    public static func scan(schemas: [VersionSchema], configurations: [Configuration]) -> [CacheFolder] {
        roots(schemas: schemas, configurations: configurations).map { measure(written: $0.written, url: $0.url, origins: $0.origins) }
    }

    static func allocatedSize(_ url: URL) -> UInt64 {
        let keys: Set<URLResourceKey> = [.totalFileAllocatedSizeKey, .isDirectoryKey]
        guard let values = try? url.resourceValues(forKeys: keys) else { return 0 }
        guard values.isDirectory == true else { return UInt64(values.totalFileAllocatedSize ?? 0) }
        var total: UInt64 = 0
        let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: Array(keys))
        while let item = enumerator?.nextObject() as? URL {
            total += UInt64((try? item.resourceValues(forKeys: keys))?.totalFileAllocatedSize ?? 0)
        }
        return total
    }
}
