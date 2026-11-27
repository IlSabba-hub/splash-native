import Foundation

public struct LocalWeights: Sendable, Equatable, Identifiable {
    public enum Role: String, Sendable, Equatable {
        case target, draft, projector
    }

    public enum Format: String, Sendable, Equatable {
        case gguf
        case safetensors
    }

    public struct Quantization: Sendable, Equatable {
        public let bits: Int?
        public let groupSize: Int?
        public let mode: String?
        public let method: String?
        public let mixed: Bool
    }

    public let path: String
    public let role: Role
    public let format: Format
    public let bytes: Int64
    public let parts: Int
    public let architectures: [String]
    public let modelType: String?
    public let quantization: Quantization?
    public var modified: Date? = nil
    public var missingParts: [MissingFile] = []

    public var id: String { path }

    public var expectedParts: Int { parts + missingParts.count }

    public var isIncomplete: Bool { !missingParts.isEmpty }

    public var name: String {
        let last = URL(filePath: path).lastPathComponent
        return format == .gguf ? last.replacing(/(?i)\.gguf$/, with: "") : last
    }

    public var displayName: String { Self.displayName(path: path) }

    public static func displayName(path: String) -> String {
        let last = URL(filePath: path).lastPathComponent
        var leaf = last.replacing(/(?i)\.gguf$/, with: "")
        if leaf != last { leaf = leaf.replacing(/-\d{5}-of-\d{5}$/, with: "") }
        guard Self.isGeneric(leaf) else { return leaf }
        var folder = URL(filePath: path).deletingLastPathComponent()
        for _ in 0 ..< 3 where Self.isGeneric(folder.lastPathComponent) || folder.lastPathComponent == "snapshots" {
            folder = folder.deletingLastPathComponent()
        }
        var parent = folder.lastPathComponent
        guard !parent.isEmpty, parent != "/" else { return leaf }
        if parent.hasPrefix("models--") {
            let parts = parent.dropFirst("models--".count).components(separatedBy: "--")
            if parts.count >= 2 { parent = parts.joined(separator: "/") }
        }
        func letters(_ text: String) -> String { text.lowercased().filter { $0.isLetter || $0.isNumber } }
        if Self.isHash(leaf) || letters(parent).contains(letters(leaf)) { return parent }
        return parent + "/" + leaf
    }

    static func isGeneric(_ name: String) -> Bool {
        isHash(name) || name.wholeMatch(of: /(?i)\d+[-_ ]?bits?|i?q\d\w*|f(p)?(8|16|32)|bf16|int[48]|[nm]xfp4|mlx|gguf|safetensors|main|model|weights/) != nil
    }

    static func isHash(_ name: String) -> Bool {
        name.wholeMatch(of: /[0-9a-f]{40}/) != nil
    }
}

public enum LocalWeightsScanner {
    public static let defaultRoots: [URL] = [
        URL.homeDirectory.appending(path: "models"),
        URL.homeDirectory.appending(path: ".lmstudio/models"),
    ]

    static let depth = 5

    public static func scan(roots: [URL] = defaultRoots) -> [LocalWeights] {
        var found: [LocalWeights] = []
        for root in roots { walk(root, level: 0, into: &found) }
        return found.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }

    private static func walk(_ folder: URL, level: Int, into found: inout [LocalWeights]) {
        let manager = FileManager.default
        guard level <= depth,
              let entries = try? manager.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isDirectoryKey])
        else { return }
        let names = Set(entries.map(\.lastPathComponent))
        let safetensors = entries.filter { $0.pathExtension == "safetensors" }
        if names.contains("config.json"), !safetensors.isEmpty {
            found.append(folderWeights(folder, files: entries))
            return
        }
        var splits: [String: [URL]] = [:]
        for entry in entries where !entry.lastPathComponent.hasPrefix(".") {
            if entry.pathExtension.lowercased() == "gguf" {
                let name = entry.lastPathComponent
                if let match = name.wholeMatch(of: /(.+)-(\d{5})-of-(\d{5})\.gguf/) {
                    splits[String(match.1) + "-of-" + String(match.3), default: []].append(entry)
                    continue
                }
                let projector = name.localizedCaseInsensitiveContains("mmproj")
                found.append(LocalWeights(path: entry.path, role: projector ? .projector : .target, format: .gguf,
                                          bytes: size(entry), parts: 1, architectures: [], modelType: nil, quantization: nil,
                                          modified: modified([entry])))
            } else if (try? entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true,
                      entry.lastPathComponent != "blobs" {
                walk(entry, level: level + 1, into: &found)
            }
        }
        for (_, parts) in splits {
            let sorted = parts.sorted { $0.lastPathComponent < $1.lastPathComponent }
            let present = Set(sorted.map(\.lastPathComponent))
            let missing = ConfigurationFiles.splitParts(of: sorted[0].path)
                .filter { !present.contains(URL(filePath: $0).lastPathComponent) }
                .map { path in
                    let part = (try? manager.attributesOfItem(atPath: path + ".part"))?[.size] as? NSNumber
                    return MissingFile(flag: nil, path: path, partialBytes: part?.int64Value)
                }
            found.append(LocalWeights(path: sorted[0].path, role: .target, format: .gguf, bytes: sorted.map(size).reduce(0, +),
                                      parts: sorted.count, architectures: [], modelType: nil, quantization: nil, modified: modified(sorted),
                                      missingParts: missing))
        }
    }

    private static func folderWeights(_ folder: URL, files: [URL]) -> LocalWeights {
        struct Config: Decodable {
            let architectures: [String]?
            let model_type: String?
            let quantization: JSONValue?
            let quantization_config: JSONValue?
        }
        let config = (try? Data(contentsOf: folder.appending(path: "config.json")))
            .flatMap { try? JSONDecoder().decode(Config.self, from: $0) }
        let architectures = config?.architectures ?? []
        let draft = architectures.contains { $0.localizedCaseInsensitiveContains("DFlash") }
        let visible = files.filter { !$0.lastPathComponent.hasPrefix(".") }
        let bytes = visible.map(size).reduce(0, +)
        return LocalWeights(path: folder.path, role: draft ? .draft : .target, format: .safetensors, bytes: bytes, parts: 1,
                            architectures: architectures, modelType: config?.model_type,
                            quantization: quantization(config?.quantization ?? config?.quantization_config),
                            modified: modified(visible))
    }

    static func quantization(_ value: JSONValue?) -> LocalWeights.Quantization? {
        guard case .object(let fields)? = value else { return nil }
        let mixed = fields.values.contains { if case .object = $0 { true } else { false } }
        return LocalWeights.Quantization(bits: fields["bits"]?.int.map(Int.init), groupSize: fields["group_size"]?.int.map(Int.init),
                                         mode: fields["mode"]?.text, method: fields["quant_method"]?.text, mixed: mixed)
    }

    static func modified(_ files: [URL]) -> Date? {
        files.compactMap { try? $0.resolvingSymlinksInPath().resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate }.max()
    }

    static func size(_ url: URL) -> Int64 {
        let resolved = url.resolvingSymlinksInPath()
        let values = try? resolved.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])
        if values?.isDirectory == true {
            let files = (FileManager.default.enumerator(at: resolved, includingPropertiesForKeys: nil)?.allObjects as? [URL]) ?? []
            return files.reduce(0) { total, file in
                let size = (try? file.resolvingSymlinksInPath().resourceValues(forKeys: [.fileSizeKey, .isDirectoryKey]))
                return total + (size?.isDirectory == true ? 0 : Int64(size?.fileSize ?? 0))
            }
        }
        return Int64(values?.fileSize ?? 0)
    }

    public static func splashPath(_ path: String) -> String {
        let url = URL(filePath: path).standardizedFileURL
        return url.deletingLastPathComponent().resolvingSymlinksInPath().appending(path: url.lastPathComponent).path
    }
}
