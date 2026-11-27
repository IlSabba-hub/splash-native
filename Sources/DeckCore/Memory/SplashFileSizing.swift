import Foundation

public enum SplashFileSizing {
    static let pageBytes: UInt64 = 16 * 1024

    static func alignUp(_ bytes: UInt64) -> UInt64 { (bytes + pageBytes - 1) / pageBytes * pageBytes }

    public struct DraftShape: Sendable, Equatable {
        public var layers: UInt64
        public var hiddenSize: UInt64
        public var targetLayers: UInt64
    }

    public static func draftShape(directory: URL) -> DraftShape? {
        guard let data = try? Data(contentsOf: directory.appending(path: "config.json")),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let layers = (root["num_hidden_layers"] as? NSNumber)?.uint64Value,
              let hidden = (root["hidden_size"] as? NSNumber)?.uint64Value,
              let targets = (root["dflash_config"] as? [String: Any])?["target_layer_ids"] as? [Any], !targets.isEmpty
        else { return nil }
        return DraftShape(layers: layers, hiddenSize: hidden, targetLayers: UInt64(targets.count))
    }

    static func safetensorsShapes(directory: URL) -> [String: [UInt64]]? {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return nil }
        var shapes: [String: [UInt64]] = [:]
        for name in names.sorted() where name.hasSuffix(".safetensors") {
            guard let handle = try? FileHandle(forReadingFrom: directory.appending(path: name)) else { return nil }
            defer { try? handle.close() }
            guard let prefix = try? handle.read(upToCount: 8), prefix.count == 8 else { return nil }
            let length = prefix.withUnsafeBytes { $0.loadUnaligned(as: UInt64.self) }.littleEndian
            guard length < 100 << 20, let header = try? handle.read(upToCount: Int(length)), header.count == Int(length),
                  let root = try? JSONSerialization.jsonObject(with: header) as? [String: Any] else { return nil }
            for (tensor, value) in root where tensor != "__metadata__" {
                guard let info = value as? [String: Any], info["dtype"] as? String == "BF16",
                      let shape = info["shape"] as? [NSNumber] else { continue }
                shapes[tensor] = shape.map(\.uint64Value)
            }
        }
        return shapes.isEmpty ? nil : shapes
    }

    public static func draftImageBytes(directory: URL) -> UInt64? {
        guard let shape = draftShape(directory: directory), let shapes = safetensorsShapes(directory: directory) else { return nil }
        struct Image {
            var cursor: UInt64 = 16
            mutating func section(_ bytes: UInt64) { cursor = SplashFileSizing.alignUp(cursor) + bytes }
            var bytes: UInt64 { SplashFileSizing.alignUp(cursor) }
        }
        func elements(_ name: String) -> UInt64? { shapes[name]?.reduce(1, *) }
        var failed = false
        func stored(_ image: inout Image, _ name: String) {
            guard let count = elements(name) else { failed = true; return }
            image.section(count * 2)
        }
        func projection(_ image: inout Image, _ parts: [String]) {
            var rows: UInt64 = 0, columns: UInt64?
            for part in parts {
                guard let shape = shapes[part + ".weight"], shape.count == 2, columns == nil || columns == shape[1] else {
                    failed = true
                    return
                }
                rows += shape[0]
                columns = shape[1]
            }
            guard let columns, columns % 64 == 0 else { failed = true; return }
            image.section(56)
            image.section(rows * (columns / 32) * 16)
            image.section(rows * (columns / 64) * 4)
        }
        var total: UInt64 = 0
        for layer in 0..<shape.layers {
            var image = Image()
            let prefix = "layers.\(layer).", attention = prefix + "self_attn."
            stored(&image, prefix + "input_layernorm.weight")
            stored(&image, prefix + "attention_conv.base_kernel")
            projection(&image, [prefix + "attention_conv.kernel_projection"])
            projection(&image, [attention + "q_proj", attention + "k_proj", attention + "v_proj"])
            stored(&image, attention + "q_norm.weight")
            stored(&image, attention + "k_norm.weight")
            projection(&image, [attention + "o_proj"])
            stored(&image, prefix + "post_attention_layernorm.weight")
            stored(&image, prefix + "mlp_conv.base_kernel")
            projection(&image, [prefix + "mlp_conv.kernel_projection"])
            projection(&image, [prefix + "mlp.gate_proj"])
            projection(&image, [prefix + "mlp.up_proj"])
            projection(&image, [prefix + "mlp.down_proj"])
            total += image.bytes
        }
        var model = Image()
        projection(&model, ["fc"])
        stored(&model, "hidden_norm.weight")
        stored(&model, "norm.weight")
        projection(&model, ["candidate_selector.hidden_projection"])
        stored(&model, "candidate_selector.predecessor_codebook")
        stored(&model, "candidate_selector.successor_codebook")
        if shapes["mask_embedding"] != nil { stored(&model, "mask_embedding") }
        total += model.bytes
        return failed ? nil : total
    }

    struct Recurrent {
        var layers: UInt64
        var convolutionChannels: UInt64
        var valueHeads: UInt64
        var headDimension: UInt64
        var auxiliaryBytes: UInt64
    }

    static func recurrent(family: String) -> Recurrent? {
        switch family {
        case "Qwen3.8-27B": Recurrent(layers: 64 - 16, convolutionChannels: 10_240, valueHeads: 48, headDimension: 128, auxiliaryBytes: 0)
        case "Qwen3.6-35B-A3B": Recurrent(layers: 40 - 10, convolutionChannels: 8_192, valueHeads: 32, headDimension: 128, auxiliaryBytes: 0)
        case "Qwen3.5-122B-A10B": Recurrent(layers: 48 - 12, convolutionChannels: 12_288, valueHeads: 64, headDimension: 128, auxiliaryBytes: 0)
        case "Inkling-2-Mini": Recurrent(layers: 0, convolutionChannels: 0, valueHeads: 0, headDimension: 0, auxiliaryBytes: 1_916_928)
        default: nil
        }
    }

    public enum StateFormat: Sendable { case fp32, bf16 }

    public static func laneStateBytes(family: String, format: StateFormat, draft: DraftShape) -> UInt64? {
        guard let state = recurrent(family: family) else { return nil }
        let convolution = state.layers > 0 ? alignUp(3 * state.convolutionChannels * 2) : 0
        let recurrent = alignUp(state.valueHeads * state.headDimension * state.headDimension * (format == .fp32 ? 4 : 2))
        let cell = state.layers * (convolution + (state.layers > 0 ? recurrent : 0)) + alignUp(state.auxiliaryBytes)
        let window: UInt64 = 2048
        let rings = draft.layers * 2 * (8 * window * 128 * 2)
        let context = window * (draft.hiddenSize / 2) + window * (draft.hiddenSize / 64) * 4
        return 2 * cell + rings + context
    }

    public static func prefillArenaFloor(family: String, draft: DraftShape) -> UInt64? {
        guard family == "Qwen3.8-27B" else { return nil }
        let rows: UInt64 = 2048, hidden: UInt64 = 5120, width: UInt64 = 6144, intermediate: UInt64 = 17_408, pairs: UInt64 = 32
        let staged = rows + 1 * (32 - 1)
        let target: [UInt64] = [
            rows * hidden * 2, rows * hidden * 2, rows * hidden * 2,
            rows * 16_640 * 2, rows * 16 * 128 * 2, rows * 16 * 128 * 2,
            rows * width * 2, rows * 48 * 4, rows * 48 * 2,
            rows * width * 2, rows * width * 2, rows * intermediate * 2,
            rows * 14_336 * 2, 24 * staged * 256 * 2, rows * width * 2,
            rows * hidden * 2, rows * hidden * 2,
            rows * pairs * 4, rows * pairs * 4,
        ]
        let draftPairs: UInt64 = 64, contextKv: UInt64 = 6144 - 4096
        let prefill: [UInt64] = [
            rows * 4, rows * draft.targetLayers * hidden * 2, rows * intermediate * 2,
            rows * 3 * 4, rows * 4, pairs * 4, draftPairs * 4,
            rows * draft.hiddenSize * 2, rows * draft.hiddenSize * 2, rows * contextKv * 2,
            rows * draftPairs * 4, rows * draftPairs * 4,
        ]
        return (target + prefill).reduce(0) { $0 + alignUp($1) }
    }

    public static func ggufLoadedFloor(_ url: URL) -> UInt64? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return nil }
        try? handle.seek(toOffset: 0)
        var reader = GGUFReader(handle: handle)
        guard reader.bytes(4) == Data("GGUF".utf8), let version = reader.u32(), version >= 2,
              let tensors = reader.u64(), let entries = reader.u64(), tensors < 1_000_000, entries < 1_000_000 else { return nil }
        var integers: [String: UInt64] = [:]
        var architecture: String?
        for _ in 0..<entries {
            guard let key = reader.string(), let type = reader.u32() else { return nil }
            if type == 8, key == "general.architecture" {
                architecture = reader.string()
                continue
            }
            guard let value = reader.value(type) else { return nil }
            if let value { integers[key] = value }
        }
        var offsets: [(name: String, offset: UInt64)] = []
        for _ in 0..<tensors {
            guard let name = reader.string(), let dimensions = reader.u32(), dimensions <= 8 else { return nil }
            for _ in 0..<dimensions { guard reader.u64() != nil else { return nil } }
            guard reader.u32() != nil, let offset = reader.u64() else { return nil }
            offsets.append((name, offset))
        }
        let alignment = integers["general.alignment"] ?? 32
        guard alignment > 0 else { return nil }
        let dataStart = (reader.position + alignment - 1) / alignment * alignment
        guard let architecture, let blocks = integers[architecture + ".block_count"], dataStart <= size else { return nil }
        let first = blocks - min(blocks, integers[architecture + ".nextn_predict_layers"] ?? 0)
        func skipped(_ name: String) -> Bool {
            guard name.hasPrefix("blk."), let layer = UInt64(name.dropFirst(4).prefix { $0.isNumber }) else { return false }
            return layer >= first
        }
        offsets.sort { $0.offset < $1.offset }
        var total: UInt64 = 0
        for (index, tensor) in offsets.enumerated() where !skipped(tensor.name) {
            let end = index + 1 < offsets.count ? offsets[index + 1].offset : size - dataStart
            guard end >= tensor.offset else { return nil }
            let span = end - tensor.offset
            total += span > alignment - 1 ? span - (alignment - 1) : 0
        }
        return total > 0 ? total : nil
    }

    struct GGUFReader {
        let handle: FileHandle
        var buffer = Data()
        var position: UInt64 = 0
        private var start: UInt64 = 0

        init(handle: FileHandle) { self.handle = handle }

        mutating func bytes(_ count: Int) -> Data? {
            while buffer.count - Int(position - start) < count {
                guard let more = try? handle.read(upToCount: 1 << 20), !more.isEmpty else { return nil }
                let used = Int(position - start)
                buffer = buffer.subdata(in: used..<buffer.count) + more
                start = position
            }
            let from = Int(position - start)
            position += UInt64(count)
            return buffer.subdata(in: from..<from + count)
        }

        mutating func u32() -> UInt32? { bytes(4).map { $0.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }.littleEndian } }
        mutating func u64() -> UInt64? { bytes(8).map { $0.withUnsafeBytes { $0.loadUnaligned(as: UInt64.self) }.littleEndian } }

        mutating func string() -> String? {
            guard let length = u64(), length < 1 << 24, let data = bytes(Int(length)) else { return nil }
            return String(decoding: data, as: UTF8.self)
        }

        mutating func value(_ type: UInt32) -> UInt64?? {
            let widths: [UInt32: Int] = [0: 1, 1: 1, 2: 2, 3: 2, 4: 4, 5: 4, 6: 4, 7: 1, 10: 8, 11: 8, 12: 8]
            switch type {
            case 8:
                return string() == nil ? nil : .some(nil)
            case 9:
                guard let inner = u32(), let count = u64(), count < 1 << 26 else { return nil }
                if let width = widths[inner] { return bytes(Int(count) * width) == nil ? nil : .some(nil) }
                for _ in 0..<count { guard value(inner) != nil else { return nil } }
                return .some(nil)
            case 4: return u32().map { .some(UInt64($0)) }
            case 10: return u64().map { .some($0) }
            default:
                guard let width = widths[type], let data = bytes(width) else { return nil }
                if type == 0 { return .some(UInt64(data[data.startIndex])) }
                if type == 2 { return .some(UInt64(data.withUnsafeBytes { $0.loadUnaligned(as: UInt16.self) }.littleEndian)) }
                return .some(nil)
            }
        }
    }
}
