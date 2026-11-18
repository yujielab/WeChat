import SwiftUI
import CuvenCore
#if canImport(UIKit)
import UIKit
#endif

// MARK: - Apple HIG & Cuven Web Traceability
// - Apple HIG › Text Fields & Accessibility: >= 44×44pt hit targets, native TextField responder & VoiceOver semantics,
//   Increase Contrast (`colorSchemeContrast == .increased`) firmer cell borders, WCAG AA >= 4.5:1 error state.
// - Apple HIG › Motion & Playing Haptics: 120Hz spring active-cell lift, 3D ink-rail flip (`rotateX`),
//   damped phase-animated shake on error (`phaseAnimator`), selection/impact haptics, and Reduce Motion instant fallback.
// - Cuven Web Reference: `public/js/ui/invite-code.js` & `public/css/invite-code.css` (8-segment rail + unrestricted code support).

/// Visual and semantic validation states for `InviteCodeTrackView`.
public enum InviteCodeValidationState: String, Equatable, Sendable {
    case idle
    case pending
    case valid
    case error
}

extension View {
    /// Applies a damped horizontal spring-shake sequence via SwiftUI `phaseAnimator` (`iOS 17+` / `iOS 27.1 SDK`),
    /// completely free of Swift 6 `@MainActor` vs `nonisolated Animatable` concurrency conflicts.
    func cuvenDampedShake(
        trigger: Int,
        amplitude: CGFloat = 9,
        reduceMotion: Bool
    ) -> some View {
        self.phaseAnimator([0, 1, 2, 3, 4], trigger: trigger) { content, phase in
            let offset: CGFloat = {
                guard !reduceMotion else { return 0 }
                switch phase {
                case 1: return -amplitude
                case 2: return amplitude * 0.76
                case 3: return -amplitude * 0.46
                case 4: return amplitude * 0.22
                default: return 0
                }
            }()
            content.offset(x: offset)
        } animation: { phase in
            if reduceMotion {
                return .linear(duration: 0.01)
            }
            return phase == 0
                ? CuvenSprings.pressBounce
                : .spring(response: 0.085, dampingFraction: 0.68, blendDuration: 0)
        }
    }
}

/// Tactile segmented invite-code cell track (`auth.inviteCodeTrack`).
///
/// Renders 8 individual rounded cells with focus glow, staggered clipboard paste distribution,
/// backspace auto-retreat, bottom segmented ink rail (`invite-code.css`), and spring
/// shake + haptic feedback on validation error, while preserving full native `TextField`
/// responder activation, autofill, and arbitrary-length invite phrase compatibility.
public struct InviteCodeTrackView: View {
    @Binding private var code: String
    private let cellCount: Int
    private let validationState: InviteCodeValidationState
    private let shakeTrigger: Int
    private let isDisabled: Bool
    private let onCommit: (() -> Void)?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast

    @FocusState private var isFieldFocused: Bool
    @State private var localShakeCount: Int = 0
    @State private var railFlipTilt: Double = 0
    @State private var pastedRippleActive: Bool = false

    public init(
        code: Binding<String>,
        cellCount: Int = 8,
        validationState: InviteCodeValidationState = .idle,
        shakeTrigger: Int = 0,
        isDisabled: Bool = false,
        onCommit: (() -> Void)? = nil
    ) {
        self._code = code
        self.cellCount = max(4, cellCount)
        self.validationState = validationState
        self.shakeTrigger = shakeTrigger
        self.isDisabled = isDisabled
        self.onCommit = onCommit
    }

    private var characters: [Character] {
        Array(code)
    }

    /// Active cell index that advances as characters are typed and auto-retreats on backspace.
    private var activeCellIndex: Int {
        guard !characters.isEmpty else { return 0 }
        if characters.count < cellCount {
            return characters.count
        }
        return cellCount - 1
    }

    private var isOverflowPhrase: Bool {
        characters.count > cellCount
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            headerRow

            ZStack {
                visualTrackSurface
                    .accessibilityHidden(true)
                    .allowsHitTesting(false)

                // Underlying native TextField spanning full track bounds so hardware/software keyboards,
                // VoiceOver, paste Menu, and XCUITest (`auth.inviteCodeTrack`) operate directly on a real UITextField.
                TextField("", text: $code)
                    .focused($isFieldFocused)
                    .disabled(isDisabled)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled(true)
                    .keyboardType(.asciiCapable)
                    .submitLabel(.go)
                    .onSubmit {
                        onCommit?()
                    }
                    .foregroundStyle(.clear)
                    .tint(.clear)
                    .frame(maxWidth: .infinity, minHeight: isOverflowPhrase ? 82 : 58)
                    .contentShape(Rectangle())
                    .accessibilityIdentifier("auth.inviteCodeTrack")
                    .accessibilityLabel("Invite code")
                    .accessibilityHint("Enter or paste your invite code across the segmented track")
            }
            .clipped()
            .cuvenDampedShake(
                trigger: localShakeCount,
                amplitude: 9,
                reduceMotion: reduceMotion
            )
        }
        .onChange(of: isFieldFocused) { _, focused in
            if focused && !isDisabled {
                CuvenHaptics.lightTap()
            }
        }
        .onChange(of: code) { oldValue, newValue in
            handleCodeMutation(from: oldValue, to: newValue)
        }
        .onChange(of: shakeTrigger) { _, _ in
            triggerErrorShake()
        }
        .onChange(of: validationState) { oldState, newState in
            if newState == .error && oldState != .error {
                triggerErrorShake()
            }
        }
    }

    // MARK: - Subviews

    private var headerRow: some View {
        HStack(spacing: 8) {
            HStack(spacing: 6) {
                Text("INVITE CODE")
                    .font(CuvenFonts.cappedCaption(weight: .medium))
                    .tracking(0.9)
                    .foregroundStyle(CuvenColors.inkSecondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)

                Text("Optional")
                    .font(CuvenFonts.cappedCaption())
                    .foregroundStyle(CuvenColors.inkTertiary)
                    .lineLimit(1)
            }

            Spacer(minLength: 4)

            HStack(spacing: 6) {
                if !code.isEmpty && !isDisabled {
                    Button {
                        CuvenHaptics.selectionChanged()
                        withAnimation(CuvenSprings.adaptive(CuvenSprings.pressBounce, reduceMotion: reduceMotion)) {
                            code = ""
                        }
                        isFieldFocused = true
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "delete.backward.fill")
                                .font(.system(size: 11, weight: .semibold))
                            Text("Clear")
                                .font(CuvenFonts.cappedCaption(weight: .medium))
                        }
                        .foregroundStyle(CuvenColors.inkSecondary)
                        .padding(.horizontal, 10)
                        .frame(minHeight: 30)
                        .background(
                            Capsule(style: .continuous)
                                .fill(CuvenColors.elevatedSurface)
                                .overlay(
                                    Capsule(style: .continuous)
                                        .strokeBorder(borderBaseColor, lineWidth: 1)
                                )
                        )
                    }
                    .buttonStyle(.plain)
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(Rectangle())
                    .accessibilityIdentifier("auth.inviteCodeClearButton")
                    .accessibilityLabel("Clear invite code")
                }

                Button {
                    pasteFromClipboard()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "doc.on.clipboard")
                            .font(.system(size: 11, weight: .semibold))
                        Text("Paste")
                            .font(CuvenFonts.cappedCaption(weight: .semibold))
                    }
                    .foregroundStyle(CuvenColors.sidebarBlue)
                    .padding(.horizontal, 11)
                    .frame(minHeight: 30)
                    .background(
                        Capsule(style: .continuous)
                            .fill(CuvenColors.sidebarBlue.opacity(colorScheme == .dark ? 0.18 : 0.10))
                    )
                }
                .buttonStyle(.plain)
                .disabled(isDisabled)
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(Rectangle())
                .accessibilityIdentifier("auth.inviteCodePasteButton")
                .accessibilityLabel("Paste invite code from clipboard")
            }
        }
        .padding(.horizontal, 2)
    }

    private var visualTrackSurface: some View {
        VStack(spacing: 8) {
            if isOverflowPhrase {
                // Unrestricted long phrase badge (e.g. `Duo-心意-ABCD-1234567890` in `14-invite-code.png`)
                HStack(spacing: 8) {
                    Text(code)
                        .font(.system(.callout, design: .monospaced).weight(.medium))
                        .foregroundStyle(CuvenColors.inkPrimary)
                        .lineLimit(1)
                        .truncationMode(.head)

                    if isFieldFocused {
                        pulsingCaretView
                    }

                    Spacer(minLength: 0)

                    Text("\(characters.count) chars")
                        .font(CuvenFonts.cappedCaption().monospacedDigit())
                        .foregroundStyle(CuvenColors.inkSecondary)
                }
                .padding(.horizontal, 14)
                .frame(height: 48)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(CuvenColors.paperBackground)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(activeStrokeColor(isCurrent: isFieldFocused), lineWidth: isFieldFocused ? 1.5 : 1)
                )
                .shadow(
                    color: focusGlowColor(isCurrent: isFieldFocused),
                    radius: isFieldFocused ? 6 : 0,
                    x: 0,
                    y: 0
                )
            } else {
                // 8 individual tactile rounded cells
                HStack(spacing: 6) {
                    ForEach(0..<cellCount, id: \.self) { index in
                        cellView(at: index)
                    }
                }
            }

            // Segmented bottom ink rail (`invite-code.css` `.invite-code-rail`)
            HStack(spacing: 5) {
                ForEach(0..<cellCount, id: \.self) { index in
                    let isFilled = index < characters.count || isOverflowPhrase
                    let isCurrent = isFieldFocused && (isOverflowPhrase ? index == cellCount - 1 : index == activeCellIndex)
                    Capsule(style: .continuous)
                        .fill(railSegmentColor(isFilled: isFilled, isCurrent: isCurrent))
                        .frame(height: isCurrent ? 3.5 : 2.0)
                        .animation(
                            reduceMotion ? nil : CuvenSprings.pressBounce,
                            value: isCurrent
                        )
                }
            }
            .padding(.horizontal, 8)
            .rotation3DEffect(
                .degrees(reduceMotion ? 0 : railFlipTilt),
                axis: (x: 1, y: 0, z: 0),
                perspective: 0.45
            )
        }
    }

    /// Blinking insertion bar driven by `TimelineView` (pauses automatically when unfocused or under Reduce Motion).
    private var pulsingCaretView: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 24.0, paused: reduceMotion || !isFieldFocused)) { context in
            let wave = reduceMotion
                ? 1.0
                : 0.24 + 0.76 * (0.5 + 0.5 * cos(context.date.timeIntervalSinceReferenceDate * .pi * 2.2))
            RoundedRectangle(cornerRadius: 1, style: .continuous)
                .fill(CuvenColors.sidebarBlue)
                .frame(width: 2, height: 18)
                .opacity(wave)
        }
        .frame(width: 2, height: 18)
    }

    private func cellView(at index: Int) -> some View {
        let character: Character? = index < characters.count ? characters[index] : nil
        let isCurrent = isFieldFocused && index == activeCellIndex
        let isFilled = character != nil

        return ZStack {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(cellBackgroundColor(isFilled: isFilled, isCurrent: isCurrent))

            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(
                    activeStrokeColor(isCurrent: isCurrent, isFilled: isFilled),
                    lineWidth: isCurrent || validationState == .error ? 1.5 : 1.0
                )

            if let character {
                Text(String(character))
                    .font(.system(size: 17, weight: .semibold, design: .monospaced))
                    .foregroundStyle(
                        validationState == .error
                            ? CuvenColors.dangerRedText
                            : CuvenColors.inkPrimary
                    )
                    .transition(
                        reduceMotion
                            ? .opacity
                            : .scale(scale: 0.72).combined(with: .opacity)
                    )
            } else if isCurrent {
                pulsingCaretView
            } else {
                Circle()
                    .fill(CuvenColors.inkSecondary.opacity(0.22))
                    .frame(width: 4, height: 4)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 50)
        .shadow(
            color: focusGlowColor(isCurrent: isCurrent),
            radius: isCurrent ? 7 : 0,
            x: 0,
            y: 0
        )
        .scaleEffect(
            reduceMotion
                ? 1.0
                : (pastedRippleActive && isFilled ? 1.045 : (isCurrent ? 1.025 : 1.0))
        )
        .animation(
            reduceMotion ? CuvenSprings.reducedMotionFade : CuvenSprings.pressBounce,
            value: isCurrent
        )
        .animation(
            reduceMotion
                ? CuvenSprings.reducedMotionFade
                : CuvenSprings.bubblePop.delay(pastedRippleActive ? Double(index) * 0.018 : 0),
            value: isFilled
        )
    }

    // MARK: - Colors & State Styling

    private var borderBaseColor: Color {
        if colorSchemeContrast == .increased {
            return CuvenColors.inkTertiary
        }
        return CuvenColors.cardLine
    }

    private func cellBackgroundColor(isFilled: Bool, isCurrent: Bool) -> Color {
        if validationState == .error {
            return CuvenColors.dangerRed.opacity(colorScheme == .dark ? 0.14 : 0.06)
        }
        if isCurrent {
            return CuvenColors.paperBackground
        }
        if isFilled {
            return CuvenColors.elevatedSurface.opacity(colorScheme == .dark ? 0.92 : 0.76)
        }
        return CuvenColors.paperBackground
    }

    private func activeStrokeColor(isCurrent: Bool, isFilled: Bool = false) -> Color {
        switch validationState {
        case .error:
            return CuvenColors.dangerRed
        case .valid:
            return CuvenColors.onlineGreen
        case .pending:
            return CuvenColors.inkSecondary.opacity(0.6)
        case .idle:
            if isCurrent {
                return CuvenColors.sidebarBlue
            }
            if isFilled {
                return CuvenColors.inkPrimary.opacity(colorScheme == .dark ? 0.42 : 0.28)
            }
            return borderBaseColor
        }
    }

    private func focusGlowColor(isCurrent: Bool) -> Color {
        if validationState == .error {
            return CuvenColors.dangerRed.opacity(0.22)
        }
        guard isCurrent else { return .clear }
        return CuvenColors.sidebarBlue.opacity(colorScheme == .dark ? 0.32 : 0.18)
    }

    private func railSegmentColor(isFilled: Bool, isCurrent: Bool) -> Color {
        switch validationState {
        case .error:
            return CuvenColors.dangerRed.opacity(0.85)
        case .pending:
            return CuvenColors.inkSecondary.opacity(0.55)
        case .valid:
            return CuvenColors.onlineGreen
        case .idle:
            if isCurrent {
                return CuvenColors.ctaInk
            }
            if isFilled {
                return CuvenColors.inkSecondary.opacity(0.58)
            }
            return borderBaseColor
        }
    }

    // MARK: - Interaction Handlers

    private func handleCodeMutation(from oldValue: String, to newValue: String) {
        // Strip accidental newlines/tabs from pasted strings while keeping valid symbols/hyphens
        let sanitized = newValue.replacingOccurrences(of: "\n", with: "")
            .replacingOccurrences(of: "\r", with: "")
            .replacingOccurrences(of: "\t", with: "")
        if sanitized != newValue {
            code = sanitized
            return
        }

        let delta = sanitized.count - oldValue.count
        if delta > 1 {
            // Multi-character paste distribution across cells
            CuvenHaptics.lightTap()
            animatePasteRipple()
        } else if delta < 0 {
            // Backspace auto-retreat haptic confirmation
            CuvenHaptics.selectionChanged()
        } else if delta == 1 {
            CuvenHaptics.selectionChanged()
        }

        animateRailFlip()
    }

    private func pasteFromClipboard() {
        guard !isDisabled else { return }
        #if canImport(UIKit)
        if let raw = UIPasteboard.general.string {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                CuvenHaptics.rigidImpact()
                return
            }
            isFieldFocused = true
            code = trimmed
            CuvenHaptics.success()
            animatePasteRipple()
        } else {
            CuvenHaptics.rigidImpact()
        }
        #endif
    }

    private func animatePasteRipple() {
        guard !reduceMotion else { return }
        withAnimation(CuvenSprings.pressBounce) {
            pastedRippleActive = true
        }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(220))
            withAnimation(CuvenSprings.pressBounce) {
                pastedRippleActive = false
            }
        }
    }

    private func animateRailFlip() {
        guard !reduceMotion else { return }
        railFlipTilt = -24
        withAnimation(.spring(response: 0.28, dampingFraction: 0.82)) {
            railFlipTilt = 0
        }
    }

    private func triggerErrorShake() {
        CuvenHaptics.rigidImpact()
        localShakeCount += 1
    }
}
