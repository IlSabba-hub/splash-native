import SwiftUI

public struct NativeTitleBar<Leading: View, Center: View, Trailing: View>: View {
    private let leading: Leading
    private let center: Center
    private let trailing: Trailing
    @State private var width: CGFloat = 0
    @State private var leadingWidth: CGFloat = 0
    @State private var trailingWidth: CGFloat = 0
    @Environment(\.nativePalette) private var palette

    public init(@ViewBuilder leading: () -> Leading, @ViewBuilder center: () -> Center, @ViewBuilder trailing: () -> Trailing) {
        self.leading = leading()
        self.center = center()
        self.trailing = trailing()
    }

    public var body: some View {
        ZStack {
            Rectangle().fill(palette.column.color)
                .gesture(WindowDragGesture())
            HStack(spacing: Space.s) {
                Color.clear.frame(width: NativeLayout.trafficLightsInset, height: 1)
                HStack(spacing: Space.s) { leading }
                    .fixedSize()
                    .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { leadingWidth = $0 }
                Spacer(minLength: Space.s)
                HStack(spacing: Space.s) { trailing }
                    .fixedSize()
                    .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { trailingWidth = $0 }
            }
            .padding(.trailing, Space.m)
            center
                .frame(maxWidth: max(0, width - 2 * (max(NativeLayout.trafficLightsInset + leadingWidth, trailingWidth + Space.m) + Space.m)))
        }
        .frame(height: NativeLayout.titleBarHeight)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .overlay(alignment: .bottom) { Rectangle().fill(palette.separator.color).frame(height: 1) }
    }
}

public struct TitleCenter: View {
    private let loaded: [LoadedModel]
    private let picker: ModelPickerContent
    private let isPresented: Binding<Bool>?
    private let profiles: ProfilesContent?

    public init(loaded: [LoadedModel], picker: ModelPickerContent, isPresented: Binding<Bool>? = nil, profiles: ProfilesContent? = nil) {
        self.loaded = loaded
        self.picker = picker
        self.isPresented = isPresented
        self.profiles = profiles
    }

    private(set) var profilesOpen = false

    init(loaded: [LoadedModel], picker: ModelPickerContent, isPresented: Binding<Bool>?, profiles: ProfilesContent?, profilesOpen: Bool) {
        self.init(loaded: loaded, picker: picker, isPresented: isPresented, profiles: profiles)
        self.profilesOpen = profilesOpen
    }

    var primary: LoadedModel? { loaded.first(where: \.inChat) ?? loaded.first }
    var others: [LoadedModel] { loaded.filter { $0.id != primary?.id } }

    public var body: some View {
        ViewThatFits(in: .horizontal) {
            row(.full, width: NativeLayout.pickerWidth)
            row(.compact, width: 300)
            row(.minimal, width: 240)
            row(.minimal, width: 180)
        }
    }

    private func row(_ density: LoadedChip.Density, width: CGFloat) -> some View {
        HStack(spacing: Space.s) {
            if let primary {
                LoadedControl(primary, others: others, picker: picker, isPresented: isPresented, width: width, density: density)
            } else {
                ModelPickerButton(picker, isPresented: isPresented, width: width)
            }
            if let profiles { ProfilesButton(profiles, iconOnly: density != .full, open: profilesOpen) }
        }
        .fixedSize()
    }
}

public struct LoadedControl: View {
    private let model: LoadedModel
    private let others: [LoadedModel]
    private let picker: ModelPickerContent
    private let isPresented: Binding<Bool>?
    private let width: CGFloat
    private let density: LoadedChip.Density
    @State private var ownOpen = false
    @State private var showsPanel = false
    @State private var confirming = false
    @State private var showsOthers = false
    @Environment(\.nativePalette) private var palette

    public init(_ model: LoadedModel, others: [LoadedModel] = [], picker: ModelPickerContent, isPresented: Binding<Bool>? = nil,
                width: CGFloat = NativeLayout.pickerWidth, density: LoadedChip.Density = .full) {
        self.model = model
        self.others = others
        self.picker = picker
        self.isPresented = isPresented
        self.width = width
        self.density = density
    }

    private var open: Binding<Bool> { isPresented ?? $ownOpen }

    public var body: some View {
        HStack(spacing: 0) {
            main
            if !others.isEmpty { more }
            if let eject = model.eject {
                Button { perform(eject) } label: {
                    Image(systemName: "eject.fill").font(Typo.caption).foregroundStyle(palette.textSecondary.color).frame(width: 26, height: 28)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .disabled(!eject.isEnabled)
                .help(eject.disabledReason ?? tr("a11y.ejectModel", model.name))
                .accessibilityLabel(tr("a11y.ejectModel", model.name))
            }
            Rectangle().fill(palette.separator.color).frame(width: 1, height: 16).accessibilityHidden(true)
            Button { open.wrappedValue.toggle() } label: {
                Image(systemName: "chevron.down").font(Typo.caption.weight(.semibold)).foregroundStyle(palette.textTertiary.color)
                    .frame(width: 28, height: 28).contentShape(.rect)
            }
            .buttonStyle(.plain)
            .help(tr("picker.loadAnother"))
            .accessibilityLabel(tr("picker.loadAnother"))
        }
        .frame(width: width, height: 28)
        .background(palette.surface.color, in: .rect(cornerRadius: Radius.control))
        .overlay(RoundedRectangle(cornerRadius: Radius.control).strokeBorder(palette.separator.color, lineWidth: 1))
        .contextMenu {
            ForEach(model.menu.indices, id: \.self) { index in
                let action = model.menu[index]
                Button { perform(action) } label: { Label(LoadedChip.menuTitle(action), systemImage: action.systemImage ?? "circle") }
                    .disabled(!action.isEnabled)
            }
            Divider()
            Button { showsPanel = true } label: { Label(tr("chip.details"), systemImage: "info.circle") }
        }
        .popover(isPresented: $showsPanel, arrowEdge: .bottom) {
            LoadedModelPanel(model, confirming: confirming).nativeTheme()
                .presentationBackground(palette.column.color)
                .onDisappear { confirming = false }
        }
        .modelPickerDropdown(isPresented: open, content: picker)
    }

    private var main: some View {
        Button {
            if let edit = model.edit { edit.perform() } else { showsPanel = true }
        } label: {
            HStack(spacing: Space.xs) {
                StatusDot(model.status)
                if model.inChat {
                    Image(systemName: "bubble.left.fill").font(Typo.caption).foregroundStyle(palette.accent.color)
                        .help(tr("chip.inChat"))
                        .accessibilityLabel(tr("chip.inChat"))
                }
                Text(model.name).font(Typo.small.weight(.medium)).foregroundStyle(palette.text.color).lineLimit(1).truncationMode(.tail)
                    .layoutPriority(1)
                Text(NativeFormat.port(model.port)).font(Typo.caption.monospacedDigit()).foregroundStyle(palette.textTertiary.color).fixedSize()
                if density != .minimal, let memory = model.memory.value {
                    Text(NativeFormat.memory(memory)).font(Typo.caption.monospacedDigit()).foregroundStyle(palette.textSecondary.color).fixedSize()
                }
                if density == .full {
                    if model.foundOutside { NativeBadge(tr("chip.outside"), tone: .accent, monospaced: false).fixedSize() }
                    if model.usedByHermes { NativeBadge(tr("badge.hermes"), monospaced: false).fixedSize() }
                }
                Spacer(minLength: 0)
            }
            .padding(.leading, Space.m)
            .padding(.trailing, Space.xs)
            .frame(maxHeight: .infinity)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .help(model.edit.map { _ in tr("loaded.editHelp", model.name) }
              ?? [model.name, NativeFormat.port(model.port), model.status.title, model.statusDetail].compactMap { $0 }.joined(separator: " · "))
        .accessibilityLabel(tr("a11y.loadedChip", model.name, NativeFormat.port(model.port), model.status.title))
        .accessibilityHint(model.edit == nil ? "" : tr("loaded.editHelp", model.name))
    }

    private var more: some View {
        Button { showsOthers.toggle() } label: {
            Text(verbatim: "+" + NativeFormat.count(others.count)).font(Typo.caption.weight(.semibold).monospacedDigit())
                .foregroundStyle(palette.textSecondary.color)
                .padding(.horizontal, Space.xs + 1).padding(.vertical, 1)
                .background(palette.surfaceRaised.color, in: .rect(cornerRadius: Radius.small))
                .frame(height: 28).contentShape(.rect)
        }
        .buttonStyle(.plain)
        .padding(.trailing, Space.xxs)
        .help(tr("loaded.others", NativeFormat.count(others.count)))
        .accessibilityLabel(tr("loaded.others", NativeFormat.count(others.count)))
        .popover(isPresented: $showsOthers, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(others) { other in
                    LoadedModelPanel(other)
                    if other.id != others.last?.id { Divider().overlay(palette.separator.color) }
                }
            }
            .nativeTheme()
            .presentationBackground(palette.column.color)
        }
    }

    private func perform(_ action: NativeAction) {
        if case .destructive = action.role {
            confirming = true
            showsPanel = true
        } else {
            action.perform()
        }
    }
}

public struct LoadedChip: View {
    public enum Density: Sendable {
        case full, compact, minimal
    }

    private let model: LoadedModel
    private let density: Density
    @State private var showsPanel = false
    @State private var confirming = false
    @Environment(\.nativePalette) private var palette

    public init(_ model: LoadedModel, density: Density = .full) {
        self.model = model
        self.density = density
    }

    public var body: some View {
        HStack(spacing: Space.xs) {
            Button { showsPanel.toggle() } label: {
                HStack(spacing: Space.xs) {
                    StatusDot(model.status)
                    if model.inChat {
                        Image(systemName: "bubble.left.fill").font(Typo.caption).foregroundStyle(palette.accent.color)
                            .help(tr("chip.inChat"))
                            .accessibilityLabel(tr("chip.inChat"))
                    }
                    Text(model.name).font(Typo.small.weight(.medium)).lineLimit(1).truncationMode(.tail)
                        .frame(maxWidth: density == .minimal ? 72 : NativeLayout.chipMaxWidth / 2, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                    if density != .minimal {
                        Text(NativeFormat.port(model.port)).font(Typo.caption.monospacedDigit()).foregroundStyle(palette.textTertiary.color)
                    }
                    if density == .full {
                        if let memory = model.memory.value {
                            Text(NativeFormat.memory(memory)).font(Typo.caption.monospacedDigit()).foregroundStyle(palette.textSecondary.color)
                        }
                        if model.foundOutside { NativeBadge(tr("chip.outside"), tone: .accent, monospaced: false) }
                        if model.usedByHermes { NativeBadge(tr("badge.hermes"), monospaced: false) }
                    }
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .help([model.name, NativeFormat.port(model.port), model.status.title, model.statusDetail].compactMap { $0 }.joined(separator: " · "))
            .accessibilityLabel(tr("a11y.loadedChip", model.name, NativeFormat.port(model.port), model.status.title))
            if let eject = model.eject {
                Button { perform(eject) } label: {
                    Image(systemName: "xmark").font(Typo.caption.weight(.bold)).foregroundStyle(palette.textSecondary.color)
                }
                .buttonStyle(.plain)
                .disabled(!eject.isEnabled)
                .help(eject.disabledReason ?? eject.title)
                .accessibilityLabel(tr("a11y.ejectModel", model.name))
            }
        }
        .padding(.horizontal, Space.s)
        .frame(height: 26)
        .fixedSize(horizontal: true, vertical: false)
        .background(palette.surface.color, in: .rect(cornerRadius: Radius.control))
        .overlay(RoundedRectangle(cornerRadius: Radius.control).strokeBorder(palette.separator.color, lineWidth: 1))
        .contextMenu {
            ForEach(model.menu.indices, id: \.self) { index in
                let action = model.menu[index]
                Button { perform(action) } label: {
                    Label(Self.menuTitle(action), systemImage: action.systemImage ?? "circle")
                }
                .disabled(!action.isEnabled)
            }
        }
        .popover(isPresented: $showsPanel, arrowEdge: .bottom) {
            LoadedModelPanel(model, confirming: confirming).nativeTheme()
                .presentationBackground(palette.column.color)
                .onDisappear { confirming = false }
        }
    }

    private func perform(_ action: NativeAction) {
        if case .destructive = action.role {
            confirming = true
            showsPanel = true
        } else {
            action.perform()
        }
    }

    static func menuTitle(_ action: NativeAction) -> String {
        if case .destructive = action.role { return tr("menu.withConfirmation", action.title) }
        return action.title
    }
}

public struct LoadedModelPanel: View {
    private let model: LoadedModel
    private let requested: Bool
    @State private var confirming: Bool
    @Environment(\.nativePalette) private var palette

    public init(_ model: LoadedModel, confirming: Bool = false) {
        self.model = model
        requested = confirming
        _confirming = State(initialValue: confirming)
    }

    public var body: some View {
        panel.onChange(of: requested) { _, now in if now { confirming = true } }
    }

    private var panel: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: Space.xs) {
                HStack(spacing: Space.s) {
                    StatusDot(model.status)
                    Text(model.name).font(Typo.headline).lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: Space.s)
                    StatusPill(model.status, detail: model.statusDetail)
                }
                HStack(spacing: Space.xs) {
                    Text(model.model).font(Typo.code).foregroundStyle(palette.textSecondary.color).lineLimit(1).truncationMode(.middle)
                        .textSelection(.enabled)
                    Spacer(minLength: Space.xs)
                    if model.foundOutside { NativeBadge(tr("chip.outside"), tone: .accent, monospaced: false) }
                    if model.usedByHermes { NativeBadge(tr("badge.hermes"), monospaced: false) }
                }
                Text(model.endpoint).font(Typo.code).foregroundStyle(palette.textTertiary.color).textSelection(.enabled)
            }
            .padding(Space.m)
            if !model.facts.isEmpty {
                Divider().overlay(palette.separator.color)
                Grid(alignment: .leading, horizontalSpacing: Space.m, verticalSpacing: Space.xs) {
                    ForEach(model.facts) { fact in
                        GridRow {
                            Text(fact.title).foregroundStyle(palette.textTertiary.color)
                            MeasuredText(fact.value, font: Typo.small)
                                .gridColumnAlignment(.trailing)
                                .frame(maxWidth: .infinity, alignment: .trailing)
                        }
                        .font(Typo.small)
                        .help(fact.provenance?.sourceDescription ?? "")
                    }
                }
                .padding(Space.m)
            }
            if !model.menu.isEmpty {
                Divider().overlay(palette.separator.color)
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(model.menu.indices, id: \.self) { index in
                        let action = model.menu[index]
                        if case let .destructive(question, consequence, confirmTitle) = action.role, confirming {
                            InlineConfirmation(question: question, consequence: consequence, confirmTitle: confirmTitle,
                                               cancel: { confirming = false }, confirm: action.perform)
                                .padding(Space.xs)
                        } else {
                            MenuRow(action) {
                                if case .destructive = action.role { confirming = true } else { action.perform() }
                            }
                        }
                    }
                }
                .padding(Space.xs)
            }
        }
        .frame(width: 340, alignment: .leading)
        .background(palette.column.color)
    }
}

struct MenuRow: View {
    let action: NativeAction
    let perform: () -> Void
    @State private var hovered = false
    @Environment(\.nativePalette) private var palette

    init(_ action: NativeAction, perform: @escaping () -> Void) {
        self.action = action
        self.perform = perform
    }

    var body: some View {
        Button(action: perform) {
            HStack(spacing: Space.s) {
                Image(systemName: action.systemImage ?? "circle").frame(width: 16).foregroundStyle(palette.textSecondary.color)
                    .accessibilityHidden(true)
                Text(LoadedChip.menuTitle(action)).font(Typo.body)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, Space.s)
            .padding(.vertical, Space.xs + 1)
            .background(hovered && action.isEnabled ? palette.surface.color : .clear, in: .rect(cornerRadius: Radius.small))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .disabled(!action.isEnabled)
        .opacity(action.isEnabled ? 1 : 0.5)
        .help(action.disabledReason ?? "")
        .onHover { hovered = $0 }
    }
}

public struct InlineConfirmation: View {
    private let question: String
    private let consequence: String?
    private let confirmTitle: String
    private let cancel: () -> Void
    private let confirm: () -> Void
    private let remember: NativeAction.Remember?
    @State private var remembers = false
    @FocusState private var cancelFocused: Bool
    @Environment(\.nativePalette) private var palette

    public init(question: String, consequence: String?, confirmTitle: String, remember: NativeAction.Remember? = nil,
                cancel: @escaping () -> Void, confirm: @escaping () -> Void) {
        self.question = question
        self.consequence = consequence
        self.confirmTitle = confirmTitle
        self.remember = remember
        self.cancel = cancel
        self.confirm = confirm
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            Label(question, systemImage: "exclamationmark.triangle.fill").font(Typo.headline).foregroundStyle(palette.text.color)
                .fixedSize(horizontal: false, vertical: true)
            if let consequence {
                Text(consequence).font(Typo.small).foregroundStyle(palette.textSecondary.color).fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: Space.s) {
                if let remember {
                    Toggle(remember.title, isOn: $remembers).toggleStyle(.checkbox).font(Typo.small)
                }
                Spacer(minLength: 0)
                Button(tr("confirm.cancel"), action: cancel).keyboardShortcut(.cancelAction).focused($cancelFocused)
                Button(role: .destructive) {
                    if remembers { remember?.perform() }
                    confirm()
                } label: { Text(confirmTitle) }
                    .buttonStyle(.borderedProminent)
                    .tint(palette.error.color)
            }
            .controlSize(.small)
        }
        .padding(Space.m)
        .background(palette.error.over(palette.surface, alpha: 0.10).color, in: .rect(cornerRadius: Radius.control))
        .overlay(RoundedRectangle(cornerRadius: Radius.control).strokeBorder(palette.error.color.opacity(0.6), lineWidth: 1))
        .onAppear {
            cancelFocused = true
            AccessibilityNotification.Announcement(question).post()
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(question)
    }
}

public struct ModelPickerButton: View {
    private let content: ModelPickerContent
    private let width: CGFloat
    @State private var ownOpen = false
    private let isPresented: Binding<Bool>?
    @Environment(\.nativePalette) private var palette

    public init(_ content: ModelPickerContent, isPresented: Binding<Bool>? = nil, width: CGFloat = NativeLayout.pickerWidth) {
        self.content = content
        self.isPresented = isPresented
        self.width = width
    }

    private var open: Binding<Bool> { isPresented ?? $ownOpen }

    public var body: some View {
        Button { open.wrappedValue.toggle() } label: {
            HStack(spacing: Space.s) {
                Image(systemName: "cube").foregroundStyle(palette.textTertiary.color).accessibilityHidden(true)
                Text(tr("picker.title")).font(Typo.small).foregroundStyle(palette.textSecondary.color).lineLimit(1).fixedSize()
                Spacer(minLength: Space.s)
                Image(systemName: "chevron.down").font(Typo.caption.weight(.semibold)).foregroundStyle(palette.textTertiary.color)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, Space.m)
            .frame(width: width, height: 28)
            .background(palette.surface.color, in: .rect(cornerRadius: Radius.control))
            .overlay(RoundedRectangle(cornerRadius: Radius.control).strokeBorder(palette.separator.color, lineWidth: 1))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(open.wrappedValue ? .isSelected : [])
        .modelPickerDropdown(isPresented: open, content: content)
    }
}

extension View {
    public func modelPickerDropdown(isPresented: Binding<Bool>, content: ModelPickerContent) -> some View {
        nativeDropdown(isPresented: isPresented) { width, height, dismiss in
            ModelPickerPanel(content, dismiss: dismiss, width: width, maxHeight: height)
        }
    }

    public func nativeDropdown<Panel: View>(isPresented: Binding<Bool>, width: CGFloat = NativeLayout.pickerPanelWidth,
                                          @ViewBuilder panel: @escaping (CGFloat, CGFloat, @escaping () -> Void) -> Panel) -> some View {
        modifier(NativeDropdown(isPresented: isPresented, preferredWidth: width, panel: panel))
    }
}

struct NativeDropdown<Panel: View>: ViewModifier {
    @Binding var isPresented: Bool
    let preferredWidth: CGFloat
    let panel: (CGFloat, CGFloat, @escaping () -> Void) -> Panel
    @State private var anchor: CGRect = .zero
    @Environment(\.nativeWindowSize) private var window
    @Environment(\.nativePalette) private var palette

    func body(content view: Content) -> some View {
        if window == .zero {
            view.popover(isPresented: $isPresented, arrowEdge: .bottom) {
                panel(preferredWidth, 572) { isPresented = false }.nativeTheme()
                    .presentationBackground(palette.column.color)
            }
        } else {
            view
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { anchor = $0 }
                .overlay(alignment: .top) {
                    if isPresented { dropdown }
                }
        }
    }

    private var dropdown: some View {
        let margin = Space.s
        let width = min(preferredWidth, window.width - 2 * margin)
        let left = anchor.midX - width / 2
        let shift = min(max(left, margin), window.width - margin - width) - left
        let top = anchor.height + Space.xs + 2
        let height = max(160, window.height - anchor.maxY - Space.xs - 2 - NativeLayout.statusBarHeight - margin)
        return ZStack(alignment: .top) {
            Color.clear
                .frame(width: window.width * 2 + 200, height: window.height * 2 + 200)
                .contentShape(.rect)
                .onTapGesture { isPresented = false }
                .accessibilityHidden(true)
            panel(width, height) { isPresented = false }
                .clipShape(.rect(cornerRadius: Radius.card))
                .overlay(RoundedRectangle(cornerRadius: Radius.card).strokeBorder(palette.separator.color, lineWidth: 1))
                .shadow(color: .black.opacity(0.5), radius: 20, y: 8)
                .offset(x: shift, y: top)
                .onExitCommand { isPresented = false }
        }
        .frame(width: anchor.width, height: anchor.height, alignment: .top)
    }
}

public struct ModelPickerPanel: View {
    private let content: ModelPickerContent
    private let dismiss: () -> Void
    private let width: CGFloat
    private let maxHeight: CGFloat
    @State private var query = ""
    @FocusState private var searching: Bool
    @Environment(\.nativePalette) private var palette

    public init(_ content: ModelPickerContent, dismiss: @escaping () -> Void = {}, width: CGFloat = NativeLayout.pickerPanelWidth,
                maxHeight: CGFloat = 572) {
        self.content = content
        self.dismiss = dismiss
        self.width = width
        self.maxHeight = maxHeight
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: Space.s) {
                Image(systemName: "magnifyingglass").foregroundStyle(palette.textTertiary.color).accessibilityHidden(true)
                TextField(tr("picker.search"), text: $query).textFieldStyle(.plain).font(Typo.body).focused($searching)
                if !query.isEmpty {
                    Button { query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(palette.textTertiary.color) }
                        .buttonStyle(.plain)
                        .accessibilityLabel(tr("picker.clearSearch"))
                }
            }
            .padding(Space.m)
            Divider().overlay(palette.separator.color)
            ScrollView {
                VStack(alignment: .leading, spacing: Space.l) {
                    principals
                    list(tr("picker.configurations"), content.configurations)
                    list(tr("picker.local"), content.local)
                    if nothingShown {
                        Text(tr(query.isEmpty ? "picker.empty" : "picker.noMatch")).font(Typo.small).foregroundStyle(palette.textTertiary.color)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, Space.l)
                    }
                }
                .padding(Space.m)
            }
            .frame(maxHeight: max(120, maxHeight - 46))
        }
        .frame(width: width)
        .fixedSize(horizontal: false, vertical: true)
        .background(palette.column.color)
        .onAppear { searching = true }
    }

    private var shownPrincipals: [PrincipalSummary] {
        guard case let .available(list) = content.principals else { return [] }
        return list.filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) || $0.model.localizedCaseInsensitiveContains(query) }
    }

    private func shown(_ state: SectionState<[LoadableItem]>) -> [LoadableItem] {
        guard case let .available(items) = state else { return [] }
        return items.filter { $0.matches(query) }
    }

    private var nothingShown: Bool {
        func unavailable<T>(_ state: SectionState<T>) -> Bool { if case .unavailable = state { true } else { false } }
        return shownPrincipals.isEmpty && shown(content.configurations).isEmpty && shown(content.local).isEmpty
            && !unavailable(content.principals) && !unavailable(content.configurations) && !unavailable(content.local)
    }

    @ViewBuilder
    private var principals: some View {
        switch content.principals {
        case .available:
            let list = shownPrincipals
            if !list.isEmpty {
                VStack(alignment: .leading, spacing: Space.s) {
                    SectionHeader(tr("overview.principals"))
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 240), spacing: Space.s)], alignment: .leading, spacing: Space.s) {
                        ForEach(list) { principal in
                            PrincipalTile(principal, action: content.principalAction(principal).map(dismissing),
                                          menu: content.principalMenu(principal).map(dismissing))
                        }
                    }
                }
            }
        case let .unavailable(reason):
            VStack(alignment: .leading, spacing: Space.s) {
                SectionHeader(tr("overview.principals"))
                UnavailableState(title: tr("overview.principals"), reason: reason)
            }
        }
    }

    @ViewBuilder
    private func list(_ title: String, _ state: SectionState<[LoadableItem]>) -> some View {
        switch state {
        case .available:
            let items = shown(state)
            if !items.isEmpty {
                VStack(alignment: .leading, spacing: Space.xxs) {
                    SectionHeader(title, detail: NativeFormat.count(items.count))
                    ForEach(items) { LoadableRow(item: $0, dismiss: dismiss) }
                }
            }
        case let .unavailable(reason):
            VStack(alignment: .leading, spacing: Space.xxs) {
                SectionHeader(title)
                UnavailableState(title: title, reason: reason)
            }
        }
    }

    private func dismissing(_ action: NativeAction) -> NativeAction {
        let dismiss = dismiss
        return NativeAction(title: action.title, systemImage: action.systemImage, role: action.role, isEnabled: action.isEnabled,
                          disabledReason: action.disabledReason) {
            if case .destructive = action.role {} else { dismiss() }
            action.perform()
        }
    }
}

enum FitMark {
    static func symbol(_ verdict: WeightsFitEstimate.Verdict) -> String {
        switch verdict {
        case .fits: "checkmark.circle"
        case .tight: "exclamationmark.circle"
        case .doesNotFit: "xmark.circle"
        }
    }
}

struct LoadableRow: View {
    let item: LoadableItem
    let dismiss: () -> Void
    @State private var hovered = false
    @Environment(\.nativePalette) private var palette

    private var subtitleIsPath: Bool { item.subtitle.hasPrefix("~") || item.subtitle.hasPrefix("/") }

    var body: some View {
        Button {
            dismiss()
            item.open.perform()
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: Space.s) {
                    Text(item.title).font(Typo.body).lineLimit(1).truncationMode(.tail)
                        .help(subtitleIsPath ? item.subtitle : item.titleHelp ?? item.title)
                    Spacer(minLength: Space.s)
                    ForEach(item.tags, id: \.self) { NativeBadge($0).fixedSize() }
                    if let detail = item.detail {
                        Text(detail).font(Typo.caption.monospacedDigit()).foregroundStyle(palette.textSecondary.color).fixedSize()
                    }
                }
                HStack(spacing: Space.xs) {
                    if !subtitleIsPath { Text(item.subtitle).lineLimit(1).truncationMode(.middle) }
                    if let last = item.lastLoaded {
                        if !subtitleIsPath { Text(verbatim: "·").accessibilityHidden(true) }
                        Text(tr("picker.lastLoaded", NativeFormat.moment(last))).lineLimit(1).fixedSize()
                    }
                    Spacer(minLength: Space.s)
                    if item.loadedID != nil {
                        StatusPill(.ready)
                    } else if let fit = item.fit {
                        if let confirmation = fit.confirmation {
                            Image(systemName: "hand.raised").foregroundStyle(palette.starting.color)
                                .help(tr("fit.confirmation", confirmation))
                                .accessibilityLabel(tr("fit.confirmation", confirmation))
                        }
                        Label(fit.word, systemImage: FitMark.symbol(fit.verdict))
                            .foregroundStyle(NativeBadge.color(fit.tone, palette).color).fixedSize()
                            .help(fit.help)
                            .accessibilityLabel(tr("fit.a11y", fit.word))
                    }
                }
                .font(Typo.caption)
                .foregroundStyle(palette.textTertiary.color)
            }
            .padding(.horizontal, Space.s)
            .padding(.vertical, Space.xs + 1)
            .background(hovered ? palette.surface.color : .clear, in: .rect(cornerRadius: Radius.control))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .disabled(!item.open.isEnabled)
        .help(item.open.disabledReason ?? item.open.title)
        .onHover { hovered = $0 }
        .contextMenu {
            if let edit = item.edit {
                Button {
                    dismiss()
                    edit.perform()
                } label: { Label(edit.title, systemImage: edit.systemImage ?? "pencil") }
            }
        }
    }
}
