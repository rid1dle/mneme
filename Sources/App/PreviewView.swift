import AppKit
import SwiftUI

/// The selected item at full size in place of the card row. Text can be edited here (rich text keeps its formatting).
struct PreviewView: View {
    let item: Item
    @ObservedObject var model: ShelfModel
    @EnvironmentObject var theme: ThemeStore
    @State private var full: FullItem?
    @State private var editor = TextEditorBox()

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color(nsColor: .textBackgroundColor)))
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(model.editing ? theme.accent : Color.primary.opacity(0.10), lineWidth: model.editing ? 2 : 1))
            side.frame(width: 200)
        }
        .task(id: item) { full = await model.loadFull(item) }
    }

    private var isText: Bool { item.kind == .text || item.kind == .richText }

    @ViewBuilder private var content: some View {
        if let full {
            switch item.kind {
            case .text, .richText, .link:
                RichTextView(text: full.attributed ?? NSAttributedString(string: full.text ?? item.preview, attributes: [
                                 .font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.textColor]),
                             rich: item.kind == .richText, editable: model.editing && isText, box: editor)
            case .image:
                if let image = full.image {
                    Image(nsImage: image).resizable().aspectRatio(contentMode: .fit).padding(8)
                } else {
                    Text("This image could not be read").foregroundStyle(.secondary)
                }
            case .file:
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(item.fileURLs, id: \.self) { url in
                            HStack(spacing: 8) {
                                Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().frame(width: 20, height: 20)
                                Text(url.path).font(.system(size: 12)).lineLimit(1).truncationMode(.middle)
                                if !FileManager.default.fileExists(atPath: url.path) {
                                    Text("Missing").font(.system(size: 10, weight: .semibold)).foregroundStyle(.red)
                                }
                            }
                        }
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            case .color:
                HStack(spacing: 16) {
                    RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color(hex: item.preview)).frame(width: 120, height: 120)
                    VStack(alignment: .leading, spacing: 6) {
                        Text(item.preview).font(.system(size: 18, weight: .semibold, design: .monospaced)).textSelection(.enabled)
                        Text(footerText(item)).font(.system(size: 13, design: .monospaced)).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                }
            }
        } else {
            ProgressView().controlSize(.small)
        }
    }

    private var side: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(item.title ?? item.source?.name ?? "Item").font(.system(size: 15, weight: .semibold)).lineLimit(2)
            Text("\(footerText(item)) · \(relativeTimeLong(item.lastUsedAt))").note()
            Spacer(minLength: 6)
            if model.editing {
                Button { if let t = editor.current() { model.saveText(item, t) } } label: { Label("Save", systemImage: "checkmark") .frame(maxWidth: .infinity) }
                    .keyboardShortcut("s", modifiers: .command)
                    .buttonStyle(.borderedProminent)
                Button { model.editing = false; editor.reset() } label: { Text("Cancel").frame(maxWidth: .infinity) }
                Text("⌘S saves, Esc cancels").font(.system(size: 10)).foregroundStyle(.tertiary)
            } else {
                Button { model.perform(.paste(item, plainText: false)) } label: { Label("Paste", systemImage: "arrow.down.doc").frame(maxWidth: .infinity) }
                    .buttonStyle(.borderedProminent)
                Button { model.perform(.copy(item)) } label: { Label("Copy", systemImage: "doc.on.doc").frame(maxWidth: .infinity) }
                if isText {
                    Button { model.editing = true } label: { Label("Edit", systemImage: "pencil").frame(maxWidth: .infinity) }
                } else if item.kind == .image {
                    Button { model.perform(.editImage(item)) } label: { Label("Edit in Preview", systemImage: "pencil.tip.crop.circle").frame(maxWidth: .infinity) }
                }
                Text("Space closes, ⌘E edits").font(.system(size: 10)).foregroundStyle(.tertiary)
            }
        }
        .controlSize(.large)
    }
}

/// Lets the side buttons read what is in the text view.
final class TextEditorBox {
    weak var textView: NSTextView?
    var original: NSAttributedString?
    func current() -> NSAttributedString? { textView.map { NSAttributedString(attributedString: $0.attributedString()) } }
    func reset() { if let original, let tv = textView { tv.textStorage?.setAttributedString(original) } }
}

struct RichTextView: NSViewRepresentable {
    let text: NSAttributedString
    let rich: Bool
    let editable: Bool
    let box: TextEditorBox

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        let tv = scroll.documentView as! NSTextView
        tv.drawsBackground = false
        tv.textContainerInset = NSSize(width: 10, height: 10)
        tv.isRichText = rich
        tv.usesAdaptiveColorMappingForDarkAppearance = true
        tv.allowsUndo = true
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.textStorage?.setAttributedString(text)
        if !rich { tv.font = .systemFont(ofSize: 13); tv.textColor = .textColor }
        box.textView = tv
        box.original = text
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let tv = scroll.documentView as? NSTextView else { return }
        if box.original != text {
            tv.textStorage?.setAttributedString(text)
            if !rich { tv.font = .systemFont(ofSize: 13); tv.textColor = .textColor }
            box.original = text
        }
        tv.isEditable = editable
        tv.isSelectable = true
        if editable, tv.window?.firstResponder !== tv { DispatchQueue.main.async { tv.window?.makeFirstResponder(tv) } }
    }
}

// MARK: small sheets inside the shelf

struct OverlaySheet: View {
    let overlay: Overlay
    @ObservedObject var model: ShelfModel
    @EnvironmentObject var theme: ThemeStore
    @State private var text = ""
    @State private var color = ShelfModel.pinboardColors[0]
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            switch overlay {
            case .rename(let item):
                Text("Rename").font(.system(size: 14, weight: .semibold))
                TextField("Title", text: $text).textFieldStyle(.roundedBorder).focused($focused)
                    .onSubmit { model.rename(item, to: text) }
                    .onAppear { text = item.title ?? ""; focused = true }
                Text("Leave empty to remove the title.").note()
                buttons("Rename") { model.rename(item, to: text) }
            case .newPinboard(let item):
                Text("New Pinboard").font(.system(size: 14, weight: .semibold))
                TextField("Name", text: $text).textFieldStyle(.roundedBorder).focused($focused)
                    .onSubmit { model.newPinboard(name: text, color: color, pinning: item) }
                    .onAppear { focused = true }
                HStack(spacing: 8) {
                    ForEach(ShelfModel.pinboardColors, id: \.self) { c in
                        Circle().fill(Color(hex: c)).frame(width: 20, height: 20)
                            .overlay(Circle().strokeBorder(Color.primary.opacity(c == color ? 0.8 : 0), lineWidth: 2).padding(-3))
                            .onTapGesture { color = c }
                            .accessibilityLabel(c)
                    }
                }
                buttons("Create") { model.newPinboard(name: text, color: color, pinning: item) }
            case .confirmDelete(let item, let boards):
                Text("Delete everywhere?").font(.system(size: 14, weight: .semibold))
                Text("“\(item.title ?? (item.preview.count > 50 ? item.preview.prefix(50) + "…" : item.preview))” is on \(boards) pinboard\(boards == 1 ? "" : "s"). It will be removed from History and from \(boards == 1 ? "it" : "them").")
                    .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                buttons("Delete", destructive: true) { model.deleteEverywhere(item, confirmed: true) }
            case .preview:
                EmptyView()
            }
        }
        .padding(18)
        .frame(width: 360)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color(nsColor: .windowBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Color.primary.opacity(0.12)))
        .shadow(color: .black.opacity(0.25), radius: 18, y: 6)
    }

    private func buttons(_ title: String, destructive: Bool = false, action: @escaping () -> Void) -> some View {
        HStack {
            Spacer()
            Button("Cancel") { model.overlay = nil }.keyboardShortcut(.cancelAction)
            Button(title, role: destructive ? .destructive : nil, action: action).keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
        }
    }
}
