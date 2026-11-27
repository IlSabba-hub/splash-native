import Darwin
import Foundation
import LocalAuthentication

public struct DeletionChoices: Sendable, Equatable {
    public enum Configurations: Sendable, Equatable {
        case keep
        case remove
    }

    public var configurations: Configurations?
    public var includeOtherApps: Bool
    public var includeHubCache: Bool
    public var breakPreparations: Bool

    public init(configurations: Configurations? = nil, includeOtherApps: Bool = false, includeHubCache: Bool = false,
                breakPreparations: Bool = false) {
        self.configurations = configurations
        self.includeOtherApps = includeOtherApps
        self.includeHubCache = includeHubCache
        self.breakPreparations = breakPreparations
    }
}

public struct RunningProcess: Sendable, Equatable {
    public let pid: Int32
    public let name: String
    public let arguments: [String]
    public let mapped: [String]

    public init(pid: Int32, name: String, arguments: [String], mapped: [String]) {
        self.pid = pid
        self.name = name
        self.arguments = arguments
        self.mapped = mapped
    }

    public static func scan() -> [RunningProcess] {
        ProcessFacts.allPIDs().compactMap { pid in
            guard pid != getpid(), let identity = ProcessFacts.identity(pid), identity.user == getuid() else { return nil }
            return RunningProcess(pid: pid, name: identity.name, arguments: ProcessArguments.read(pid)?.argv ?? [],
                                  mapped: ProcessFacts.mappedFiles(pid)?.map(\.path) ?? [])
        }
    }
}

public struct DeletionFacts: Sendable {
    public var inventory: ModelInventory
    public var selections: [PreparedSelection]
    public var unlinked: [String]
    public var models: URL?
    public var installation: SplashInstallation?
    public var configurations: [Configuration]
    public var processes: [RunningProcess]
    public var linkRoots: [URL]
    public var held: @Sendable (PreparedSelection) -> Bool

    public init(inventory: ModelInventory, selections: [PreparedSelection], unlinked: [String], models: URL?,
                installation: SplashInstallation?, configurations: [Configuration], processes: [RunningProcess],
                linkRoots: [URL] = LocalWeightsScanner.defaultRoots, held: @escaping @Sendable (PreparedSelection) -> Bool = SelectionScanner.isHeld) {
        self.inventory = inventory
        self.selections = selections
        self.unlinked = unlinked
        self.models = models
        self.installation = installation
        self.configurations = configurations
        self.processes = processes
        self.linkRoots = linkRoots
        self.held = held
    }
}

public struct DeletionPlan: Sendable, Equatable {
    public struct TrashItem: Sendable, Equatable, Identifiable {
        public enum What: Sendable, Equatable {
            case weights
            case hubEntry
            case hubBlob
            case otherApp(String)
            case selectionLink
            case packageLink
            case packageFiles
        }

        public let path: String
        public let what: What
        public let freedBytes: Int64
        public var id: String { path }
    }

    public struct SplashRemoval: Sendable, Equatable, Identifiable {
        public let model: String
        public let textOnly: Bool
        public let links: [String]
        public let command: [String]
        public var id: String { model + (textOnly ? " text" : "") }
    }

    public enum Issue: Sendable, Equatable {
        case served(link: String)
        case usedByProcess(pid: Int32, name: String, path: String)
        case splashWouldDelete(paths: [String])
        case noInstallation
        case configurationsNeedChoice([String])
        case usedByPreparations([String])
        case configurationsKept([String])
        case configurationsRemoved([String])
        case preparationsBroken([String])
        case otherAppSkipped(app: String, path: String)
        case otherAppIncluded(app: String, path: String)
        case hubCacheSkipped(path: String)
        case hubCacheIncluded(path: String)
        case sharedBlobKept(path: String, users: [String])
        case outsideBlob(link: String, target: String)
        case linkedFrom(link: String)
        case hardLinks(path: String)
        case noSplashCommand(link: String)
        case obsoletePackage(link: String, files: String?)
        case splashDataLater
        case emptyTrashToFree

        public var blocks: Bool {
            switch self {
            case .served, .usedByProcess, .splashWouldDelete, .noInstallation, .configurationsNeedChoice, .usedByPreparations: true
            default: false
            }
        }

        public var needsChoice: Bool {
            switch self {
            case .configurationsNeedChoice, .usedByPreparations: true
            default: false
            }
        }
    }

    public let model: InventoryModel
    public let choices: DeletionChoices
    public let trash: [TrashItem]
    public let removals: [SplashRemoval]
    public let configurations: [String]
    public let removedConfigurations: [String]
    public let otherAppPaths: [String]
    public let issues: [Issue]
    public let freedBytes: Int64

    public var blocked: Bool { issues.contains(where: \.blocks) }
    public var isEmpty: Bool { trash.isEmpty && removals.isEmpty && removedConfigurations.isEmpty }
    public var canProceed: Bool { !blocked && !isEmpty }
}

public enum DeletionPlanner {
    public static func plan(_ model: InventoryModel, facts: DeletionFacts, choices: DeletionChoices = DeletionChoices()) -> DeletionPlan {
        var trash: [DeletionPlan.TrashItem] = []
        var issues: [DeletionPlan.Issue] = []
        var removals: [DeletionPlan.SplashRemoval] = []
        var otherAppPaths: [String] = []
        var freed: [DiskFile.Key: Int64] = [:]
        func add(_ path: String, _ what: DeletionPlan.TrashItem.What, freed bytes: Int64 = 0, key: DiskFile.Key? = nil) {
            guard !trash.contains(where: { $0.path == path }) else { return }
            var counted: Int64 = 0
            if let key, bytes > 0, freed[key] == nil {
                freed[key] = bytes
                counted = bytes
            }
            trash.append(.init(path: path, what: what, freedBytes: counted))
        }

        var hubFolders: [String: [String: [String]]] = [:]
        let entries = Set(model.sources.filter { source in
            guard source.weights != nil else { return false }
            if case .otherApp = source.kind { return choices.includeOtherApps }
            if source.kind == .hubCache { return choices.includeHubCache }
            return true
        }.flatMap(\.files).map(\.path))
        for source in model.sources where source.weights != nil {
            var what = DeletionPlan.TrashItem.What.weights
            if case let .otherApp(app) = source.kind {
                guard choices.includeOtherApps else {
                    otherAppPaths.append(source.path)
                    issues.append(.otherAppSkipped(app: app, path: source.path))
                    continue
                }
                what = .otherApp(app)
                issues.append(.otherAppIncluded(app: app, path: source.path))
            }
            if source.kind == .hubCache {
                guard choices.includeHubCache else {
                    otherAppPaths.append(source.path)
                    issues.append(.hubCacheSkipped(path: source.path))
                    continue
                }
                issues.append(.hubCacheIncluded(path: source.path))
            }
            let folder = (try? URL(filePath: source.path).resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
            if let repo = hubRepository(source.path) {
                let names = hubFolders[repo] ?? blobEntries(repo)
                hubFolders[repo] = names
                for file in source.files {
                    if file.links > 1 { issues.append(.hardLinks(path: file.real)) }
                    guard file.path != file.real else {
                        add(file.path, what, freed: file.links == 1 ? file.bytes : 0, key: file.key)
                        continue
                    }
                    add(file.path, source.kind == .hubCache ? .hubEntry : what)
                    guard file.real.hasPrefix(repo + "/blobs/") else {
                        issues.append(.outsideBlob(link: file.path, target: file.real))
                        continue
                    }
                    let users = (names[file.real] ?? []).filter { !entries.contains($0) }
                    if users.isEmpty {
                        add(file.real, .hubBlob, freed: file.links == 1 ? file.bytes : 0, key: file.key)
                    } else {
                        issues.append(.sharedBlobKept(path: file.real, users: users.sorted()))
                    }
                }
            } else if folder {
                add(source.path, what)
                var bytes: Int64 = 0
                for file in source.files where file.real.hasPrefix(source.path + "/") || file.real == file.path {
                    if file.links == 1 { bytes += countOnce(file, &freed) } else { issues.append(.hardLinks(path: file.path)) }
                }
                trash[trash.count - 1] = .init(path: source.path, what: what, freedBytes: bytes)
            } else {
                for file in source.files {
                    add(file.path, what, freed: file.links == 1 ? file.bytes : 0, key: file.key)
                    if file.links > 1 { issues.append(.hardLinks(path: file.path)) }
                }
            }
        }

        let selections = model.selections
        for selection in selections where facts.held(selection) {
            issues.append(.served(link: selection.link.path))
        }
        var removedLinks = Set<String>()
        let hubIDs = Set(selections.filter { $0.kind == .assembly && !$0.local }.compactMap(\.model))
        for id in hubIDs.sorted() {
            guard let installation = facts.installation, let models = facts.models else {
                issues.append(.noInstallation)
                break
            }
            let mine = facts.selections.filter { $0.kind == .assembly && $0.model == id }
            let plain = mine.first { !$0.hashed }
            let textOnly = mine.first { $0.hashed && $0.name == Runtime.textOnlySelection(id) }
            let (taken, text): ([PreparedSelection], Bool) = plain != nil ? (mine, false) : textOnly.map { ([$0], true) } ?? ([], false)
            for selection in taken { removedLinks.insert(selection.link.path) }
            if !taken.isEmpty {
                removals.append(.init(model: id, textOnly: text, links: taken.map(\.name),
                                      command: ModelShelf.removalCommand(id, textOnly: text, installation: installation, models: models)))
            }
            for selection in mine where !taken.contains(where: { $0.id == selection.id }) && model.selections.contains(where: { $0.id == selection.id }) {
                add(selection.link.path, .selectionLink)
                removedLinks.insert(selection.link.path)
                issues.append(.noSplashCommand(link: selection.link.path))
            }
        }
        for selection in selections where !removedLinks.contains(selection.link.path) {
            switch selection.kind {
            case .assembly:
                add(selection.link.path, .selectionLink)
                issues.append(.noSplashCommand(link: selection.link.path))
            case .package, .broken:
                add(selection.link.path, .packageLink)
                let target = (try? FileManager.default.destinationOfSymbolicLink(atPath: selection.link.path)).map { URL(filePath: $0) }
                var files: String?
                if let target, target.deletingLastPathComponent().lastPathComponent == "snapshots" {
                    let repo = target.deletingLastPathComponent().deletingLastPathComponent()
                    if repo.lastPathComponent.hasPrefix("models--"), FileManager.default.fileExists(atPath: repo.path) {
                        files = repo.path
                        let bytes = DiskFile.files(in: repo.path).filter { $0.links == 1 }.reduce(Int64(0)) { $0 + countOnce($1, &freed) }
                        trash.append(.init(path: repo.path, what: .packageFiles, freedBytes: bytes))
                    }
                }
                issues.append(.obsoletePackage(link: selection.link.path, files: files))
            }
            removedLinks.insert(selection.link.path)
        }
        if !selections.isEmpty { issues.append(.splashDataLater) }

        if !removals.isEmpty, let models = facts.models {
            let staying = facts.selections.filter { !removedLinks.contains($0.link.path) }
            let kept = Set(staying.compactMap(\.assembly))
            var gone = Set(facts.unlinked)
            for selection in facts.selections where removedLinks.contains(selection.link.path) {
                if let assembly = selection.assembly, !kept.contains(assembly) { gone.insert(assembly) }
            }
            let planned = Set(trash.map(\.path))
            let keptFiles = Set(staying.flatMap(\.files).map(\.path))
            var risky: [String] = []
            for assembly in gone.sorted() {
                let folder = models.appending(path: ".resolved/\(assembly)")
                let record = facts.selections.first { $0.assembly == assembly }
                    ?? SelectionScanner.read(folder, hashed: true, models: models, data: models.standardizedFileURL.path)
                for file in hubEntries(record) where file.present && !planned.contains(file.path) && !keptFiles.contains(file.path) {
                    risky.append(file.path)
                }
            }
            if !risky.isEmpty { issues.append(.splashWouldDelete(paths: Array(Set(risky)).sorted())) }
        }

        let names = identifiers(model)
        let real = Set(model.files.map(\.real))
        let folders = model.sources.filter { source in
            source.weights?.format == .safetensors
        }.flatMap { [$0.path, realPath($0.path)] }
        for process in facts.processes {
            if let path = process.mapped.first(where: real.contains) {
                issues.append(.usedByProcess(pid: process.pid, name: process.name, path: path))
                continue
            }
            if let path = process.arguments.lazy.flatMap(argumentValues).first(where: { value in
                names.contains(value) || folders.contains { value.hasPrefix($0 + "/") }
            }) {
                issues.append(.usedByProcess(pid: process.pid, name: process.name, path: path))
            }
        }
        let configurations = facts.configurations.filter { uses($0, names) }.map(\.name).sorted()
        var removedConfigurations: [String] = []
        if !configurations.isEmpty {
            switch choices.configurations {
            case nil: issues.append(.configurationsNeedChoice(configurations))
            case .keep?: issues.append(.configurationsKept(configurations))
            case .remove?:
                removedConfigurations = configurations
                issues.append(.configurationsRemoved(configurations))
            }
        }
        let users = model.usedBy.filter { !removedLinks.contains($0.link.path) }.map { $0.model ?? $0.name }
        if !users.isEmpty {
            let unique = Array(Set(users)).sorted()
            issues.append(choices.breakPreparations ? .preparationsBroken(unique) : .usedByPreparations(unique))
        }

        let moved = trash.map(\.path)
        for link in symlinks(in: facts.linkRoots) {
            let destination = realPath(link)
            if moved.contains(where: { destination == $0 || destination.hasPrefix($0 + "/") }) { issues.append(.linkedFrom(link: link)) }
        }
        if freed.values.contains(where: { $0 > 0 }) { issues.append(.emptyTrashToFree) }
        return DeletionPlan(model: model, choices: choices, trash: trash, removals: removals, configurations: configurations,
                            removedConfigurations: removedConfigurations, otherAppPaths: otherAppPaths, issues: issues,
                            freedBytes: freed.values.reduce(0, +))
    }

    static func countOnce(_ file: DiskFile, _ freed: inout [DiskFile.Key: Int64]) -> Int64 {
        guard freed[file.key] == nil else { return 0 }
        freed[file.key] = file.bytes
        return file.bytes
    }

    static func hubRepository(_ path: String) -> String? {
        var url = URL(filePath: path)
        while url.pathComponents.count > 2 {
            if url.deletingLastPathComponent().lastPathComponent == "snapshots" {
                let repo = url.deletingLastPathComponent().deletingLastPathComponent()
                return repo.lastPathComponent.hasPrefix("models--") ? repo.path : nil
            }
            url = url.deletingLastPathComponent()
        }
        return nil
    }

    static func blobEntries(_ repo: String) -> [String: [String]] {
        var found: [String: [String]] = [:]
        for file in DiskFile.files(in: repo + "/snapshots") where file.path != file.real {
            found[file.real, default: []].append(file.path)
        }
        return found
    }

    static func hubEntries(_ selection: PreparedSelection) -> [RecordFile] {
        selection.files.filter { file in
            guard !file.inSplashData, hubRepository(file.path) != nil else { return false }
            if file.name.hasPrefix("draft/") { return selection.draftRevision != nil }
            return selection.targetRevision != nil
        }
    }

    static func identifiers(_ model: InventoryModel) -> Set<String> {
        var names = Set(model.hubModels)
        for source in model.sources where source.weights != nil {
            names.insert(source.path)
            names.insert(LocalWeightsScanner.splashPath(source.path))
            names.insert(realPath(source.path))
        }
        for selection in model.selections where selection.local {
            if let path = selection.model { names.insert(path) }
        }
        return names
    }

    static func argumentValues(_ argument: String) -> [String] {
        var values = [argument]
        if let equal = argument.firstIndex(of: "="), argument.hasPrefix("-") { values.append(String(argument[argument.index(after: equal)...])) }
        return values.flatMap { value -> [String] in
            let expanded = expandTilde(value)
            guard expanded.hasPrefix("/") else { return [value] }
            return [value, expanded, URL(filePath: expanded).standardizedFileURL.path, LocalWeightsScanner.splashPath(expanded)]
        }
    }

    public static func configurations(using model: InventoryModel, among configurations: [Configuration]) -> [Configuration] {
        let names = identifiers(model)
        return configurations.filter { uses($0, names) }
    }

    static func uses(_ configuration: Configuration, _ names: Set<String>) -> Bool {
        var values = [configuration.model]
        for flag in ["--draft-model", "--mmproj"] {
            if case let .value(value)? = configuration.parameters[flag] { values.append(value) }
        }
        return values.flatMap(argumentValues).contains(where: names.contains)
    }

    static func symlinks(in roots: [URL]) -> [String] {
        var found: [String] = []
        func walk(_ folder: URL, _ level: Int) {
            guard level < 3, let entries = try? FileManager.default.contentsOfDirectory(
                at: folder, includingPropertiesForKeys: [.isSymbolicLinkKey, .isDirectoryKey]) else { return }
            for entry in entries {
                let values = try? entry.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey])
                if values?.isSymbolicLink == true { found.append(entry.path) } else if values?.isDirectory == true { walk(entry, level + 1) }
            }
        }
        for root in roots { walk(root, 0) }
        return found
    }
}

public protocol Trash: Sendable {
    func move(_ url: URL) throws -> URL?
}

public struct SystemTrash: Trash {
    public init() {}

    public func move(_ url: URL) throws -> URL? {
        var result: NSURL?
        try FileManager.default.trashItem(at: url, resultingItemURL: &result)
        return result as URL?
    }
}

public enum OwnerAuthentication {
    public enum Outcome: Sendable, Equatable {
        case confirmed
        case cancelled
        case unavailable(String)
        case failed(String)
    }

    public static func confirm(reason: String) async -> Outcome {
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            return .unavailable(error?.localizedDescription ?? "")
        }
        do {
            return try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) ? .confirmed : .failed("")
        } catch let failure as LAError where [.userCancel, .appCancel, .systemCancel].contains(failure.code) {
            return .cancelled
        } catch {
            return .failed(error.localizedDescription)
        }
    }
}

public struct DeletionOutcome: Sendable, Equatable {
    public struct Moved: Sendable, Equatable {
        public let path: String
        public let trashed: String?
    }

    public var moved: [Moved] = []
    public var removals: [String: ModelShelf.RemovalOutcome] = [:]
    public var configurations: [String] = []
    public var failure: String?
}
