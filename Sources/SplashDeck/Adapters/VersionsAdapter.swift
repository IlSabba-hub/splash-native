import AppKit
import DeckCore
import DeckUI
import Observation
import SwiftUI

@MainActor @Observable
final class VersionsController {
    private(set) var releases: [AvailableVersions.Release]?
    private(set) var checkedAt: Date?
    private(set) var checking = false
    private(set) var checkError: String?
    private(set) var upgrade: VersionUpgrade.State = .idle
    private(set) var cached: [VersionSchema] = []

    func checkGitHub(navigation: DeckNavigation, model: DeckModel) {
        guard !checking else { return }
        checking = true
        checkError = nil
        Task {
            do {
                releases = try await AvailableVersions.fetchReleases()
                checkedAt = .now
            } catch {
                checkError = error.localizedDescription
            }
            checking = false
            refreshUpdateBadge(navigation: navigation, model: model)
        }
    }

    func reloadCachedSchemas(_ model: DeckModel) async {
        let store = model.schemaStore
        cached = await Task.detached { store.cachedSchemas() }.value
    }

    func refreshUpdateBadge(navigation: DeckNavigation, model: DeckModel) {
        navigation.updateAvailable = SplashUpgrade.newer(than: model.installations, offers: offers) != nil
    }

    var offers: [AvailableVersions.Offer] {
        AvailableVersions.fromTap() + (releases.map(AvailableVersions.offers) ?? [])
    }

    func runUpgrade(_ action: SplashUpgrade.Action, model: DeckModel, navigation: DeckNavigation) {
        guard upgrade != .running else { return }
        upgrade = .running
        Task {
            do {
                let outcome = try await SplashUpgrade.run(action)
                upgrade = .finished(status: outcome.status, output: outcome.output)
            } catch {
                upgrade = .failed(reason: error.localizedDescription)
            }
            model.refreshInstallations()
            for installation in model.installations { _ = try? await model.schema(for: installation) }
            await reloadCachedSchemas(model)
            refreshUpdateBadge(navigation: navigation, model: model)
        }
    }
}

struct VersionsSection: View {
    private let services = AppServices.shared

    var body: some View {
        SectionPage(.versions, state: VersionsAdapter.content(services: services)) { VersionsScreen($0) }
            .task {
                let model = services.model
                for installation in model.installations { _ = try? await model.schema(for: installation) }
                await services.versions.reloadCachedSchemas(model)
                services.versions.refreshUpdateBadge(navigation: services.navigation, model: model)
            }
    }
}

@MainActor
enum VersionsAdapter {
    static func content(services: AppServices) -> SectionState<VersionsContent> {
        let model = services.model, controller = services.versions, navigation = services.navigation
        let installations = model.installations
        let newest = installations.compactMap(\.version).map(SplashVersion.init).max()
        func isNewer(_ version: String) -> Bool { newest.map { SplashVersion(version) > $0 } ?? true }

        let releases = (controller.releases ?? []).filter { !$0.draft }
            .sorted { SplashVersion($0.tagName) > SplashVersion($1.tagName) }
            .prefix(6)
        let installedVersions = Set(installations.compactMap(\.version).map(SplashVersion.init))
        func note(_ version: String) -> VersionReleaseNote? {
            releases.first { SplashVersion($0.tagName) == SplashVersion(version) }.map {
                VersionReleaseNote(version: $0.tagName, title: $0.name, published: $0.publishedAt, prerelease: $0.prerelease,
                                   body: $0.body, url: $0.htmlURL, installed: installedVersions.contains(SplashVersion($0.tagName)))
            }
        }

        let roots = model.supervisor.owned.map(\.installationRoot) + model.found.map(\.root.path)
        var rows = installations.map { installation in
            let schema: Measured<String> = if let schema = model.schemas[installation.id] {
                .value(tr("versions.schema.value", DeckFormat.count(schema.serve.parameters.count)))
            } else { .unavailable(reason: tr("versions.schema.pending")) }
            let root = installation.root
            let version = installation.version ?? DeckText.sourceCheckout
            return VersionRow(
                id: installation.id, version: version, state: installation.linked ? .inUse : .installed,
                source: DeckText.kind(installation.kind, linked: installation.linked), path: root.path,
                date: note(version)?.published, schema: schema, servers: roots.filter { $0 == root.path }.count,
                notes: note(version),
                reveal: DeckAction(title: tr("action.showInFinder"), systemImage: "folder") {
                    NSWorkspace.shared.activateFileViewerSelecting([root])
                })
        }

        let tap = AvailableVersions.fromTap()
        let tapDate = SplashUpgrade.tapFormulaDate()
        let offers: [(version: String, channel: String, date: Date?)] =
            tap.map { ($0.version, tr($0.channel == .cask ? "versions.source.cask" : "versions.source.formula"), tapDate) }
            + releases.map { ($0.tagName, tr("versions.source.github"), $0.publishedAt) }
        let offered = Dictionary(grouping: offers.filter { !installedVersions.contains(SplashVersion($0.version)) }) { $0.version }
            .mapValues { group in (channels: group.map(\.channel), date: group.compactMap(\.date).max()) }
        rows += offered.map { version, offer in
            VersionRow(id: "offer-\(version)", version: version, state: isNewer(version) ? .update : .older,
                       source: offer.channels.joined(separator: " · "), path: nil, date: offer.date, schema: nil, servers: 0,
                       notes: note(version), reveal: nil)
        }
        rows.sort { SplashVersion($0.version) > SplashVersion($1.version) }

        let check = DeckAction(title: tr("versions.github.check"), systemImage: "arrow.down.circle") {
            controller.checkGitHub(navigation: navigation, model: model)
        }
        let github: VersionsGitHub = if controller.checking {
            .checking
        } else if let error = controller.checkError {
            .failed(reason: error, retry: check)
        } else if let at = controller.checkedAt {
            .checked(at: at, refresh: check)
        } else {
            .notChecked(check: check)
        }

        let known = (controller.cached + Array(model.schemas.values)).filter { $0.installation.version != nil }
        let latestSchemas = Dictionary(grouping: known) { $0.installation.version ?? "" }.values.compactMap { group in
            group.max { $0.generated < $1.generated }
        }
        let ordered = latestSchemas.sorted { SplashVersion($0.installation.version!) > SplashVersion($1.installation.version!) }
        var diffs: [VersionDiff] = []
        for (index, newer) in ordered.enumerated() {
            for older in ordered.dropFirst(index + 1) {
                diffs.append(diff(SchemaDiff(from: older.serve, version: older.installation.version!,
                                             to: newer.serve, version: newer.installation.version!), older: older, newer: newer))
            }
        }

        let action = SplashUpgrade.action(for: installations)
        let newerVersion = SplashUpgrade.newer(than: installations, offers: controller.offers)
        let enabled = action == .install || newerVersion != nil
        let command = SplashUpgrade.display(action)
        let newerChannels = newerVersion.flatMap { offered[$0]?.channels.joined(separator: " · ") }
        let upgradeAction = DeckAction(
            title: tr(action == .install ? "versions.upgrade.install" : "versions.upgrade.upgrade"), systemImage: "arrow.down.app",
            role: .destructive(question: tr("versions.upgrade.question", command),
                               consequence: tr(action == .install ? "versions.upgrade.installConsequence" : "versions.upgrade.consequence"),
                               confirmTitle: tr("versions.upgrade.confirm")),
            isEnabled: enabled && controller.upgrade != .running,
            disabledReason: enabled ? nil : tr("versions.upgrade.nothingNewer")) {
                controller.runUpgrade(action, model: model, navigation: navigation)
            }

        return .available(VersionsContent(
            rows: .available(rows), github: github,
            upgrade: VersionUpgrade(command: command,
                                    newer: newerVersion.map { version in newerChannels.map { tr("versions.update.newer", version, $0) } ?? version },
                                    action: upgradeAction, state: controller.upgrade, note: tr("versions.upgrade.note")),
            diffs: diffs, schemaVersions: ordered.compactMap(\.installation.version)))
    }

    static func diff(_ diff: SchemaDiff, older: VersionSchema, newer: VersionSchema) -> VersionDiff {
        func changes(_ list: [SchemaDiff.Change]) -> [VersionDiff.Change] {
            list.map { .init(flag: $0.flag, before: $0.before, after: $0.after) }
        }
        let source = tr("versions.diff.source", diff.from, DeckFormat.moment(older.generated), diff.to, DeckFormat.moment(newer.generated))
        return VersionDiff(from: diff.from, to: diff.to, added: diff.added, removed: diff.removed, defaults: changes(diff.defaults),
                           needs: changes(diff.needs), parsers: changes(diff.parsers), environment: changes(diff.environment),
                           help: changes(diff.help), source: source)
    }
}
