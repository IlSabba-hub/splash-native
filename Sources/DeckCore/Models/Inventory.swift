import Darwin
import Foundation

func realPath(_ path: String) -> String {
    guard let resolved = realpath(path, nil) else { return path }
    defer { free(resolved) }
    return String(cString: resolved)
}

public struct DiskFile: Sendable, Hashable {
    public struct Key: Sendable, Hashable {
        public let device: Int64
        public let inode: UInt64
    }

    public let path: String
    public let real: String
    public let bytes: Int64
    public let key: Key
    public let links: Int

    public static func at(_ path: String) -> DiskFile? {
        var info = stat()
        guard stat(path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else { return nil }
        let real = realPath(path)
        return DiskFile(path: path, real: real, bytes: Int64(info.st_size),
                        key: Key(device: Int64(info.st_dev), inode: UInt64(info.st_ino)), links: Int(info.st_nlink))
    }

    public static func files(in folder: String) -> [DiskFile] {
        guard let enumerator = FileManager.default.enumerator(atPath: folder) else { return [] }
        var files: [DiskFile] = []
        while let relative = enumerator.nextObject() as? String {
            if let file = at(folder + "/" + relative) { files.append(file) }
        }
        return files
    }

    public var blobDigest: String? {
        let url = URL(filePath: real)
        let name = url.lastPathComponent
        guard url.deletingLastPathComponent().lastPathComponent == "blobs", name.wholeMatch(of: /[0-9a-f]{64}/) != nil else { return nil }
        return name
    }
}

public struct InventorySource: Sendable, Equatable, Identifiable {
    public enum Kind: Sendable, Equatable {
        case localFiles
        case otherApp(String)
        case hubCache
        case preparation
        case obsolete
    }

    public let kind: Kind
    public let path: String
    public let weights: LocalWeights?
    public let selection: PreparedSelection?
    public let files: [DiskFile]

    public var id: String { path }

    public var present: Bool { selection.map(\.present) ?? !files.isEmpty }
}

public struct InventoryModel: Sendable, Equatable, Identifiable {
    public enum State: String, Sendable, Equatable {
        case prepared
        case ready
        case hubOnly
        case obsolete
        case incomplete
    }

    public let id: String
    public let role: LocalWeights.Role
    public let name: String
    public let sources: [InventorySource]
    public let state: State
    public let files: [DiskFile]
    public let digests: [String]
    public let usedBy: [PreparedSelection]

    public var bytes: Int64? { files.isEmpty ? nil : files.reduce(0) { $0 + $1.bytes } }

    public var weights: [LocalWeights] { sources.compactMap(\.weights) }
    public var selections: [PreparedSelection] { sources.compactMap(\.selection) }

    public var hubModels: [String] {
        var seen: [String] = []
        for selection in selections where !selection.local {
            if let model = selection.model, !seen.contains(model) { seen.append(model) }
        }
        return seen
    }

    public var family: String? { selections.compactMap(\.family).first }

    public var incompleteWeights: LocalWeights? {
        state == .incomplete ? weights.first(where: \.isIncomplete) : nil
    }
}

public struct ModelInventory: Sendable, Equatable {
    public let models: [InventoryModel]
    public let totalBytes: Int64

    public static let empty = ModelInventory(models: [], totalBytes: 0)

    public static let otherApps: [(folder: URL, app: String)] = [
        (URL.homeDirectory.appending(path: ".lmstudio"), "LM Studio"),
    ]

    public func model(_ id: String) -> InventoryModel? { models.first { $0.id == id } }

    public func model(withSource path: String) -> InventoryModel? {
        models.first { $0.sources.contains { $0.path == path } }
    }

    public static func build(selections: [PreparedSelection], weights: [LocalWeights], hubCache: [LocalWeights] = [],
                             otherApps: [(folder: URL, app: String)] = otherApps) -> ModelInventory {
        var entries: [Entry] = []
        var recorded: [String: String] = [:]
        for selection in selections {
            for file in selection.files where file.digest != nil && Self.isWeights(file.name) {
                recorded[LocalWeightsScanner.splashPath(file.path)] = file.digest
                recorded[realPath(file.path)] = file.digest
            }
        }
        for (list, cache) in [(weights, false), (hubCache, true)] {
            for item in list {
                let files = item.format == .gguf ? Self.ggufFiles(item) : DiskFile.files(in: item.path)
                let kind: InventorySource.Kind = cache ? .hubCache
                    : otherApps.first { item.path.hasPrefix($0.folder.path + "/") }.map { .otherApp($0.app) } ?? .localFiles
                var tokens = Set(files.filter { Self.isWeights($0.path) }.map { "f:\($0.key.device):\($0.key.inode)" })
                var digests: [String] = []
                for file in files where Self.isWeights(file.path) {
                    if let digest = file.blobDigest ?? recorded[LocalWeightsScanner.splashPath(file.path)] ?? recorded[file.real] {
                        digests.append(digest)
                    }
                }
                tokens.formUnion(digests.map { "d:" + $0 })
                if tokens.isEmpty { tokens.insert("p:" + realPath(item.path)) }
                entries.append(Entry(role: item.role, tokens: tokens, digests: digests,
                                     source: InventorySource(kind: kind, path: item.path, weights: item, selection: nil, files: files)))
            }
        }
        for selection in selections {
            let data = selection.files.filter { $0.inSplashData || $0.path.contains("/.metadata/") }.compactMap { DiskFile.at($0.path) }
            guard selection.kind == .assembly else {
                entries.append(Entry(role: .target, tokens: ["l:" + selection.link.path], digests: [],
                                     source: InventorySource(kind: .obsolete, path: selection.link.path, weights: nil,
                                                             selection: selection, files: data)))
                continue
            }
            let (tokens, digests) = Self.tokens(of: selection.files.filter { $0.name.hasPrefix("target/") })
            entries.append(Entry(role: .target, tokens: tokens.isEmpty ? ["l:" + selection.link.path] : tokens, digests: digests,
                                 source: InventorySource(kind: .preparation, path: selection.link.path, weights: nil,
                                                         selection: selection, files: data)))
        }
        var parent = Array(entries.indices)
        func find(_ index: Int) -> Int {
            var index = index
            while parent[index] != index {
                parent[index] = parent[parent[index]]
                index = parent[index]
            }
            return index
        }
        var owner: [String: Int] = [:]
        for (index, entry) in entries.enumerated() {
            for token in entry.tokens {
                let key = "\(entry.role.rawValue)|\(token)"
                if let other = owner[key] { parent[find(index)] = find(other) } else { owner[key] = index }
            }
        }
        var groups: [Int: [Int]] = [:]
        for index in entries.indices { groups[find(index), default: []].append(index) }

        var users: [Int: [PreparedSelection]] = [:]
        for selection in selections where selection.kind == .assembly {
            for prefix in ["draft/", "vision/"] {
                let (tokens, _) = Self.tokens(of: selection.files.filter { $0.name.hasPrefix(prefix) })
                let role: LocalWeights.Role = prefix == "draft/" ? .draft : .projector
                let found = Set(tokens.compactMap { owner["\(role.rawValue)|\($0)"] }.map(find))
                for group in found where !(users[group] ?? []).contains(where: { $0.id == selection.id }) {
                    users[group, default: []].append(selection)
                }
            }
        }

        var all: [DiskFile.Key: DiskFile] = [:]
        var models: [InventoryModel] = []
        for (root, members) in groups {
            let group = members.map { entries[$0] }
            let sources = group.map(\.source)
            var unique: [DiskFile.Key: DiskFile] = [:]
            for file in sources.flatMap(\.files) where unique[file.key] == nil { unique[file.key] = file }
            for (key, file) in unique { all[key] = file }
            let digests = Array(Set(group.flatMap(\.digests))).sorted()
            let role = group.first { $0.source.weights != nil }?.role ?? group[0].role
            let id = digests.isEmpty ? "path:" + (sources.first { $0.weights != nil }?.path ?? sources[0].path) : "sha256:" + digests.joined(separator: ",")
            models.append(InventoryModel(id: id, role: role, name: Self.name(sources), sources: Self.ordered(sources),
                                         state: Self.state(sources), files: unique.values.sorted { $0.path < $1.path },
                                         digests: digests, usedBy: (users[root] ?? []).sorted { $0.id < $1.id }))
        }
        models.sort { a, b in
            let order: [LocalWeights.Role] = [.target, .draft, .projector]
            if a.role != b.role { return order.firstIndex(of: a.role)! < order.firstIndex(of: b.role)! }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
        return ModelInventory(models: models, totalBytes: all.values.reduce(0) { $0 + $1.bytes })
    }

    struct Entry {
        let role: LocalWeights.Role
        let tokens: Set<String>
        let digests: [String]
        let source: InventorySource
    }

    static func isWeights(_ path: String) -> Bool {
        let lower = path.lowercased()
        return lower.hasSuffix(".safetensors") || lower.hasSuffix(".gguf")
    }

    static func ggufFiles(_ weights: LocalWeights) -> [DiskFile] {
        let parts = weights.parts > 1 || weights.isIncomplete ? ConfigurationFiles.splitParts(of: weights.path) : []
        guard !parts.isEmpty else { return DiskFile.at(weights.path).map { [$0] } ?? [] }
        return parts.compactMap { DiskFile.at($0) }
    }

    static func tokens(of files: [RecordFile]) -> (Set<String>, [String]) {
        var tokens = Set<String>()
        var digests: [String] = []
        for file in files where isWeights(file.name) {
            if let digest = file.digest {
                tokens.insert("d:" + digest)
                digests.append(digest)
            }
            if file.present, let disk = DiskFile.at(file.path) { tokens.insert("f:\(disk.key.device):\(disk.key.inode)") }
        }
        return (tokens, digests)
    }

    static func ordered(_ sources: [InventorySource]) -> [InventorySource] {
        func rank(_ kind: InventorySource.Kind) -> Int {
            switch kind {
            case .localFiles: 0
            case .hubCache: 1
            case .otherApp: 2
            case .preparation: 3
            case .obsolete: 4
            }
        }
        return sources.sorted { rank($0.kind) != rank($1.kind) ? rank($0.kind) < rank($1.kind) : $0.path < $1.path }
    }

    static func state(_ sources: [InventorySource]) -> InventoryModel.State {
        if sources.contains(where: { $0.selection?.present == true }) { return .prepared }
        if sources.contains(where: { $0.weights?.isIncomplete == false && !$0.files.isEmpty }) { return .ready }
        if sources.contains(where: { $0.weights?.isIncomplete == true && !$0.files.isEmpty }) { return .incomplete }
        if sources.contains(where: { $0.kind == .preparation && $0.selection?.local == false }) { return .hubOnly }
        return .obsolete
    }

    static func name(_ sources: [InventorySource]) -> String {
        if let weights = ordered(sources).compactMap(\.weights).first { return weights.displayName }
        let selections = sources.compactMap(\.selection)
        if let hub = selections.first(where: { !$0.local && $0.model != nil })?.model {
            return String(hub.split(separator: "/").last ?? Substring(hub))
        }
        if let path = selections.first(where: \.local)?.model { return LocalWeights.displayName(path: path) }
        return selections.first.map { URL(filePath: $0.name).lastPathComponent } ?? sources.first.map { URL(filePath: $0.path).lastPathComponent } ?? ""
    }
}
