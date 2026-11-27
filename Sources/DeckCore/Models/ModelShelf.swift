import Foundation
import Observation

@MainActor @Observable
public final class ModelShelf {
    public let deck: DeckModel
    public var roots: [URL]

    public private(set) var selections: [PreparedSelection] = []
    public private(set) var unlinked: [String] = []
    public private(set) var weights: [LocalWeights] = []
    public private(set) var hubWeights: [LocalWeights] = []
    public private(set) var inventory = ModelInventory.empty
    public private(set) var headers: [String: ModelTools.GGUFHeader] = [:]
    public private(set) var verifications: [String: ModelTools.Verification] = [:]
    public private(set) var verifying: [String: Bool] = [:]
    public private(set) var verifyErrors: [String: String] = [:]
    public private(set) var removing: String?
    public private(set) var removals: [String: RemovalOutcome] = [:]
    public private(set) var configurationLinks: [String: URL] = [:]
    public private(set) var scanned: Date?
    public private(set) var scanning = false

    public init(deck: DeckModel, roots: [URL] = LocalWeightsScanner.defaultRoots, hubCache: URL? = nil) {
        self.deck = deck
        self.roots = roots
        self.hubCache = hubCache
    }

    public var installation: SplashInstallation? {
        deck.installations.first { $0.linked } ?? deck.installations.first
    }

    public var modelsFolder: URL? { modelsOverride ?? installation?.models }

    @ObservationIgnored public var modelsOverride: URL?
    @ObservationIgnored public var commandEnvironment: [String: String]?

    public var hubCache: URL?

    public func refresh() async {
        guard !scanning else { return }
        scanning = true
        defer { scanning = false }
        let models = modelsFolder
        let roots = roots
        let hub = hubCache
        let (selections, unlinked, weights, hubWeights, inventory) = await Task.detached {
            let selections = models.map { SelectionScanner.scan(models: $0) } ?? []
            let unlinked = models.map { SelectionScanner.unlinkedAssemblies(models: $0, selections: selections) } ?? []
            let weights = LocalWeightsScanner.scan(roots: roots)
            let hubWeights = hub.map { LocalWeightsScanner.scan(roots: [$0]) } ?? []
            let inventory = ModelInventory.build(selections: selections, weights: weights, hubCache: hubWeights)
            return (selections, unlinked, weights, hubWeights, inventory)
        }.value
        self.selections = selections
        self.unlinked = unlinked
        self.weights = weights
        self.hubWeights = hubWeights
        self.inventory = inventory
        scanned = .now
        if let installation {
            let missing = weights.filter { $0.format == .gguf && headers[$0.path] == nil }.map(\.path)
            if let read = try? await ModelTools.ggufHeaders(missing, with: installation) {
                headers.merge(read) { $1 }
            }
        }
        await refreshLinks()
    }

    public func preparations(of weights: LocalWeights) -> [PreparedSelection] {
        let path = LocalWeightsScanner.splashPath(weights.path)
        return selections.filter { $0.model == path }
    }

    public func preparations(ofHub model: String) -> [PreparedSelection] {
        selections.filter { !$0.local && $0.model == model }
    }

    public var hubModels: [String] {
        var seen: [String] = []
        for selection in selections where !selection.local {
            if let model = selection.model, !seen.contains(model) { seen.append(model) }
        }
        return seen
    }

    public var preparedElsewhere: [PreparedSelection] {
        let known = Set(weights.map { LocalWeightsScanner.splashPath($0.path) })
        return selections.filter { $0.local && !known.contains($0.model ?? "") }
    }

    public func verify(_ selection: PreparedSelection, full: Bool) async {
        guard let installation, verifying[selection.id] == nil else { return }
        verifying[selection.id] = full
        verifyErrors[selection.id] = nil
        defer { verifying[selection.id] = nil }
        do {
            verifications[selection.id] = try await ModelTools.verify(selection.link, full: full, with: installation)
        } catch {
            verifyErrors[selection.id] = error.localizedDescription
        }
    }

    public enum RemovalOutcome: Sendable, Equatable {
        case removed(freed: Int64)
        case failed(message: String)
    }

    public func removalVerdict(_ selection: PreparedSelection) -> RemovalVerdict {
        RemovalVerdict.judge(selection, among: selections, unlinked: unlinked)
    }

    public func remove(_ selection: PreparedSelection) async {
        guard removing == nil, let installation, let models = modelsFolder else { return }
        removing = selection.model ?? selection.name
        defer { removing = nil }
        while scanning { try? await Task.sleep(for: .milliseconds(50)) }
        await refresh()
        guard let fresh = selections.first(where: { $0.id == selection.id }),
              case .allowed(let model, _, _) = removalVerdict(fresh)
        else { return }
        removing = model
        let textOnly = fresh.hashed
        let runtime = installation.runtime
        runtime.shellSettings.set(deck.shellSettings)
        let command = Self.removalCommand(model, textOnly: textOnly, installation: installation, models: models)
        do {
            let result = try await Command.run(command, environment: runtime.environment, timeout: .seconds(300))
            removals[model] = Self.outcome(of: result)
        } catch {
            removals[model] = .failed(message: error.localizedDescription)
        }
        await refresh()
    }

    nonisolated static func removalCommand(_ model: String, textOnly: Bool, installation: SplashInstallation, models: URL) -> [String] {
        var command = installation.runtime.removeCommand(model, textOnly: textOnly)
        if models.standardizedFileURL != installation.models.standardizedFileURL,
           let script = command.firstIndex(where: { $0.hasSuffix("install/models.py") }) {
            command.insert(contentsOf: ["--models", models.path], at: script + 1)
        }
        return command
    }

    nonisolated static func outcome(of result: Command.Result) -> RemovalOutcome {
        struct Event: Decodable { let event: String; let bytes: Int64?; let message: String? }
        let events = result.text.split(separator: "\n").compactMap { try? JSONDecoder().decode(Event.self, from: Data($0.utf8)) }
        if result.status == 0, let removed = events.last(where: { $0.event == "removed" }) {
            return .removed(freed: removed.bytes ?? 0)
        }
        let message = events.last(where: { $0.event == "error" })?.message
            ?? result.errorText.trimmingCharacters(in: .whitespacesAndNewlines)
        return .failed(message: message)
    }

    public private(set) var deleting: String?
    public private(set) var deletions: [String: DeletionOutcome] = [:]

    public func deletionPlan(for id: String, choices: DeletionChoices = DeletionChoices()) async -> DeletionPlan? {
        while scanning { try? await Task.sleep(for: .milliseconds(50)) }
        await refresh()
        guard let model = inventory.model(id) else { return nil }
        let facts = DeletionFacts(inventory: inventory, selections: selections, unlinked: unlinked, models: modelsFolder,
                                  installation: installation, configurations: deck.configurations, processes: [], linkRoots: roots)
        let scan = processScan
        return await Task.detached {
            var facts = facts
            facts.processes = scan()
            return DeletionPlanner.plan(model, facts: facts, choices: choices)
        }.value
    }

    @ObservationIgnored public var processScan: @Sendable () -> [RunningProcess] = { RunningProcess.scan() }

    @discardableResult
    public func delete(_ plan: DeletionPlan, trash: any Trash = SystemTrash(),
                       confirm: @escaping @Sendable () async -> OwnerAuthentication.Outcome) async -> DeletionOutcome {
        var outcome = DeletionOutcome()
        guard deleting == nil else { return outcome }
        deleting = plan.model.name
        defer { deleting = nil }
        guard let fresh = await deletionPlan(for: plan.model.id, choices: plan.choices),
              fresh.trash == plan.trash, fresh.removals == plan.removals, fresh.removedConfigurations == plan.removedConfigurations,
              fresh.canProceed
        else {
            outcome.failure = DeckText.deletionChanged
            deletions[plan.model.name] = outcome
            return outcome
        }
        switch await confirm() {
        case .confirmed: break
        case .cancelled: outcome.failure = DeckText.deletionCancelled
        case let .unavailable(reason): outcome.failure = DeckText.deletionAuthUnavailable(reason)
        case let .failed(reason): outcome.failure = DeckText.deletionAuthFailed(reason)
        }
        guard outcome.failure == nil else {
            deletions[plan.model.name] = outcome
            return outcome
        }
        let ordered = fresh.trash.filter { $0.what != .selectionLink && $0.what != .packageLink }
            + fresh.trash.filter { $0.what == .selectionLink || $0.what == .packageLink }
        for item in ordered {
            let url = URL(filePath: item.path)
            guard FileManager.default.fileExists(atPath: item.path)
                    || (try? FileManager.default.destinationOfSymbolicLink(atPath: item.path)) != nil else { continue }
            do {
                let moved = try await Task.detached { try trash.move(url) }.value
                outcome.moved.append(.init(path: item.path, trashed: moved?.path))
            } catch {
                outcome.failure = DeckText.deletionTrashFailed(item.path, error.localizedDescription)
                break
            }
        }
        if outcome.failure == nil, let installation {
            let runtime = installation.runtime
            runtime.shellSettings.set(deck.shellSettings)
            for removal in fresh.removals {
                do {
                    let result = try await Command.run(removal.command, environment: commandEnvironment ?? runtime.environment,
                                                       timeout: .seconds(300))
                    let removed = Self.outcome(of: result)
                    outcome.removals[removal.model] = removed
                    if case let .failed(message) = removed {
                        outcome.failure = message
                        break
                    }
                } catch {
                    outcome.removals[removal.model] = .failed(message: error.localizedDescription)
                    outcome.failure = error.localizedDescription
                    break
                }
            }
        }
        if outcome.failure == nil {
            for name in fresh.removedConfigurations {
                guard let configuration = deck.configurations.first(where: { $0.name == name }) else { continue }
                do {
                    try await deck.remove(configuration, message: DeckText.deletionCommit(name, plan.model.name))
                    outcome.configurations.append(name)
                } catch {
                    outcome.failure = DeckText.deletionConfigurationFailed(name, error.localizedDescription)
                    break
                }
            }
        }
        deletions[plan.model.name] = outcome
        await refresh()
        return outcome
    }

    public func refreshLinks() async {
        var links: [String: URL] = [:]
        var byInstallation: [SplashInstallation: [(String, [String])]] = [:]
        for configuration in deck.configurations {
            guard let plan = try? await deck.plan(for: configuration) else { continue }
            byInstallation[plan.installation, default: []].append((configuration.name, plan.serveArguments))
        }
        for (installation, lines) in byInstallation {
            guard let found = try? await ModelTools.selectionLinks(lines.map(\.1), with: installation, models: installation.models)
            else { continue }
            for (line, link) in zip(lines, found) { links[line.0] = link }
        }
        configurationLinks = links
    }

    public struct SharedSelection: Sendable, Equatable, Identifiable {
        public let link: String
        public let users: [(configuration: String, version: String)]
        public var id: String { link }

        public static func == (a: SharedSelection, b: SharedSelection) -> Bool {
            a.link == b.link && a.users.map(\.configuration) == b.users.map(\.configuration) && a.users.map(\.version) == b.users.map(\.version)
        }
    }

    public var sharedSelections: [SharedSelection] {
        Self.shared(links: configurationLinks, configurations: deck.configurations, installations: deck.installations)
    }

    nonisolated static func shared(links: [String: URL], configurations: [Configuration],
                                   installations: [SplashInstallation]) -> [SharedSelection] {
        var groups: [String: [(String, SplashInstallation)]] = [:]
        for configuration in configurations {
            guard let link = links[configuration.name], let installation = configuration.installation(among: installations) else { continue }
            groups[link.path, default: []].append((configuration.name, installation))
        }
        return groups.compactMap { link, users in
            guard Set(users.map(\.1.root)).count > 1 else { return nil }
            return SharedSelection(link: link, users: users.sorted { $0.0 < $1.0 }.map { ($0.0, $0.1.label) })
        }.sorted { $0.link < $1.link }
    }

    public func configurations(using link: URL) -> [Configuration] {
        deck.configurations.filter { configurationLinks[$0.name]?.standardizedFileURL == link.standardizedFileURL }
    }
}
