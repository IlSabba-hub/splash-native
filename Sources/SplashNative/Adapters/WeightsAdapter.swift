import NativeCore
import NativeUI
import Foundation

@MainActor
enum WeightsAdapter {
    static func choices(_ shelf: ModelShelf, role: LocalWeights.Role) -> [WeightsChoice] {
        var list = shelf.inventory.models.filter { $0.role == role }.compactMap { model in
            model.weights.first.map { choice(model, weights: $0, shelf: shelf) }
        }
        if role == .target { list += shelf.hubModels.map { hub($0, shelf: shelf) } }
        return list
    }

    static func choice(_ model: InventoryModel, weights: LocalWeights, shelf: ModelShelf) -> WeightsChoice {
        let path = ModelsAdapter.display(weights.path)
        return WeightsChoice(token: path, name: model.name, badges: badges(weights, shelf: shelf), size: model.bytes.map { NativeFormat.disk($0) },
                             detail: path, group: .mac,
                             unavailable: ModelsAdapter.incompleteReason(model))
    }

    static func badges(_ weights: LocalWeights, shelf: ModelShelf) -> [String] {
        var badges = [weights.format == .gguf ? tr("models.format.gguf") : tr("weights.badge.mlx")]
        if let quantization = ModelsAdapter.quantization(weights, header: shelf.headers[weights.path], ggufSource: "")?.text {
            badges.append(quantization)
        }
        return badges
    }

    static func hub(_ id: String, shelf: ModelShelf) -> WeightsChoice {
        let parts = id.split(separator: ":", maxSplits: 1).map(String.init)
        let repo = parts.first ?? id
        let model = shelf.inventory.models.first { $0.hubModels.contains(id) }
        return WeightsChoice(token: id, name: String(repo.split(separator: "/").last.map(String.init) ?? repo),
                             badges: parts.count > 1 ? [parts[1]] : [], size: model?.bytes.map { NativeFormat.disk($0) }, detail: id, group: .hub)
    }

    static func describe(_ value: String, among choices: [WeightsChoice], shelf: ModelShelf) -> WeightsChoice? {
        let value = value.trimmingCharacters(in: .whitespaces)
        guard !value.isEmpty else { return nil }
        if let known = choices.first(where: { $0.token == value }) { return known }
        let local = value.hasPrefix("/") || value.hasPrefix("~")
        guard local else { return hub(value, shelf: shelf) }
        let path = (value as NSString).expandingTildeInPath
        if let model = shelf.inventory.model(withSource: path) {
            let weights = model.weights.first { $0.path == path } ?? model.weights.first
            if let weights {
                let found = choice(model, weights: weights, shelf: shelf)
                return WeightsChoice(token: value, name: found.name, badges: found.badges, size: found.size, detail: value, group: .mac,
                                     unavailable: found.unavailable)
            }
        }
        return WeightsChoice(token: value, name: LocalWeights.displayName(path: path), detail: value, group: .mac)
    }

    static func control(_ flag: String, value: NativeUI.ParameterValue?, shelf: ModelShelf) -> SettingControl? {
        let role: LocalWeights.Role
        let unset: String
        switch flag {
        case "--draft-model":
            role = .draft
            unset = ParameterDescriptor.defaultEntry(word: tr("weights.draft.auto"), value: nil)
        case "--mmproj":
            role = .projector
            unset = tr("weights.projector.none")
        default:
            return nil
        }
        let choices = choices(shelf, role: role)
        let text: String? = if case let .text(path)? = value { path } else { nil }
        return .weights(choices, current: text.flatMap { describe($0, among: choices, shelf: shelf) }, unset: unset)
    }
}
