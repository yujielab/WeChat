import SwiftUI
import CuvenCore

// MARK: - Apple HIG & iOS 27.1 SDK Traceability
// - Apple HIG › Designing for iPhone Duo: Full-bleed paper/ink background extending edge-to-edge under
//   iOS 27.1 right status column (`DuoLayoutMetrics`), centering the editorial card clear of asymmetric safe areas
//   and splitting cleanly across `hingeDivisionRect` in `duoHalfBook` so interactive inputs never straddle a fold.
// - Apple HIG › Materials / Liquid Glass: Gliding Sign In ↔ Create Account capsule indicator and prominent
//   "Explore Instant Demo (iPhone & Duo)" button powered by `.cuvenLiquidGlass(...)` with Reduce Transparency support.
// - Apple HIG › Typography & Accessibility: `Clarinetta` tracked uppercase wordmark (`auth.wordmark`),
//   capped Dynamic Type (`<= 21pt`), >= 44×44pt hit targets (`docs/hig-audit.md` P1-4), WCAG AA >= 4.5:1 error alerts.
// - Apple HIG › Motion & Playing Haptics: Staggered entrance reveal, spring shake + smart focus routing on error
//   (`public/js/views/auth.js:119-129`), and choreographed scale+opacity arrival into the 4-column Duo shell.

/// Authentication gate for Cuven (`Sign In`, `Create Account` w/ Segmented Invite Track, Server Config & Instant Demo).
public struct AuthRootView: View {
    private enum AuthMode: String, CaseIterable, Identifiable, Sendable {
        case signIn
        case createAccount

        var id: String { rawValue }

        var tabTitle: String {
            switch self {
            case .signIn: return "Sign In"
            case .createAccount: return "Create Account"
            }
        }

        var submitTitle: String {
            switch self {
            case .signIn: return "Sign In"
            case .createAccount: return "Create Account"
            }
        }

        var submittingTitle: String {
            switch self {
            case .signIn: return "Signing in…"
            case .createAccount: return "Creating account…"
            }
        }
    }

    private enum FocusedAuthField: Hashable, Sendable {
        case username
        case displayName
        case password
        case serverURL
    }

    private let store: AppStore

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast

    @Namespace private var modeIndicatorNamespace
    @FocusState private var focusedField: FocusedAuthField?

    @State private var mode: AuthMode = .signIn
    @State private var username: String = ""
    @State private var displayName: String = ""
    @State private var password: String = ""
    @State private var inviteCode: String = ""
    @State private var isPasswordVisible: Bool = false

    @State private var isSubmitting: Bool = false
    @State private var submitTask: Task<Void, Never>?
    @State private var localErrorMessage: String?
    @State private var invalidFieldTag: String?
    @State private var inviteValidationState: InviteCodeValidationState = .idle
    @State private var formShakeTrigger: Int = 0
    @State private var inviteShakeTrigger: Int = 0

    // Server URL disclosure state (`https://wechat.cuven.us` default)
    @State private var isServerConfigExpanded: Bool = false
    @State private var serverURLDraft: String = "https://wechat.cuven.us"
    @State private var serverConfigFeedback: String?

    // Entrance & Demo arrival choreography state
    @State private var hasAppeared: Bool = false
    @State private var isArrivingIntoDemo: Bool = false

    public init(store: AppStore) {
        self.store = store
    }

    private var activeErrorMessage: String? {
        if let localErrorMessage, !localErrorMessage.isEmpty {
            return localErrorMessage
        }
        if let storeError = store.authError, !storeError.isEmpty {
            return storeError
        }
        return nil
    }

    /// Live inline validation hint for Create Account username (`docs/ux-plan.md` #13, `src/hub.js` `/^[a-zA-Z0-9_.-]{3,24}$/`).
    private var liveUsernameValidationHint: String? {
        guard mode == .createAccount else { return nil }
        let trimmed = username.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.count < 3 {
            return "Username needs at least 3 characters."
        }
        if trimmed.count > 24 {
            return "Username must be 24 characters or fewer."
        }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_.-")
        if trimmed.unicodeScalars.contains(where: { !allowed.contains($0) }) {
            return "Use letters, numbers, dots, underscores, or hyphens."
        }
        return nil
    }

    public var body: some View {
        GeometryReader { proxy in
            let metrics = DuoLayoutMetrics.compute(
                size: proxy.size,
                safeTop: proxy.safeAreaInsets.top,
                safeBottom: proxy.safeAreaInsets.bottom,
                safeLeft: proxy.safeAreaInsets.leading,
                safeRight: proxy.safeAreaInsets.trailing,
                activePairStartsAtThread: false,
                postureOverride: store.postureOverride
            )

            ZStack {
                CuvenColors.paperBackground
                    .ignoresSafeArea()

                if metrics.posture == .duoHalfBook,
                   let hinge = metrics.hingeDivisionRect,
                   proxy.size.width >= 700 {
                    duoBookSplitAuthLayout(proxy: proxy, metrics: metrics, hinge: hinge)
                } else {
                    singleColumnAuthLayout(proxy: proxy, metrics: metrics)
                }
            }
            .scaleEffect(isArrivingIntoDemo && !reduceMotion ? 1.045 : 1.0)
            .opacity(isArrivingIntoDemo ? 0.0 : 1.0)
        }
        .cuvenCappedDynamicType()
        .onAppear {
            serverURLDraft = store.serverBaseURL.absoluteString
            if reduceMotion {
                hasAppeared = true
            } else {
                withAnimation(CuvenSprings.sheetPresent) {
                    hasAppeared = true
                }
            }
        }
        .onDisappear {
            submitTask?.cancel()
            submitTask = nil
        }
        .onChange(of: username) { _, newValue in
            if newValue.count > 24 {
                username = String(newValue.prefix(24))
            }
            clearInlineErrors()
        }
        .onChange(of: password) { _, _ in
            clearInlineErrors()
        }
        .onChange(of: displayName) { _, _ in
            clearInlineErrors()
        }
        .onChange(of: inviteCode) { _, _ in
            if inviteValidationState == .error {
                inviteValidationState = .idle
            }
            if invalidFieldTag == "invite" {
                invalidFieldTag = nil
                localErrorMessage = nil
            }
        }
    }

    // MARK: - Adaptive Posture Layouts

    private func singleColumnAuthLayout(proxy: GeometryProxy, metrics: DuoLayoutMetrics) -> some View {
        let safeTop = proxy.safeAreaInsets.top
        let safeBottom = proxy.safeAreaInsets.bottom
        let safeLeft = proxy.safeAreaInsets.leading
        let baseHorizontalMargin: CGFloat = proxy.size.width >= 700 ? 40 : 22

        // Clear iPhone Duo's asymmetric right-edge status/camera column when active on >= 460pt Duo display
        let trailingInset: CGFloat = {
            if proxy.safeAreaInsets.trailing >= 64 {
                return proxy.safeAreaInsets.trailing + 16
            }
            if metrics.hasRightSystemColumn && proxy.size.width >= 460 {
                return 84 + 14
            }
            return proxy.safeAreaInsets.trailing + baseHorizontalMargin
        }()

        return ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: proxy.size.height < 580 ? 24 : 34) {
                wordmarkHeader
                    .opacity(hasAppeared ? 1 : 0)
                    .offset(y: (hasAppeared || reduceMotion) ? 0 : 12)

                authCardSection
                    .opacity(hasAppeared ? 1 : 0)
                    .offset(y: (hasAppeared || reduceMotion) ? 0 : 18)

                instantDemoSection
                    .opacity(hasAppeared ? 1 : 0)
                    .offset(y: (hasAppeared || reduceMotion) ? 0 : 22)

                serverConfigurationSection
                    .opacity(hasAppeared ? 1 : 0)
            }
            .frame(maxWidth: 400)
            .frame(maxWidth: .infinity)
            .padding(.top, max(safeTop, 16) + (proxy.size.height < 580 ? 12 : 28))
            .padding(.bottom, max(safeBottom, 16) + 28)
            .padding(.leading, safeLeft + baseHorizontalMargin)
            .padding(.trailing, trailingInset)
            .frame(minHeight: proxy.size.height)
        }
        .scrollDismissesKeyboard(.interactively)
    }

    /// Book-fold (`duoHalfBook`) layout placing editorial branding on the left leaf and interactive form on the right leaf,
    /// ensuring no text field or button ever straddles `hingeDivisionRect`.
    private func duoBookSplitAuthLayout(
        proxy: GeometryProxy,
        metrics: DuoLayoutMetrics,
        hinge: CGRect
    ) -> some View {
        let rightTrailingClearance = max(proxy.safeAreaInsets.trailing, metrics.hasRightSystemColumn ? 84 : 24) + 16

        return HStack(spacing: 0) {
            // Left leaf: Editorial Wordmark + Demo Launch
            VStack(spacing: 28) {
                Spacer(minLength: 16)
                wordmarkHeader
                instantDemoSection
                Spacer(minLength: 16)
            }
            .padding(.leading, proxy.safeAreaInsets.leading + 28)
            .padding(.trailing, 24)
            .frame(width: max(280, hinge.minX), height: proxy.size.height)

            Spacer(minLength: 0)
                .frame(width: max(0, hinge.width))

            // Right leaf: Account Form + Server Config
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 26) {
                    authCardSection
                    serverConfigurationSection
                }
                .padding(.top, max(proxy.safeAreaInsets.top, 20) + 24)
                .padding(.bottom, max(proxy.safeAreaInsets.bottom, 20) + 24)
                .padding(.leading, 24)
                .padding(.trailing, rightTrailingClearance)
                .frame(minHeight: proxy.size.height)
            }
            .scrollDismissesKeyboard(.interactively)
            .frame(width: max(280, proxy.size.width - hinge.maxX))
        }
    }

    // MARK: - Editorial Wordmark (`auth.wordmark`)

    private var wordmarkHeader: some View {
        VStack(spacing: 10) {
            // Editorial Clarinetta display serif wordmark matching `public/css/auth.css:6` & `01-auth.png`
            // (`text-indent` optical balance achieved via symmetric leading kerning compensation)
            Text("CUVEN")
                .font(CuvenFonts.clarinettaDisplay(size: 32, weight: .bold, italic: false))
                .tracking(10.5)
                .padding(.leading, 10.5)
                .foregroundStyle(CuvenColors.ctaInk)
                .accessibilityIdentifier("auth.wordmark")
                .accessibilityLabel("Cuven")
                .accessibilityAddTraits(.isHeader)

            Text("Paper, ink, and instant presence across iPhone & iPhone Duo")
                .font(CuvenFonts.cappedCaption())
                .foregroundStyle(CuvenColors.inkSecondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Mode Switcher & Account Form Card

    private var authCardSection: some View {
        VStack(alignment: .leading, spacing: 24) {
            segmentedModeSwitcher

            VStack(alignment: .leading, spacing: 16) {
                usernameFieldWell

                if mode == .createAccount {
                    displayNameFieldWell
                        .transition(
                            reduceMotion
                                ? .opacity
                                : .opacity.combined(with: .move(edge: .top))
                        )
                }

                passwordFieldWell

                if mode == .createAccount {
                    InviteCodeTrackView(
                        code: $inviteCode,
                        cellCount: 8,
                        validationState: inviteValidationState,
                        shakeTrigger: inviteShakeTrigger,
                        isDisabled: isSubmitting,
                        onCommit: {
                            triggerSubmit()
                        }
                    )
                    .padding(.top, 2)
                    .transition(
                        reduceMotion
                            ? .opacity
                            : .opacity.combined(with: .move(edge: .top))
                    )
                }

                if let errorText = activeErrorMessage {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "exclamationmark.circle.fill")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(CuvenColors.dangerRedText)
                            .padding(.top, 2)

                        Text(errorText)
                            .font(CuvenFonts.cappedCaption(weight: .medium))
                            .foregroundStyle(CuvenColors.dangerRedText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.horizontal, 4)
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("auth.errorMessage")
                    .transition(.opacity)
                }

                submitActionButton
                    .padding(.top, 4)
            }
            .cuvenDampedShake(
                trigger: formShakeTrigger,
                amplitude: 8,
                reduceMotion: reduceMotion
            )
        }
    }

    private var segmentedModeSwitcher: some View {
        HStack(spacing: 0) {
            ForEach(AuthMode.allCases) { item in
                let isSelected = mode == item
                Button {
                    switchMode(to: item)
                } label: {
                    ZStack {
                        if isSelected {
                            RoundedRectangle(cornerRadius: 21, style: .continuous)
                                .fill(CuvenColors.cardSurface.opacity(colorScheme == .dark ? 0.55 : 0.72))
                                .cuvenLiquidGlass(
                                    mode: store.prefs.glassMode,
                                    cornerRadius: 21,
                                    interactiveBounce: false
                                )
                                .matchedGeometryEffect(
                                    id: "authModeGlidingPill",
                                    in: modeIndicatorNamespace
                                )
                        }

                        Text(item.tabTitle)
                            .font(CuvenFonts.cappedFootnote(weight: isSelected ? .semibold : .medium))
                            .tracking(0.25)
                            .foregroundStyle(
                                isSelected
                                    ? CuvenColors.inkPrimary
                                    : CuvenColors.inkSecondary
                            )
                            .frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .contentShape(Capsule(style: .continuous))
                }
                .buttonStyle(.plain)
                .disabled(isSubmitting)
                .accessibilityIdentifier(
                    item == .signIn ? "auth.mode.signIn" : "auth.mode.register"
                )
                .accessibilityLabel(item.tabTitle)
                .accessibilityAddTraits(isSelected ? [.isSelected] : [])
            }
        }
        .padding(3)
        .background(
            Capsule(style: .continuous)
                .fill(CuvenColors.fieldBackground)
                .overlay(
                    Capsule(style: .continuous)
                        .strokeBorder(hairlineBorderColor, lineWidth: 1)
                )
        )
        .accessibilityElement(children: .contain)
    }

    private var usernameFieldWell: some View {
        let isFocused = focusedField == .username
        let isInvalid = invalidFieldTag == "username"

        return VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text("USERNAME")
                    .font(CuvenFonts.cappedCaption(weight: .medium))
                    .tracking(0.9)
                    .foregroundStyle(CuvenColors.inkSecondary)

                Spacer()

                if mode == .createAccount && !username.isEmpty {
                    Text("\(username.count)/24")
                        .font(CuvenFonts.cappedCaption().monospacedDigit())
                        .foregroundStyle(CuvenColors.inkTertiary)
                }
            }
            .padding(.horizontal, 4)

            TextField("Username", text: $username)
                .focused($focusedField, equals: .username)
                .disabled(isSubmitting)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled(true)
                .textContentType(.username)
                .submitLabel(.next)
                .onSubmit {
                    focusedField = mode == .createAccount ? .displayName : .password
                }
                .font(CuvenFonts.cappedBody())
                .foregroundStyle(CuvenColors.inkPrimary)
                .padding(.horizontal, 16)
                .frame(height: 52)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(CuvenColors.paperBackground)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(
                            fieldStrokeColor(isFocused: isFocused, isInvalid: isInvalid),
                            lineWidth: (isFocused || isInvalid) ? 1.5 : 1.0
                        )
                )
                .shadow(
                    color: fieldFocusHalo(isFocused: isFocused, isInvalid: isInvalid),
                    radius: (isFocused || isInvalid) ? 5 : 0,
                    x: 0,
                    y: 0
                )
                .accessibilityIdentifier("auth.username")

            if let hint = liveUsernameValidationHint {
                Text(hint)
                    .font(CuvenFonts.cappedCaption())
                    .foregroundStyle(CuvenColors.dangerRedText)
                    .padding(.horizontal, 4)
            }
        }
    }

    private var displayNameFieldWell: some View {
        let isFocused = focusedField == .displayName

        return VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text("DISPLAY NAME")
                    .font(CuvenFonts.cappedCaption(weight: .medium))
                    .tracking(0.9)
                    .foregroundStyle(CuvenColors.inkSecondary)

                Spacer()

                Text("Optional")
                    .font(CuvenFonts.cappedCaption())
                    .foregroundStyle(CuvenColors.inkTertiary)
            }
            .padding(.horizontal, 4)

            TextField("How friends see you", text: $displayName)
                .focused($focusedField, equals: .displayName)
                .disabled(isSubmitting)
                .autocorrectionDisabled(true)
                .textContentType(.nickname)
                .submitLabel(.next)
                .onSubmit {
                    focusedField = .password
                }
                .font(CuvenFonts.cappedBody())
                .foregroundStyle(CuvenColors.inkPrimary)
                .padding(.horizontal, 16)
                .frame(height: 52)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(CuvenColors.paperBackground)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(
                            fieldStrokeColor(isFocused: isFocused, isInvalid: false),
                            lineWidth: isFocused ? 1.5 : 1.0
                        )
                )
                .shadow(
                    color: fieldFocusHalo(isFocused: isFocused, isInvalid: false),
                    radius: isFocused ? 5 : 0,
                    x: 0,
                    y: 0
                )
                .accessibilityIdentifier("auth.displayName")
        }
    }

    private var passwordFieldWell: some View {
        let isFocused = focusedField == .password
        let isInvalid = invalidFieldTag == "password"
        let placeholder = mode == .createAccount ? "At least 6 characters" : "Password"

        return VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text("PASSWORD")
                    .font(CuvenFonts.cappedCaption(weight: .medium))
                    .tracking(0.9)
                    .foregroundStyle(CuvenColors.inkSecondary)

                Spacer()

                if mode == .createAccount && !password.isEmpty && password.count < 6 {
                    Text("\(password.count)/6 min")
                        .font(CuvenFonts.cappedCaption().monospacedDigit())
                        .foregroundStyle(CuvenColors.warningAmberText)
                }
            }
            .padding(.horizontal, 4)

            HStack(spacing: 6) {
                Group {
                    if isPasswordVisible {
                        TextField(placeholder, text: $password)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled(true)
                            .textContentType(mode == .createAccount ? .newPassword : .password)
                            .accessibilityIdentifier("auth.password")
                    } else {
                        SecureField(placeholder, text: $password)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled(true)
                            .textContentType(mode == .createAccount ? .newPassword : .password)
                            .accessibilityIdentifier("auth.password")
                    }
                }
                .focused($focusedField, equals: .password)
                .disabled(isSubmitting)
                .submitLabel(mode == .signIn ? .go : .done)
                .onSubmit {
                    triggerSubmit()
                }
                .font(CuvenFonts.cappedBody())
                .foregroundStyle(CuvenColors.inkPrimary)

                Button {
                    CuvenHaptics.selectionChanged()
                    isPasswordVisible.toggle()
                } label: {
                    Text(isPasswordVisible ? "Hide" : "Show")
                        .font(CuvenFonts.cappedCaption(weight: .medium))
                        .foregroundStyle(CuvenColors.inkSecondary)
                        .padding(.horizontal, 10)
                        .frame(minWidth: 48, minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(isSubmitting)
                .accessibilityIdentifier("auth.passwordToggle")
                .accessibilityLabel(isPasswordVisible ? "Hide password" : "Show password")
            }
            .padding(.leading, 16)
            .padding(.trailing, 6)
            .frame(height: 52)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(CuvenColors.paperBackground)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(
                        fieldStrokeColor(isFocused: isFocused, isInvalid: isInvalid),
                        lineWidth: (isFocused || isInvalid) ? 1.5 : 1.0
                    )
            )
            .shadow(
                color: fieldFocusHalo(isFocused: isFocused, isInvalid: isInvalid),
                radius: (isFocused || isInvalid) ? 5 : 0,
                x: 0,
                y: 0
            )
        }
    }

    private var submitActionButton: some View {
        Button {
            triggerSubmit()
        } label: {
            HStack(spacing: 10) {
                if isSubmitting {
                    ProgressView()
                        .tint(CuvenColors.onCtaInk)
                        .controlSize(.small)
                }

                Text(isSubmitting ? mode.submittingTitle : mode.submitTitle)
                    .font(CuvenFonts.cappedBody(weight: .semibold))
                    .tracking(0.25)
            }
            .foregroundStyle(CuvenColors.onCtaInk)
            .frame(maxWidth: .infinity)
            .frame(minHeight: 52)
            .background(
                Capsule(style: .continuous)
                    .fill(CuvenColors.ctaInk)
            )
            .opacity(isSubmitting ? 0.58 : 1.0)
        }
        .buttonStyle(AuthTactileCapsuleButtonStyle(reduceMotion: reduceMotion))
        .disabled(isSubmitting)
        .accessibilityIdentifier("auth.submit")
    }

    // MARK: - Prominent Liquid Glass Demo Entry (`auth.demoButton`)

    private var instantDemoSection: some View {
        VStack(spacing: 16) {
            HStack(spacing: 12) {
                Rectangle()
                    .fill(hairlineBorderColor)
                    .frame(height: 1)

                Text("OR")
                    .font(CuvenFonts.cappedCaption(weight: .medium))
                    .tracking(1.1)
                    .foregroundStyle(CuvenColors.inkTertiary)

                Rectangle()
                    .fill(hairlineBorderColor)
                    .frame(height: 1)
            }

            // Never disable `auth.demoButton` while a slow/unreachable server request is pending:
            // tapping Demo cancels any in-flight `submitTask` and immediately enters Demo Mode.
            Button {
                triggerInstantDemoArrival()
            } label: {
                HStack(spacing: 12) {
                    ZStack {
                        Circle()
                            .fill(CuvenColors.sidebarBlue.opacity(colorScheme == .dark ? 0.22 : 0.12))
                            .frame(width: 36, height: 36)

                        Image(systemName: "rectangle.split.2x1.fill")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(CuvenColors.sidebarBlue)
                    }

                    VStack(alignment: .leading, spacing: 2) {
                        Text("Explore Instant Demo (iPhone & Duo)")
                            .font(CuvenFonts.cappedBody(weight: .semibold))
                            .foregroundStyle(CuvenColors.inkPrimary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.85)

                        Text("Rich chats, Moments, Notes, AI & Duo postures")
                            .font(CuvenFonts.cappedCaption())
                            .foregroundStyle(CuvenColors.inkSecondary)
                            .lineLimit(1)
                    }

                    Spacer(minLength: 4)

                    Image(systemName: "arrow.up.right")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(CuvenColors.sidebarBlue)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity, minHeight: 58)
                .cuvenLiquidGlass(
                    mode: store.prefs.glassMode,
                    cornerRadius: 29,
                    interactiveBounce: true
                )
            }
            .buttonStyle(AuthTactileCapsuleButtonStyle(reduceMotion: reduceMotion))
            .disabled(isArrivingIntoDemo)
            .accessibilityIdentifier("auth.demoButton")
            .accessibilityLabel("Explore Instant Demo (iPhone & Duo)")
            .accessibilityHint("Enters interactive demo mode with sample contacts, conversations, Moments, and iPhone Duo postures")
        }
    }

    // MARK: - Server URL Configuration Disclosure (`https://wechat.cuven.us` default)

    private var serverConfigurationSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button {
                CuvenHaptics.selectionChanged()
                withAnimation(CuvenSprings.adaptive(CuvenSprings.pressBounce, reduceMotion: reduceMotion)) {
                    isServerConfigExpanded.toggle()
                    serverConfigFeedback = nil
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "globe")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(CuvenColors.sidebarBlue)

                    Text("Server")
                        .font(CuvenFonts.cappedCaption(weight: .medium))
                        .foregroundStyle(CuvenColors.inkSecondary)

                    Text(store.serverBaseURL.host() ?? store.serverBaseURL.absoluteString)
                        .font(.system(.caption, design: .monospaced).weight(.medium))
                        .foregroundStyle(CuvenColors.inkPrimary)
                        .lineLimit(1)

                    Spacer(minLength: 4)

                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(CuvenColors.inkSecondary)
                        .rotationEffect(.degrees(isServerConfigExpanded ? 90 : 0))
                }
                .padding(.horizontal, 14)
                .frame(minHeight: 44)
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(CuvenColors.fieldBackground.opacity(0.65))
                        .overlay(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .strokeBorder(hairlineBorderColor, lineWidth: 1)
                        )
                )
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("auth.serverDisclosure")
            .accessibilityLabel("Server configuration, \(store.serverBaseURL.absoluteString)")

            if isServerConfigExpanded {
                VStack(alignment: .leading, spacing: 10) {
                    TextField("https://wechat.cuven.us", text: $serverURLDraft)
                        .focused($focusedField, equals: .serverURL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled(true)
                        .keyboardType(.URL)
                        .submitLabel(.done)
                        .onSubmit {
                            applyServerBaseURL()
                        }
                        .font(.system(.footnote, design: .monospaced))
                        .foregroundStyle(CuvenColors.inkPrimary)
                        .padding(.horizontal, 12)
                        .frame(height: 44)
                        .background(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(CuvenColors.paperBackground)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                                        .strokeBorder(hairlineBorderColor, lineWidth: 1)
                                )
                        )
                        .accessibilityIdentifier("auth.serverURLField")

                    HStack(spacing: 8) {
                        serverPresetChip(title: "wechat.cuven.us", urlString: "https://wechat.cuven.us")
                        serverPresetChip(title: "Local :8787", urlString: "http://127.0.0.1:8787")

                        Spacer(minLength: 4)

                        Button {
                            applyServerBaseURL()
                        } label: {
                            Text("Save")
                                .font(CuvenFonts.cappedCaption(weight: .semibold))
                                .foregroundStyle(CuvenColors.onCtaInk)
                                .padding(.horizontal, 14)
                                .frame(minHeight: 36)
                                .background(
                                    Capsule(style: .continuous)
                                        .fill(CuvenColors.ctaInk)
                                )
                        }
                        .buttonStyle(.plain)
                        .frame(minWidth: 44, minHeight: 44)
                        .contentShape(Rectangle())
                        .accessibilityIdentifier("auth.serverSaveButton")
                    }

                    if let feedback = serverConfigFeedback {
                        Text(feedback)
                            .font(CuvenFonts.cappedCaption())
                            .foregroundStyle(CuvenColors.inkSecondary)
                    }
                }
                .padding(12)
                .background(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(CuvenColors.elevatedSurface)
                        .overlay(
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .strokeBorder(hairlineBorderColor, lineWidth: 1)
                        )
                )
                .transition(
                    reduceMotion
                        ? .opacity
                        : .opacity.combined(with: .scale(scale: 0.98, anchor: .top))
                )
            }
        }
    }

    private func serverPresetChip(title: String, urlString: String) -> some View {
        let isActive = store.serverBaseURL.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/")) == urlString
        return Button {
            serverURLDraft = urlString
            applyServerBaseURL()
        } label: {
            Text(title)
                .font(CuvenFonts.cappedCaption(weight: .medium))
                .foregroundStyle(isActive ? CuvenColors.sidebarBlue : CuvenColors.inkSecondary)
                .padding(.horizontal, 10)
                .frame(minHeight: 34)
                .background(
                    Capsule(style: .continuous)
                        .fill(
                            isActive
                                ? CuvenColors.sidebarBlue.opacity(colorScheme == .dark ? 0.20 : 0.10)
                                : CuvenColors.fieldBackground
                        )
                )
        }
        .buttonStyle(.plain)
        .frame(minWidth: 44, minHeight: 44)
        .contentShape(Rectangle())
    }

    // MARK: - Actions & Validation Logic

    private func switchMode(to nextMode: AuthMode) {
        guard !isSubmitting, nextMode != mode else { return }
        CuvenHaptics.selectionChanged()
        clearInlineErrors()
        store.authError = nil
        inviteValidationState = .idle

        if reduceMotion {
            mode = nextMode
        } else {
            withAnimation(CuvenSprings.pressBounce) {
                mode = nextMode
            }
        }
    }

    private func clearInlineErrors() {
        localErrorMessage = nil
        invalidFieldTag = nil
        if store.authError != nil {
            store.authError = nil
        }
    }

    private func applyServerBaseURL() {
        let trimmed = serverURLDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard
            let candidate = URL(string: trimmed),
            let scheme = candidate.scheme?.lowercased(),
            (scheme == "https" || scheme == "http"),
            let host = candidate.host(),
            !host.isEmpty
        else {
            CuvenHaptics.rigidImpact()
            serverConfigFeedback = "Enter a valid http:// or https:// server URL."
            return
        }

        store.serverBaseURL = candidate
        serverURLDraft = candidate.absoluteString
        CuvenHaptics.lightTap()
        serverConfigFeedback = "Connected endpoint set to \(candidate.absoluteString)"
    }

    private func triggerSubmit() {
        guard !isSubmitting else { return }

        let trimmedUser = username.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedDisplay = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedInvite = inviteCode.trimmingCharacters(in: .whitespacesAndNewlines)
        let activeMode = mode
        let passwordSnapshot = password

        // Client-side validation matching `public/js/views/auth.js` & `src/hub.js`
        if trimmedUser.isEmpty {
            presentValidationFailure(
                message: "Enter your username to continue.",
                fieldTag: "username",
                focusTarget: .username
            )
            return
        }

        if activeMode == .createAccount, let usernameProblem = liveUsernameValidationHint {
            presentValidationFailure(
                message: usernameProblem,
                fieldTag: "username",
                focusTarget: .username
            )
            return
        }

        if passwordSnapshot.isEmpty {
            presentValidationFailure(
                message: "Enter your password to continue.",
                fieldTag: "password",
                focusTarget: .password
            )
            return
        }

        if activeMode == .createAccount && passwordSnapshot.count < 6 {
            presentValidationFailure(
                message: "Password must be at least 6 characters.",
                fieldTag: "password",
                focusTarget: .password
            )
            return
        }

        isSubmitting = true
        clearInlineErrors()
        if activeMode == .createAccount && !trimmedInvite.isEmpty {
            inviteValidationState = .pending
        }

        submitTask?.cancel()
        submitTask = Task { @MainActor in
            do {
                if activeMode == .signIn {
                    try await store.signIn(username: trimmedUser, password: passwordSnapshot)
                } else {
                    try await store.register(
                        username: trimmedUser,
                        password: passwordSnapshot,
                        display: trimmedDisplay.isEmpty ? trimmedUser : trimmedDisplay,
                        inviteCode: trimmedInvite.isEmpty ? nil : trimmedInvite
                    )
                }

                guard !Task.isCancelled else { return }
                isSubmitting = false
                submitTask = nil

                if store.isAuthenticated {
                    inviteValidationState = .valid
                    CuvenHaptics.success()
                } else if let err = store.authError, !err.isEmpty {
                    handleServerAuthFailure(err)
                }
            } catch {
                guard !Task.isCancelled else { return }
                isSubmitting = false
                submitTask = nil
                let message = (store.authError?.isEmpty == false ? store.authError! : error.localizedDescription)
                handleServerAuthFailure(message)
            }
        }
    }

    private func presentValidationFailure(
        message: String,
        fieldTag: String,
        focusTarget: FocusedAuthField?
    ) {
        localErrorMessage = message
        invalidFieldTag = fieldTag
        focusedField = focusTarget
        CuvenHaptics.rigidImpact()
        formShakeTrigger += 1
    }

    private func handleServerAuthFailure(_ message: String) {
        localErrorMessage = message
        let lowered = message.lowercased()

        // Route focus to the field where the fix belongs (`public/js/views/auth.js:119-129`)
        if lowered.contains("invite") || lowered.contains("code") {
            invalidFieldTag = "invite"
            inviteValidationState = .error
            inviteShakeTrigger += 1
            focusedField = nil
        } else if lowered.contains("username") && !lowered.contains("or password") {
            invalidFieldTag = "username"
            inviteValidationState = .idle
            focusedField = .username
            CuvenHaptics.rigidImpact()
        } else {
            invalidFieldTag = "password"
            inviteValidationState = .idle
            focusedField = .password
            CuvenHaptics.rigidImpact()
        }

        formShakeTrigger += 1
    }

    private func triggerInstantDemoArrival() {
        guard !isArrivingIntoDemo else { return }
        submitTask?.cancel()
        submitTask = nil
        isSubmitting = false
        focusedField = nil
        CuvenHaptics.success()

        if reduceMotion {
            store.enterDemoMode()
            return
        }

        withAnimation(.spring(response: 0.22, dampingFraction: 0.88)) {
            isArrivingIntoDemo = true
        }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(120))
            withAnimation(CuvenSprings.sheetPresent) {
                store.enterDemoMode()
            }
            isArrivingIntoDemo = false
        }
    }

    // MARK: - Token Helpers

    private var hairlineBorderColor: Color {
        if colorSchemeContrast == .increased {
            return CuvenColors.inkTertiary
        }
        return CuvenColors.cardLine
    }

    private func fieldStrokeColor(isFocused: Bool, isInvalid: Bool) -> Color {
        if isInvalid {
            return CuvenColors.dangerRed
        }
        if isFocused {
            return CuvenColors.inkPrimary
        }
        return hairlineBorderColor
    }

    private func fieldFocusHalo(isFocused: Bool, isInvalid: Bool) -> Color {
        if isInvalid {
            return CuvenColors.dangerRed.opacity(0.18)
        }
        if isFocused {
            return CuvenColors.inkPrimary.opacity(colorScheme == .dark ? 0.14 : 0.08)
        }
        return .clear
    }
}

/// Tactile capsule press button style matching `auth.css:28-29` (`scale(0.97)` on press, spring release).
private struct AuthTactileCapsuleButtonStyle: ButtonStyle {
    let reduceMotion: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.972 : 1.0)
            .animation(
                reduceMotion ? CuvenSprings.reducedMotionFade : CuvenSprings.pressBounce,
                value: configuration.isPressed
            )
    }
}
