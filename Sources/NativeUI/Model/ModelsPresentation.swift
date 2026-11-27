import Foundation

public struct ModelTag: Sendable, Equatable, Hashable {
    public enum Tone: Sendable, Equatable, Hashable {
        case neutral, accent, ready, warning, error
    }

    public let title: String
    public let symbol: String?
    public let tone: Tone

    public init(_ title: String, symbol: String? = nil, tone: Tone = .neutral) {
        self.title = title
        self.symbol = symbol
        self.tone = tone
    }
}

public enum VerificationState: Sendable, Equatable {
    case none
    case running(full: Bool)
    case passed(full: Bool, seconds: Double, date: Date)
    case failed(full: Bool, message: String, seconds: Double?)
}

public struct PreparationSummary: Sendable, Identifiable {
    public let id: String
    public let title: String
    public let link: String
    public let present: Bool
    public let tags: [ModelTag]
    public let facts: [Fact]
    public let verification: VerificationState
    public let verifyQuick: NativeAction?
    public let verifyFull: NativeAction?
    public let remove: NativeAction?
    public let removeRefusal: String?
    public let configurations: [String]
    public let warning: String?

    public init(id: String, title: String, link: String, present: Bool, tags: [ModelTag] = [], facts: [Fact] = [],
                verification: VerificationState = .none, verifyQuick: NativeAction? = nil, verifyFull: NativeAction? = nil,
                remove: NativeAction? = nil, removeRefusal: String? = nil, configurations: [String] = [], warning: String? = nil) {
        self.id = id
        self.title = title
        self.link = link
        self.present = present
        self.tags = tags
        self.facts = facts
        self.verification = verification
        self.verifyQuick = verifyQuick
        self.verifyFull = verifyFull
        self.remove = remove
        self.removeRefusal = removeRefusal
        self.configurations = configurations
        self.warning = warning
    }
}

public struct ModelCardSummary: Sendable, Identifiable {
    public let id: String
    public let name: String
    public let location: String
    public let tags: [ModelTag]
    public let facts: [Fact]
    public let preparations: [PreparationSummary]
    public let configurations: [String]
    public let actions: [NativeAction]

    public init(id: String, name: String, location: String, tags: [ModelTag] = [], facts: [Fact] = [],
                preparations: [PreparationSummary] = [], configurations: [String] = [], actions: [NativeAction] = []) {
        self.id = id
        self.name = name
        self.location = location
        self.tags = tags
        self.facts = facts
        self.preparations = preparations
        self.configurations = configurations
        self.actions = actions
    }

    public var warnings: [String] { preparations.compactMap(\.warning) }
}

public struct WeightsSummary: Sendable, Identifiable {
    public let id: String
    public let name: String
    public let location: String
    public let facts: [Fact]
    public let usedBy: [String]
    public let actions: [NativeAction]

    public init(id: String, name: String, location: String, facts: [Fact] = [], usedBy: [String] = [], actions: [NativeAction] = []) {
        self.id = id
        self.name = name
        self.location = location
        self.facts = facts
        self.usedBy = usedBy
        self.actions = actions
    }
}

public struct ModelsOverview: Sendable {
    public let folders: [Fact]
    public let scanned: Date?
    public let models: [ModelCardSummary]
    public let drafts: [WeightsSummary]
    public let projectors: [WeightsSummary]
    public let notices: [String]
    public let rows: [ModelRow]
    public let folder: ModelsFolder?

    public init(folders: [Fact], scanned: Date?, models: [ModelCardSummary], drafts: [WeightsSummary], projectors: [WeightsSummary],
                notices: [String] = [], rows: [ModelRow] = [], folder: ModelsFolder? = nil) {
        self.folders = folders
        self.scanned = scanned
        self.models = models
        self.drafts = drafts
        self.projectors = projectors
        self.notices = notices
        self.rows = rows
        self.folder = folder
    }

    public func count(_ filter: ModelsFilter) -> Int { rows.filter { filter.includes($0.kind) }.count }
}

public enum ModelKind: String, Sendable, Equatable, Hashable {
    case llm, draft, projector
}

public enum ModelsFilter: String, Sendable, CaseIterable, Identifiable, Hashable {
    case all, llm, drafts, projectors

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .all: tr("models.filter.all")
        case .llm: tr("models.filter.llm")
        case .drafts: tr("models.filter.drafts")
        case .projectors: tr("models.filter.projectors")
        }
    }

    public func includes(_ kind: ModelKind) -> Bool {
        switch self {
        case .all: true
        case .llm: kind == .llm
        case .drafts: kind == .draft
        case .projectors: kind == .projector
        }
    }
}

public struct SourcedText: Sendable, Equatable, Hashable {
    public let text: String
    public let source: String

    public init(_ text: String, source: String) {
        self.text = text
        self.source = source
    }
}

public struct ModelRow: Sendable, Identifiable {
    public let id: String
    public let kind: ModelKind
    public let architecture: SourcedText?
    public let family: String?
    public let parameters: SourcedText?
    public let name: String
    public let location: String
    public let capabilities: [Capability]
    public let capabilitiesSource: String?
    public let quantization: SourcedText?
    public let bytes: Int64?
    public let sizeReason: String?
    public let note: ModelTag?
    public let noteHelp: String?
    public let modified: SourcedText?
    public let modifiedDate: Date?
    public let busy: Bool
    public let menu: [NativeAction]
    public let settings: [NativeAction]

    public init(id: String, kind: ModelKind, architecture: SourcedText? = nil, family: String? = nil, parameters: SourcedText? = nil,
                name: String, location: String, capabilities: [Capability] = [], capabilitiesSource: String? = nil,
                quantization: SourcedText? = nil, bytes: Int64? = nil, sizeReason: String? = nil, note: ModelTag? = nil,
                noteHelp: String? = nil, modified: SourcedText? = nil, modifiedDate: Date? = nil,
                busy: Bool = false, menu: [NativeAction] = [], settings: [NativeAction] = []) {
        self.id = id
        self.kind = kind
        self.architecture = architecture
        self.family = family
        self.parameters = parameters
        self.name = name
        self.location = location
        self.capabilities = capabilities
        self.capabilitiesSource = capabilitiesSource
        self.quantization = quantization
        self.bytes = bytes
        self.sizeReason = sizeReason
        self.note = note
        self.noteHelp = noteHelp
        self.modified = modified
        self.modifiedDate = modifiedDate
        self.busy = busy
        self.menu = menu
        self.settings = settings
    }

    public func matches(_ query: String) -> Bool {
        let query = query.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return true }
        return [name, location, architecture?.text ?? "", family ?? "", quantization?.text ?? "", parameters?.text ?? ""]
            .contains { $0.localizedCaseInsensitiveContains(query) }
    }
}

public struct ModelsFolder: Sendable {
    public let path: String
    public let actions: [NativeAction]

    public init(path: String, actions: [NativeAction]) {
        self.path = path
        self.actions = actions
    }
}
