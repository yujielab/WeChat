import SwiftUI
import CuvenCore

// MARK: - Canonical Column 3 Artifact Container (`PROJECT.md § 5.4`)
//
// Exact Public Contract:
// `public struct ArtifactColumnView: View {`
// `    public init(store: AppStore, roomID: String, mode: ArtifactMode, metrics: DuoLayoutMetrics, onClose: @escaping () -> Void)`
// `}`
//
// Hosts either `RoomDetailsInfoView` (`.roomInfo`) or `DrawingBoardCanvasView` (`.drawingBoard`)
// in Column 3 beside the active `Thread` (`525 | 426` zero-reflow split on `duoOpen`, `462 | hinge | 461`
// on `duoHalfBook`, or single-column stack on `iPhoneCompact` / `duoClosed` / `duoHalfLaptop`),
// enforcing unsaved-ink discard protection when leaving an inked drawing board (`draw-guard.js`).

public struct ArtifactColumnView: View {
    private let store: AppStore
    private let roomID: String
    private let mode: ArtifactMode
    private let metrics: DuoLayoutMetrics
    private let onClose: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var drawingHasUnsavedInk: Bool = false
    @State private var displayedMode: ArtifactMode
    @State private var pendingModeTransition: ArtifactMode?
    @State private var showModeSwitchDiscardAlert: Bool = false

    public init(
        store: AppStore,
        roomID: String,
        mode: ArtifactMode,
        metrics: DuoLayoutMetrics,
        onClose: @escaping () -> Void
    ) {
        self.store = store
        self.roomID = roomID
        self.mode = mode
        self.metrics = metrics
        self.onClose = onClose
        self._displayedMode = State(initialValue: mode)
    }

    public var body: some View {
        ZStack {
            switch displayedMode {
            case .roomInfo:
                RoomDetailsInfoView(
                    store: store,
                    roomID: roomID,
                    metrics: metrics,
                    onClose: onClose
                )
                .transition(.opacity)

            case .drawingBoard:
                DrawingBoardCanvasView(
                    store: store,
                    roomID: roomID,
                    metrics: metrics,
                    hasUnsavedInk: $drawingHasUnsavedInk,
                    onClose: onClose
                )
                .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(CuvenColors.paperBackground)
        .animation(CuvenSprings.adaptive(CuvenSprings.smooth, reduceMotion: reduceMotion), value: displayedMode)
        .onChange(of: mode) { _, nextMode in
            guard nextMode != displayedMode else { return }
            if displayedMode == .drawingBoard && drawingHasUnsavedInk {
                pendingModeTransition = nextMode
                CuvenHaptics.warning()
                showModeSwitchDiscardAlert = true
            } else {
                displayedMode = nextMode
            }
        }
        .alert("Discard unsent drawing?", isPresented: $showModeSwitchDiscardAlert) {
            Button("Discard", role: .destructive) {
                drawingHasUnsavedInk = false
                if let target = pendingModeTransition {
                    displayedMode = target
                }
                pendingModeTransition = nil
            }
            Button("Keep Drawing", role: .cancel) {
                pendingModeTransition = nil
                if store.activeArtifactMode != .drawingBoard {
                    store.openArtifact(.drawingBoard)
                }
            }
        } message: {
            Text("Switching away from the drawing board will discard your unsent sketch.")
        }
    }
}
