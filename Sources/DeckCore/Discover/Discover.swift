import Foundation
import Observation

public struct CatalogEntry: Sendable, Equatable, Identifiable {
    public let id: String
    public let name: String
    public let memoryGB: Int
    public let downloadGB: Int
    public let about: String
    public let fits: Bool
    public let suggested: Bool
    public let installed: Bool

    public var variant: String { Catalog.variant(of: id) }

    public var format: String? {
        if id.contains(":") { return "GGUF" }
        return variant == "MLX" ? "MLX" : nil
    }

    public var repo: String { HubCards.repo(of: id) }
}

public enum ModelNames {
    public static func names(of ids: some Sequence<String>, installation: SplashInstallation?) -> [String: String] {
        let catalog = installation.map { Catalog(contentsOf: $0.runtime.suggestedModels) } ?? Catalog(text: "")
        return Dictionary(ids.map { ($0, $0.hasPrefix("/") ? LocalWeights.displayName(path: $0) : catalog.name(of: $0)) }) { first, _ in first }
    }
}

public enum DiscoverCatalog {
    public static func entries(_ installation: SplashInstallation, memoryGB: Int? = nil) -> [CatalogEntry] {
        entries(Catalog(contentsOf: installation.runtime.suggestedModels), installed: Set(installation.runtime.installedModels().map(\.id)),
                memoryGB: memoryGB ?? Catalog.memory)
    }

    static func entries(_ catalog: Catalog, installed: Set<String>, memoryGB: Int) -> [CatalogEntry] {
        let suggested = Set(catalog.suggestions(memory: memoryGB).map(\.id))
        return catalog.variants.map {
            CatalogEntry(id: $0.id, name: $0.name, memoryGB: $0.memory, downloadGB: $0.size, about: $0.about, fits: $0.memory <= memoryGB,
                         suggested: suggested.contains($0.id), installed: installed.contains($0.id))
        }
    }

    public static var macMemoryGB: Int { Catalog.memory }

    public static func hubCache(_ settings: [String: String]) -> URL {
        if let cache = settings["HF_HUB_CACHE"] { return URL(filePath: cache) }
        if let home = settings["HF_HOME"] { return URL(filePath: home).appending(path: "hub") }
        if let xdg = settings["XDG_CACHE_HOME"] { return URL(filePath: xdg).appending(path: "huggingface/hub") }
        return URL.homeDirectory.appending(path: ".cache/huggingface/hub")
    }

    public static func freeBytes(at folder: URL) -> Int64? {
        var url = folder
        while !FileManager.default.fileExists(atPath: url.path), url.path != "/" { url = url.deletingLastPathComponent() }
        return (try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?.volumeAvailableCapacityForImportantUsage
    }
}

@MainActor @Observable
public final class Downloads {
    public let deck: DeckModel
    @ObservationIgnored let installer: Installer
    @ObservationIgnored let runtime: Runtime
    @ObservationIgnored public var finished: (String) -> Void = { _ in }

    public private(set) var completed: String?

    public init(deck: DeckModel, installation: SplashInstallation,
                log: URL = URL.libraryDirectory.appending(path: "Logs/SplashDeck/downloads.log"),
                defaults: UserDefaults = .standard) {
        self.deck = deck
        runtime = installation.runtime
        try? FileManager.default.createDirectory(at: log.deletingLastPathComponent(), withIntermediateDirectories: true)
        installer = Installer(runtime: runtime, log: log, defaults: defaults)
        installer.installed = { [weak self] model in
            self?.completed = model
            self?.finished(model)
        }
    }

    @ObservationIgnored var overrides: [String: String] = [:]

    public var running: Bool { installer.running }
    public var model: String? { installer.model }

    public var progress: (repo: String, done: Int64, total: Int64)? {
        installer.progress.map { ($0.repo, $0.done, $0.total) }
    }

    public var remaining: Duration? { installer.remaining }

    public var failure: (model: String, message: String)? {
        guard let failure = installer.failure else { return nil }
        return (failure.model, Self.wording(log: installer.log, model: failure.model) ?? DeckText.downloadStoppedUnexpectedly)
    }

    public func download(_ model: String) {
        guard !installer.running else { return }
        completed = nil
        runtime.shellSettings.set(deck.shellSettings.merging(overrides) { $1 })
        installer.install(model)
    }

    public func cancel() { installer.cancel() }

    public func dismissFailure() { installer.dismissFailure() }

    nonisolated static func wording(log: URL, model: String) -> String? {
        guard let text = try? String(contentsOf: log, encoding: .utf8),
              let failure = text.split(whereSeparator: \.isNewline).reversed().lazy.compactMap({ Installer.Failure(line: String($0)) }).first
        else { return nil }
        return DeckText.downloadFailure(kind: failure.kind, message: failure.message, model: model, needed: failure.needed,
                                        available: failure.available)
    }
}

extension DeckModel {
    public var hubCache: URL { DiscoverCatalog.hubCache(shellSettings) }
}
