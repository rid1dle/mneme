import AppKit
import SwiftUI

@MainActor
final class StackPanelModel: ObservableObject {
    @Published var items: [Item] = []
    @Published var pressesForYou = true
    var onRemove: (UUID) -> Void = { _ in }
    var onMove: (IndexSet, Int) -> Void = { _, _ in }
    var onStop: () -> Void = {}
}

/// The paste stack while it is on: what ⌘V pastes next, and the order of the rest. Rows can be dragged and removed.
struct StackPanelView: View {
    @ObservedObject var model: StackPanelModel
    @EnvironmentObject var theme: ThemeStore

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "square.stack.3d.up.fill").foregroundStyle(theme.accent)
                Text("Paste stack").font(.system(size: 13, weight: .semibold))
                Text(model.items.isEmpty ? "" : "\(model.items.count)").font(.system(size: 12)).foregroundStyle(.secondary)
                Spacer()
                Button("Stop") { model.onStop() }.controlSize(.small)
            }
            .padding(.horizontal, 12).padding(.top, 10).padding(.bottom, 8)

            if model.items.isEmpty {
                Text("Copy things and they line up here, in the order they will paste.")
                    .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 12).padding(.bottom, 12)
            } else {
                List {
                    ForEach(Array(model.items.enumerated()), id: \.element.id) { n, item in
                        row(n, item)
                            .listRowInsets(EdgeInsets(top: 3, leading: 6, bottom: 3, trailing: 6))
                            .listRowSeparator(.hidden)
                    }
                    .onMove { model.onMove($0, $1) }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                Text(model.pressesForYou ? "⌘V pastes the top one, then the next. Drag to reorder." : "Allow Accessibility so ⌘V pastes them in order.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .padding(.horizontal, 12).padding(.vertical, 8)
            }
        }
        .frame(width: 300)
        .glassSurface(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .tint(theme.accent)
        .environment(\.colorScheme, theme.colorScheme ?? systemScheme)
    }

    @Environment(\.colorScheme) private var systemScheme

    private func row(_ n: Int, _ item: Item) -> some View {
        HStack(spacing: 8) {
            Text("\(n + 1)")
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .foregroundStyle(n == 0 ? Color.white : Color.secondary)
                .frame(width: 20, height: 20)
                .background(Circle().fill(n == 0 ? theme.accent : Color.primary.opacity(0.08)))
            VStack(alignment: .leading, spacing: 1) {
                Text(item.title ?? item.preview).font(.system(size: 12, weight: n == 0 ? .semibold : .regular)).lineLimit(1)
                Text(n == 0 ? "Next · \(item.source?.name ?? "")" : footerText(item)).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 4)
            Button { model.onRemove(item.id) } label: { Image(systemName: "xmark.circle.fill") }
                .buttonStyle(.plain).foregroundStyle(.tertiary).help("Take out of the stack")
                .accessibilityLabel("Remove \(item.title ?? item.preview)")
        }
        .padding(.horizontal, 6).padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(n == 0 ? theme.accent.opacity(0.14) : Color.clear))
    }
}

/// A small floating panel at the top right of the screen; never takes focus from the app being pasted into.
@MainActor
final class StackPanelController {
    let model = StackPanelModel()
    private var panel: NSPanel?
    private let theme: ThemeStore

    init(theme: ThemeStore) { self.theme = theme }

    func show(_ items: [Item], pressesForYou: Bool) {
        model.items = items
        model.pressesForYou = pressesForYou
        let p = panel ?? make()
        let rows = min(max(items.count, 1), 7)
        let height: CGFloat = items.isEmpty ? 92 : CGFloat(44 + rows * 44 + 34)
        let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main
        let vf = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1280, height: 800)
        if !p.isVisible {
            p.setFrame(NSRect(x: vf.maxX - 300 - 14, y: vf.maxY - height - 14, width: 300, height: height), display: true)
            p.orderFrontRegardless()
        } else {
            var f = p.frame
            f.origin.y += f.height - height
            f.size.height = height
            p.setFrame(f, display: true, animate: true)
        }
    }

    func hide() {
        panel?.orderOut(nil)
        panel?.contentView = nil
        panel = nil
        model.items = []
    }

    private func make() -> NSPanel {
        let p = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.level = .floating
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.isMovableByWindowBackground = true
        p.hidesOnDeactivate = false
        p.becomesKeyOnlyIfNeeded = true
        p.contentView = NSHostingView(rootView: StackPanelView(model: model).environmentObject(theme))
        panel = p
        return p
    }
}
