import NativeCore
import NativeUI
import Foundation
import Observation

@MainActor @Observable
final class ConfigurationsState {
    let native: NativeModel
    let shelf: ModelShelf

    private(set) var selection: String?
    var header = ConfigurationHeader(name: "", installation: "", model: "", apiModelID: "", port: nil, principal: false,
                                     usesAPIKey: false, apiKey: "") {
        didSet {
            if !opening, header.installation != oldValue.installation || header.model != oldValue.model { Task { await loadSchema() } }
        }
    }
    var values: [String: NativeUI.ParameterValue] = [:]
    private var opening = false
    var search = ""

    private(set) var base: Configuration?
    private(set) var isOpen = false
    private(set) var schema: VersionSchema?
    private(set) var schemaError: String?
    private(set) var family: String?
    private(set) var fields: [EditorField] = []
    private(set) var groups: [EditorGroup] = []

    private(set) var assessment: NativeModel.Assessment?
    private(set) var verifyFailure: String?
    private(set) var verified: Date?
    private(set) var verifying = false
    var showsEditor = false
    var showsInapplicable = false

    private(set) var history: [ConfigurationStore.Change] = []
    private(set) var historySelection: String?
    private(set) var historyConfiguration: Configuration?

    private(set) var notices: [String] = []

    init(native: NativeModel, shelf: ModelShelf) {
        self.native = native
        self.shelf = shelf
    }

    func select(_ name: String?) {
        guard let name, let configuration = native.configurations.first(where: { $0.name == name }) else {
            selection = nil
            isOpen = false
            return
        }
        selection = name
        open(configuration, isNew: false)
    }

    private func open(_ configuration: Configuration, isNew: Bool, values edited: Configuration? = nil) {
        base = isNew ? nil : configuration
        isOpen = true
        assessment = nil
        verifyFailure = nil
        verified = nil
        historySelection = nil
        historyConfiguration = nil
        values = [:]
        fields = []
        groups = []
        let key = configuration.usesAPIKey && !isNew ? ((try? APIKeys.read(configuration.name)) ?? nil) ?? "" : ""
        let shown = edited ?? configuration
        let installation = shown.installation(among: native.installations)
        pending = shown
        opening = true
        defer { opening = false }
        header = ConfigurationHeader(name: shown.name, installation: installation?.id ?? "", model: shown.model,
                                     apiModelID: shown.apiModelID ?? "", port: shown.port,
                                     principal: shown.principal, usesAPIKey: shown.usesAPIKey, apiKey: key,
                                     observe: shown.observe)
        Task {
            await loadSchema()
            await loadHistory()
        }
    }

    private var pending: Configuration?

    var installation: SplashInstallation? { native.installations.first { $0.id == header.installation } }

    func loadSchema() async {
        guard isOpen else { return }
        guard let installation else {
            schema = nil
            schemaError = tr("config.noVersion")
            return
        }
        do {
            let schema = try await native.schema(for: installation)
            for other in native.installations where other.id != installation.id && native.schemas[other.id] == nil {
                _ = try? await native.schema(for: other)
            }
            let others = native.installations.compactMap { native.schemas[$0.id] }
            let source = pending ?? current()
            pending = nil
            let previous = values
            self.schema = schema
            schemaError = nil
            family = native.family(of: source, in: installation)
            groups = ConfigurationEditor.groups(for: source, schema: schema, family: family, others: others)
            fields = groups.flatMap(\.fields)
            var fresh: [String: NativeUI.ParameterValue] = [:]
            for field in fields { fresh[field.flag] = previous[field.flag] ?? ConfigurationsAdapter.ui(field.value) }
            values = fresh
        } catch {
            schema = nil
            schemaError = error.localizedDescription
        }
    }

    private func loadHistory() async {
        guard let base else {
            history = []
            return
        }
        history = (try? await native.store.history(base.name)) ?? []
    }

    func current() -> Configuration {
        let installation = installation
        var parameters = base?.parameters ?? [:]
        if !fields.isEmpty {
            let editor = values.mapValues(ConfigurationsAdapter.core)
            parameters = ConfigurationEditor.parameters(editor, fields: fields)
        }
        return Configuration(
            name: header.name.trimmingCharacters(in: .whitespaces),
            splashVersion: installation?.version ?? base?.splashVersion,
            installationRoot: installation?.kind == .checkout ? installation?.root.path : nil,
            model: header.model.trimmingCharacters(in: .whitespaces),
            apiModelID: header.isLocal ? header.apiModelID.trimmingCharacters(in: .whitespaces) : nil,
            port: header.port ?? 0, principal: header.principal, parameters: parameters,
            usesAPIKey: header.usesAPIKey, origin: base?.origin, observe: header.observe)
    }

    var problems: [String: String] {
        guard let schema else { return [:] }
        var found: [String: String] = [:]
        let configuration = current()
        if case .failure(let problems) = LaunchPlan.make(configuration, schema: schema, family: family) {
            for problem in problems.list { found[problem.field] = problem.message }
        }
        if configuration.model.isEmpty { found["model"] = tr("config.model.missing") }
        if base?.name != configuration.name, native.configurations.contains(where: { $0.name == configuration.name }) {
            found["name"] = tr("config.name.taken", configuration.name)
        }
        if configuration.usesAPIKey && header.apiKey.isEmpty && (base?.usesAPIKey != true) {
            found["--api-key"] = tr("config.key.missing")
        }
        return found
    }

    var changed: Bool { base.map { $0 != current() } ?? true }

    func save() async {
        let configuration = current()
        guard problems.keys.allSatisfy({ $0.hasPrefix("--") && $0 != "--api-key" }) else { return }
        do {
            if configuration.usesAPIKey {
                if !header.apiKey.isEmpty { try APIKeys.write(header.apiKey, for: configuration.name) }
            } else {
                try APIKeys.write(nil, for: configuration.name)
            }
            let renamed = base.map { $0.name != configuration.name } ?? false
            try await native.save(configuration, message: base == nil ? tr("config.commit.new", configuration.name)
                                : renamed ? tr("config.commit.renamed", base!.name, configuration.name)
                                : tr("config.commit.saved", configuration.name))
            if renamed, let old = base {
                try await native.remove(old, message: tr("config.commit.renamedAway", old.name, configuration.name))
                if old.usesAPIKey, header.apiKey.isEmpty, let key = try? APIKeys.read(old.name) { try APIKeys.write(key, for: configuration.name) }
                try? APIKeys.write(nil, for: old.name)
            }
            notices = [tr("config.saved", configuration.name)]
            await shelf.refreshLinks()
            select(configuration.name)
        } catch {
            notices = [tr("config.saveFailed", error.localizedDescription)]
        }
    }

    func verify() async {
        verifying = true
        defer { verifying = false }
        assessment = nil
        verifyFailure = nil
        do {
            assessment = try await native.assess(current(), apiKey: header.usesAPIKey ? keyForLaunch : nil)
        } catch let problems as LaunchPlan.Problems {
            verifyFailure = problems.list.map(\.message).joined(separator: "\n")
        } catch {
            verifyFailure = error.localizedDescription
        }
        verified = .now
    }

    private var keyForLaunch: String? {
        if !header.apiKey.isEmpty { return header.apiKey }
        return base.flatMap { (try? APIKeys.read($0.name)) ?? nil }
    }

    func duplicate() async {
        var copy = current()
        copy.name = ConfigurationEditor.freeName(copy.name + "-copia", among: native.configurations.map(\.name))
        copy.principal = false
        do {
            if copy.usesAPIKey, let key = keyForLaunch { try APIKeys.write(key, for: copy.name) }
            try await native.save(copy, message: tr("config.commit.duplicated", copy.name, header.name))
            notices = [tr("config.duplicated", copy.name)]
            select(copy.name)
        } catch {
            notices = [tr("config.saveFailed", error.localizedDescription)]
        }
    }

    @discardableResult
    func remove() async -> Bool {
        guard let base else { return false }
        do {
            try await native.remove(base, message: tr("config.commit.removed", base.name))
            try? APIKeys.write(nil, for: base.name)
            notices = [tr("config.removed", base.name)]
            select(nil)
            return true
        } catch {
            notices = [tr("config.saveFailed", error.localizedDescription)]
            return false
        }
    }

    func dropForeignFlags() {
        for field in fields where field.state != .active {
            if case .noEffect = field.state { continue }
            values[field.flag] = .unset
        }
    }

    func selectHistory(_ commit: String) async {
        guard let base else { return }
        if historySelection == commit {
            historySelection = nil
            historyConfiguration = nil
            return
        }
        historySelection = commit
        historyConfiguration = try? await native.store.configuration(base.name, at: commit)
    }

    func restoreHistory() async {
        guard let old = historyConfiguration, let commit = historySelection else { return }
        do {
            try await native.save(old, message: tr("config.commit.restored", old.name, String(commit.prefix(8))))
            notices = [tr("config.restored", old.name)]
            select(old.name)
        } catch {
            notices = [tr("config.saveFailed", error.localizedDescription)]
        }
    }

    func openEditor(_ configuration: Configuration, isNew: Bool) {
        notices = []
        search = ""
        if !isNew, let saved = native.configurations.first(where: { $0.name == configuration.name }) {
            selection = saved.name
            open(saved, isNew: false, values: saved == configuration ? nil : configuration)
        } else {
            selection = nil
            open(configuration, isNew: true)
            history = []
        }
        showsEditor = true
    }

    func closeEditor() {
        showsEditor = false
    }

    private(set) var panelFailure: String?

    func edit(_ name: String) {
        guard let saved = native.configurations.first(where: { $0.name == name }) else { return }
        openEditor(saved, isNew: false)
    }

    func portForNew() -> Int { ModelPort.shared.port }

    func newBlank() {
        let installation = native.installations.first { $0.linked } ?? native.installations.first
        let name = ConfigurationEditor.freeName(tr("profiles.new.blankName"), among: native.configurations.map(\.name))
        openEditor(Configuration(name: name, splashVersion: installation?.version, model: "", apiModelID: nil, port: portForNew(),
                                 parameters: [:]), isNew: true)
    }

    func duplicate(named name: String) async {
        guard let saved = native.configurations.first(where: { $0.name == name }) else { return }
        var copy = saved
        copy.name = ConfigurationEditor.freeName(name + "-copia", among: native.configurations.map(\.name))
        copy.principal = false
        do {
            if saved.usesAPIKey, let key = (try? APIKeys.read(saved.name)) ?? nil { try APIKeys.write(key, for: copy.name) }
            try await native.save(copy, message: tr("config.commit.duplicated", copy.name, name))
            panelFailure = nil
            edit(copy.name)
        } catch {
            panelFailure = tr("config.saveFailed", error.localizedDescription)
        }
    }

    func renameProblem(_ old: String, to new: String) -> String? {
        let new = new.trimmingCharacters(in: .whitespaces)
        if new == old { return nil }
        if !Configuration.validName(new) { return NativeText.problem(.invalidName(new)) }
        if native.configurations.contains(where: { $0.name == new }) { return tr("config.name.taken", new) }
        return nil
    }

    func rename(_ old: String, to new: String) async {
        guard let saved = native.configurations.first(where: { $0.name == old }), renameProblem(old, to: new) == nil else { return }
        var renamed = saved
        renamed.name = new.trimmingCharacters(in: .whitespaces)
        do {
            try await native.save(renamed, message: tr("config.commit.renamed", old, renamed.name))
            try await native.remove(saved, message: tr("config.commit.renamedAway", old, renamed.name))
            if saved.usesAPIKey, let key = try? APIKeys.read(old) { try APIKeys.write(key, for: renamed.name) }
            try? APIKeys.write(nil, for: old)
            panelFailure = nil
            await shelf.refreshLinks()
        } catch {
            panelFailure = tr("config.saveFailed", error.localizedDescription)
        }
    }

    func remove(named name: String) async {
        guard let saved = native.configurations.first(where: { $0.name == name }) else { return }
        do {
            try await native.remove(saved, message: tr("config.commit.removed", name))
            try? APIKeys.write(nil, for: name)
            panelFailure = nil
            if base?.name == name { select(nil) }
        } catch {
            panelFailure = tr("config.saveFailed", error.localizedDescription)
        }
    }
}
