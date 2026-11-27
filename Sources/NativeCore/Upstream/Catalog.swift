import Foundation

struct Catalog {
    struct Variant: Hashable {
        let id: String
        let name: String
        let memory: Int
        let size: Int
        let about: String
    }

    let variants: [Variant]

    init(contentsOf url: URL) {
        self.init(text: (try? String(contentsOf: url, encoding: .utf8)) ?? "")
    }

    init(text: String) {
        variants = text.split(separator: "\n").compactMap { line in
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard !line.hasPrefix("#"), fields.count == 5, let memory = Int(fields[2]), let size = Int(fields[3])
            else { return nil }
            return Variant(id: fields[0], name: fields[1], memory: memory, size: size, about: fields[4])
        }
    }

    func suggestions(memory: Int) -> [Variant] {
        var chosen: [String: Variant] = [:]
        for variant in variants where variant.memory <= memory {
            if variant.memory > chosen[variant.name]?.memory ?? -1 { chosen[variant.name] = variant }
        }
        var names: [String] = []
        for variant in variants where !names.contains(variant.name) { names.append(variant.name) }
        return names.compactMap { chosen[$0] }
    }

    var minimumMemory: Int? { variants.map(\.memory).min() }

    func name(of id: String) -> String {
        if let name = variants.first(where: { $0.id == id })?.name { return name }
        if id.hasPrefix("/") { return URL(filePath: id).lastPathComponent.replacing(/(?i)\.gguf$/, with: "") }
        let repository = id.split(separator: ":")[0].split(separator: "/").last.map(String.init) ?? id
        let lower = repository.lowercased()
        return lower.hasSuffix("-gguf") ? String(repository.dropLast(5)) : lower.hasSuffix("-mlx") ? String(repository.dropLast(4)) : repository
    }

    static func variant(of id: String) -> String {
        if id.hasPrefix("/") { return URL(filePath: id).deletingLastPathComponent().lastPathComponent }
        if let variant = id.split(separator: ":", maxSplits: 1).dropFirst().first { return String(variant) }
        return id.localizedCaseInsensitiveContains("mlx") ? "MLX" : String(id.split(separator: "/").last ?? Substring(id))
    }

    func about(of id: String) -> String? {
        variants.first { $0.id == id }?.about
    }

    static var memory: Int {
        Int((Double(ProcessInfo.processInfo.physicalMemory) / Double(1 << 30)).rounded())
    }
}
