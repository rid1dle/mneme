import SwiftUI

/// Shows what the paste stack holds while it is on.
struct StackStrip: View {
    @ObservedObject var model: ShelfModel
    let stop: () -> Void
    @EnvironmentObject var theme: ThemeStore

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "square.stack.3d.up.fill").foregroundStyle(theme.accent)
            Text("Paste stack").font(.system(size: 12, weight: .semibold))
            Text(model.stackItems.isEmpty ? "Copy things to add them" : "\(model.stackItems.count) to paste, ⌃⌘V pastes the next")
                .font(.system(size: 12)).foregroundStyle(.secondary)
            ForEach(Array(model.stackItems.prefix(6).enumerated()), id: \.element.id) { n, item in
                Text("\(n + 1). \(item.title ?? item.preview)")
                    .font(.system(size: 11)).lineLimit(1).frame(maxWidth: 140, alignment: .leading)
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(Capsule().fill(Color.primary.opacity(0.07)))
            }
            Spacer()
            Button("Stop", action: stop).controlSize(.small)
        }
        .padding(.horizontal, 10)
        .frame(height: 28)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(theme.accent.opacity(0.12)))
    }
}
