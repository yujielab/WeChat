import SwiftUI

struct AuthView: View {
    @Environment(AppModel.self) private var model
    @State private var mode: Mode = .signIn
    @State private var username = ""
    @State private var display = ""
    @State private var password = ""
    @State private var code = ""
    @State private var server = ""
    @State private var needsCode = false
    @State private var showServer = false
    @State private var busy = false
    @State private var error: String?
    @State private var appear = false
    @FocusState private var focus: Field?

    enum Mode: String, CaseIterable { case signIn, register }
    enum Field: Hashable { case user, display, password, code, server }

    var body: some View {
        ZStack {
            Theme.bg.ignoresSafeArea()
            GlowField(palette: "ocean", intensity: 1.3)
                .frame(height: 520)
                .frame(maxHeight: .infinity, alignment: .top)
                .ignoresSafeArea()

            ScrollView {
                VStack(spacing: 28) {
                    Spacer(minLength: 40)
                    VStack(spacing: 10) {
                        Image(systemName: "bubble.left.and.bubble.right.fill")
                            .font(.system(size: 40, weight: .semibold))
                            .foregroundStyle(Theme.blue.gradient)
                            .symbolEffect(.bounce, value: mode)
                        Text("CUVEN")
                            .font(AppFont.make(30, .black))
                            .tracking(10)
                            .foregroundStyle(Theme.label)
                        Text(mode == .signIn ? "Welcome back" : "Messages, calls and moments — on your own server")
                            .font(.subheadC)
                            .foregroundStyle(Theme.label2)
                            .multilineTextAlignment(.center)
                            .contentTransition(.opacity)
                    }
                    .opacity(appear ? 1 : 0)
                    .offset(y: appear ? 0 : 12)

                    modePicker

                    VStack(spacing: 12) {
                        field("Username", text: $username, field: .user, symbol: "at")
                            .textContentType(.username)
                        if mode == .register {
                            field("Display name", text: $display, field: .display, symbol: "person")
                                .textContentType(.name)
                                .transition(.move(edge: .top).combined(with: .opacity))
                        }
                        secureField
                        if mode == .register && needsCode {
                            field("Invite code", text: $code, field: .code, symbol: "ticket")
                                .transition(.move(edge: .top).combined(with: .opacity))
                        }
                    }

                    if let error {
                        Label(error, systemImage: "exclamationmark.circle.fill")
                            .font(.footnoteC)
                            .foregroundStyle(Theme.redText)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .transition(.opacity.combined(with: .move(edge: .top)))
                    }

                    PrimaryButton(title: mode == .signIn ? "Sign in" : "Create account", loading: busy, enabled: canSubmit) {
                        submit()
                    }

                    serverRow
                    Spacer(minLength: 20)
                }
                .padding(.horizontal, 28)
                .frame(maxWidth: 440)
                .frame(maxWidth: .infinity)
            }
            .scrollDismissesKeyboard(.interactively)
        }
        .animation(Motion.ui, value: mode)
        .animation(Motion.ui, value: error)
        .animation(Motion.ui, value: needsCode)
        .task {
            server = model.serverURL.absoluteString
            withAnimation(.spring(response: 0.6, dampingFraction: 0.8).delay(0.05)) { appear = true }
            needsCode = await model.authStatus()?.needsCode ?? false
        }
    }

    private var canSubmit: Bool {
        username.count >= 3 && password.count >= 6 && !busy
    }

    private var modePicker: some View {
        HStack(spacing: 0) {
            ForEach(Mode.allCases, id: \.self) { m in
                Button {
                    mode = m
                    error = nil
                    Haptics.selection()
                } label: {
                    Text(m == .signIn ? "Sign in" : "Create account")
                        .font(.subheadMediumC)
                        .foregroundStyle(mode == m ? Theme.label : Theme.label2)
                        .frame(maxWidth: .infinity, minHeight: 40)
                        .background {
                            if mode == m {
                                Capsule().fill(Theme.elevated)
                                    .shadow(color: .black.opacity(0.08), radius: 6, y: 2)
                                    .matchedGeometryEffect(id: "mode", in: ns)
                            }
                        }
                }
                .buttonStyle(.plain)
            }
        }
        .padding(4)
        .background(Theme.field, in: Capsule())
    }

    @Namespace private var ns

    private func field(_ title: LocalizedStringKey, text: Binding<String>, field: Field, symbol: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol).foregroundStyle(Theme.label3).frame(width: 20)
            TextField(title, text: text)
                .font(.bodyC)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .focused($focus, equals: field)
                .submitLabel(.next)
                .onSubmit { advance(from: field) }
        }
        .padding(.horizontal, 16)
        .frame(height: 54)
        .background(Theme.field, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(focus == field ? Theme.blue.opacity(0.6) : .clear, lineWidth: 1.5))
        .animation(Motion.quick, value: focus)
    }

    private var secureField: some View {
        HStack(spacing: 12) {
            Image(systemName: "lock").foregroundStyle(Theme.label3).frame(width: 20)
            SecureField("Password", text: $password)
                .font(.bodyC)
                .textContentType(mode == .signIn ? .password : .newPassword)
                .focused($focus, equals: .password)
                .submitLabel(.go)
                .onSubmit { if canSubmit { submit() } }
        }
        .padding(.horizontal, 16)
        .frame(height: 54)
        .background(Theme.field, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(focus == .password ? Theme.blue.opacity(0.6) : .clear, lineWidth: 1.5))
    }

    private var serverRow: some View {
        VStack(spacing: 10) {
            Button {
                withAnimation(Motion.ui) { showServer.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "server.rack")
                    Text(model.serverURL.host ?? "Server")
                    Image(systemName: "chevron.down").rotationEffect(.degrees(showServer ? 180 : 0))
                }
                .font(.footnoteC)
                .foregroundStyle(Theme.label2)
            }
            .buttonStyle(.plain)
            if showServer {
                HStack {
                    TextField("https://your-server", text: $server)
                        .font(.subheadC)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .focused($focus, equals: .server)
                        .onSubmit { applyServer() }
                    Button("Use") { applyServer() }
                        .font(.subheadMediumC)
                }
                .padding(.horizontal, 14)
                .frame(height: 46)
                .background(Theme.field, in: Capsule())
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }

    private func applyServer() {
        if model.setServer(server) {
            server = model.serverURL.absoluteString
            focus = nil
            Haptics.success()
            Task { needsCode = await model.authStatus()?.needsCode ?? false }
        } else {
            error = String(localized: "That doesn't look like a server address")
        }
    }

    private func advance(from f: Field) {
        switch f {
        case .user: focus = mode == .register ? .display : .password
        case .display: focus = .password
        case .password: focus = needsCode && mode == .register ? .code : nil
        default: focus = nil
        }
    }

    private func submit() {
        focus = nil
        error = nil
        busy = true
        Task {
            do {
                if mode == .signIn {
                    try await model.login(username: username.trimmingCharacters(in: .whitespaces), password: password)
                } else {
                    try await model.register(username: username.trimmingCharacters(in: .whitespaces),
                                             display: display.trimmingCharacters(in: .whitespaces),
                                             password: password, code: code.trimmingCharacters(in: .whitespaces))
                }
                Haptics.success()
            } catch {
                self.error = error.localizedDescription
                Haptics.error()
            }
            busy = false
        }
    }
}
