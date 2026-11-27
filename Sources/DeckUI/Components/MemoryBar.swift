import SwiftUI

public struct MemoryBar: View {
    private let breakdown: MemoryBreakdown
    @Environment(\.deckPalette) private var palette

    public init(_ breakdown: MemoryBreakdown) {
        self.breakdown = breakdown
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            HStack(alignment: .firstTextBaseline) {
                Text(breakdown.budgetTitle).font(Typo.caption).foregroundStyle(palette.textSecondary.color)
                Text(DeckFormat.memory(breakdown.budget)).font(Typo.caption.monospacedDigit()).foregroundStyle(palette.text.color)
                Spacer()
                if breakdown.overcommitted > 0 {
                    Label(tr("memory.over", DeckFormat.memory(breakdown.overcommitted)), systemImage: "exclamationmark.triangle.fill")
                        .font(Typo.caption)
                        .foregroundStyle(palette.error.color)
                }
            }
            bar
            legend
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(tr("a11y.memoryBar", breakdown.budgetTitle, DeckFormat.memory(breakdown.budget)))
        .accessibilityValue(Self.spokenLegend(breakdown))
    }

    private var bar: some View {
        GeometryReader { geometry in
            let segments = MemoryBarLayout(breakdown).segments(width: geometry.size.width)
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: Radius.small).fill(palette.surfaceRaised.color)
                ForEach(segments) { segment in
                    segmentView(segment.kind)
                        .frame(width: segment.width)
                        .offset(x: segment.x)
                }
            }
            .clipShape(.rect(cornerRadius: Radius.small))
        }
        .frame(height: DeckLayout.memoryBarHeight)
        .deckAnimation(.settle, value: breakdown)
    }

    @ViewBuilder
    private func segmentView(_ kind: MemoryBarLayout.Kind) -> some View {
        switch kind {
        case .measured:
            Rectangle().fill(palette.accent.color)
        case .reserved:
            Hatch(color: palette.accent.color).background(palette.accent.color.opacity(0.14))
        case .others:
            Rectangle().fill(palette.others.color)
        case .system:
            Rectangle().fill(palette.textTertiary.color)
        }
    }

    static func spokenLegend(_ breakdown: MemoryBreakdown) -> String {
        legendItems(breakdown).map { tr("a11y.legendItem", $0.title, $0.value) }.joined(separator: ", ")
    }

    private struct LegendItem: Identifiable {
        let id: String
        let swatch: MemoryBarLayout.Kind?
        let title: String
        let value: String
    }

    private var legendItems: [LegendItem] { Self.legendItems(breakdown) }

    private static func legendItems(_ breakdown: MemoryBreakdown) -> [LegendItem] {
        var items: [LegendItem] = []
        if let system = breakdown.system {
            items.append(LegendItem(id: "system", swatch: .system, title: breakdown.systemTitle ?? "", value: DeckFormat.memory(system)))
        }
        items += breakdown.instances.map {
            LegendItem(id: "m-\($0.id)", swatch: .measured, title: $0.name, value: DeckFormat.memory($0.measured))
        }
        if breakdown.reservedUnused > 0 {
            items.append(LegendItem(id: "reserved", swatch: .reserved, title: tr("memory.reservedUnused"), value: DeckFormat.memory(breakdown.reservedUnused)))
        }
        if breakdown.showsOthers {
            switch breakdown.others {
            case let .value(bytes):
                items.append(LegendItem(id: "others", swatch: .others, title: tr("memory.others"), value: DeckFormat.memory(bytes)))
            case .unavailable:
                items.append(LegendItem(id: "others", swatch: nil, title: tr("memory.others"), value: tr("value.unavailable")))
            }
        }
        let free = DeckFormat.memory(breakdown.free)
        items.append(LegendItem(id: "free", swatch: nil, title: tr("memory.free"),
                                value: breakdown.showsOthers && breakdown.others.value == nil ? tr("memory.atMost", free) : free))
        return items
    }

    private var legend: some View {
        FlowLayout(spacing: Space.m, lineSpacing: Space.xs) {
            ForEach(legendItems) { item in
                HStack(spacing: Space.xs) {
                    swatch(item.swatch)
                    Text(item.title).foregroundStyle(palette.textSecondary.color)
                    Text(item.value).monospacedDigit().foregroundStyle(palette.text.color)
                }
                .font(Typo.caption)
                .help(item.id == "others" ? (breakdown.others.unavailableReason ?? "") : "")
            }
        }
    }

    @ViewBuilder
    private func swatch(_ kind: MemoryBarLayout.Kind?) -> some View {
        let shape = RoundedRectangle(cornerRadius: 2)
        Group {
            if let kind {
                segmentView(kind).clipShape(shape)
            } else {
                shape.strokeBorder(palette.stroke.color, lineWidth: 1)
            }
        }
        .frame(width: 10, height: 10)
    }
}

extension Measured {
    var unavailableReason: String? {
        if case let .unavailable(reason) = self { reason } else { nil }
    }
}

struct MemoryBarLayout {
    enum Kind: Hashable { case measured, reserved, others, system }

    struct Segment: Identifiable, Equatable {
        let id: String
        let kind: Kind
        let x: CGFloat
        let width: CGFloat
    }

    let breakdown: MemoryBreakdown

    init(_ breakdown: MemoryBreakdown) {
        self.breakdown = breakdown
    }

    func segments(width: CGFloat) -> [Segment] {
        let scale = Double(max(breakdown.budget, breakdown.committed))
        guard scale > 0, width > 0 else { return [] }
        var parts: [(String, Kind, Int64)] = []
        if let system = breakdown.system { parts.append(("system", .system, system)) }
        for instance in breakdown.instances {
            parts.append(("m-\(instance.id)", .measured, instance.measured))
            parts.append(("r-\(instance.id)", .reserved, instance.reservedUnused))
        }
        if breakdown.showsOthers, let others = breakdown.others.value { parts.append(("others", .others, others)) }
        var x: CGFloat = 0
        var segments: [Segment] = []
        for (id, kind, bytes) in parts where bytes > 0 {
            let w = CGFloat(Double(bytes) / scale) * width
            segments.append(Segment(id: id, kind: kind, x: x, width: w))
            x += w
        }
        return segments
    }
}

private struct Hatch: View {
    let color: Color

    var body: some View {
        Canvas { context, size in
            var path = Path()
            var x: CGFloat = -size.height
            while x < size.width {
                path.move(to: CGPoint(x: x, y: size.height))
                path.addLine(to: CGPoint(x: x + size.height, y: 0))
                x += 5
            }
            context.stroke(path, with: .color(color), lineWidth: 1.5)
        }
    }
}

struct FlowLayout: Layout {
    var spacing: CGFloat
    var lineSpacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews: subviews)
        let width = rows.map(\.width).max() ?? 0
        let height = rows.map(\.height).reduce(0, +) + lineSpacing * CGFloat(max(0, rows.count - 1))
        return CGSize(width: proposal.width ?? width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(width: bounds.width, subviews: subviews) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + lineSpacing
        }
    }

    private struct Row { var indices: [Int] = []; var width: CGFloat = 0; var height: CGFloat = 0 }

    private func arrange(width: CGFloat, subviews: Subviews) -> [Row] {
        var rows: [Row] = [Row()]
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let needed = rows[rows.count - 1].indices.isEmpty ? size.width : rows[rows.count - 1].width + spacing + size.width
            if needed > width, !rows[rows.count - 1].indices.isEmpty {
                rows.append(Row())
            }
            var row = rows[rows.count - 1]
            row.width = row.indices.isEmpty ? size.width : row.width + spacing + size.width
            row.height = max(row.height, size.height)
            row.indices.append(index)
            rows[rows.count - 1] = row
        }
        return rows.filter { !$0.indices.isEmpty }
    }
}

#Preview("Barra della memoria") {
    let breakdown = MemoryBreakdown(
        budget: 40_200_896_512, budgetTitle: tr("memory.budgetMetal"),
        budgetProvenance: Provenance(source: .status(field: "memory_plan.device.recommended_max_working_set_bytes")),
        instances: [.init(id: "inkling", name: "inkling", measured: 21_189_083_136, reservedUnused: 39_127_154_688 - 21_189_083_136)],
        others: .unavailable(reason: tr("reason.notInFixture")))
    DeckCard { MemoryBar(breakdown) }
        .padding(Space.xl)
        .frame(width: 620)
        .deckTheme()
}
