import SwiftUI
import PhotosUI

/// Settings (views/sheets.js openSettings): the card that opens your
/// profile, then Account, Display & interaction, Messages, Smart and
/// Notifications as the web groups them, and Log out at the foot.
struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(Nav.self) private var nav
    @Environment(\.column) private var ctx
    @AppStorage("ui:glass") private var glassMode = "auto"
    @AppStorage("ui:glassTint") private var glassTint = "tinted"
    @AppStorage("ui:motion") private var motion = "system"
    @AppStorage("ui:time-format") private var timeFormat = "system"
    @State private var confirmSignOut = false
    @State private var confirmForget = false
    @State private var editing = false
    @State private var password = false

    var body: some View {
        @Bindable var model = model
        ScrollView {
            VStack(spacing: 0) {
                SheetHeader(title: "Settings", large: true) { SheetClose() }
                    .padding(.top, 10)

                Button { editing = true } label: {
                    HStack(spacing: 16) {
                        Avatar(user: model.me, size: 64)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(model.me?.name ?? "")
                                .font(AppFont.make(22, .semibold)).tracking(-0.44)
                                .foregroundStyle(Theme.label).lineLimit(2)
                            Text("@\(model.me?.username ?? "")").font(.footnoteC).foregroundStyle(Theme.label2)
                        }
                        Spacer(minLength: 0)
                        SymbolView(.chevronRight, size: 18).foregroundStyle(Theme.label3)
                    }
                    .padding(20)
                    .background(Theme.elevated, in: RoundedRectangle(cornerRadius: 23, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 23, style: .continuous).strokeBorder(Theme.line, lineWidth: 1))
                }
                .buttonStyle(.press)
                .accessibilityLabel("\(model.me?.name ?? ""), edit profile")
                .padding(.top, 2)

                GroupTitle(text: "Account")
                GroupCard {
                    Button { password = true } label: { Cell(icon: .lock, title: "Change password", chevron: true) }
                        .buttonStyle(CellButtonStyle())
                    CellSeparator(leading: 58)
                    Cell(icon: .globe, title: "Server") {
                        Text(model.serverURL.host ?? model.serverURL.absoluteString)
                            .font(.bodyC).foregroundStyle(Theme.label2).lineLimit(1)
                    }
                }

                GroupTitle(text: "Display & interaction")
                GroupCard {
                    segmentRow("Appearance", [("light", "Light"), ("dark", "Dark"), ("system", "Auto")], $model.appearance)
                    CellSeparator()
                    segmentRow("Liquid Glass", [("clear", "Clear"), ("tinted", "Tinted")], $glassTint)
                    CellSeparator()
                    segmentRow("Composer glow", [("off", "Off"), ("ocean", "Ocean"), ("dawn", "Dawn"), ("aurora", "Aurora")], $model.composerGlow)
                    CellSeparator()
                    toggleRow("Reduce transparency", isOn: Binding(get: { glassMode == "solid" }, set: { glassMode = $0 ? "solid" : "auto" }))
                    CellSeparator()
                    toggleRow("Reduce motion", isOn: Binding(get: { motion == "reduce" }, set: { motion = $0 ? "reduce" : "system" }))
                    CellSeparator()
                    toggleRow("Haptic feedback", isOn: $model.haptics)
                    CellSeparator()
                    toggleRow("Book layout", subtitle: String(localized: "iPhone Duo held like a book: the list and the chat meet at the fold."),
                              isOn: $model.bookLayout)
                }

                GroupTitle(text: "Messages")
                GroupCard {
                    segmentRow("Time format", [("system", "System"), ("12", "12-hour"), ("24", "24-hour")], $timeFormat)
                    CellSeparator()
                    toggleRow("Read receipts", isOn: Binding(get: { model.prefs.receipts }, set: { v in Task { await model.setReceipts(v) } }))
                    CellSeparator()
                    toggleRow("Live typing", subtitle: String(localized: "Friends see what you write as you write it."), isOn: $model.livePreview)
                }
                GroupFoot(text: "With read receipts off, friends won’t see when you’ve read.")

                if model.assistEnabled {
                    GroupTitle(text: "Smart")
                    GroupCard {
                        toggleRow("Typing suggestions", isOn: $model.predictions)
                        CellSeparator()
                        toggleRow("Highlight keywords", isOn: $model.highlights)
                    }
                    GroupCard {
                        Button { confirmForget = true } label: { Cell(icon: .sparkles, title: "Clear memory", chevron: true) }
                            .buttonStyle(CellButtonStyle())
                    }
                    .padding(.top, 12)
                    GroupFoot(text: "Suggestions learn only from your own use. View or clear them anytime.")
                }

                GroupCard {
                    Button { confirmSignOut = true } label: {
                        Text("Log out").font(.bodyC).foregroundStyle(Theme.redText)
                            .frame(maxWidth: .infinity).frame(minHeight: 58).contentShape(Rectangle())
                    }
                    .buttonStyle(CellButtonStyle())
                }
                .padding(.top, 20)

                Text("Cuven \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0") · iOS")
                    .font(.footnoteC).foregroundStyle(Theme.label3)
                    .padding(.top, 14)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, max(ctx.insets.bottom, 16) + 24)
        }
        .background(Theme.paper)
        .confirmationDialog("Log out of Cuven?", isPresented: $confirmSignOut, titleVisibility: .visible) {
            Button("Log out", role: .destructive) {
                nav.settingsOpen = false
                Task { await model.logout() }
            }
        }
        .confirmationDialog("Forget your writing style and chat summaries?", isPresented: $confirmForget, titleVisibility: .visible) {
            Button("Clear memory", role: .destructive) {
                Task {
                    try? await model.api.delete("/api/ai/memory")
                    model.show(String(localized: "Memory cleared"))
                }
            }
        }
        .sheet(isPresented: $editing) { EditProfileSheet() }
        .sheet(isPresented: $password) { PasswordSheet() }
        .onChange(of: model.haptics) { _, on in if on { Haptics.selection() } }
    }

    private func segmentRow(_ title: LocalizedStringKey, _ options: [(String, LocalizedStringKey)], _ value: Binding<String>) -> some View {
        HStack(spacing: 12) {
            Text(title).font(.bodyC).foregroundStyle(Theme.label)
                .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                .frame(minWidth: 80, alignment: .leading)
            Spacer(minLength: 0)
            InkSegmented(options: options, selection: value)
                .frame(maxWidth: CGFloat(options.count) * 84)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
        .frame(minHeight: 58)
    }

    private func toggleRow(_ title: LocalizedStringKey, subtitle: String? = nil, isOn: Binding<Bool>) -> some View {
        Toggle(isOn: isOn) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.bodyC).foregroundStyle(Theme.label)
                if let subtitle {
                    Text(subtitle).font(.footnoteC).lineSpacing(3).foregroundStyle(Theme.label2)
                }
            }
        }
        .toggleStyle(.ink)
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
        .frame(minHeight: 58)
    }
}

/// Edit profile: the cover across the top, your photo over its lower edge,
/// your name and a line about you.
struct EditProfileSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var display = ""
    @State private var bio = ""
    @State private var avatarItem: PhotosPickerItem?
    @State private var coverItem: PhotosPickerItem?
    @State private var uploading = false
    @State private var saving = false
    @State private var recent: [String] = []

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                SheetHeader(title: "Edit profile", centered: true) {
                    GlassIconButton(sym: .xmark, title: "Cancel") { dismiss() }
                } trailing: {
                    EmptyView()
                }
                PhotosPicker(selection: $coverItem, matching: .images) {
                    ZStack {
                        Group {
                            if let cover = model.me?.cover, !cover.isEmpty, !cover.hasPrefix("preset:") {
                                RemoteImage(cover, maxPixel: 1200)
                            } else {
                                LinearGradient(colors: [Color(hex: 0x0d1430), Color(hex: 0x1c2f6b), Color(hex: 0x0a0f24)],
                                               startPoint: .topLeading, endPoint: .bottomTrailing)
                            }
                        }
                        .frame(height: 140)
                        .frame(maxWidth: .infinity)
                        .clipped()
                        HStack(spacing: 6) {
                            SymbolView(.photo, size: 16)
                            Text("Change cover").font(AppFont.make(13, .semibold))
                        }
                        .foregroundStyle(.white)
                        .padding(.horizontal, 12).frame(height: 32)
                        .background(.black.opacity(0.4), in: Capsule())
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 23, style: .continuous))
                }
                .buttonStyle(.press)
                .accessibilityLabel("Change cover")

                PhotosPicker(selection: $avatarItem, matching: .images) {
                    Avatar(user: model.me, size: 96)
                        .background(Circle().fill(Theme.paper).padding(-4))
                        .overlay(alignment: .bottomTrailing) {
                            SymbolView(.camera, size: 15).foregroundStyle(Theme.onInk)
                                .frame(width: 30, height: 30).background(Theme.ink, in: Circle())
                                .background(Circle().fill(Theme.paper).padding(-2.5))
                                .opacity(uploading ? 0.5 : 1)
                        }
                }
                .buttonStyle(.press(0.96))
                .padding(.top, -48)
                .padding(.leading, 20)
                .accessibilityLabel("Change avatar")

                if !recent.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 10) {
                            ForEach(recent, id: \.self) { url in
                                Button { Task { _ = await model.updateProfile(avatar: url) } } label: {
                                    Avatar(path: url, name: "", id: url, size: 40)
                                }
                                .buttonStyle(.press(0.9))
                            }
                        }
                        .padding(.horizontal, 4)
                    }
                    .padding(.top, 12)
                }

                label("Display name")
                field("Display name", text: $display)
                label("Bio")
                field("Bio (optional)", text: $bio)

                Button {
                    saving = true
                    Task {
                        let name = display.trimmingCharacters(in: .whitespaces)
                        if await model.updateProfile(display: name.isEmpty ? model.me?.username : name,
                                                     bio: bio.trimmingCharacters(in: .whitespaces)) {
                            Haptics.success()
                            model.show(String(localized: "Saved"))
                            dismiss()
                        }
                        saving = false
                    }
                } label: {
                    Text("Save").font(.headlineC).foregroundStyle(Theme.onInk)
                        .frame(maxWidth: .infinity).frame(height: 50)
                        .background(Theme.ink, in: Capsule())
                }
                .buttonStyle(.press)
                .disabled(saving)
                .padding(.top, 24)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 24)
        }
        .background(Theme.paper)
        .presentationDetents([.large])
        .presentationCornerRadius(30)
        .presentationBackground(Theme.paper)
        .onChange(of: avatarItem) { _, item in
            guard let item else { return }
            Task {
                uploading = true
                if let data = try? await item.loadTransferable(type: Data.self), let img = UIImage(data: data) {
                    _ = await model.uploadAvatar(img)
                    recent = await model.recentAvatars()
                }
                uploading = false
                avatarItem = nil
            }
        }
        .onChange(of: coverItem) { _, item in
            guard let item else { return }
            Task {
                if let data = try? await item.loadTransferable(type: Data.self), let img = UIImage(data: data) {
                    _ = await model.uploadCover(img)
                }
                coverItem = nil
            }
        }
        .task {
            display = model.me?.display ?? ""
            bio = model.me?.bio ?? ""
            recent = await model.recentAvatars()
        }
    }

    private func label(_ t: LocalizedStringKey) -> some View {
        Text(t).font(AppFont.make(13, .semibold)).foregroundStyle(Theme.label2)
            .padding(.top, 18).padding(.bottom, 6).padding(.leading, 6)
    }

    private func field(_ placeholder: LocalizedStringKey, text: Binding<String>) -> some View {
        TextField(placeholder, text: text)
            .font(.bodyC)
            .padding(.horizontal, 16)
            .frame(height: 50)
            .background(Theme.elevated, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Theme.line, lineWidth: 1))
    }
}

/// Change password.
struct PasswordSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var current = ""
    @State private var next = ""
    @State private var busy = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SheetHeader(title: "Change password", centered: true) {
                GlassIconButton(sym: .xmark, title: "Cancel") { dismiss() }
            } trailing: {
                EmptyView()
            }
            Text("Current password").font(AppFont.make(13, .semibold)).foregroundStyle(Theme.label2)
                .padding(.top, 8).padding(.bottom, 6).padding(.leading, 6)
            SecureField("Current password", text: $current)
                .textContentType(.password)
                .font(.bodyC).padding(.horizontal, 16).frame(height: 50)
                .background(Theme.elevated, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Theme.line, lineWidth: 1))
            Text("New password").font(AppFont.make(13, .semibold)).foregroundStyle(Theme.label2)
                .padding(.top, 18).padding(.bottom, 6).padding(.leading, 6)
            SecureField("New password (6+ characters)", text: $next)
                .textContentType(.newPassword)
                .font(.bodyC).padding(.horizontal, 16).frame(height: 50)
                .background(Theme.elevated, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Theme.line, lineWidth: 1))
            Button {
                busy = true
                Task {
                    if await model.changePassword(current: current, next: next) {
                        model.show(String(localized: "Password updated"))
                        dismiss()
                    }
                    busy = false
                }
            } label: {
                Group {
                    if busy { ProgressView().tint(Theme.onInk) } else { Text("Update password").font(.headlineC) }
                }
                .foregroundStyle(Theme.onInk)
                .frame(maxWidth: .infinity).frame(height: 50)
                .background(Theme.ink, in: Capsule())
            }
            .buttonStyle(.press)
            .disabled(current.isEmpty || next.count < 6 || busy)
            .opacity(current.isEmpty || next.count < 6 ? 0.4 : 1)
            .padding(.top, 24)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 20)
        .background(Theme.paper)
        .presentationDetents([.height(400), .large])
        .presentationCornerRadius(30)
        .presentationBackground(Theme.paper)
    }
}
