import SwiftUI
import PhotosUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var display = ""
    @State private var bio = ""
    @State private var avatarItem: PhotosPickerItem?
    @State private var coverItem: PhotosPickerItem?
    @State private var uploading = false
    @State private var confirmSignOut = false
    @State private var confirmForget = false
    @State private var recent: [String] = []

    var body: some View {
        @Bindable var model = model
        NavigationStack {
            Form {
                Section {
                    VStack(spacing: 12) {
                        ZStack(alignment: .bottom) {
                            Group {
                                if let cover = model.me?.cover, !cover.isEmpty, !cover.hasPrefix("preset:") {
                                    RemoteImage(cover, maxPixel: 1200)
                                } else {
                                    LinearGradient(colors: [Theme.blue.opacity(0.35), Theme.sky.opacity(0.2)], startPoint: .topLeading, endPoint: .bottomTrailing)
                                }
                            }
                            .frame(height: 120)
                            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                            .overlay(alignment: .topTrailing) {
                                PhotosPicker(selection: $coverItem, matching: .images) {
                                    Image(systemName: "photo").font(.system(size: 13, weight: .bold)).foregroundStyle(.white)
                                        .frame(width: 32, height: 32).background(.black.opacity(0.3), in: Circle())
                                }
                                .padding(8)
                                .accessibilityLabel("Change cover")
                            }

                            PhotosPicker(selection: $avatarItem, matching: .images) {
                                Avatar(user: model.me, size: 88)
                                    .overlay(Circle().stroke(Theme.groupedCell, lineWidth: 4))
                                    .overlay(alignment: .bottomTrailing) {
                                        Image(systemName: uploading ? "arrow.triangle.2.circlepath" : "camera.fill")
                                            .font(.system(size: 12, weight: .bold)).foregroundStyle(.white)
                                            .frame(width: 28, height: 28).background(Theme.blue, in: Circle())
                                            .overlay(Circle().stroke(Theme.groupedCell, lineWidth: 2))
                                            .symbolEffect(.pulse, isActive: uploading)
                                    }
                            }
                            .offset(y: 44)
                            .accessibilityLabel("Change photo")
                        }
                        .padding(.bottom, 44)
                        Text("@\(model.me?.username ?? "")").font(.subheadC).foregroundStyle(Theme.label2)
                        if !recent.isEmpty {
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 10) {
                                    ForEach(recent, id: \.self) { url in
                                        Button {
                                            Task { _ = await model.updateProfile(avatar: url) }
                                        } label: {
                                            Avatar(path: url, name: "", id: url, size: 40)
                                        }
                                        .buttonStyle(.press(0.9))
                                    }
                                }
                            }
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .listRowBackground(Color.clear)
                }

                Section("Profile") {
                    TextField("Name", text: $display).font(.bodyC)
                    TextField("Bio", text: $bio, axis: .vertical).font(.bodyC).lineLimit(1...4)
                    if display != (model.me?.display ?? "") || bio != (model.me?.bio ?? "") {
                        Button("Save profile") {
                            Task {
                                if await model.updateProfile(display: display, bio: bio) { Haptics.success() }
                            }
                        }
                        .font(.headlineC)
                    }
                }

                Section("Display") {
                    Picker("Appearance", selection: $model.appearance) {
                        Text("Light").tag("light")
                        Text("Dark").tag("dark")
                        Text("Automatic").tag("system")
                    }
                    Picker("Composer glow", selection: $model.composerGlow) {
                        Text("Off").tag("off")
                        Text("Ocean").tag("ocean")
                        Text("Dawn").tag("dawn")
                        Text("Aurora").tag("aurora")
                    }
                    Toggle("Haptics", isOn: $model.haptics)
                    Toggle(isOn: $model.bookLayout) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Equal panes when open")
                            Text("For iPhone Duo held like a book: list and chat split at the fold.").font(.captionC).foregroundStyle(Theme.label2)
                        }
                    }
                }
                .tint(Theme.blue)

                Section("Privacy") {
                    Toggle(isOn: Binding(get: { model.prefs.receipts }, set: { v in Task { await model.setReceipts(v) } })) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Read receipts")
                            Text("Friends see when you've read their messages.").font(.captionC).foregroundStyle(Theme.label2)
                        }
                    }
                    Toggle(isOn: $model.livePreview) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Live typing")
                            Text("Others see what you're writing as you write it.").font(.captionC).foregroundStyle(Theme.label2)
                        }
                    }
                }
                .tint(Theme.blue)

                if model.assistEnabled {
                    Section {
                        Toggle("Input prediction", isOn: $model.predictions)
                        Toggle("Highlight key words", isOn: $model.highlights)
                        Button("Clear what the writing help remembers", role: .destructive) { confirmForget = true }
                    } header: {
                        Text("Smart")
                    } footer: {
                        Text("Suggestions read only messages already sent, never anyone's live typing.")
                    }
                    .tint(Theme.blue)
                }

                Section("Account") {
                    NavigationLink("Change password") { PasswordView() }
                    LabeledContent("Server", value: model.serverURL.host ?? model.serverURL.absoluteString)
                    Button("Sign out", role: .destructive) { confirmSignOut = true }
                }

                Section {
                    LabeledContent("Version", value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0")
                } footer: {
                    Text("Cuven for iOS — native, designed for iPhone Duo.")
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .confirmationDialog("Sign out of Cuven?", isPresented: $confirmSignOut, titleVisibility: .visible) {
                Button("Sign out", role: .destructive) {
                    dismiss()
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
    }
}

struct PasswordView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var current = ""
    @State private var next = ""
    @State private var busy = false

    var body: some View {
        Form {
            SecureField("Current password", text: $current).textContentType(.password)
            SecureField("New password (6+ characters)", text: $next).textContentType(.newPassword)
            Button {
                busy = true
                Task {
                    if await model.changePassword(current: current, next: next) { dismiss() }
                    busy = false
                }
            } label: {
                if busy { ProgressView() } else { Text("Change password").font(.headlineC) }
            }
            .disabled(current.isEmpty || next.count < 6 || busy)
        }
        .navigationTitle("Password")
    }
}
