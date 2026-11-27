import Foundation

enum JSONLines {
    static func append(_ lines: Data, to file: URL, synchronize: Bool = false) throws {
        let manager = FileManager.default
        try manager.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !manager.fileExists(atPath: file.path) {
            manager.createFile(atPath: file.path, contents: nil, attributes: [.posixPermissions: 0o600])
        }
        let handle = try FileHandle(forUpdating: file)
        defer { try? handle.close() }
        var data = lines
        let end = try handle.seekToEnd()
        if end > 0 {
            try handle.seek(toOffset: end - 1)
            if try handle.read(upToCount: 1) != Data([0x0A]) { data.insert(0x0A, at: 0) }
            try handle.seekToEnd()
        }
        try handle.write(contentsOf: data)
        if synchronize { try handle.synchronize() }
    }
}
