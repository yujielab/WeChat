import CuvenCore
import SwiftUI

/// Organized Cuven Settings Center supporting Profile editing, Appearance & Liquid Glass materials,
/// 8 Chat & Call Backdrop swatches, Smart & Workers AI (`AIMemoryAndRoutineSheet`), iPhone & iPhone Duo
/// Posture Lab (`store.postureOverride`), Local Notifications/Badges, Privacy, Password change, and Sign Out.
///
/// Grounded in:
/// - Canonical Contract: `PROJECT.md § 5.4` (`public struct SettingsRootSheet: View { public init(store: AppStore, initialTab: String? = nil) }`)
/// - Canonical Accessibility IDs: `PROJECT.md § 5.5` (`settings.root`, `settings.avatarEditorButton`, `settings.aiMemoryButton`)
/// - Apple HIG: *Settings*, *Materials / Liquid Glass*, *Designing for iPhone Duo*, *Privacy*
/// - Cuven Web Reference: `public/js/views/sheets.js`, `public/js/ui/appearance.js`, `public/js/views/backdrops.js`, `public/css/backdrops.css`
public struct SettingsRootSheet: View {
    private let store: AppStore
    private let initialTab: String?

    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var displayNameDraft: String = ""
    @State private var bioDraft: String = ""
    @State private var isSavingProfile: Bool = false
    @State private var profileSaveFeedback: String?

    @State private var showAvatarCoverEditor: Bool = false
    @State private var avatarEditorInitialTab: ProfileEditorTab = .avatar
    @State private var showAIMemorySheet: Bool = false
    @State private var didHandleInitialTab: Bool = false

    // Password change state
    @State private var isPasswordFormExpanded: Bool = false
    @State private var currentPasswordInput: String = ""
    @State private var newPasswordInput: String = ""
    @State private var isUpdatingPassword: Bool = false
    @State private var passwordFeedbackMessage: String?
    @State private var passwordFeedbackIsError: Bool = false

    // Haptics local toggle state mirrored from CuvenHaptics
    @State private var hapticsEnabled: Bool = CuvenHaptics.isEnabled

    // Sign out confirmation
    @State private var showSignOutConfirmation: Bool = false

    private let notificationManager = LocalNotificationBadgeManager.shared

    public init(store: AppStore, initialTab: String? = nil) {
        self.store = store
        self.initialTab = initialTab
        self._displayNameDraft = State(initialValue: store.currentUser?.display ?? "")
        self._bioDraft = State(initialValue: store.currentUser?.bio ?? "")
    }

    private var activeTintColor: Color {
        if let hex = store.currentUser?.dominantTintHex,
           let parsed = DominantColorExtractor.color(fromHex: hex) {
            return parsed
        }
        return CuvenColors.sidebarBlue
    }

    private var hasUnsavedProfileEdits: Bool {
        let currentDisplay = store.currentUser?.display ?? ""
        let currentBio = store.currentUser?.bio ?? ""
        return displayNameDraft.trimmingCharacters(in: .whitespacesAndNewlines) != currentDisplay
            || bioDraft.trimmingCharacters(in: .whitespacesAndNewlines) != currentBio
    }

    public var body: some View {
        NavigationStack {
            ScrollViewReader { scrollProxy in
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 18) {
                        profileSummarySection
                            .id("profile")

                        appearanceAndMaterialsSection
                            .id("appearance")

                        smartAndWorkersAISection
                            .id("ai")

                        duoPostureLabSection
                            .id("posture")

                        notificationsAndBadgeSection
                            .id("notifications")

                        privacyAndSecuritySection
                            .id("privacy")

                        signOutDangerSection
                    }
                    .padding(.horizontal, 18)
                    .padding(.top, 8)
                    .padding(.bottom, 36)
                }
                .background(CuvenColors.paperBackground.ignoresSafeArea())
                .navigationTitle("Settings")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Done") {
                            CuvenHaptics.lightTap()
                            dismiss()
                        }
                        .font(CuvenFonts.cappedSubheadline(weight: .semibold))
                        .foregroundStyle(CuvenColors.sidebarBlue)
                        .accessibilityIdentifier("settings.close")
                    }
                }
                .onAppear {
                    syncProfileDraftsFromStore()
                    Task {
                        await notificationManager.refreshAuthorizationStatus()
                        await notificationManager.syncBadgeCount(for: store.rooms)
                    }
                    guard !didHandleInitialTab else { return }
                    didHandleInitialTab = true
                    routeInitialTabIfNeeded(using: scrollProxy)
                }
                .onChange(of: store.currentUser) { _, _ in
                    if !hasUnsavedProfileEdits {
                        syncProfileDraftsFromStore()
                    }
                }
            }
        }
        .accessibilityIdentifier("settings.root")
        .sheet(isPresented: $showAvatarCoverEditor) {
            ProfileAvatarCoverEditorSheet(store: store, initialTab: avatarEditorInitialTab)
        }
        .sheet(isPresented: $showAIMemorySheet) {
            AIMemoryAndRoutineSheet(store: store)
        }
        .alert("Sign out of Cuven?", isPresented: $showSignOutConfirmation) {
            Button("Sign Out", role: .destructive) {
                Task {
                    CuvenHaptics.rigidImpact()
                    await store.signOut()
                    dismiss()
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Cached session credentials on this device will be cleared.")
        }
    }

    // MARK: - 1. Profile Summary Card + Inline Display Name & Bio Save

    private var profileSummarySection: some View {
        let user = store.currentUser
        let display = (user?.display.isEmpty == false ? user?.display : user?.username) ?? "Me"
        let username = user?.username ?? "cuven"

        return VStack(alignment: .leading, spacing: 0) {
            // Top Cover Banner + Avatar Editor Trigger (`settings.avatarEditorButton`)
            Button {
                CuvenHaptics.lightTap()
                avatarEditorInitialTab = .avatar
                showAvatarCoverEditor = true
            } label: {
                VStack(alignment: .leading, spacing: 0) {
                    ZStack(alignment: .topTrailing) {
                        profileCoverBanner(for: user)
                            .frame(height: 58)
                            .clipped()

                        HStack(spacing: 5) {
                            Image(systemName: "camera.aperture")
                                .font(.system(size: 11, weight: .semibold))
                            Text("Avatar & Cover")
                                .font(CuvenFonts.cappedCaption2(weight: .semibold))
                        }
                        .foregroundStyle(CuvenColors.inkPrimary)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 5)
                        .background(.ultraThinMaterial, in: Capsule())
                        .padding(8)
                    }

                    HStack(alignment: .bottom, spacing: 12) {
                        ZStack(alignment: .bottomTrailing) {
                            CuvenAvatarView(
                                name: display,
                                urlString: user?.avatarURL,
                                size: 60,
                                isOnline: user?.isOnline ?? true
                            )
                            .overlay {
                                Circle()
                                    .strokeBorder(CuvenColors.elevatedSurface, lineWidth: 3.0)
                            }

                            Image(systemName: "camera.fill")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(CuvenColors.onCtaInk)
                                .frame(width: 22, height: 22)
                                .background(CuvenColors.ctaInk, in: Circle())
                                .overlay {
                                    Circle().strokeBorder(CuvenColors.elevatedSurface, lineWidth: 1.5)
                                }
                        }
                        .offset(y: -20)
                        .padding(.bottom, -20)

                        VStack(alignment: .leading, spacing: 2) {
                            Text(display)
                                .font(CuvenFonts.cappedHeadline(weight: .bold))
                                .foregroundStyle(CuvenColors.inkPrimary)
                                .lineLimit(1)

                            HStack(spacing: 8) {
                                Text("@\(username)")
                                    .font(CuvenFonts.cappedCaption())
                                    .foregroundStyle(CuvenColors.inkSecondary)
                                    .lineLimit(1)

                                if let hex = user?.dominantTintHex, !hex.isEmpty {
                                    HStack(spacing: 4) {
                                        Circle()
                                            .fill(activeTintColor)
                                            .frame(width: 7, height: 7)
                                        Text(hex.uppercased())
                                            .font(CuvenFonts.cappedCaption2(weight: .semibold))
                                            .monospacedDigit()
                                            .foregroundStyle(CuvenColors.inkSecondary)
                                    }
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(CuvenColors.fieldBackground, in: Capsule())
                                }
                            }
                        }

                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 14)
                    .padding(.top, 6)
                    .padding(.bottom, 10)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("settings.avatarEditorButton")

            Divider()
                .overlay(CuvenColors.hairlineSeparator)
                .padding(.horizontal, 14)

            // Compact Inline Display Name & Bio Fields
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    TextField("Display name", text: $displayNameDraft)
                        .font(CuvenFonts.cappedSubheadline(weight: .medium))
                        .foregroundStyle(CuvenColors.inkPrimary)
                        .textInputAutocapitalization(.words)
                        .autocorrectionDisabled()
                        .onChange(of: displayNameDraft) { _, newValue in
                            if newValue.count > 40 {
                                displayNameDraft = String(newValue.prefix(40))
                            }
                            profileSaveFeedback = nil
                        }
                        .padding(.horizontal, 10)
                        .frame(minHeight: 44)
                        .background(CuvenColors.fieldBackground, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                        .accessibilityIdentifier("settings.displayNameField")

                    if hasUnsavedProfileEdits || isSavingProfile {
                        Button {
                            Task { await saveInlineProfile() }
                        } label: {
                            HStack(spacing: 5) {
                                if isSavingProfile {
                                    ProgressView()
                                        .tint(CuvenColors.onCtaInk)
                                }
                                Text("Save")
                                    .font(CuvenFonts.cappedCaption(weight: .semibold))
                                    .foregroundStyle(CuvenColors.onCtaInk)
                            }
                            .padding(.horizontal, 14)
                            .frame(minHeight: 44)
                            .background(CuvenColors.ctaInk, in: Capsule())
                        }
                        .buttonStyle(.plain)
                        .disabled(isSavingProfile)
                        .accessibilityIdentifier("settings.saveProfileButton")
                    } else if let profileSaveFeedback {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(CuvenColors.onlineGreen)
                            .accessibilityLabel(profileSaveFeedback)
                    }
                }

                TextField("Short bio (optional)", text: $bioDraft)
                    .font(CuvenFonts.cappedFootnote())
                    .foregroundStyle(CuvenColors.inkPrimary)
                    .onChange(of: bioDraft) { _, newValue in
                        if newValue.count > 120 {
                            bioDraft = String(newValue.prefix(120))
                        }
                        profileSaveFeedback = nil
                    }
                    .padding(.horizontal, 10)
                    .frame(minHeight: 44)
                    .background(CuvenColors.fieldBackground, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                    .accessibilityIdentifier("settings.bioField")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
        .background(CuvenColors.elevatedSurface, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(CuvenColors.cardLine, lineWidth: 1)
        }
    }

    @ViewBuilder
    private func profileCoverBanner(for user: CuvenUser?) -> some View {
        if let cover = user?.coverURL, !cover.isEmpty {
            if cover.hasPrefix("preset:"),
               let preset = BackdropPreset(rawValue: String(cover.dropFirst(7))) {
                CuvenBackdropView(preset: preset)
            } else if let preset = BackdropPreset(rawValue: cover) {
                CuvenBackdropView(preset: preset)
            } else {
                CuvenBackdropView(preset: .mist, customImageURL: cover)
            }
        } else {
            LinearGradient(
                colors: [
                    activeTintColor.opacity(0.34),
                    activeTintColor.opacity(0.10),
                    CuvenColors.elevatedSurface
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
    }

    // MARK: - 2. Appearance & Materials Card (Theme, Liquid Glass, Composer Glow, 8 Chat & Call Backdrops, 12h/24h)

    private var appearanceAndMaterialsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader("Appearance & Materials")

            VStack(alignment: .leading, spacing: 12) {
                // Theme (`System` / `Light` / `Dark` — 44pt HIG pill buttons)
                VStack(alignment: .leading, spacing: 6) {
                    rowLabel(icon: "circle.lefthalf.filled", title: "Theme")
                    pillOptionBar(
                        options: [
                            ("System", AppThemePreference.system, "settings.theme.system"),
                            ("Light", AppThemePreference.light, "settings.theme.light"),
                            ("Dark", AppThemePreference.dark, "settings.theme.dark")
                        ],
                        selection: store.prefs.theme
                    ) { next in
                        updatePrefs { $0.theme = next }
                    }
                    .accessibilityIdentifier("settings.themePicker")
                }

                cardDivider

                // Liquid Glass Mode (`Clear` vs `Tinted` — 44pt HIG pill buttons)
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        rowLabel(icon: "drop.halffull", title: "Liquid Glass")
                        Spacer()
                        Text(store.prefs.glassMode == .clear ? "Refractive" : "High Contrast")
                            .font(CuvenFonts.cappedCaption2(weight: .semibold))
                            .foregroundStyle(CuvenColors.inkPrimary)
                            .padding(.horizontal, 9)
                            .padding(.vertical, 4)
                            .cuvenLiquidGlass(mode: store.prefs.glassMode, cornerRadius: 12)
                    }

                    pillOptionBar(
                        options: [
                            ("Clear", GlassAppearanceMode.clear, "settings.glass.clear"),
                            ("Tinted", GlassAppearanceMode.tinted, "settings.glass.tinted")
                        ],
                        selection: store.prefs.glassMode
                    ) { next in
                        updatePrefs { $0.glassMode = next }
                    }
                    .accessibilityIdentifier("settings.glassModePicker")
                }

                cardDivider

                // Composer Ambient Glow (`Ocean` / `Dawn` / `Aurora` / `Off`) + Live Aura Underlay
                VStack(alignment: .leading, spacing: 6) {
                    rowLabel(icon: "rays", title: "Composer Glow")

                    ZStack {
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(CuvenColors.fieldBackground)

                        ComposerGlowView(style: store.prefs.composerGlow, audioLevel: 0.25, isFocused: true)
                            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))

                        pillOptionBar(
                            options: [
                                ("Ocean", ComposerGlowStyle.ocean, "settings.glow.ocean"),
                                ("Dawn", ComposerGlowStyle.dawn, "settings.glow.dawn"),
                                ("Aurora", ComposerGlowStyle.aurora, "settings.glow.aurora"),
                                ("Off", ComposerGlowStyle.off, "settings.glow.off")
                            ],
                            selection: store.prefs.composerGlow,
                            translucentTrack: true
                        ) { next in
                            updatePrefs { $0.composerGlow = next }
                        }
                        .padding(3)
                    }
                    .accessibilityIdentifier("settings.composerGlowPicker")
                }

                cardDivider

                // 8 Chat Backdrop Swatches (`store.prefs.defaultBackdrop`)
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        rowLabel(icon: "bubble.left.and.bubble.right.fill", title: "Chat Backdrop")
                        Spacer()
                        Text(ProfileAvatarCoverEditorSheet.backdropDisplayName(store.prefs.defaultBackdrop))
                            .font(CuvenFonts.cappedCaption(weight: .medium))
                            .foregroundStyle(CuvenColors.inkSecondary)
                    }

                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(BackdropPreset.allCases, id: \.self) { preset in
                                backdropSwatchTile(
                                    preset: preset,
                                    isSelected: store.prefs.defaultBackdrop == preset,
                                    isCallPreview: false
                                ) {
                                    updatePrefs { $0.defaultBackdrop = preset }
                                }
                            }
                        }
                        .padding(.vertical, 2)
                    }
                    .accessibilityIdentifier("settings.chatBackdropStrip")
                }

                cardDivider

                // 8 Call Backdrop Swatches (`store.prefs.callBackdrop`)
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        rowLabel(icon: "phone.fill", title: "Call Backdrop")
                        Spacer()
                        Text(ProfileAvatarCoverEditorSheet.backdropDisplayName(store.prefs.callBackdrop))
                            .font(CuvenFonts.cappedCaption(weight: .medium))
                            .foregroundStyle(CuvenColors.inkSecondary)
                    }

                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(BackdropPreset.allCases, id: \.self) { preset in
                                backdropSwatchTile(
                                    preset: preset,
                                    isSelected: store.prefs.callBackdrop == preset,
                                    isCallPreview: true
                                ) {
                                    updatePrefs { $0.callBackdrop = preset }
                                }
                            }
                        }
                        .padding(.vertical, 2)
                    }
                    .accessibilityIdentifier("settings.callBackdropStrip")
                }

                cardDivider

                // 24-Hour Time Format & Haptics Toggles
                HStack {
                    rowLabel(icon: "clock", title: "24-Hour Time")
                    Spacer()
                    Toggle(
                        "24-Hour Time",
                        isOn: Binding(
                            get: { store.prefs.use24HourTime },
                            set: { next in updatePrefs { $0.use24HourTime = next } }
                        )
                    )
                    .labelsHidden()
                    .tint(CuvenColors.onlineGreen)
                    .accessibilityIdentifier("settings.time24hToggle")
                }

                cardDivider

                HStack {
                    rowLabel(icon: "waveform.path", title: "Haptic Feedback")
                    Spacer()
                    Toggle(
                        "Haptic Feedback",
                        isOn: Binding(
                            get: { hapticsEnabled },
                            set: { next in
                                hapticsEnabled = next
                                CuvenHaptics.isEnabled = next
                                if next { CuvenHaptics.selectionChanged() }
                            }
                        )
                    )
                    .labelsHidden()
                    .tint(CuvenColors.onlineGreen)
                    .accessibilityIdentifier("settings.hapticsToggle")
                }
            }
            .padding(14)
            .background(CuvenColors.elevatedSurface, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .strokeBorder(CuvenColors.cardLine, lineWidth: 1)
            }
        }
    }

    private func backdropSwatchTile(
        preset: BackdropPreset,
        isSelected: Bool,
        isCallPreview: Bool,
        action: @escaping () -> Void
    ) -> some View {
        let label = ProfileAvatarCoverEditorSheet.backdropDisplayName(preset)
        return Button {
            CuvenHaptics.selectionChanged()
            action()
        } label: {
            ZStack(alignment: .bottom) {
                CuvenBackdropView(preset: preset)
                    .environment(\.colorScheme, isCallPreview ? .dark : .light)

                if isCallPreview {
                    Circle()
                        .fill(.white.opacity(0.82))
                        .frame(width: 18, height: 18)
                        .offset(y: -26)
                } else {
                    VStack(spacing: 3) {
                        Capsule()
                            .fill(CuvenColors.incomingBubble)
                            .frame(width: 28, height: 6)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Capsule()
                            .fill(CuvenColors.outgoingBubble)
                            .frame(width: 24, height: 6)
                            .frame(maxWidth: .infinity, alignment: .trailing)
                    }
                    .padding(.horizontal, 6)
                    .offset(y: -24)
                }

                Text(label)
                    .font(CuvenFonts.cappedCaption2(weight: .semibold))
                    .foregroundStyle(CuvenColors.inkPrimary)
                    .lineLimit(1)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.ultraThinMaterial, in: Capsule())
                    .padding(.bottom, 4)
            }
            .frame(width: 66, height: 70)
            .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .strokeBorder(
                        isSelected ? CuvenColors.sidebarBlue : CuvenColors.cardLine,
                        lineWidth: isSelected ? 2.5 : 1.0
                    )
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(isCallPreview ? "Call" : "Chat") backdrop \(label)")
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
        .accessibilityIdentifier("settings.\(isCallPreview ? "call" : "chat")Backdrop.\(preset.rawValue)")
    }

    // MARK: - 3. Smart & Workers AI Card (`settings.aiMemoryButton`)

    private var smartAndWorkersAISection: some View {
        let routineSummary = RoutineAnalyticsModel.summarize(
            buckets: store.aiRoutineBuckets,
            routineLearningEnabled: store.prefs.routineLearningEnabled,
            use24HourTime: store.prefs.use24HourTime
        )

        return VStack(alignment: .leading, spacing: 8) {
            sectionHeader("Smart & Workers AI")

            VStack(spacing: 12) {
                // AI Memory & 24-Hour Routine Inspector Button (`settings.aiMemoryButton`) placed first for immediate scroll reachability
                Button {
                    CuvenHaptics.lightTap()
                    showAIMemorySheet = true
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "sparkles")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(CuvenColors.sidebarBlue)
                            .frame(width: 22)

                        VStack(alignment: .leading, spacing: 2) {
                            Text("AI Memory & 24h Routine")
                                .font(CuvenFonts.cappedBody(weight: .medium))
                                .foregroundStyle(CuvenColors.inkPrimary)
                            Text(aiMemorySubtitle(summary: routineSummary))
                                .font(CuvenFonts.cappedCaption())
                                .foregroundStyle(CuvenColors.inkSecondary)
                                .lineLimit(1)
                        }

                        Spacer(minLength: 4)

                        // Mini 24-bar sparkline preview
                        HStack(alignment: .bottom, spacing: 1.5) {
                            ForEach(routineSummary.normalizedBuckets.strideSampled(every: 2), id: \.hour) { b in
                                RoundedRectangle(cornerRadius: 1)
                                    .fill(CuvenColors.sidebarBlue.opacity(0.35 + b.activityScore * 0.65))
                                    .frame(width: 3, height: max(3, CGFloat(b.activityScore) * 18))
                            }
                        }
                        .frame(height: 20)

                        Image(systemName: "chevron.right")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(CuvenColors.inkTertiary)
                    }
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("settings.aiMemoryButton")

                cardDivider

                HStack {
                    rowLabel(icon: "wand.and.stars", title: "Smart Assist")
                    Spacer()
                    Toggle(
                        "Smart Assist",
                        isOn: Binding(
                            get: { store.prefs.smartAssistEnabled },
                            set: { next in updatePrefs { $0.smartAssistEnabled = next } }
                        )
                    )
                    .labelsHidden()
                    .tint(CuvenColors.onlineGreen)
                    .accessibilityIdentifier("settings.smartAssistToggle")
                }

                cardDivider

                HStack {
                    rowLabel(icon: "chart.bar.xaxis", title: "Routine Learning")
                    Spacer()
                    Toggle(
                        "Routine Learning",
                        isOn: Binding(
                            get: { store.prefs.routineLearningEnabled },
                            set: { next in updatePrefs { $0.routineLearningEnabled = next } }
                        )
                    )
                    .labelsHidden()
                    .tint(CuvenColors.onlineGreen)
                    .accessibilityIdentifier("settings.routineLearningToggle")
                }
            }
            .padding(14)
            .background(CuvenColors.elevatedSurface, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .strokeBorder(CuvenColors.cardLine, lineWidth: 1)
            }
        }
    }

    private func aiMemorySubtitle(summary: RoutineSummaryMetrics) -> String {
        let countText = "\(store.aiMemories.count) \(store.aiMemories.count == 1 ? "memory" : "memories")"
        if let peak = summary.peakCalloutText {
            return "\(countText) · \(peak)"
        }
        return "\(countText) · \(summary.confidenceLabel)"
    }

    // MARK: - 4. iPhone & iPhone Duo Posture Lab (`store.postureOverride`)

    private var duoPostureLabSection: some View {
        let options: [(title: String, subtitle: String, symbol: String, posture: DuoPosture?)] = [
            ("Auto", "Hardware", "iphone.gen3", nil),
            ("Compact", "1 col · 56pt", "iphone", .iPhoneCompact),
            ("Split", "2 col", "iphone.landscape", .iPhoneSplit),
            ("Closed", "466×678", "rectangle.portrait.righthalf.inset.filled", .duoClosed),
            ("Half Book", "462|28|461", "book.pages", .duoHalfBook),
            ("Half Laptop", "Top / Deck", "laptopcomputer", .duoHalfLaptop),
            ("Duo Open", "951×669", "rectangle.split.2x1", .duoOpen)
        ]

        return VStack(alignment: .leading, spacing: 8) {
            sectionHeader("iPhone & iPhone Duo Posture Lab")

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(Array(options.enumerated()), id: \.offset) { _, item in
                        let isSelected = store.postureOverride == item.posture
                        Button {
                            CuvenHaptics.selectionChanged()
                            withAnimation(reduceMotion ? CuvenSprings.reducedMotionFade : CuvenSprings.railMorph) {
                                store.postureOverride = item.posture
                            }
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: item.symbol)
                                    .font(.system(size: 14, weight: .semibold))
                                    .foregroundStyle(isSelected ? CuvenColors.sidebarBlue : CuvenColors.inkSecondary)

                                VStack(alignment: .leading, spacing: 1) {
                                    Text(item.title)
                                        .font(CuvenFonts.cappedCaption(weight: .semibold))
                                        .foregroundStyle(CuvenColors.inkPrimary)
                                    Text(item.subtitle)
                                        .font(CuvenFonts.cappedCaption2())
                                        .foregroundStyle(CuvenColors.inkSecondary)
                                }
                            }
                            .padding(.horizontal, 12)
                            .frame(minHeight: 46)
                            .background(
                                isSelected ? CuvenColors.sidebarBlue.opacity(0.14) : CuvenColors.elevatedSurface,
                                in: RoundedRectangle(cornerRadius: 14, style: .continuous)
                            )
                            .overlay {
                                RoundedRectangle(cornerRadius: 14, style: .continuous)
                                    .strokeBorder(
                                        isSelected ? CuvenColors.sidebarBlue : CuvenColors.cardLine,
                                        lineWidth: isSelected ? 2.0 : 1.0
                                    )
                            }
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
                        .accessibilityIdentifier("settings.posture.\(item.posture?.rawValue ?? "auto")")
                    }
                }
                .padding(.vertical, 2)
            }
            .accessibilityIdentifier("settings.posturePicker")
        }
    }

    // MARK: - 5. Local Notifications & Unread App Icon Badges

    private var notificationsAndBadgeSection: some View {
        let unreadBadge = LocalNotificationBadgeManager.computeUnreadBadgeCount(for: store.rooms)

        return VStack(alignment: .leading, spacing: 8) {
            sectionHeader("Notifications & Badges")

            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    rowLabel(icon: "bell.badge.fill", title: "Local Notifications")
                    Text("\(notificationManager.statusDescription) · Unread badge: \(unreadBadge)")
                        .font(CuvenFonts.cappedCaption())
                        .monospacedDigit()
                        .foregroundStyle(CuvenColors.inkSecondary)
                        .padding(.leading, 28)
                }

                Spacer()

                if notificationManager.authorizationStatus == .notDetermined {
                    Button("Enable") {
                        Task {
                            let granted = await notificationManager.requestPermission()
                            if granted {
                                await notificationManager.syncBadgeCount(for: store.rooms)
                                CuvenHaptics.success()
                            }
                        }
                    }
                    .font(CuvenFonts.cappedSubheadline(weight: .semibold))
                    .foregroundStyle(CuvenColors.onCtaInk)
                    .padding(.horizontal, 14)
                    .frame(minHeight: 44)
                    .background(CuvenColors.ctaInk, in: Capsule())
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("settings.enableNotificationsButton")
                } else {
                    Toggle(
                        "In-App Notifications",
                        isOn: Binding(
                            get: { notificationManager.inAppNotificationsEnabled },
                            set: { next in
                                notificationManager.inAppNotificationsEnabled = next
                                Task { await notificationManager.syncBadgeCount(for: store.rooms) }
                            }
                        )
                    )
                    .labelsHidden()
                    .tint(CuvenColors.onlineGreen)
                    .accessibilityIdentifier("settings.notificationsToggle")
                }
            }
            .padding(14)
            .background(CuvenColors.elevatedSurface, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .strokeBorder(CuvenColors.cardLine, lineWidth: 1)
            }
        }
    }

    // MARK: - 6. Privacy & Security Card (Read Receipts, Password Change, Sign Out)

    private var privacyAndSecuritySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader("Privacy & Security")

            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    rowLabel(icon: "checkmark.circle", title: "Read Receipts")
                    Spacer()
                    Toggle(
                        "Read Receipts",
                        isOn: Binding(
                            get: { store.prefs.sendReadReceipts },
                            set: { next in updatePrefs { $0.sendReadReceipts = next } }
                        )
                    )
                    .labelsHidden()
                    .tint(CuvenColors.onlineGreen)
                    .accessibilityIdentifier("settings.readReceiptsToggle")
                }

                cardDivider

                Button {
                    CuvenHaptics.lightTap()
                    withAnimation(reduceMotion ? nil : CuvenSprings.smooth) {
                        isPasswordFormExpanded.toggle()
                        passwordFeedbackMessage = nil
                    }
                } label: {
                    HStack {
                        rowLabel(icon: "lock.fill", title: "Change Password")
                        Spacer()
                        Image(systemName: isPasswordFormExpanded ? "chevron.up" : "chevron.down")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(CuvenColors.inkTertiary)
                    }
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("settings.changePasswordButton")

                if isPasswordFormExpanded {
                    VStack(alignment: .leading, spacing: 10) {
                        SecureField("Current password", text: $currentPasswordInput)
                            .font(CuvenFonts.cappedBody())
                            .textContentType(.password)
                            .padding(.horizontal, 12)
                            .frame(minHeight: 44)
                            .background(CuvenColors.fieldBackground, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                            .accessibilityIdentifier("settings.currentPasswordField")

                        SecureField("New password (6+ characters)", text: $newPasswordInput)
                            .font(CuvenFonts.cappedBody())
                            .textContentType(.newPassword)
                            .padding(.horizontal, 12)
                            .frame(minHeight: 44)
                            .background(CuvenColors.fieldBackground, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                            .accessibilityIdentifier("settings.newPasswordField")

                        if let passwordFeedbackMessage {
                            Text(passwordFeedbackMessage)
                                .font(CuvenFonts.cappedFootnote())
                                .foregroundStyle(passwordFeedbackIsError ? CuvenColors.dangerRedText : CuvenColors.onlineGreen)
                        }

                        HStack {
                            Spacer()
                            Button {
                                Task { await submitPasswordChange() }
                            } label: {
                                HStack(spacing: 6) {
                                    if isUpdatingPassword {
                                        ProgressView()
                                            .tint(CuvenColors.onCtaInk)
                                    }
                                    Text("Update Password")
                                        .font(CuvenFonts.cappedSubheadline(weight: .semibold))
                                        .foregroundStyle(CuvenColors.onCtaInk)
                                }
                                .padding(.horizontal, 18)
                                .frame(minHeight: 44)
                                .background(CuvenColors.ctaInk, in: Capsule())
                            }
                            .buttonStyle(.plain)
                            .disabled(isUpdatingPassword)
                            .accessibilityIdentifier("settings.submitPasswordButton")
                        }
                    }
                    .padding(.top, 4)
                    .transition(.opacity)
                }
            }
            .padding(14)
            .background(CuvenColors.elevatedSurface, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .strokeBorder(CuvenColors.cardLine, lineWidth: 1)
            }
        }
    }

    private var signOutDangerSection: some View {
        Button(role: .destructive) {
            CuvenHaptics.rigidImpact()
            showSignOutConfirmation = true
        } label: {
            HStack {
                Spacer()
                Label("Sign Out", systemImage: "rectangle.portrait.and.arrow.right")
                    .font(CuvenFonts.cappedBody(weight: .semibold))
                    .foregroundStyle(CuvenColors.dangerRedText)
                Spacer()
            }
            .frame(minHeight: 48)
            .background(CuvenColors.elevatedSurface, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .strokeBorder(CuvenColors.dangerRed.opacity(0.28), lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Sign Out")
        .accessibilityIdentifier("settings.signOut")
    }

    // MARK: - Helpers & Actions

    private func pillOptionBar<Value: Hashable>(
        options: [(label: String, value: Value, aid: String)],
        selection: Value,
        translucentTrack: Bool = false,
        onSelect: @escaping (Value) -> Void
    ) -> some View {
        HStack(spacing: 4) {
            ForEach(Array(options.enumerated()), id: \.offset) { _, option in
                let isSelected = option.value == selection
                Button {
                    guard !isSelected else { return }
                    onSelect(option.value)
                } label: {
                    Text(option.label)
                        .font(CuvenFonts.cappedSubheadline(weight: isSelected ? .semibold : .medium))
                        .foregroundStyle(isSelected ? CuvenColors.inkPrimary : CuvenColors.inkSecondary)
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .background {
                            if isSelected {
                                RoundedRectangle(cornerRadius: 11, style: .continuous)
                                    .fill(CuvenColors.elevatedSurface)
                                    .shadow(color: .black.opacity(0.10), radius: 3, x: 0, y: 1)
                            }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(option.label)
                .accessibilityAddTraits(isSelected ? [.isSelected] : [])
                .accessibilityIdentifier(option.aid)
            }
        }
        .padding(3)
        .background(
            translucentTrack
                ? AnyShapeStyle(.ultraThinMaterial)
                : AnyShapeStyle(CuvenColors.fieldBackground),
            in: RoundedRectangle(cornerRadius: 14, style: .continuous)
        )
    }

    private func sectionHeader(_ text: String) -> some View {
        Text(text)
            .font(CuvenFonts.cappedSubheadline(weight: .semibold))
            .foregroundStyle(CuvenColors.inkSecondary)
            .padding(.horizontal, 6)
    }

    private func rowLabel(icon: String, title: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(CuvenColors.sidebarBlue)
                .frame(width: 18)
            Text(title)
                .font(CuvenFonts.cappedBody(weight: .medium))
                .foregroundStyle(CuvenColors.inkPrimary)
        }
    }

    private var cardDivider: some View {
        Divider()
            .overlay(CuvenColors.hairlineSeparator)
    }

    private func syncProfileDraftsFromStore() {
        displayNameDraft = store.currentUser?.display ?? ""
        bioDraft = store.currentUser?.bio ?? ""
    }

    private func updatePrefs(_ mutate: (inout UserPrefs) -> Void) {
        var next = store.prefs
        mutate(&next)
        CuvenHaptics.selectionChanged()
        Task {
            await store.updatePreferences(next)
        }
    }

    private func saveInlineProfile() async {
        guard !isSavingProfile else { return }
        isSavingProfile = true
        profileSaveFeedback = nil

        let cleanDisplay = displayNameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        let effectiveDisplay = cleanDisplay.isEmpty ? (store.currentUser?.username ?? "Me") : cleanDisplay
        let cleanBio = bioDraft.trimmingCharacters(in: .whitespacesAndNewlines)

        await store.updateProfile(
            display: effectiveDisplay,
            bio: cleanBio,
            avatarData: nil,
            coverData: nil,
            dominantTintHex: store.currentUser?.dominantTintHex
        )

        displayNameDraft = effectiveDisplay
        bioDraft = cleanBio
        profileSaveFeedback = "Saved"
        isSavingProfile = false
        CuvenHaptics.success()
    }

    private func submitPasswordChange() async {
        passwordFeedbackMessage = nil
        let cur = currentPasswordInput
        let next = newPasswordInput

        guard !cur.isEmpty else {
            passwordFeedbackIsError = true
            passwordFeedbackMessage = "Please enter your current password."
            CuvenHaptics.error()
            return
        }
        guard next.count >= 6 else {
            passwordFeedbackIsError = true
            passwordFeedbackMessage = "New password must be at least 6 characters."
            CuvenHaptics.error()
            return
        }

        isUpdatingPassword = true
        do {
            try await store.changePassword(current: cur, next: next)
            currentPasswordInput = ""
            newPasswordInput = ""
            passwordFeedbackIsError = false
            passwordFeedbackMessage = "Password updated."
            CuvenHaptics.success()
        } catch {
            passwordFeedbackIsError = true
            passwordFeedbackMessage = error.localizedDescription
            CuvenHaptics.error()
        }
        isUpdatingPassword = false
    }

    private func routeInitialTabIfNeeded(using scrollProxy: ScrollViewProxy) {
        guard let rawTab = initialTab?.lowercased().trimmingCharacters(in: .whitespacesAndNewlines),
              !rawTab.isEmpty else {
            return
        }
        switch rawTab {
        case "avatar", "photo":
            avatarEditorInitialTab = .avatar
            showAvatarCoverEditor = true
        case "cover":
            avatarEditorInitialTab = .cover
            showAvatarCoverEditor = true
        case "ai", "memory", "aimemory", "routine":
            showAIMemorySheet = true
        case "appearance", "posture", "privacy", "notifications", "profile":
            scrollProxy.scrollTo(rawTab, anchor: .top)
        default:
            break
        }
    }
}

private extension Array {
    func strideSampled(every step: Int) -> [Element] {
        guard step > 1 else { return self }
        return enumerated().compactMap { idx, element in
            idx % step == 0 ? element : nil
        }
    }
}
