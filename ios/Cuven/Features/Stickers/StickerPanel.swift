import SwiftUI

/// Your sticker packs (Telegram), one tab each, and a "+" to add more.
struct StickerPanel: View {
    let roomId: String
    @Binding var replyTo: Message?
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var sets: [StickerSet] = []
    @State private var catalog: [StickerPack] = []
    @State private var selected: String = ""
    @State private var loading = true

    var body: some View {
        VStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(sets) { s in
                        Button {
                            Haptics.selection()
                            withAnimation(Motion.ui) { selected = s.name }
                        } label: {
                            Group {
                                if let first = s.stickers.first {
                                    StickerView(sticker: first, set: s.name, size: 34)
                                } else {
                                    Text(String(s.title.prefix(1)))
                                }
                            }
                            .frame(width: 46, height: 46)
                            .background(selected == s.name ? Theme.fill : .clear, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        }
                        .buttonStyle(.press(0.9))
                        .accessibilityLabel(Text(s.title))
                    }
                    Button {
                        withAnimation(Motion.ui) { selected = "+" }
                        Task { if catalog.isEmpty { catalog = await model.stickerCatalog() } }
                    } label: {
                        Image(systemName: "plus").font(.system(size: 17, weight: .semibold)).foregroundStyle(Theme.label)
                            .frame(width: 46, height: 46)
                            .background(selected == "+" ? Theme.fill : .clear, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }
                    .accessibilityLabel("Add sticker packs")
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
            }
            Hairline()

            if selected == "+" {
                catalogList
            } else if let set = sets.first(where: { $0.name == selected }) {
                ScrollView {
                    Text(set.title).font(.footnoteC.weight(.semibold)).foregroundStyle(Theme.label2)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 16).padding(.top, 12)
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 4), spacing: 8) {
                        ForEach(set.stickers) { st in
                            Button {
                                model.sendSticker(st, set: set.name, room: roomId, replyTo: replyTo)
                                replyTo = nil
                                dismiss()
                            } label: {
                                StickerView(sticker: st, set: set.name, size: 72, animate: false)
                                    .frame(maxWidth: .infinity)
                                    .frame(height: 80)
                            }
                            .buttonStyle(.press(0.85))
                        }
                    }
                    .padding(12)
                }
            } else if loading {
                ProgressView().frame(maxHeight: .infinity)
            } else {
                ContentUnavailableView("No sticker packs", systemImage: "face.smiling", description: Text("Tap + to add some."))
            }
        }
        .task {
            sets = await model.stickerSets()
            selected = sets.first?.name ?? "+"
            loading = false
            if sets.isEmpty { catalog = await model.stickerCatalog() }
        }
    }

    private var catalogList: some View {
        List(catalog) { p in
            HStack(spacing: 12) {
                if let cover = p.cover {
                    StickerView(sticker: cover, set: p.name, size: 44)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(p.title).font(.bodyC)
                    Text("\(p.count) stickers").font(.captionC).foregroundStyle(Theme.label2)
                }
                Spacer()
                Button(p.added ? "Remove" : "Add") {
                    Task {
                        if let fresh = await model.setPack(p.name, added: !p.added) {
                            sets = fresh
                            if let i = catalog.firstIndex(where: { $0.name == p.name }) { catalog[i].added.toggle() }
                        }
                    }
                }
                .font(.subheadMediumC)
                .foregroundStyle(p.added ? Theme.label : .white)
                .padding(.horizontal, 14).frame(height: 32)
                .background(p.added ? Theme.fillQuiet : Theme.blue, in: Capsule())
                .buttonStyle(.press)
            }
        }
        .listStyle(.plain)
        .overlay { if catalog.isEmpty { ProgressView() } }
    }
}
