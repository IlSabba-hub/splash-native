import Foundation

public struct VersionsContent: Sendable {
    public var rows: SectionState<[VersionRow]>
    public var github: VersionsGitHub
    public var upgrade: VersionUpgrade
    public var diffs: [VersionDiff]
    public var schemaVersions: [String]

    public init(rows: SectionState<[VersionRow]>, github: VersionsGitHub, upgrade: VersionUpgrade, diffs: [VersionDiff],
                schemaVersions: [String]) {
        self.rows = rows
        self.github = github
        self.upgrade = upgrade
        self.diffs = diffs
        self.schemaVersions = schemaVersions
    }
}

public struct VersionRow: Sendable, Identifiable {
    public enum State: Sendable, Equatable {
        case inUse
        case installed
        case update
        case older
    }

    public let id: String
    public let version: String
    public let state: State
    public let source: String
    public let path: String?
    public let date: Date?
    public let schema: Measured<String>?
    public let servers: Int
    public let notes: VersionReleaseNote?
    public let reveal: DeckAction?

    public init(id: String, version: String, state: State, source: String, path: String?, date: Date?, schema: Measured<String>?,
                servers: Int, notes: VersionReleaseNote?, reveal: DeckAction?) {
        self.id = id
        self.version = version
        self.state = state
        self.source = source
        self.path = path
        self.date = date
        self.schema = schema
        self.servers = servers
        self.notes = notes
        self.reveal = reveal
    }
}

public enum VersionsGitHub: Sendable {
    case notChecked(check: DeckAction)
    case checking
    case failed(reason: String, retry: DeckAction)
    case checked(at: Date, refresh: DeckAction)
}

public struct VersionReleaseNote: Sendable, Equatable, Identifiable {
    public let version: String
    public let title: String?
    public let published: Date?
    public let prerelease: Bool
    public let body: String?
    public let url: String
    public let installed: Bool

    public var id: String { version }

    public init(version: String, title: String?, published: Date?, prerelease: Bool, body: String?, url: String, installed: Bool) {
        self.version = version
        self.title = title
        self.published = published
        self.prerelease = prerelease
        self.body = body
        self.url = url
        self.installed = installed
    }
}

public struct VersionDiff: Sendable, Equatable, Identifiable {
    public struct Change: Sendable, Equatable, Identifiable {
        public let flag: String
        public let before: String?
        public let after: String?
        public var id: String { flag }

        public init(flag: String, before: String?, after: String?) {
            self.flag = flag
            self.before = before
            self.after = after
        }
    }

    public let from: String
    public let to: String
    public let added: [String]
    public let removed: [String]
    public let defaults: [Change]
    public let needs: [Change]
    public let parsers: [Change]
    public let environment: [Change]
    public let help: [Change]
    public let source: String

    public var id: String { "\(from)→\(to)" }

    public init(from: String, to: String, added: [String], removed: [String], defaults: [Change], needs: [Change], parsers: [Change],
                environment: [Change], help: [Change], source: String) {
        self.from = from
        self.to = to
        self.added = added
        self.removed = removed
        self.defaults = defaults
        self.needs = needs
        self.parsers = parsers
        self.environment = environment
        self.help = help
        self.source = source
    }
}

public struct VersionUpgrade: Sendable {
    public enum State: Sendable, Equatable {
        case idle
        case running
        case finished(status: Int32, output: String)
        case failed(reason: String)
    }

    public let command: String
    public let newer: String?
    public let action: DeckAction
    public let state: State
    public let note: String

    public init(command: String, newer: String?, action: DeckAction, state: State, note: String) {
        self.command = command
        self.newer = newer
        self.action = action
        self.state = state
        self.note = note
    }
}
