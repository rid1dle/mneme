import SwiftUI

struct ShelfView: View {
    @ObservedObject var model: ShelfModel
    let onPaste: (Item, Bool) -> Void
    @EnvironmentObject var theme: ThemeStore
    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            topBar
            if model.stackOn { StackStrip(model: model) { model.perform(.stopStack) } }
            if case .preview(let item) = model.overlay {
                PreviewView(item: model.selectedItem?.id == item.id ? model.selectedItem! : item, model: model)
            } else if model.loaded && model.items.isEmpty {
                empty
            } else {
                cards
            }
        }
        .overlay {
            if let o = model.overlay, !o.isPreview {
                ZStack {
                    Color.black.opacity(0.12).onTapGesture { model.overlay = nil }
                    OverlaySheet(overlay: o, model: model)
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 14)
        .padding(.bottom, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background { background }
        .tint(theme.accent)
        .environment(\.colorScheme, theme.colorScheme ?? systemScheme)
        .onAppear { if !LaunchOptions.current.offscreen { searchFocused = true } }
    }

    @Environment(\.colorScheme) private var systemScheme

    @ViewBuilder private var background: some View {
        let shape = RoundedRectangle(cornerRadius: 22, style: .continuous)
        ZStack {
            ShelfShadow(shape: shape)
            if theme.theme.shelf == .glass {
                Color.clear.glassSurface(shape)
            } else {
                shape.fill(Color(nsColor: .windowBackgroundColor))
                    .overlay(shape.strokeBorder(Color.primary.opacity(0.10)))
            }
        }
    }

    // MARK: top bar

    private static let kindChips: [(String, Set<ItemKind>)] = [
        ("All", []), ("Text", [.text, .richText]), ("Images", [.image]), ("Links", [.link]), ("Files", [.file]), ("Colors", [.color]),
    ]

    private var topBar: some View {
        HStack(spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search", text: $model.searchText)
                    .textFieldStyle(.plain)
                    .focused($searchFocused)
                    .accessibilityIdentifier("search")
                if !model.searchText.isEmpty {
                    Button { model.searchText = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 10)
            .frame(width: 240, height: 30)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.primary.opacity(0.07)))

            HStack(spacing: 4) {
                ForEach(Self.kindChips, id: \.0) { name, kinds in
                    chip(name, selected: model.kinds == kinds) { model.kinds = kinds }
                }
            }

            Menu {
                Button("Any app") { model.sourceBundleID = nil }
                Divider()
                ForEach(model.apps, id: \.bundleID) { app in
                    Button(app.name) { model.sourceBundleID = app.bundleID }
                }
            } label: {
                Text(model.apps.first { $0.bundleID == model.sourceBundleID }?.name ?? "Any app").font(.system(size: 12))
            }
            .menuStyle(.borderlessButton)
            .tint(.secondary)
            .fixedSize()

            Menu {
                ForEach(DateFilter.allCases, id: \.self) { f in Button(f.rawValue) { model.dateFilter = f } }
            } label: {
                Text(model.dateFilter.rawValue).font(.system(size: 12))
            }
            .menuStyle(.borderlessButton)
            .tint(.secondary)
            .fixedSize()

            Spacer(minLength: 8)

            if !model.captureAllowed {
                Label("Capture is off", systemImage: "pause.circle").font(.system(size: 12, weight: .medium)).foregroundStyle(.orange)
            }

            HStack(spacing: 4) {
                tab("History", color: nil, selected: model.pinboard == nil) { model.pinboard = nil }
                    .padding(.leading, 0)
                ForEach(model.pinboards) { board in
                    tab(board.name, color: Color(hex: board.color), selected: model.pinboard == board.id) { model.pinboard = board.id }
                }
                Button { model.perform(.openSettings) } label: { Image(systemName: "gearshape").font(.system(size: 13)) }
                    .buttonStyle(.plain).foregroundStyle(.secondary).padding(.leading, 6)
                    .help("Settings").accessibilityLabel("Settings")
            }
        }
    }

    private func chip(_ name: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(name)
                .font(.system(size: 12, weight: selected ? .semibold : .regular))
                .padding(.horizontal, 10).padding(.vertical, 5)
                .foregroundStyle(selected ? Color.white : Color.primary)
                .background(Capsule().fill(selected ? theme.accent : Color.primary.opacity(0.06)))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func tab(_ name: String, color: Color?, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if let color { Circle().fill(color).frame(width: 8, height: 8) }
                Text(name).font(.system(size: 12, weight: selected ? .semibold : .regular)).lineLimit(1)
            }
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(Capsule().fill(selected ? Color.primary.opacity(0.12) : Color.clear))
        }
        .buttonStyle(.plain)
        .help("Tab and ⇧Tab switch between History and pinboards")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    // MARK: cards

    private var cards: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 12) {
                    ForEach(Array(model.items.enumerated()), id: \.element.id) { i, item in
                        CardView(item: item, index: i, selected: i == model.selection, model: model)
                            .equatable()
                            .overlay(alignment: .leading) {
                                if model.dropTarget == item.id {
                                    Capsule().fill(theme.accent).frame(width: 4).padding(.vertical, 8).offset(x: -8)
                                }
                            }
                            .onDrop(of: [.item], delegate: ReorderDrop(target: item, model: model))
                            .id(item.id)
                            .onTapGesture(count: 2) { onPaste(item, false) }
                            .accessibilityAction(named: "Pin to first pinboard") { if let b = model.pinboards.first { model.pin(item, to: b.id) } }
                            .onTapGesture { model.selection = i }
                            .accessibilityAction { onPaste(item, false) }
                            .onAppear { if i >= model.items.count - 10 { model.loadMore() } }
                    }
                }
                .padding(.horizontal, 2)
                .padding(.vertical, 6)
            }
            .onChange(of: model.selection) {
                guard let item = model.selectedItem else { return }
                if LaunchOptions.current.scroll != nil { proxy.scrollTo(item.id) } else {
                    withAnimation(.easeOut(duration: 0.12)) { proxy.scrollTo(item.id) }
                }
            }
        }
    }

    private var empty: some View {
        VStack(spacing: 8) {
            Image(systemName: model.searchText.isEmpty ? "doc.on.clipboard" : "magnifyingglass")
                .font(.system(size: 28)).foregroundStyle(.tertiary)
            Text(emptyMessage).font(.system(size: 13, weight: .medium)).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyMessage: String {
        if !model.searchText.isEmpty { return "Nothing matches “\(model.searchText)”" }
        if model.pinboard != nil { return "This pinboard is empty" }
        if !model.kinds.isEmpty || model.sourceBundleID != nil || model.dateFilter != .any { return "Nothing matches these filters" }
        return "Nothing copied yet. Copy something and it shows up here."
    }
}

extension Overlay {
    var isPreview: Bool { if case .preview = self { return true } else { return false } }
}

/// The shelf's shadow, following its rounded shape, with the inside cut away so it never darkens the glass.
struct ShelfShadow: View {
    let shape: RoundedRectangle

    var body: some View {
        shape.fill(Color.black)
            .shadow(color: .black.opacity(0.35), radius: 14, y: 5)
            .mask {
                Rectangle().padding(-ShelfPanel.margin)
                    .overlay(shape.blendMode(.destinationOut))
                    .compositingGroup()
            }
            .allowsHitTesting(false)
    }
}
