import Foundation

public struct MissingFile: Sendable, Equatable {
    public let flag: String?
    public let path: String
    public let partialBytes: Int64?

    public init(flag: String?, path: String, partialBytes: Int64? = nil) {
        self.flag = flag
        self.path = path
        self.partialBytes = partialBytes
    }
}

public enum ConfigurationFiles {
    public static func missing(_ configuration: Configuration, fileManager: FileManager = .default) -> [MissingFile] {
        var missing: [MissingFile] = []
        func check(_ path: String, flag: String?, directory: Bool?) {
            var isDirectory: ObjCBool = false
            let exists = fileManager.fileExists(atPath: path, isDirectory: &isDirectory)
            if exists, directory.map({ $0 == isDirectory.boolValue }) ?? true { return }
            let part = (try? fileManager.attributesOfItem(atPath: path + ".part"))?[.size] as? NSNumber
            missing.append(MissingFile(flag: flag, path: path, partialBytes: part?.int64Value))
        }
        if configuration.isLocal {
            let model = expandTilde(configuration.model)
            let parts = splitParts(of: model)
            if parts.isEmpty { check(model, flag: nil, directory: nil) } else { parts.forEach { check($0, flag: nil, directory: false) } }
        }
        if case let .value(path)? = configuration.parameters["--mmproj"] { check(expandTilde(path), flag: "--mmproj", directory: false) }
        if case let .value(draft)? = configuration.parameters["--draft-model"], draft.hasPrefix("/") || draft.hasPrefix("~/") {
            check(expandTilde(draft), flag: "--draft-model", directory: true)
        }
        return missing
    }

    public static func splitParts(of path: String) -> [String] {
        let url = URL(filePath: path)
        guard let match = url.lastPathComponent.wholeMatch(of: /(.+)-(\d{5})-of-(\d{5})\.gguf/), let count = Int(match.3), count > 0 else {
            return []
        }
        let folder = url.deletingLastPathComponent()
        let width = match.3.count
        return (1 ... count).map { index in
            let number = String(index)
            let padded = String(repeating: "0", count: max(0, width - number.count)) + number
            return folder.appending(path: "\(match.1)-\(padded)-of-\(match.3).gguf").path
        }
    }
}
