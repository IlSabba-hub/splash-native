import NativeCore
import NativeUI
import Foundation
import Observation

@MainActor @Observable
final class DiscoverState {
    let native: NativeModel
    let shelf: ModelShelf
    var onlyFitting = false
    var hubID = ""
    private(set) var selection: String?
    var search = ""
    var format = DiscoverFormat.all
    private(set) var cards: [String: Result<HubCard, Error>] = [:]
    private(set) var fetching: Set<String> = []
    private(set) var checked: (id: String, accepted: Bool, message: String?)?
    @ObservationIgnored private var store: Downloads?

    init(native: NativeModel, shelf: ModelShelf) {
        self.native = native
        self.shelf = shelf
    }

    var installation: SplashInstallation? { shelf.installation }

    var downloads: Downloads? {
        if let store { return store }
        guard let installation else { return nil }
        let made = Downloads(native: native, installation: installation)
        made.finished = { [shelf] _ in Task { await shelf.refresh() } }
        store = made
        return made
    }

    func select(_ id: String?) {
        selection = id
        guard let id else { return }
        let repo = HubCards.repo(of: id)
        if case .success? = cards[repo] { return }
        guard !fetching.contains(repo) else { return }
        fetching.insert(repo)
        Task {
            let result: Result<HubCard, Error>
            do { result = .success(try await HubCards.fetch(repo)) } catch { result = .failure(error) }
            cards[repo] = result
            fetching.remove(repo)
        }
    }

    func check() async {
        let id = hubID.trimmingCharacters(in: .whitespaces)
        guard let installation, !id.isEmpty else { return }
        do {
            let verdict = try await ParserVerdict.judge(["serve", "--model", id], with: installation)
            checked = (id, verdict.accepted, verdict.message)
        } catch {
            checked = (id, false, error.localizedDescription)
        }
    }
}

@MainActor
enum DiscoverAdapter {
    static func overview(_ state: DiscoverState) -> SectionState<DiscoverOverview> {
        guard let installation = state.installation, let downloads = state.downloads else {
            return .unavailable(reason: tr("models.noInstallation"))
        }
        let version = installation.version ?? installation.label
        let mac = DiscoverCatalog.macMemoryGB
        let cache = state.native.hubCache
        let free: Measured<String> = DiscoverCatalog.freeBytes(at: cache).map { .value(tr("discover.freeValue", NativeFormat.disk($0), ModelsAdapter.display(cache.path))) }
            ?? .unavailable(reason: tr("discover.freeUnknown"))
        let busy = downloads.running
        let consequence = tr("discover.consequence", ModelsAdapter.display(cache.path))
        let families = state.native.schemas[installation.id]?.families
        let budget = state.native.budget
        let items = DiscoverCatalog.entries(installation).map { entry in
            var tags: [ModelTag] = []
            if entry.installed { tags.append(ModelTag(tr("discover.installed"), symbol: "checkmark.circle.fill", tone: .ready)) }
            tags.append(entry.fits ? ModelTag(tr("discover.fits"), symbol: "checkmark", tone: .accent)
                        : ModelTag(tr("discover.doesNotFit", NativeFormat.count(entry.memoryGB)), symbol: "xmark", tone: .warning))
            let source = Provenance(source: .file(name: "install/suggested-models.tsv, Splash \(version)"))
            let facts = [
                Fact(title: tr("discover.memory"), value: .value(tr("discover.forMac", NativeFormat.count(entry.memoryGB))), provenance: source),
                Fact(title: tr("discover.size"), value: .value(tr("discover.gb", NativeFormat.count(entry.downloadGB))), provenance: source),
            ]
            let offer = entry.installed ? nil : DownloadOffer(
                model: entry.id, size: .value(tr("discover.sizeCatalog", NativeFormat.count(entry.downloadGB))), free: free,
                consequence: consequence, isEnabled: !busy, disabledReason: busy ? tr("discover.busy") : nil) {
                downloads.download(entry.id)
            }
            let family = families?.families[entry.name] != nil ? entry.name : nil
            let note = budget.map { budget in
                let bytes = Double(entry.downloadGB) * 1e9
                return tr(bytes <= Double(budget) ? "discover.budget.fits" : "discover.budget.over",
                          NativeFormat.count(entry.downloadGB), NativeFormat.memory(Int64(budget)))
            }
            return DiscoverItem(id: entry.id, name: entry.name, about: entry.about, repo: entry.repo, variant: entry.variant,
                                format: entry.format, family: family, capabilities: ModelsAdapter.capabilities(family, families),
                                tags: tags, facts: facts, fits: entry.fits, budgetNote: note, suggested: entry.suggested,
                                installed: entry.installed, offer: offer)
        }
        var download: DownloadStatus?
        if downloads.running, let model = downloads.model {
            let progress = downloads.progress
            var detail = progress.map { tr("discover.progress", NativeFormat.disk($0.done), NativeFormat.disk($0.total), $0.repo) }
                ?? tr("discover.preparing")
            if let remaining = downloads.remaining {
                detail += " · " + tr("discover.remaining", NativeFormat.duration(seconds: Double(remaining.components.seconds)))
            }
            download = DownloadStatus(model: model, fraction: progress.map { $0.total > 0 ? Double($0.done) / Double($0.total) : 0 },
                                      detail: detail,
                                      cancel: NativeAction(title: tr("discover.cancel"), systemImage: "xmark.circle") { downloads.cancel() })
        }
        var notices: [String] = []
        if let failure = downloads.failure { notices.append(tr("discover.failed", failure.model, failure.message)) }
        if let completed = downloads.completed { notices.append(tr("discover.completed", completed)) }
        var hubCheck: (message: String?, offer: DownloadOffer?)?
        if let checked = state.checked, checked.id == state.hubID.trimmingCharacters(in: .whitespaces) {
            hubCheck = checked.accepted
                ? (nil, DownloadOffer(model: checked.id, size: .unavailable(reason: tr("discover.sizeUnknown")), free: free,
                                      consequence: consequence, isEnabled: !busy, disabledReason: busy ? tr("discover.busy") : nil) {
                    downloads.download(checked.id)
                })
                : (checked.message ?? "", nil)
        }
        let facts = [
            Fact(title: tr("discover.mac"), value: .value(tr("discover.gb", NativeFormat.count(mac))),
                 provenance: Provenance(source: .system(name: "ProcessInfo.physicalMemory (Catalog.memory)"))),
            Fact(title: tr("discover.catalogSource"), value: .value(ModelsAdapter.display(installation.root.appending(path: "install/suggested-models.tsv").path)),
                 provenance: Provenance(source: .file(name: "Splash \(version)"))),
            Fact(title: tr("discover.free"), value: free, provenance: Provenance(source: .system(name: "volumeAvailableCapacityForImportantUsage"))),
        ]
        var hub: [String: HubState] = [:]
        for repo in state.fetching { hub[repo] = .loading }
        for (repo, result) in state.cards {
            switch result {
            case let .success(card): hub[repo] = .available(summary(card))
            case let .failure(error): hub[repo] = .unavailable(reason: error.localizedDescription)
            }
        }
        return .available(DiscoverOverview(facts: facts, items: items, download: download, notices: notices, hubCheck: hubCheck, hub: hub))
    }

    static func summary(_ card: HubCard) -> HubSummary {
        HubSummary(downloads: card.downloads.map { NativeFormat.count($0) }, likes: card.likes.map { NativeFormat.count($0) },
                   updated: card.lastModified.map { NativeFormat.ago($0) }, readme: card.readme,
                   source: tr("discover.hub.source", NativeFormat.moment(card.fetched)),
                   page: URL(string: "https://huggingface.co/" + card.repo))
    }
}
