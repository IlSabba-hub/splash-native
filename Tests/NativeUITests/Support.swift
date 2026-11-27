import Foundation

enum Fixtures {
    static let root = URL(filePath: #filePath).deletingLastPathComponent().appending(path: "../Fixtures").standardized

    static func text(_ path: String) throws -> String { try String(contentsOf: root.appending(path: path), encoding: .utf8) }

    static let package = URL(filePath: #filePath).deletingLastPathComponent().appending(path: "../..").standardized
}
