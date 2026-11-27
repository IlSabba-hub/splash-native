import Darwin
import Foundation

public struct RecordFile: Sendable, Equatable, Hashable {
    public let name: String
    public let path: String
    public let bytes: Int64
    public let present: Bool
    public let inSplashData: Bool
    public var digest: String? = nil
}

public struct PreparedSelection: Sendable, Equatable, Identifiable {
    public enum Kind: String, Sendable, Equatable {
        case assembly
        case package
        case broken
    }

    public let link: URL
    public let name: String
    public let hashed: Bool
    public let kind: Kind
    public let assembly: String?
    public let model: String?
    public let family: String?
    public let targetFormat: String?
    public let visionFormat: String?
    public let visionUnavailable: String?
    public let draft: String?
    public let draftRevision: String?
    public let targetRevision: String?
    public let files: [RecordFile]

    public var id: String { link.path }

    public var present: Bool { kind == .assembly && files.allSatisfy(\.present) }

    public var bytes: Int64 {
        Dictionary(files.map { ($0.path, $0.bytes) }) { first, _ in first }.values.reduce(0, +)
    }

    public var local: Bool { model?.hasPrefix("/") == true }

    public var vision: RecordFile? { files.first { $0.name.hasPrefix("vision/") && !$0.name.hasSuffix(".json") } }
}

public enum SelectionScanner {
    public static func scan(models: URL) -> [PreparedSelection] {
        let manager = FileManager.default
        var links: [(URL, Bool)] = []
        let owners = (try? manager.contentsOfDirectory(at: models, includingPropertiesForKeys: nil)) ?? []
        for owner in owners where !owner.lastPathComponent.hasPrefix(".") {
            let repositories = (try? manager.contentsOfDirectory(at: owner, includingPropertiesForKeys: nil)) ?? []
            links += repositories.filter(isLink).map { ($0, false) }
        }
        let hashed = (try? manager.contentsOfDirectory(at: models.appending(path: ".selections"), includingPropertiesForKeys: nil)) ?? []
        links += hashed.filter(isLink).map { ($0, true) }
        let data = models.standardizedFileURL.path
        return links.map { read($0.0, hashed: $0.1, models: models, data: data) }.sorted { $0.link.path < $1.link.path }
    }

    static func isLink(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true
    }

    static func read(_ link: URL, hashed: Bool, models: URL, data: String) -> PreparedSelection {
        struct Record: Decodable {
            struct File: Decodable { let path: String; let bytes: Int64; let digest: String? }
            struct Source: Decodable { let repo: String?; let revision: String? }
            let model: String?
            let family: String?
            let target_format: String?
            let vision_format: String?
            let vision_unavailable: String?
            let sources: [String: Source]?
            let files: [String: File]?
        }
        let name = hashed ? link.lastPathComponent
            : "\(link.deletingLastPathComponent().lastPathComponent)/\(link.lastPathComponent)"
        let target = link.resolvingSymlinksInPath()
        let manager = FileManager.default
        let realData = realPath(data)
        let assemblyName = target.deletingLastPathComponent().lastPathComponent == ".resolved" ? target.lastPathComponent : nil
        if let bytes = try? Data(contentsOf: link.appending(path: "model.json")),
           let record = try? JSONDecoder().decode(Record.self, from: bytes) {
            let files = (record.files ?? [:]).sorted { $0.key < $1.key }.map { name, file in
                RecordFile(name: name, path: file.path, bytes: file.bytes, present: manager.fileExists(atPath: file.path),
                           inSplashData: file.path.hasPrefix(data + "/") || realPath(file.path).hasPrefix(realData + "/"),
                           digest: file.digest)
            }
            return PreparedSelection(
                link: link, name: name, hashed: hashed, kind: .assembly, assembly: assemblyName, model: record.model,
                family: record.family, targetFormat: record.target_format, visionFormat: record.vision_format,
                visionUnavailable: record.vision_unavailable, draft: record.sources?["draft"]?.repo,
                draftRevision: record.sources?["draft"]?.revision, targetRevision: record.sources?["target"]?.revision,
                files: files)
        }
        let package = manager.fileExists(atPath: link.appending(path: "manifest.json").path)
        return PreparedSelection(
            link: link, name: name, hashed: hashed, kind: package ? .package : .broken, assembly: nil,
            model: hashed ? nil : name, family: nil, targetFormat: nil, visionFormat: nil, visionUnavailable: nil,
            draft: nil, draftRevision: nil, targetRevision: nil, files: [])
    }

    public static func unlinkedAssemblies(models: URL, selections: [PreparedSelection]) -> [String] {
        let linked = Set(selections.compactMap(\.assembly))
        let all = (try? FileManager.default.contentsOfDirectory(at: models.appending(path: ".resolved"),
                                                                 includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        return all.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .map(\.lastPathComponent).filter { !linked.contains($0) }.sorted()
    }

    public static func isHeld(_ selection: PreparedSelection) -> Bool {
        let descriptor = open(selection.link.appending(path: "model.json").path, O_RDONLY | O_CLOEXEC)
        guard descriptor >= 0 else { return false }
        defer { close(descriptor) }
        if flock(descriptor, LOCK_EX | LOCK_NB) == 0 {
            flock(descriptor, LOCK_UN)
            return false
        }
        return errno == EWOULDBLOCK
    }
}

public enum RemovalVerdict: Sendable, Equatable {
    case allowed(model: String, links: [String], assemblies: [String])
    case refused(RemovalRefusal)
}

public enum RemovalRefusal: Sendable, Equatable {
    case localFiles
    case package
    case broken
    case optionsSelection
    case wouldFreeFiles(count: Int, bytes: Int64)
    case held
    case otherUnlinked(count: Int)

    public var message: String { DeckText.removalRefusal(self) }
}

extension RemovalVerdict {
    public static func judge(_ selection: PreparedSelection, among selections: [PreparedSelection], unlinked: [String],
                             held: (PreparedSelection) -> Bool = SelectionScanner.isHeld) -> RemovalVerdict {
        switch selection.kind {
        case .package: return .refused(.package)
        case .broken: return .refused(.broken)
        case .assembly: break
        }
        if selection.local { return .refused(.localFiles) }
        guard let model = selection.model else { return .refused(.broken) }
        let taken: [PreparedSelection]
        if !selection.hashed {
            taken = selections.filter { $0.model == model && $0.kind == .assembly }
        } else if selection.name == Runtime.textOnlySelection(model) {
            taken = [selection]
        } else {
            return .refused(.optionsSelection)
        }
        if taken.contains(where: held) { return .refused(.held) }
        if !unlinked.isEmpty { return .refused(.otherUnlinked(count: unlinked.count)) }
        let staying = selections.filter { s in !taken.contains(where: { $0.id == s.id }) }
        let kept = Set(staying.compactMap(\.assembly))
        let assemblies = Set(taken.compactMap(\.assembly)).subtracting(kept)
        let keptFiles = Set(staying.flatMap(\.files).map(\.path))
        let freeable = taken.filter { $0.assembly.map(assemblies.contains) == true }
            .flatMap(\.files).filter { !$0.inSplashData && $0.present && !keptFiles.contains($0.path) }
        let unique = Dictionary(freeable.map { ($0.path, $0.bytes) }) { first, _ in first }
        if !unique.isEmpty { return .refused(.wouldFreeFiles(count: unique.count, bytes: unique.values.reduce(0, +))) }
        return .allowed(model: model, links: taken.map(\.name), assemblies: assemblies.sorted())
    }
}
