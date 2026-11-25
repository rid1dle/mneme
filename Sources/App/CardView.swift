import AppKit
import SwiftUI

/// Equatable on what it shows, so moving the selection redraws only the two cards involved.
struct CardView: View, Equatable {
    let item: Item
    let index: Int
    let selected: Bool
    let model: ShelfModel

    nonisolated static func == (a: CardView, b: CardView) -> Bool {
        a.item == b.item && a.index == b.index && a.selected == b.selected
    }

    @EnvironmentObject var theme: ThemeStore
    @State private var thumb: NSImage?
    @State private var linkImage: NSImage?

    var body: some View {
        let size = theme.cardSize
        VStack(spacing: 0) {
            header
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .clipped()
            footer
        }
        .frame(width: size.width, height: size.height)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color(nsColor: .textBackgroundColor).opacity(theme.theme.shelf == .glass ? 0.88 : 1)))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(selected ? theme.accent : Color.primary.opacity(0.10), lineWidth: selected ? 3 : 1)
        )
        .task(id: item.thumb) { thumb = await model.thumbnail(item) }
        .task(id: item.linkImage) { linkImage = await model.linkImage(item) }
        .contextMenu { CardMenu(item: item, model: model) }
        .onDrag { model.itemProvider(item) } preview: { DragPreview(item: item) }
        .accessibilityElement(children: .ignore)
        .accessibilityAction(named: "Preview") { model.overlay = .preview(item) }
        .accessibilityAction(named: "Rename") { model.overlay = .rename(item) }
        .accessibilityAction(named: "Remove") { model.removeFromCurrent(item) }
        .accessibilityAction(named: "Delete Everywhere") { model.deleteEverywhere(item) }
        .accessibilityAction(named: "New Pinboard") { model.overlay = .newPinboard(pinning: item) }
        .accessibilityLabel("\(kindName), \(item.title ?? item.preview), from \(item.source?.name ?? "unknown app"), \(relativeTime(item.lastUsedAt))")
        .accessibilityAddTraits(selected ? [.isSelected, .isButton] : .isButton)
    }

    private var kindName: String {
        switch item.kind {
        case .text: return "Text"
        case .richText: return "Rich text"
        case .image: return "Image"
        case .file: return item.fileURLs.count == 1 ? "File" : "Files"
        case .link: return "Link"
        case .color: return "Color"
        }
    }

    private var tint: Color {
        switch item.kind {
        case .text: return .blue
        case .richText: return .indigo
        case .image: return .teal
        case .file: return .orange
        case .link: return .green
        case .color: return Color(hex: item.preview)
        }
    }

    /// A band in the source app's colour: what it is (or its title) and when, with the app's icon on the right.
    private var header: some View {
        HStack(alignment: .center, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title ?? kindName)
                    .font(.system(size: 15, weight: .semibold))
                    .lineLimit(1)
                Text(relativeTimeLong(item.lastUsedAt))
                    .font(.system(size: 11, weight: .medium))
                    .opacity(0.85)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            if let icon = model.appIcon(item.source?.bundleID) {
                Image(nsImage: icon).resizable().interpolation(.high)
                    .frame(width: 40, height: 40)
                    .shadow(color: .black.opacity(0.25), radius: 3, y: 1)
                    .accessibilityLabel(item.source?.name ?? "")
            }
        }
        .foregroundStyle(.white)
        .padding(.leading, 12)
        .padding(.trailing, 8)
        .frame(height: 56)
        .background(model.appColor(item.source?.bundleID) ?? Color(hex: "#56606E"))
    }

    @ViewBuilder private var content: some View {
        switch item.kind {
        case .text, .richText:
            Text(item.charCount > item.preview.count ? item.preview + "…" : item.preview)
                .font(.system(size: 12))
                .lineSpacing(2)
                .padding(10)
        case .image:
            if let thumb {
                Image(nsImage: thumb).resizable().aspectRatio(contentMode: .fill)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipped()
            } else {
                Image(systemName: "photo").font(.system(size: 30)).foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        case .link:
            VStack(alignment: .leading, spacing: 6) {
                if let linkImage {
                    Image(nsImage: linkImage).resizable().aspectRatio(contentMode: .fill)
                        .frame(maxWidth: .infinity).frame(height: 92).clipped()
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                } else {
                    Image(systemName: "link").font(.system(size: 22, weight: .medium)).foregroundStyle(tint)
                }
                if let title = item.linkTitle {
                    Text(title).font(.system(size: 12, weight: .semibold)).lineLimit(3)
                }
                Text(item.preview).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(4)
            }
            .padding(10)
        case .file:
            let missing = model.filesMissing(item)
            VStack(spacing: 8) {
                if let icon = model.fileIcon(item) {
                    Image(nsImage: icon).resizable().frame(width: 56, height: 56)
                        .opacity(missing ? 0.4 : 1)
                }
                Text(item.preview).font(.system(size: 12, weight: .medium)).multilineTextAlignment(.center).lineLimit(3)
                if missing {
                    Text("Missing").font(.system(size: 10, weight: .semibold)).foregroundStyle(.red)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(10)
        case .color:
            VStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color(hex: item.preview))
                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.primary.opacity(0.12)))
                Text(item.preview).font(.system(size: 13, weight: .semibold, design: .monospaced))
            }
            .padding(12)
        }
    }

    private var footer: some View {
        HStack {
            Text(footerText(item)).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
            Spacer()
            if index < 9 {
                Text("⌘\(index + 1)").font(.system(size: 10, weight: .medium)).foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 24)
    }
}
