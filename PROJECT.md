# Project: Cuven — 100% Native iOS & iPhone Duo App (`iOS 27.2 SDK` + `.ipa`)

## 1. Mission & Non-Negotiable Mandates
1. **100% Native iOS App + Genuine `.ipa` Artifact**: Built purely with Apple native `Swift 6` + `SwiftUI` + `UIKit` + `CoreAnimation` + `CoreImage` + `AVFoundation` + `CallKit` + `Network` (ZERO hybrid WebView UI shell, ZERO `WebKit` linkage). Packaged into a genuine ARM64 `Cuven.ipa` (and `WeChat.ipa` alias in `dist/`).
2. **Mandatory iOS 27.2 SDK Build & Adaptation** *(User Override `2026-11-18T04:56:54Z` superseding `27.1`)*:
   - GitHub Actions CI MUST run on `runs-on: xcode-27`, explicitly probing and selecting **`/Applications/Xcode_27.2.app`** (`Xcode_27.2*.app`, Build `27B52`) and building against **`iphoneos27.2` / `iphonesimulator27.2` SDKs**.
   - Compiled Mach-O binary inside `Payload/Cuven.app/Cuven` MUST carry `LC_BUILD_VERSION` **`sdk 27.2`**, verified via `otool -l` / `vtool -show-build` on macOS and `llvm-objdump --macho --private-headers` on Linux.
   - `Info.plist` MUST set `UIRequiresFullScreen = false`, `UIApplicationSupportsMultipleScenes = true`, `UILaunchScreen = {}`, and all 4 orientations so iOS 27.2 dynamically extends edge-to-edge under the iPhone Duo right-edge status column & camera without letterboxing (aligned with `README.md` iOS 27.2 Duo right-edge system column & safe-area behavior).
3. **Dedicated iPhone & iPhone Duo Spatial Optimization**:
   - **Standard iPhone (`390×844` / `393×852` / `440×956` portrait; `956×440` Pro Max landscape)**: 1-column `stack` (`<700pt`) or symmetric 2-column `split` (`>=700pt`), `56pt` floating Liquid Glass horizontal bottom dock (with counter-translated stationary `Back` pill during swipe-back).
   - **iPhone Duo Postures**:
     - `closed` (Outer cover display `466×678pt` portrait / `678×466pt` landscape): 1-column `stack` (`<700pt`), asymmetric right safe-area column (`>=64pt`, `~91pt` width, `170pt` top reserve for camera + ring), `52pt` vertical right-edge `DuoRailView` (`centerX = width - 49pt`) + 6-item `PagesCapsuleView` (`Chats`, `Moments`, `Memories`, `Friends`, `You`, `Menu`).
     - `halfBook` & `halfLaptop` (Fold/hinge postures `462 | 28..40pt division | 461pt` book with subtle crease binding depth shadow, and tabletop top/bottom split especially for Video Calls & Media).
     - `open` (Inner canvas `951×669pt` landscape / `890×626pt`): 2-column `split` (`>=700pt`) inside the 4-column horizontal strip (`0: Sidebar | 1: ChatList | 2: Thread | 3: Artifact`). `ChatList | Thread` = `342pt | 609pt` (`525pt` thread content + `84pt` right system rail, `118pt` top reserve); `Thread | Artifact` = `525pt | 426pt` (`342pt` details + `84pt` right rail) — **Thread content stays `525pt` with ZERO text reflow!** Leading column uses `56pt` horizontal capsule bar; trailing column uses `52pt` vertical right-edge `DuoRailView` + `PagesCapsuleView`.
4. **Explicit Apple HIG & iOS 27.2 Developer Documentation Grounding**:
   - Every view, layout, bar, menu, gesture, spring, Dynamic Type cap, safe-area inset, and haptic MUST conform to and cite official **Apple Human Interface Guidelines** (*Designing for iPhone Duo*, *Preparing your app for iPhone Duo*, *Materials / Liquid Glass*, *Layout*, *Motion*, *Gestures*, *Menus and Actions*, *Typography*, *Playing Haptics*) and **iOS 27.2 SDK Documentation**, cross-referenced with repo docs (`design-qa.md`, `README.md`, `docs/style-spec.md`, `docs/hig-audit.md`, `docs/quality-bar.md`, `docs/ux-plan.md`) and consolidated in `docs/ios-hig-27.2-reference.md` (and synced in `docs/ios-hig-27.1-reference.md`).
5. **Beyond-Apple UI/UX Craft + Cuven Web Design Fidelity**:
   - Paper-white (`#FFFFFF` / `#F2F2F7`) & near-black (`#18181B` / `#000000` / `#1C1C1E`) Cuven surface hierarchy; `#18181B` dark ink outgoing bubbles (`#27272A` in dark mode) & `#F4F4F5` incoming bubbles with custom Bezier iMessage tails; Facebook/iOS Blue (`#007AFF` / `#1877F2`) sidebar scope icons; `Clarinetta` display serif wordmark/editorial accents + SF Pro with `21pt` chrome Dynamic Type ceiling; Liquid Glass (`Clear` & `Tinted` + `Reduce Transparency` fallback); Composer ambient glow (`Ocean`, `Dawn`, `Aurora`, `Off`) + mic-reactive `VoiceBeam`; 1:1 finger-tracking springs with velocity projection (`project(v, 0.998)`), mid-flight catch/interruption, and reversible deformation.

---

## 2. Architecture
```text
Cuven Native iOS Architecture (Xcode 27.2 / iphoneos27.2 SDK)
├── CuvenCore (Pure Swift 6 Package — Foundation only, <2s Linux `swift test` + iOS link)
│   ├── Models (User, Room, Message, Reaction, Contact, Moment, Note, Memory, Insight, Sticker, Call, Prefs, AI)
│   ├── LayoutMath (DuoPosture, DuoViewportMetrics, ColumnMath 342|609 <-> 525|426, SpringSolver, VelocityProjector)
│   ├── Networking (CuvenAPIClient w/ Origin + cfm_session + x-tz, CuvenWebSocketClient, NDJSONStreamClient)
│   └── Persistence (BootCache, PersistentOutbox FIFO + localId idempotency, RichDemoSeedData)
└── Cuven.app (100% Native SwiftUI + UIKit + CoreAnimation + CoreImage + AVFoundation + CallKit)
    ├── Core (AppStore @Observable coordinator, KeychainSessionStore, AuthenticatedMediaLoader)
    ├── DesignSystem (Tokens, Clarinetta+SFPro Typography, LiquidGlass, SpringPhysics, Haptics, Glow, Backdrops, Sheets)
    ├── Layout & App (4-Column StripContainer, DuoPostureMonitor, Horizontal Dock vs 52pt Vertical DuoRail, PagesCapsule)
    └── Features (Auth, Sidebar, ChatList/Notes/Insights, Thread/Composer/AI, Moments/Editor, Artifact/Drawing/Stickers/Memories, WebRTC Calls/PiP, Settings/AvatarEditor)
```

---

## 3. Feature Inventory (100% Assigned to Milestones)
| # | Feature | Description & Apple HIG / Web Reference | Milestone | Source |
|---|---------|-----------------------------------------|-----------|--------|
| F1 | Apple HIG & iOS 27.2 Traceability Spec | Complete mapping of Apple HIG (*Designing for iPhone Duo*, *Liquid Glass*, *Motion*, *Layout*) + iOS 27.2 SDK APIs + Web `docs/*` & `README.md` iOS 27.2 Duo behavior | M1 | `ORIGINAL_REQUEST`, `design-qa.md`, `README.md` |
| F2 | Xcode 27.2 Project, Assets, Fonts & `.ipa` CI | `project.yml`, `Clarinetta.ttf` conversion, `AppIcon`, `Info.plist` (`UIRequiresFullScreen=false`), `xcode-27` (`Xcode_27.2.app`, `iphoneos27.2`) CI & Mach-O `sdk 27.2` verification | M2 | `explorer_survey_1`, `explorer_survey_3` |
| F3 | Backend Auth, REST, WebSocket & Outbox | `https://wechat.cuven.us` client (`Origin` header + `cfm_session` cookie + `x-tz`), `/api/ws` 16 realtime events, `BootCache`, FIFO `PersistentOutbox`, Demo seed mode | M3 | `src/index.js`, `src/hub.js` |
| F4 | Cuven Design System, Liquid Glass & Physics | Paper/ink palette, `Clarinetta` + capped Dynamic Type, `Clear`/`Tinted` Liquid Glass, 1:1 spring physics, haptics, 8 backdrops, `ComposerGlow`, `VoiceBeam`, adaptive sheets | M4 | `tokens.css`, `liquid-glass/*` |
| F5 | iPhone & iPhone Duo 4-Column Strip & Rail | `Sidebar|List|Thread|Artifact` strip, `700pt` split, `342|609` & zero-reflow `525|426`, `closed`/`halfBook`/`halfLaptop`/`open`, `56pt` bottom dock (pinned `Back`) vs `52pt` right `DuoRail` + 6-item `Pages` capsule | M5 | `viewport.js`, `columns.js`, `strip.js`, `bars.js`, `pages.js` |
| F6 | Auth, Segmented Invite Code, Sidebar & Guides | `Clarinetta` wordmark Sign In / Register, segmented invite-code track, cross-fade arrival, Sidebar w/ Facebook-Blue scope icons, Skeleton shimmer & Onboarding guides | M6 | `views/auth.js`, `views/sidebar.js` |
| F7 | Chat List, Notes, Requests, People & Insights | Messages list, `24h` 60-char Notes strip, For You Smart Insights + weather cards, gliding filter tabs, Pinned grid, physics swipe-to-delete/unread, blurred context menu, People/Requests, Global Search | M7 | `views/list.js`, `src/insights.js` |
| F8 | Conversation Thread, Ink Bubbles, Honk & AI | Large-avatar header pill, `#18181B` ink curved-tail bubbles, `PhotoStack` fan, swipe-reply & timestamps, lifted blurred menu + 6 tapbacks, 15m/5x Edit + history, Unsend, Honk live typing, Whisper mic, AI ghost completion & streaming Search/Explain | M8 | `views/thread.js`, `src/assist.js`, `src/explain.js` |
| F9 | Moments Feed, Profile Waterfall & Photo Editor | Stories row, Moments cards, double-tap heart, comments, Profile `Posts`/`Media` grid, full-page Editor (6 CoreImage tones, crop/rotate, `+ALT`, `@tag`, permissions, schedule, undo/redo) | M9 | `views/moments.js`, `src/store.js` |
| F10 | Drawing Board, Telegram Stickers & Memories | `Column 3` Room Info + velocity-smoothed Drawing Board (`Pen/Marker/Highlighter/Pencil/Eraser` + `Plain/Lines/Grid` paper), 14 Telegram sticker packs (WebP/Lottie/Video), Memories flashback slideshow + 4-col grid + hero zoom Lightbox | M10 | `views/draw.js`, `src/stickers.js`, `views/memories.js` |
| F11 | WebRTC Audio/Video Calls, Laptop Split & PiP | Cloudflare Realtime SFU (`/rtc/*` + `/api/ws`), `CallKit`, synthesized tones (`450Hz` ring, rising/falling chimes), dark glass call controls, Duo `halfLaptop` top/bottom split, corner-snapping PiP tile | M11 | `src/call.js`, `views/call.js` |
| F12 | Profile Framing Editor, Settings, AI Memory & Unit Tests | `512×512` avatar/cover crop + dominant tint + 8 recent avatars, Appearance/Glass/Glow/Backdrop/Receipts/Password settings, AI Memory & 24h Routine bar chart, local notifications/badges, `CuvenTests` | M12 | `views/settings.js`, `src/memory.js`, `src/routine.js` |
| F13 | Opaque-Box E2E Suite (`iPhone` + `iPhone Duo` + `.ipa`) | Tier 1–4 `CuvenUITests` across `iPhone` & `iPhone Duo` postures + Mach-O `sdk 27.2` & `.ipa` verification harness | E2E | `ORIGINAL_REQUEST`, Dual Track |

---

## 4. Milestones
| # | Name | Scope | Dependencies | Status |
|---|------|-------|-------------|--------|
| M1 | Apple HIG & iOS 27.2 Reference Matrix | `docs/ios-hig-27.2-reference.md` & `docs/ios-hig-27.1-reference.md` | Interface Contract | IN_PROGRESS (`worker_m1_hig_docs_r3`: upgrading baseline to `iOS 27.2 SDK`) |
| M2 | Xcode 27.2 Scaffolding, Assets & `.ipa` CI | `.gitignore`, `.github/workflows/ios-ipa-ci.yml`, `ios/project.yml`, fonts/icons, Linux Swift 6.4.2 | Interface Contract | IN_PROGRESS (`70dbc6c1f7b417b7760b837a85b6e328` — `Xcode_27.2.app` / `iphoneos27.2`) |
| M3 | Core Models, Networking, WS, Store & Outbox | `ios/Packages/CuvenCore/**`, `ios/Cuven/Core/**` | Interface Contract | IN_PROGRESS (`77d41b3b7b8ad1b38752d6d1d3f52cbe`) |
| M4 | Design System, Liquid Glass & Spring Physics | `ios/Cuven/DesignSystem/**` | Interface Contract | IN_PROGRESS (`fe2c6340384e72f2e1dab3e03f01b4f0`) |
| M5 | iPhone Duo 4-Column Strip, Postures & Rail | `ios/Cuven/App/**`, `ios/Cuven/Layout/**` | Interface Contract | IN_PROGRESS (`f3421983052cb714662faae60b127186`) |
| M6 | Auth, Invite Track, Sidebar & Guides | `ios/Cuven/Features/Auth/**`, `ios/Cuven/Features/Sidebar/**` | Interface Contract | IN_PROGRESS (`049c6b443e75a2cf813e8b7abf59d29f`) |
| M7 | Chat List, Notes, Requests & For You Insights | `ios/Cuven/Features/ChatList/**` | Interface Contract | IN_PROGRESS (`5dcded1d0d56e1661a53a34e8a590ada`) |
| M8 | Conversation Thread, Composer, Honk & AI Explain | `ios/Cuven/Features/Thread/**`, `ios/Cuven/Features/SmartAI/**` | Interface Contract | IN_PROGRESS (`b9b483e3d6e9d717b558607e2f0db34e`) |
| M9 | Moments Feed, Profile Grid & Full-Page Editor | `ios/Cuven/Features/Moments/**` | Interface Contract | IN_PROGRESS (`7e817df2e8f1f3346efc64f1b22bdfa0`) |
| M10 | Artifact Info, Drawing Board, Stickers & Memories | `ios/Cuven/Features/Artifact/**`, `Stickers/**`, `Memories/**` | Interface Contract | IN_PROGRESS (`f3741b1c820f9dbcae5c5df5e0fffbfd`) |
| M11 | WebRTC SFU Calls, Laptop Posture & PiP | `ios/Cuven/Features/Calls/**` | Interface Contract | IN_PROGRESS (`69edb05ed18d29f63a94eeaa983ba882`) |
| M12 | Profile Crop Editor, Settings, AI Routine & Unit Tests | `ios/Cuven/Features/Settings/**`, `ios/CuvenTests/**` | Interface Contract | IN_PROGRESS (`452023ec6c7ffa21fa156c9b7246456b`) |
| E2E | Opaque-Box E2E Test Track (Tiers 1–4) | `ios/CuvenUITests/**`, `ios/scripts/run-e2e-suite.sh`, `TEST_READY.md` | `TEST_INFRA.md` | IN_PROGRESS (`d7dc1109897b8cd2595cb86cdd1669a6` — `sdk 27.2` + `SimRuntime.iOS-27-2`) |
| M13 | Final Integration, `xcode-27` (`27.2 SDK`) `.ipa` Build, E2E Tiers 1–4 & Tier 5 Hardening | Wire all slices, build & download `Cuven.ipa` (`sdk 27.2`), pass 100% E2E + Reviewer/Challenger/Auditor gates | M1–M12, E2E | PLANNED |

---

## 5. Exact Swift Cross-Module Interface Contracts (CANONICAL — ALL WORKERS MUST CONFORM)

### 5.1 `CuvenCore` Public Domain Types (`import CuvenCore`)
`worker_m3_core_network_store` MUST define these exact `public` types (`Sendable`, `Codable`, `Identifiable`, `Hashable` where applicable) in `ios/Packages/CuvenCore/Sources/CuvenCore/`:

```swift
import Foundation

public enum DuoPosture: String, Codable, CaseIterable, Sendable {
    case iPhoneCompact      // <700pt, symmetric safe area -> 1-col stack + 56pt horizontal bottom dock
    case iPhoneSplit        // >=700pt, symmetric safe area (e.g., Pro Max 956x440) -> 2-col split + horizontal docks
    case duoClosed          // 466x678pt outer display, safeRight >= 64pt (~91pt, 170pt top reserve) -> 1-col + 52pt vertical DuoRail
    case duoHalfBook        // Book fold: left 462pt | 28..40pt hinge division | right 461pt + right DuoRail
    case duoHalfLaptop      // Tabletop fold: top display pane | hinge division | bottom controls/composer pane
    case duoOpen            // 951x669pt inner display, safeRight >= 64pt (84pt, 118pt top reserve) -> 2-col split (342|609 or 525|426) + hybrid bars
}

public enum NavigationPage: String, Codable, CaseIterable, Identifiable, Sendable {
    case chats, moments, memories, friends, you, menu
    public var id: String { rawValue }
}

public enum SidebarScope: String, Codable, CaseIterable, Identifiable, Sendable {
    case all, unread, direct, groups
    public var id: String { rawValue }
}

public enum ArtifactMode: String, Codable, Equatable, Sendable {
    case roomInfo
    case drawingBoard
}

public enum GlassAppearanceMode: String, Codable, CaseIterable, Sendable { case clear, tinted }
public enum ComposerGlowStyle: String, Codable, CaseIterable, Sendable { case ocean, dawn, aurora, off }
public enum BackdropPreset: String, Codable, CaseIterable, Sendable { case mist, dawn, mint, sand, ocean, dusk, dots, night }
public enum AppThemePreference: String, Codable, CaseIterable, Sendable { case system, light, dark }

public struct DuoLayoutMetrics: Equatable, Sendable {
    public let posture: DuoPosture
    public let viewportSize: CGSize
    public let safeAreaTop: CGFloat
    public let safeAreaBottom: CGFloat
    public let safeAreaLeft: CGFloat
    public let safeAreaRight: CGFloat
    public let hasRightSystemColumn: Bool       // safeRight >= 64 && abs(safeRight - safeLeft) > 8
    public let visibleColumnCount: Int          // 1 or 2
    public let leadingColumnWidth: CGFloat      // e.g. 342 on 951pt List|Thread; 525 on Thread|Details
    public let trailingColumnWidth: CGFloat     // e.g. 609 on 951pt List|Thread (525 content + 84 rail); 426 on Thread|Details
    public let threadContentWidth: CGFloat      // Constant 525pt on 951x669 Duo Open across both List|Thread & Thread|Details!
    public let hingeDivisionRect: CGRect?       // Non-nil in duoHalfBook / duoHalfLaptop
    public let railWidth: CGFloat               // 52pt when hasRightSystemColumn else 0
    public let railCenterFromRight: CGFloat     // 49pt
    public let railTopReserve: CGFloat          // 170pt closed portrait, 118pt open
    public static func compute(size: CGSize, safeTop: CGFloat, safeBottom: CGFloat, safeLeft: CGFloat, safeRight: CGFloat, activePairStartsAtThread: Bool, postureOverride: DuoPosture? = nil) -> DuoLayoutMetrics
}

public struct CuvenUser: Codable, Identifiable, Hashable, Sendable {
    public var id: String
    public var username: String
    public var display: String
    public var bio: String
    public var avatarURL: String?
    public var coverURL: String?
    public var dominantTintHex: String?
    public var isOnline: Bool
    public init(id: String, username: String, display: String, bio: String = "", avatarURL: String? = nil, coverURL: String? = nil, dominantTintHex: String? = nil, isOnline: Bool = false)
}

public enum RoomKind: String, Codable, Hashable, Sendable { case dm, group }

public struct Room: Codable, Identifiable, Hashable, Sendable {
    public var id: String
    public var kind: RoomKind
    public var title: String
    public var subtitle: String
    public var avatarURL: String?
    public var peerUserID: String?
    public var memberIDs: [String]
    public var lastMessagePreview: String
    public var lastMessageTimestamp: Int64
    public var unreadCount: Int
    public var isPinned: Bool
    public var isMuted: Bool
    public var isMarkedUnread: Bool
    public var isHidden: Bool
    public var backdrop: BackdropPreset?
}

public enum MessageKind: String, Codable, Hashable, Sendable {
    case text, image, drawing, sticker, voice, video, file, call, system
}

public enum MessageDeliveryState: String, Codable, Hashable, Sendable {
    case queued, sending, sent, delivered, read, revoked, failed
}

public struct MessageReaction: Codable, Hashable, Sendable {
    public var userID: String
    public var emoji: String // One of ["❤️", "😂", "👍", "😮", "😢", "🙏"]
}

public struct MessageEditEntry: Codable, Hashable, Sendable {
    public var text: String
    public var editedAt: Int64
}

public struct Message: Codable, Identifiable, Hashable, Sendable {
    public var id: String
    public var localID: String?
    public var roomID: String
    public var senderID: String
    public var senderDisplay: String
    public var kind: MessageKind
    public var text: String
    public var mediaURLs: [String]
    public var mediaWidth: Int?
    public var mediaHeight: Int?
    public var durationSeconds: Double?
    public var stickerID: String?
    public var stickerSet: String?
    public var stickerFormat: StickerFormat?
    public var replyToMessageID: String?
    public var highlightedKeywords: [String]
    public var mentions: [String]
    public var reactions: [MessageReaction]
    public var editCount: Int
    public var editHistory: [MessageEditEntry]
    public var deliveryState: MessageDeliveryState
    public var createdAt: Int64
}

public enum ContactStatus: String, Codable, Hashable, Sendable { case pendingOut, pendingIn, accepted, blocked, suggested }

public struct ContactItem: Codable, Identifiable, Hashable, Sendable {
    public var id: String { user.id }
    public var user: CuvenUser
    public var status: ContactStatus
    public var mutualNote: String?
}

public struct UserNote: Codable, Identifiable, Hashable, Sendable {
    public var id: String { userID }
    public var userID: String
    public var userDisplay: String
    public var avatarURL: String?
    public var text: String        // <= 60 chars, 24h TTL
    public var createdAt: Int64
}

public struct MomentMedia: Codable, Identifiable, Hashable, Sendable {
    public var id: String
    public var url: String
    public var isVideo: Bool
    public var width: Int
    public var height: Int
    public var altText: String?
    public var filterName: String?
}

public struct MomentComment: Codable, Identifiable, Hashable, Sendable {
    public var id: String
    public var authorID: String
    public var authorDisplay: String
    public var text: String
    public var createdAt: Int64
}

public struct MomentPost: Codable, Identifiable, Hashable, Sendable {
    public var id: String
    public var author: CuvenUser
    public var text: String
    public var media: [MomentMedia]
    public var audience: String          // "everyone" | "friends"
    public var commentPolicy: String     // "everyone" | "friends" | "off"
    public var taggedUserIDs: [String]
    public var likedUserIDs: [String]
    public var comments: [MomentComment]
    public var scheduledAt: Int64?
    public var createdAt: Int64
}

public struct MemoryItem: Codable, Identifiable, Hashable, Sendable {
    public var id: String
    public var kind: MessageKind         // .image, .video, .drawing
    public var mediaURL: String
    public var caption: String
    public var roomTitle: String
    public var monthKey: String          // e.g. "2026-11"
    public var createdAt: Int64
}

public enum StickerFormat: String, Codable, Hashable, Sendable { case staticWebP, videoWebM, animatedLottie }

public struct StickerItem: Codable, Identifiable, Hashable, Sendable {
    public var id: String
    public var setName: String
    public var emoji: String
    public var format: StickerFormat
    public var thumbURL: String
    public var assetURL: String
}

public struct StickerPack: Codable, Identifiable, Hashable, Sendable {
    public var id: String { name }
    public var name: String
    public var title: String
    public var format: StickerFormat
    public var stickers: [StickerItem]
}

public struct RoomInsight: Codable, Identifiable, Hashable, Sendable {
    public var id: String
    public var roomID: String
    public var summary: String
    public var actionChip: String?
    public var peerLocalTime: String?
    public var weatherSummary: String?
    public var temperatureText: String?
}

public enum CallPhase: String, Codable, Hashable, Sendable { case idle, outgoingRinging, incomingRinging, connecting, connected, unstable, ended }
public enum CallMediaKind: String, Codable, Hashable, Sendable { case audio, video }

public struct CallSession: Codable, Identifiable, Hashable, Sendable {
    public var id: String
    public var roomID: String
    public var peerDisplay: String
    public var peerAvatarURL: String?
    public var mediaKind: CallMediaKind
    public var phase: CallPhase
    public var isMuted: Bool
    public var isCameraEnabled: Bool
    public var isSpeakerEnabled: Bool
    public var isMinimizedPiP: Bool
    public var startedAt: Int64?
}

public struct UserPrefs: Codable, Hashable, Sendable {
    public var theme: AppThemePreference
    public var glassMode: GlassAppearanceMode
    public var composerGlow: ComposerGlowStyle
    public var defaultBackdrop: BackdropPreset
    public var callBackdrop: BackdropPreset
    public var sendReadReceipts: Bool
    public var smartAssistEnabled: Bool
    public var routineLearningEnabled: Bool
    public var use24HourTime: Bool
}

public struct AIRoutineHourBucket: Codable, Identifiable, Hashable, Sendable {
    public var hour: Int // 0..<24
    public var id: Int { hour }
    public var activityScore: Double // 0.0...1.0
}

public struct AIMemoryItem: Codable, Identifiable, Hashable, Sendable {
    public var id: String
    public var category: String
    public var detail: String
    public var updatedAt: Int64
}
```

### 5.2 `AppStore` Observable Coordinator (`ios/Cuven/Core/AppStore.swift`)
`worker_m3_core_network_store` MUST implement `@MainActor @Observable public final class AppStore`:
- **Published State**: `serverBaseURL: URL` (default `https://wechat.cuven.us`), `currentUser: CuvenUser?`, `isAuthenticated: Bool`, `isBootstrapping: Bool`, `authError: String?`, `rooms: [Room]`, `selectedSidebarScope: SidebarScope`, `selectedRoomID: String?`, `activeColumnIndex: Int` (`0...3`), `activeArtifactMode: ArtifactMode?`, `activePage: NavigationPage`, `messagesByRoom: [String: [Message]]`, `typingPreviewByRoom: [String: String]` (Honk live preview), `draftsByRoom: [String: String]`, `ghostSuggestionByRoom: [String: String]`, `replyTargetByRoom: [String: Message]`, `editingTargetByRoom: [String: Message]`, `contacts: [ContactItem]`, `suggestedPeople: [CuvenUser]`, `notes: [UserNote]`, `myNote: UserNote?`, `moments: [MomentPost]`, `memories: [MemoryItem]`, `stickerPacks: [StickerPack]`, `installedStickerPackNames: Set<String>`, `insightsByRoom: [String: RoomInsight]`, `prefs: UserPrefs`, `aiMemories: [AIMemoryItem]`, `aiRoutineBuckets: [AIRoutineHourBucket]`, `activeCall: CallSession?`, `postureOverride: DuoPosture?`, `recentAvatarURLs: [String]`, `activeBannerMessage: Message?`.
- **Canonical Action Methods**:
  - Auth: `signIn(username: String, password: String) async throws`, `register(username: String, password: String, display: String, inviteCode: String?) async throws`, `enterDemoMode()`, `signOut() async`
  - Navigation: `selectRoom(_ roomID: String?)`, `openArtifact(_ mode: ArtifactMode, for roomID: String)`, `closeArtifact()`, `navigateToPage(_ page: NavigationPage)`
  - Messaging: `sendText(_ text: String, in roomID: String) async`, `sendImages(_ imageDatas: [Data], caption: String?, in roomID: String) async`, `sendDrawing(pngData: Data, size: CGSize, in roomID: String) async`, `sendSticker(_ sticker: StickerItem, in roomID: String) async`, `sendVoice(wavData: Data, duration: Double, in roomID: String) async`, `toggleReaction(_ emoji: String, on messageID: String, in roomID: String) async`, `beginEditing(_ message: Message)`, `commitEdit(messageID: String, newText: String, in roomID: String) async`, `revokeMessage(messageID: String, in roomID: String) async`, `setReplyTarget(_ message: Message?, in roomID: String)`, `updateLiveTyping(_ text: String, in roomID: String)`, `toggleRoomPin(_ roomID: String)`, `toggleRoomMute(_ roomID: String)`, `toggleRoomUnread(_ roomID: String)`, `deleteOrHideRoom(_ roomID: String)`
  - Contacts/Notes/Rooms: `sendFriendRequest(usernameOrID: String) async`, `acceptFriendRequest(userID: String) async`, `dismissSuggestedPerson(userID: String)`, `createDirectChat(with userID: String) async -> String`, `createGroupChat(name: String, memberIDs: [String]) async -> String`, `publishNote(text: String) async`, `deleteMyNote() async`
  - Moments/Memories/Stickers: `publishMoment(text: String, media: [MomentMedia], audience: String, commentPolicy: String, taggedUserIDs: [String], scheduledAt: Int64?) async`, `toggleMomentLike(momentID: String) async`, `addMomentComment(momentID: String, text: String) async`, `deleteMoment(momentID: String) async`, `toggleStickerPackInstalled(_ packName: String)`
  - Smart AI: `refreshGhostSuggestion(for draft: String, in roomID: String) async`, `streamExplain(selectedText: String, context: String, followUpQuestion: String?) -> AsyncStream<String>`, `transcribeWAV(_ wav16kMonoData: Data) async throws -> String`, `clearAIMemory() async`
  - Calls: `startCall(in roomID: String, mediaKind: CallMediaKind)`, `acceptIncomingCall()`, `endOrDeclineCall()`, `toggleCallMute()`, `toggleCallCamera()`, `toggleCallSpeaker()`, `setCallMinimizedPiP(_ minimized: Bool)`
  - Settings/Profile: `updateProfile(display: String, bio: String, avatarData: Data?, coverData: Data?, dominantTintHex: String?) async`, `updatePreferences(_ newPrefs: UserPrefs) async`, `changePassword(current: String, next: String) async throws`

### 5.3 `DesignSystem` Shared API (`ios/Cuven/DesignSystem/`)
`worker_m4_design_system` MUST expose:
- `enum CuvenColors` (light/dark dynamic colors matching `tokens.css`: `paperBackground`, `elevatedSurface`, `inkPrimary`, `inkSecondary`, `outgoingBubble`, `outgoingBubbleText`, `incomingBubble`, `incomingBubbleText`, `sidebarBlue`, `onlineGreen`, `dangerRed`, `warningAmber`, `hairlineSeparator`)
- `enum CuvenFonts` (`clarinettaDisplay(size:weight:italic:)`, `cappedBody()`, `cappedTitle()`, `cappedCaption()` enforcing `DYNAMIC_TYPE_MAX = 21pt` on chrome)
- `View.cuvenLiquidGlass(mode: GlassAppearanceMode = .clear, cornerRadius: CGFloat = 28, interactiveBounce: Bool = false) -> some View` (uses iOS 26/27.1 `.glassEffect()` where available + specular rim & `Reduce Transparency` solid fallback)
- `enum CuvenSprings` (`stripSlide`, `sheetPresent`, `bubblePop`, `railMorph`, `pressBounce`, plus `VelocityProjector.project(velocity:decelerationRate:)`)
- `enum CuvenHaptics` (`lightTap()`, `selectionChanged()`, `softImpact()`, `rigidImpact()`, `success()`)
- `struct ComposerGlowView: View` (`init(style: ComposerGlowStyle, audioLevel: CGFloat = 0)`)
- `struct VoiceBeamView: View` (`init(rmsLevel: CGFloat, isRecording: Bool)`)
- `struct CuvenBackdropView: View` (`init(preset: BackdropPreset, customImageURL: String? = nil)`)
- `View.cuvenAdaptiveModal(isPresented: Binding<Bool>, metrics: DuoLayoutMetrics, tall: Bool = false, @ViewBuilder content: @escaping () -> some View) -> some View`
- `struct CuvenAvatarView: View` (`init(name: String, urlString: String?, size: CGFloat, isOnline: Bool = false)`)

### 5.4 Feature Root View Signatures (Wired by `worker_m5_duo_spatial_shell`)
Every feature worker MUST provide its exact root `View` initializer so `RootCoordinatorView` (`worker_m5`) compiles cleanly:
- **M6**: `public struct AuthRootView: View { public init(store: AppStore) }` & `public struct SidebarColumnView: View { public init(store: AppStore, metrics: DuoLayoutMetrics) }`
- **M7**: `public struct ChatListColumnView: View { public init(store: AppStore, metrics: DuoLayoutMetrics) }` & `public struct FriendRequestsAndPeopleSheet: View { public init(store: AppStore) }`
- **M8**: `public struct ConversationColumnView: View { public init(store: AppStore, roomID: String, metrics: DuoLayoutMetrics, panLeadOffset: CGFloat = 0, onBack: @escaping () -> Void) }` & `public struct WordPickerExplainSheet: View { public init(store: AppStore, initialText: String, roomContext: String) }`
- **M9**: `public struct MomentsRootView: View { public init(store: AppStore, metrics: DuoLayoutMetrics, onClose: @escaping () -> Void) }`
- **M10**: `public struct ArtifactColumnView: View { public init(store: AppStore, roomID: String, mode: ArtifactMode, metrics: DuoLayoutMetrics, onClose: @escaping () -> Void) }`, `public struct StickerPickerDrawerView: View { public init(store: AppStore, onSelect: @escaping (StickerItem) -> Void) }`, `public struct MemoriesRootView: View { public init(store: AppStore, metrics: DuoLayoutMetrics, onClose: @escaping () -> Void) }`, `public struct FullscreenMediaLightboxView: View { public init(mediaURLs: [String], initialIndex: Int, onDismiss: @escaping () -> Void) }`
- **M11**: `public struct CallOverlayContainerView: View { public init(store: AppStore, metrics: DuoLayoutMetrics) }`
- **M12**: `public struct SettingsRootSheet: View { public init(store: AppStore, initialTab: String? = nil) }` & `public struct ProfileAvatarCoverEditorSheet: View { public init(store: AppStore) }`

### 5.5 Launch Arguments & Accessibility Identifiers for Opaque-Box E2E Testing
To enable deterministic `XCUITest` execution across all postures and offline/CI environments without modifying code:
- Launch Arguments honored by `CuvenApp` / `AppStore`:
  - `--uitest-demo`: Boots straight into authenticated rich Demo dataset with deterministic seed contacts, chats, Moments, Memories, Notes, Insights, and Stickers.
  - `--uitest-logged-out`: Boots at `AuthRootView`.
  - `--uitest-posture=<iPhoneCompact|iPhoneSplit|duoClosed|duoHalfBook|duoHalfLaptop|duoOpen>`: Pins initial `postureOverride` for deterministic viewport/posture verification alongside native `iPhone Duo` Simulator traits.
- Key Accessibility Identifiers:
  - `auth.wordmark`, `auth.username`, `auth.password`, `auth.submit`, `auth.demoButton`, `auth.inviteCodeTrack`
  - `shell.strip`, `shell.bottomDock`, `shell.duoRail`, `shell.pagesCapsule`, `shell.postureSwitcher`
  - `sidebar.scope.all`, `sidebar.scope.unread`, `sidebar.scope.direct`, `sidebar.scope.groups`, `sidebar.moments`, `sidebar.memories`
  - `chatlist.notesStrip`, `chatlist.insightsDeck`, `chatlist.pinnedGrid`, `chatlist.searchButton`, `chatlist.newChatButton`, `chatlist.row.<roomID>`
  - `thread.headerPill`, `thread.backButton`, `thread.messageList`, `thread.composerField`, `thread.sendButton`, `thread.micButton`, `thread.plusButton`, `thread.stickerButton`, `thread.drawButton`, `thread.callAudioButton`, `thread.callVideoButton`
  - `moments.feed`, `moments.composeButton`, `moments.editor.publishButton`, `moments.editor.filterStrip`, `moments.editor.altButton`
  - `artifact.drawingCanvas`, `artifact.roomInfo`, `memories.grid`, `memories.flashbackPlay`, `call.activeOverlay`, `call.pipTile`, `settings.root`, `settings.avatarEditorButton`, `settings.aiMemoryButton`

---

## 6. Exclusive Code Layout (STRICT WRITE OWNERSHIP — ZERO OVERLAP)
```text
/home/antigravity/yujielab/WeChat/
├── docs/ios-hig-27.2-reference.md          # Owned by worker_m1_hig_docs_r3 (+ synced ios-hig-27.1-reference.md)
├── .gitignore & .git/info/exclude          # Owned by worker_m2_xcode_ci_scaffolding (.agents/ MUST be excluded!)
├── .github/workflows/ios-ipa-ci.yml        # Owned by worker_m2_xcode_ci_scaffolding (runs-on: xcode-27, Xcode_27.2.app, iphoneos27.2)
├── ios/
│   ├── project.yml                         # Owned by worker_m2_xcode_ci_scaffolding
│   ├── scripts/                            # Owned by worker_m2_xcode_ci_scaffolding (except run-e2e-suite.sh -> E2E track)
│   ├── Packages/CuvenCore/                 # Owned by worker_m3_core_network_store
│   ├── Cuven/
│   │   ├── Info.plist & Resources/         # Owned by worker_m2_xcode_ci_scaffolding
│   │   ├── Core/                           # Owned by worker_m3_core_network_store
│   │   ├── DesignSystem/                   # Owned by worker_m4_design_system
│   │   ├── App/ & Layout/                  # Owned by worker_m5_duo_spatial_shell
│   │   └── Features/
│   │       ├── Auth/ & Sidebar/            # Owned by worker_m6_auth_sidebar_guides
│   │       ├── ChatList/                   # Owned by worker_m7_chatlist_notes_insights
│   │       ├── Thread/ & SmartAI/          # Owned by worker_m8_thread_composer_ai
│   │       ├── Moments/                    # Owned by worker_m9_moments_profile_editor
│   │       ├── Artifact/, Stickers/, Memories/ # Owned by worker_m10_drawing_stickers_memories
│   │       ├── Calls/                      # Owned by worker_m11_webrtc_calls_pip
│   │       └── Settings/                   # Owned by worker_m12_settings_avatar_unit_tests
│   ├── CuvenTests/                         # Owned by worker_m12_settings_avatar_unit_tests
│   └── CuvenUITests/                       # Owned by test_writer_e2e_suite
└── dist/Cuven.ipa & dist/WeChat.ipa        # Produced & verified by CI download in M13 (`sdk 27.2`, gitignored)
```
