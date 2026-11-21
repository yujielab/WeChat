import SwiftUI

struct AuthView: View {
    @Environment(AppModel.self) private var model
    @State private var mode: Mode = .signIn
    @State private var username = ""
    @State private var display = ""
    @State private var password = ""
    @State private var code = ""
    @State private var needsCode = false
    @State private var busy = false
    @State private var error: String?
    @State private var appear = false
    @State private var reveal = false
    @FocusState private var focus: Field?

    enum Mode: String, CaseIterable { case signIn, register }
    enum Field: Hashable { case user, display, password, code }

    var body: some View {
        GeometryReader { proxy in
        ZStack {
            Theme.bg.ignoresSafeArea()
            ScrollView {
                VStack(spacing: 0) {
                    Spacer(minLength: 28)
                    Text("CUVEN")
                        .font(AppFont.make(26, .bold))
                        .tracking(13)
                        .padding(.leading, 13)
                        .foregroundStyle(Theme.ink)
                        .modifier(Reveal(step: 0, on: appear))

                    modePicker
                        .padding(.top, 38)
                        .modifier(Reveal(step: 1, on: appear))

                    VStack(spacing: 16) {
                        labelled("Username") {
                            input("", text: $username, field: .user)
                                .textContentType(.username)
                        }
                        if mode == .register {
                            labelled("Display name") {
                                input("", text: $display, field: .display).textContentType(.name)
                            }
                            .transition(.opacity.combined(with: .offset(y: -6)))
                        }
                        labelled("Password", hint: mode == .register ? String(localized: "6+ characters") : nil) { secureField }
                        if mode == .register && needsCode {
                            labelled("Invite code") { input("", text: $code, field: .code) }
                                .transition(.opacity.combined(with: .offset(y: -6)))
                        }
                        if let error {
                            Text(error)
                                .font(.footnoteC).lineSpacing(3)
                                .foregroundStyle(Theme.redText)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .transition(.opacity)
                        }
                        Button(action: submit) {
                            ZStack {
                                if busy { ProgressView().tint(Theme.onInk) }
                                else {
                                    Text(mode == .signIn ? "Log in" : "Sign up")
                                        .font(AppFont.make(16, .semibold)).tracking(0.32)
                                }
                            }
                            .foregroundStyle(Theme.onInk)
                            .frame(maxWidth: .infinity, minHeight: 52)
                            .glassEffect(.regular.tint(Theme.ink.opacity(0.88)).interactive(), in: Capsule())
                        }
                        .buttonStyle(.press(0.97))
                        .disabled(busy)
                        .padding(.top, 8)
                    }
                    .padding(.top, 26)
                    .modifier(Reveal(step: 2, on: appear))

                    Spacer(minLength: 20)
                }
                .padding(.horizontal, 24)
                .frame(maxWidth: 380 + 48)
                .frame(maxWidth: .infinity)
                // The form stands in the middle of the screen (auth.css margin: auto).
                .frame(minHeight: proxy.size.height)
            }
            .scrollDismissesKeyboard(.interactively)
            .scrollBounceBehavior(.basedOnSize)
        }
        }
        .animation(Motion.ui, value: mode)
        .animation(Motion.ui, value: error)
        .animation(Motion.ui, value: needsCode)
        .task {
            appear = true
            needsCode = await model.authStatus()?.needsCode ?? false
        }
    }

    private var canSubmit: Bool {
        username.count >= 3 && password.count >= 6 && !busy
    }

    /// Log in · Sign up: an ink pill that slides under the chosen one.
    private var modePicker: some View {
        HStack(spacing: 0) {
            ForEach(Mode.allCases, id: \.self) { m in
                Button {
                    withAnimation(Motion.ui) { mode = m }
                    error = nil
                    Haptics.selection()
                } label: {
                    Text(m == .signIn ? "Log in" : "Sign up")
                        .font(AppFont.make(13, .semibold)).tracking(0.26)
                        .foregroundStyle(mode == m ? Theme.onInk : Theme.label2)
                        .frame(maxWidth: .infinity, minHeight: 42)
                        .background {
                            if mode == m {
                                Capsule().fill(.clear)
                                    .glassEffect(.regular.tint(Theme.ink.opacity(0.55)), in: Capsule())
                                    .matchedGeometryEffect(id: "mode", in: ns)
                            }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(Theme.field, in: Capsule())
        .overlay(Capsule().strokeBorder(Theme.line, lineWidth: 1))
    }

    @Namespace private var ns

    private func labelled<C: View>(_ title: LocalizedStringKey, hint: String? = nil, @ViewBuilder content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title).font(AppFont.make(12, .medium)).tracking(0.6).foregroundStyle(Theme.label2)
                Spacer()
                if let hint { Text(hint).font(.caption2C).foregroundStyle(Theme.label3) }
            }
            .padding(.horizontal, 4)
            content()
        }
    }

    private func inputChrome<C: View>(_ field: Field, @ViewBuilder _ content: () -> C) -> some View {
        content()
            .padding(.horizontal, 18)
            .frame(height: 52)
            .background(Theme.bg, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(focus == field ? Theme.label : Theme.line, lineWidth: 1))
            .background(RoundedRectangle(cornerRadius: 15, style: .continuous).fill(Theme.label.opacity(focus == field ? 0.08 : 0)).padding(-3))
            .animation(Motion.quick, value: focus)
    }

    private func input(_ placeholder: LocalizedStringKey, text: Binding<String>, field: Field) -> some View {
        inputChrome(field) {
            TextField(placeholder, text: text)
                .font(.calloutC)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .focused($focus, equals: field)
                .submitLabel(.next)
                .onSubmit { advance(from: field) }
        }
    }

    private var secureField: some View {
        inputChrome(.password) {
            HStack {
                Group {
                    if reveal {
                        TextField("", text: $password)
                    } else {
                        SecureField("", text: $password)
                    }
                }
                .font(.calloutC)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .textContentType(mode == .signIn ? .password : .newPassword)
                .focused($focus, equals: .password)
                .submitLabel(.go)
                .onSubmit { if canSubmit { submit() } }
                Button(reveal ? "Hide" : "Show") { reveal.toggle() }
                    .font(AppFont.make(12, .medium))
                    .foregroundStyle(Theme.label2)
                    .buttonStyle(.plain)
                    .frame(minWidth: 44, minHeight: 44)
            }
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
        guard canSubmit else {
            error = username.count < 3 ? String(localized: "Enter your username") : String(localized: "Passwords are at least 6 characters")
            Haptics.warning()
            return
        }
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
                self.error = error.userMessage
                Haptics.error()
            }
            busy = false
        }
    }
}

/// Sections settle one after another (the web's .reveal: 420ms, 60ms apart).
struct Reveal: ViewModifier {
    let step: Int
    let on: Bool
    func body(content: Content) -> some View {
        content
            .opacity(on ? 1 : 0)
            .offset(y: on ? 0 : 10)
            .animation(.timingCurve(0.22, 1, 0.36, 1, duration: 0.42).delay(Double(step) * 0.06), value: on)
    }
}
