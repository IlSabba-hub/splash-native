import Foundation

extension DeckModel {
    public var memoryCalibrations: [String: MemoryCalibration] {
        if let calibrationCache { return calibrationCache }
        let loaded = calibrationStore.load()
        calibrationCache = loaded
        return loaded
    }

    public func calibration(for configuration: Configuration) -> MemoryCalibration? {
        memoryFingerprint(configuration).flatMap { memoryCalibrations[$0] }
    }

    public func forecast(_ configuration: Configuration, physical: UInt64 = ProcessInfo.processInfo.physicalMemory) -> MemoryForecast? {
        guard let budget, let installation = configuration.installation(among: installations),
              let rules = SplashMemoryRules.of(version: installation.version),
              let geometry = FamilyGeometry.of(family: memoryFamily(of: configuration, in: installation), rules: rules)
        else { return nil }
        let parameters = configuration.parameters
        func text(_ flag: String) -> String? { if case .value(let value)? = parameters[flag] { value } else { nil } }
        var automaticExperts = configuration
        automaticExperts.parameters["--expert-memory"] = nil
        let parts = (calibration(for: configuration) ?? calibration(for: automaticExperts))?.parts
            ?? cachedFileParts(configuration, family: geometry.family)
        let expertMemory: MemoryQuestion.StreamSetting = switch text("--expert-memory")?.lowercased() {
        case nil, "auto": .automatic
        case "off": .off
        case let value?: SizeText.bytes(value).map { .size($0) } ?? .automatic
        }
        let question = MemoryQuestion(
            rules: rules, geometry: geometry, experts: geometry.experts, pleTable: geometry.pleTable, sparseKv: geometry.sparseKv,
            kvFormat: text("--kv-format") == "bf16" ? .bf16 : .int8, context: text("--max-context").flatMap(Self.contextTokens),
            maxMemory: text("--max-memory").flatMap { $0.lowercased() == "auto" ? nil : SizeText.bytes($0) },
            recommended: budget, physical: physical, expertMemory: expertMemory,
            cacheDiskOff: text("--max-cache-disk").flatMap(SizeText.bytes) == 0, parts: parts)
        return MemoryForecast.answer(question)
    }

    func cachedFileParts(_ configuration: Configuration, family: String) -> MemoryParts {
        func stamp(_ path: String?) -> String {
            guard let path, let attributes = try? FileManager.default.attributesOfItem(atPath: expandTilde(path)) else { return "-" }
            let date = (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
            return "\(date):\((attributes[.size] as? NSNumber)?.uint64Value ?? 0)"
        }
        var draft: String?
        if case .value(let value)? = configuration.parameters["--draft-model"] { draft = value }
        let flags = ["--state-format", "--mmproj", "--language-only"].map { "\($0)=\(String(describing: configuration.parameters[$0]))" }
        let key = ([family, configuration.model, stamp(configuration.model), draft ?? "-", stamp(draft)] + flags).joined(separator: "|")
        if let cached = filePartsCache[key] { return cached }
        let parts = Self.fileParts(configuration, family: family)
        filePartsCache[key] = parts
        return parts
    }

    nonisolated static func fileParts(_ configuration: Configuration, family: String) -> MemoryParts {
        var parts = MemoryParts(source: .files)
        func text(_ flag: String) -> String? { if case .value(let value)? = configuration.parameters[flag] { value } else { nil } }
        if configuration.isLocal {
            let path = expandTilde(configuration.model)
            if path.lowercased().hasSuffix(".gguf"), path.wholeMatch(of: /.+-\d{5}-of-\d{5}\.gguf/) == nil,
               let floor = SplashFileSizing.ggufLoadedFloor(URL(filePath: path).resolvingSymlinksInPath()) {
                parts.targetWeights = floor
                if configuration.parameters["--mmproj"] == nil { parts.visionWeights = 0 }
            } else {
                parts.targetWeights = weightFileBytes(path)
            }
            parts.floors.insert("target_weights_bytes")
        }
        if configuration.parameters["--language-only"] != nil { parts.visionWeights = 0 }
        if let draft = text("--draft-model"), draft.hasPrefix("/") || draft.hasPrefix("~/") {
            let directory = URL(filePath: expandTilde(draft)).resolvingSymlinksInPath()
            if let bytes = SplashFileSizing.draftImageBytes(directory: directory) {
                parts.draftWeights = bytes
                parts.floors.insert("draft_weights_bytes")
            }
            if let shape = SplashFileSizing.draftShape(directory: directory) {
                let format: SplashFileSizing.StateFormat = text("--state-format") == "bf16" ? .bf16 : .fp32
                parts.laneState = SplashFileSizing.laneStateBytes(family: family, format: format, draft: shape)
                if let prefill = SplashFileSizing.prefillArenaFloor(family: family, draft: shape) {
                    parts.sharedPrefill = prefill
                    parts.floors.insert("shared_prefill_bytes")
                }
            }
        }
        return parts
    }

    public static func contextTokens(_ text: String) -> UInt64? {
        let normalized = text.trimmingCharacters(in: .whitespaces).uppercased()
        if normalized == "AUTO" { return nil }
        let units: [Character: UInt64] = ["K": 1024, "M": 1_000_000]
        if let last = normalized.last, let unit = units[last] { return UInt64(normalized.dropLast()).map { $0 * unit } }
        return UInt64(normalized)
    }

    nonisolated static func weightFileBytes(_ path: String) -> UInt64? {
        let url = URL(filePath: path).resolvingSymlinksInPath()
        func size(_ url: URL) -> UInt64 {
            UInt64((try? url.resolvingSymlinksInPath().resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        var directory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &directory) else { return nil }
        if !directory.boolValue {
            let name = url.lastPathComponent
            guard let match = name.wholeMatch(of: /(.+)-(\d{5})-of-(\d{5})\.gguf/) else { return size(url) }
            let folder = url.deletingLastPathComponent()
            let parts = ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [])
                .filter { $0.hasPrefix(String(match.1) + "-") && $0.hasSuffix("-of-\(match.3).gguf") }
            return parts.reduce(0) { $0 + size(folder.appending(path: $1)) }
        }
        struct Index: Decodable { let weight_map: [String: String] }
        let files: [String]
        if let data = try? Data(contentsOf: url.appending(path: "model.safetensors.index.json")),
           let index = try? JSONDecoder().decode(Index.self, from: data) {
            files = Array(Set(index.weight_map.values))
        } else {
            files = ((try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []).filter { $0.hasSuffix(".safetensors") }
        }
        let total = files.reduce(UInt64(0)) { $0 + size(url.appending(path: $1)) }
        return total > 0 ? total : nil
    }

    func requestedReservation(_ configuration: Configuration, parsed: [String: JSONValue]?, budget: UInt64) -> MemoryGuard.Reservation {
        if let forecast = forecast(configuration) { return .forecast(label: configuration.name, forecast) }
        if let parsed { return .planned(label: configuration.name, parsed: parsed, budget: budget) }
        var maxMemory: String?
        if case let .value(text)? = configuration.parameters["--max-memory"] { maxMemory = text }
        return .planned(label: configuration.name, maxMemory: maxMemory, budget: budget)
    }
}
