import SwiftUI

public struct NativeMainView<Leading: View, Center: View, Column: View, Detail: View, Panel: View>: View {
    @Bindable private var navigation: NativeNavigation
    private let hasColumn: (NativeSection) -> Bool
    private let hasPanel: (NativeSection) -> Bool
    private let statusBar: NativeStatusBar?
    private let leading: Leading
    private let center: Center
    private let column: (NativeSection) -> Column
    private let detail: (NativeSection) -> Detail
    private let panel: (NativeSection) -> Panel
    @State private var size: CGSize = .zero
    @State private var autoClosed = false
    @Environment(\.nativePalette) private var palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(navigation: NativeNavigation, hasColumn: @escaping (NativeSection) -> Bool, hasPanel: @escaping (NativeSection) -> Bool,
                statusBar: NativeStatusBar?, @ViewBuilder titleLeading: () -> Leading, @ViewBuilder titleCenter: () -> Center,
                @ViewBuilder column: @escaping (NativeSection) -> Column, @ViewBuilder detail: @escaping (NativeSection) -> Detail,
                @ViewBuilder panel: @escaping (NativeSection) -> Panel) {
        self.navigation = navigation
        self.hasColumn = hasColumn
        self.hasPanel = hasPanel
        self.statusBar = statusBar
        leading = titleLeading()
        center = titleCenter()
        self.column = column
        self.detail = detail
        self.panel = panel
    }

    public var body: some View {
        let section = navigation.section
        let layout = WindowLayout(size: size, hasColumn: hasColumn(section), showsColumn: navigation.showsColumn)
        VStack(spacing: 0) {
            NativeTitleBar {
                if hasColumn(section) {
                    Button {
                        withNativeAnimation(.settle, reduceMotion: reduceMotion) { navigation.showsColumn.toggle() }
                    } label: {
                        Image(systemName: "sidebar.leading")
                            .foregroundStyle(palette.textSecondary.color)
                            .accessibilityLabel(tr(navigation.showsColumn ? "toolbar.hideColumn" : "toolbar.showColumn"))
                    }
                    .buttonStyle(.borderless)
                    .help(tr(navigation.showsColumn ? "toolbar.hideColumn" : "toolbar.showColumn"))
                }
                leading
            } center: {
                center
            } trailing: {
                if hasPanel(section), !navigation.showsPanel, size.width > 0, !layout.panelInline {
                    NarrowPanelNotice {
                        withNativeAnimation(.settle, reduceMotion: reduceMotion) { navigation.showsPanel = true }
                        autoClosed = false
                    }
                    .transition(NativeMotion.comingAndGoing(reduceMotion: reduceMotion))
                }
                if hasPanel(section) {
                    Button {
                        withNativeAnimation(.settle, reduceMotion: reduceMotion) { navigation.showsPanel.toggle() }
                        autoClosed = false
                    } label: {
                        Image(systemName: "sidebar.trailing")
                            .symbolVariant(navigation.showsPanel ? .fill : .none)
                            .foregroundStyle(palette.textSecondary.color)
                            .accessibilityLabel(tr(navigation.showsPanel ? "toolbar.hidePanel" : "toolbar.showPanel"))
                    }
                    .buttonStyle(.borderless)
                    .help(tr(navigation.showsPanel ? "toolbar.hidePanel" : "toolbar.showPanel"))
                }
            }
            .zIndex(1)
            HStack(spacing: 0) {
                NativeRail(navigation: navigation)
                if layout.columnShown {
                    column(section)
                        .transition(NativeMotion.comingAndGoing(reduceMotion: reduceMotion))
                    Rectangle().fill(palette.separator.color).frame(width: 1)
                }
                ZStack(alignment: .trailing) {
                    detail(section)
                        .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                        .background(palette.background.color)
                    if hasPanel(section), navigation.showsPanel, !layout.panelInline {
                        Color.black.opacity(0.28)
                            .contentShape(.rect)
                            .onTapGesture { withNativeAnimation(.settle, reduceMotion: reduceMotion) { navigation.showsPanel = false } }
                            .accessibilityHidden(true)
                            .transition(NativeMotion.comingAndGoing(reduceMotion: reduceMotion))
                        NativeSidePanel { panel(section) }
                            .shadow(color: .black.opacity(0.45), radius: 18, x: -4)
                            .transition(NativeMotion.comingAndGoing(reduceMotion: reduceMotion))
                    }
                }
                .clipped()
                if hasPanel(section), navigation.showsPanel, layout.panelInline {
                    NativeSidePanel { panel(section) }
                }
            }
            if let statusBar { statusBar }
        }
        .background(palette.background.color)
        .ignoresSafeArea(edges: .top)
        .environment(\.nativeWindowSize, size)
        .onGeometryChange(for: CGSize.self) { $0.size } action: { size = $0 }
        .onChange(of: layout.panelInline) { _, inline in
            if !inline, navigation.showsPanel {
                navigation.showsPanel = false
                autoClosed = true
            } else if inline, autoClosed {
                navigation.showsPanel = true
                autoClosed = false
            }
        }
    }
}

struct NarrowPanelNotice: View {
    let open: () -> Void
    @Environment(\.nativePalette) private var palette

    var body: some View {
        Button(tr("panel.narrow.open"), action: open).controlSize(.small)
        .padding(.horizontal, Space.xxs)
        .padding(.vertical, Space.xxs)
        .background(palette.surface.color, in: .capsule)
        .overlay(Capsule().strokeBorder(palette.separator.color, lineWidth: 1))
        .help(tr("panel.narrow.help"))
        .accessibilityElement(children: .combine)
    }
}

struct WindowLayout: Equatable {
    let columnShown: Bool
    let panelInline: Bool

    init(size: CGSize, hasColumn: Bool, showsColumn: Bool) {
        columnShown = hasColumn && showsColumn
        let content = size.width - NativeLayout.railWidth - (columnShown ? NativeLayout.columnWidth + 1 : 0)
        panelInline = size.width <= 0 || content - NativeLayout.inspectorWidth >= NativeLayout.contentMinWidth
    }
}

extension EnvironmentValues {
    @Entry public var nativeWindowSize: CGSize = .zero
}

extension NativeMainView where Leading == EmptyView, Center == EmptyView, Column == EmptyView {
    public init(navigation: NativeNavigation, @ViewBuilder detail: @escaping (NativeSection) -> Detail,
                @ViewBuilder inspector: @escaping (NativeSection) -> Panel) {
        self.init(navigation: navigation, hasColumn: { _ in false }, hasPanel: { _ in true }, statusBar: nil,
                  titleLeading: { EmptyView() }, titleCenter: { EmptyView() }, column: { _ in EmptyView() }, detail: detail, panel: inspector)
    }
}

public struct SectionPage<Content: Sendable, Body: View>: View {
    private let section: NativeSection
    private let state: SectionState<Content>
    private let content: (Content) -> Body
    @Environment(\.nativePalette) private var palette

    public init(_ section: NativeSection, state: SectionState<Content>, @ViewBuilder content: @escaping (Content) -> Body) {
        self.section = section
        self.state = state
        self.content = content
    }

    public var body: some View {
        NativePage {
            Text(section.title).font(Typo.pageTitle).accessibilityAddTraits(.isHeader)
            switch state {
            case let .available(value):
                content(value)
            case let .unavailable(reason):
                NativeCard { UnavailableState(title: section.title, reason: reason) }
            }
        }
    }
}

extension SectionPage where Content == Void, Body == EmptyView {
    public init(_ section: NativeSection, unavailable reason: String) {
        self.init(section, state: .unavailable(reason: reason)) { _ in EmptyView() }
    }
}

public struct InspectorEmpty: View {
    @Environment(\.nativePalette) private var palette

    public init() {}

    public var body: some View {
        EmptyState(symbol: "sidebar.trailing", title: tr("inspector.empty.title"))
            .frame(maxHeight: .infinity, alignment: .top)
    }
}
