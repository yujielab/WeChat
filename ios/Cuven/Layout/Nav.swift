import SwiftUI

/// The three columns, in the order they sit on the strip: the list, the
/// conversation, and its details (or drawing board).
enum Column: Int, CaseIterable, Comparable {
    case list = 0, chat, detail
    static func < (a: Column, b: Column) -> Bool { a.rawValue < b.rawValue }
}

enum DetailKind: Equatable {
    case info
    case draw
}

/// The pages of the capsule (ui/pages.js): Chats and Menu are the strip;
/// the rest open over it.
enum Page: String, CaseIterable, Identifiable {
    case chats, moments, friends, me
    var id: String { rawValue }
}

enum ListFilter: String, CaseIterable, Identifiable {
    case all, unread, direct, groups
    var id: String { rawValue }
    var title: LocalizedStringKey {
        switch self {
        case .all: return "All"
        case .unread: return "Unread"
        case .direct: return "Direct"
        case .groups: return "Groups"
        }
    }
}

/// Closed (the outer display), half (partly open like a book: two equal
/// panes at the fold) or open flat (navigation narrow, conversation wide).
enum Posture: String {
    case closed, half, flat
}

/// Someone's page on the stack. Each push has its own key, so the same
/// person twice (A, then B, then A) is two pages.
struct ProfileEntry: Hashable {
    let id: String
    let key: Int
}

struct ViewerItem: Identifiable, Equatable {
    var id: String { path }
    var path: String
    var aspect: CGFloat
    var source: CGRect
    var isVideo = false
    var caption: String = ""
}

/// Where the window on the strip stands and what each column holds. The
/// window moves one column forward or back; folding or unfolding keeps the
/// column in use on screen.
@MainActor
@Observable
final class Nav {
    var room: String?
    var detail: DetailKind?
    var active: Column = .list
    var leading: Column = .list
    var columns = 1
    var page: Page = .chats {
        didSet {
            guard page != oldValue else { return }
            if page != .chats && !visited.contains(page) { visited.insert(page) }
            // The page left stays mounted (kept as you left it), so a field
            // in it would hold the keyboard up over the next one: it lets
            // go, as on iOS when the tab changes.
            UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        }
    }
    /// The tab pages opened so far: each stays as you left it (its scroll,
    /// its search) while another tab shows.
    private(set) var visited: Set<Page> = []
    var filter: ListFilter = .all
    var searching = false

    // Overlays
    var viewer: ViewerItem?
    /// Someone's page, one over another: a name on one page pushes the next
    /// over it, and Back returns to the one before (iOS's push stack).
    private(set) var profiles: [ProfileEntry] = []
    @ObservationIgnored private var profileKey = 0
    /// The page on top. Setting someone pushes their page (unless it's
    /// already on top); nil closes them all.
    var profile: String? {
        get { profiles.last?.id }
        set {
            guard let id = newValue else {
                if !profiles.isEmpty { profiles.removeAll() }
                return
            }
            guard profiles.last?.id != id else { return }
            profileKey += 1
            profiles.append(ProfileEntry(id: id, key: profileKey))
            // A few deep at most: the oldest, long out of sight, goes.
            if profiles.count > 8 { profiles.removeFirst() }
        }
    }
    /// Back from someone's page to the one under it, or to where it was
    /// opened from (the caller animates, as with the other pages).
    func popProfile() {
        if !profiles.isEmpty { profiles.removeLast() }
    }
    var settingsOpen = false
    var composeMoment = false
    var noteEditor = false
    var openNote: FriendNote?
    var newGroup = false
    var editingProfile = false
    var changingPassword = false
    /// Asks the moment being written to close as its own Cancel does: at
    /// once when there's nothing in it, after asking when there is
    /// (MomentEditor answers it). Nav never closes the editor itself.
    var composeCloseRequest = 0

    var visibleColumns: [Column] {
        (0..<columns).compactMap { Column(rawValue: leading.rawValue + $0) }
    }

    func isVisible(_ c: Column) -> Bool { visibleColumns.contains(c) }
    var rightmost: Column { visibleColumns.last ?? leading }

    /// A page pushed over everything (no page capsule): settings, someone's
    /// page, the editors.
    var pushed: Bool { settingsOpen || !profiles.isEmpty || editingProfile || changingPassword || newGroup || composeMoment }
    /// How many pages are pushed, one over another.
    var pushCount: Int {
        profiles.count + [settingsOpen, editingProfile, changingPassword, newGroup, composeMoment].filter { $0 }.count
    }
    /// A task (a new moment, a new chat, your profile, a new password) is on
    /// top: it rose from the foot as a modal, so nothing under it steps
    /// sideways as it would under a push.
    var modalOnTop: Bool { composeMoment || newGroup || editingProfile || changingPassword }
    /// How far the top pushed page has been dragged back toward the trailing
    /// edge (the swipe back): what's under it follows.
    var pushDrag: CGFloat = 0
    /// A full-screen page covers the strip (a capsule page or a pushed one).
    var covered: Bool { page != .chats || pushed }
    /// A small card over the app (a note), the app receding behind it.
    var dialogUp: Bool { noteEditor || openNote != nil }
    /// Anything over the strip: it takes no touches and its rail steps aside.
    var sheeted: Bool { covered || dialogUp }

    /// Closes the topmost page or card (a moment being written is asked to,
    /// so it can ask before anything in it is lost).
    func closeTop() {
        withAnimation(Motion.move) {
            if noteEditor { noteEditor = false }
            else if openNote != nil { openNote = nil }
            else if composeMoment { composeCloseRequest += 1 }
            else if newGroup { newGroup = false }
            else if changingPassword { changingPassword = false }
            else if editingProfile { editingProfile = false }
            else if settingsOpen { settingsOpen = false }
            else if !profiles.isEmpty { profiles.removeLast() }
        }
    }

    func setColumns(_ n: Int) {
        guard n != columns else { return }
        columns = n
        if n == 1 {
            leading = active
        } else {
            leading = active == .detail ? .chat : .list
        }
        let maxLead = Column.allCases.count - columns
        if leading.rawValue > maxLead { leading = Column(rawValue: maxLead)! }
    }

    func go(_ change: () -> Void) {
        withAnimation(Motion.move) { change() }
    }

    /// The photo and the cards, which stand over the pages: closed before
    /// a page opens from outside, or it would open under them.
    func clearCards() {
        viewer = nil
        noteEditor = false
        openNote = nil
    }

    /// A way in from outside (a notification, Spotlight, Siri, Handoff, a
    /// link) or a shortcut: the photo, the cards and the pushed pages close,
    /// so what it opens shows. A moment being written isn't thrown away:
    /// it's asked to close, and asks first if there's something in it.
    func clearOverlays() {
        withAnimation(Motion.move) {
            clearCards()
            profile = nil
            settingsOpen = false
            editingProfile = false
            changingPassword = false
            newGroup = false
            if composeMoment { composeCloseRequest += 1 }
        }
    }

    func open(room id: String, keepSearch: Bool = false) {
        // The details stay only if they were on screen, not when they were
        // left behind as the list came back.
        let wasDetail = isVisible(.detail)
        go {
            // Whatever stands over the strip closes, so the chat shows (and is read).
            clearOverlays()
            if room != id { detail = nil }
            room = id
            page = .chats
            active = .chat
            leading = columns == 1 ? .chat : (detail != nil && wasDetail ? .chat : .list)
            if !keepSearch { searching = false }
        }
    }

    func show(_ kind: DetailKind) {
        go {
            detail = kind
            active = .detail
            leading = columns == 1 ? .detail : .chat
        }
    }

    func closeDetail() {
        go {
            active = .chat
            leading = columns == 1 ? .chat : .list
        }
        Task {
            try? await Task.sleep(for: .milliseconds(420))
            if active != .detail { detail = nil }
        }
    }

    func backFromChat() {
        go {
            active = .list
            leading = .list
        }
    }

    func toList() {
        go {
            page = .chats
            active = .list
            leading = .list
        }
    }

    /// The edge swipe and the window's own back: one column toward the start.
    var canGoBack: Bool {
        if columns == 1 { return active != .list }
        return leading != .list
    }

    func back() {
        if columns == 1 {
            switch active {
            case .detail: closeDetail()
            case .chat: backFromChat()
            case .list: break
            }
        } else {
            switch leading {
            case .chat: closeDetail()
            default: break
            }
        }
    }

    /// The tabs: the new page fades in where the old one fades out (no
    /// slide: tabs are peers). Chats comes back to where you left it.
    func switchPage(_ p: Page) {
        withAnimation(Motion.fade) { page = p }
    }
}

// MARK: - Column context: insets and where the controls go

struct RailMetrics: Equatable {
    var width: CGFloat
    var top: CGFloat
    var centerFromEdge: CGFloat
}

struct ColumnContext: Equatable {
    var column: Column = .list
    var insets: EdgeInsets = EdgeInsets()
    var isLeftmost = true
    var isRightmost = true
    var rail: RailMetrics?
    var size: CGSize = .zero
    var twoUp = false
    var keyboard: CGFloat = 0
    /// Room the page capsule takes at the foot of the system column (with its gap), when it shows.
    var capsule: CGFloat = 0
    /// A full-screen page's own context (its rail shows while the strip's step aside).
    var onPage = false
    /// The device puts its controls in a system column (iPhone Duo), even
    /// when that column belongs to the pane beside this one.
    var systemColumn = false

    /// Controls stand in the system's column on the trailing edge (iPhone Duo).
    var usesRail: Bool { rail != nil && isRightmost }
    /// Where content stops on the trailing side: the column, or the margin.
    var trailingContent: CGFloat { insets.trailing }
}

private struct ColumnContextKey: EnvironmentKey {
    static let defaultValue = ColumnContext()
}

private struct ContentCoveredKey: EnvironmentKey {
    static let defaultValue = false
}

private struct PageTabKey: EnvironmentKey {
    static let defaultValue: Page? = nil
}

extension EnvironmentValues {
    var column: ColumnContext {
        get { self[ColumnContextKey.self] }
        set { self[ColumnContextKey.self] = newValue }
    }
    /// Something covers this content (a page over it, or it's a tab page
    /// that isn't showing): video and animation hold still.
    var contentCovered: Bool {
        get { self[ContentCoveredKey.self] }
        set { self[ContentCoveredKey.self] = newValue }
    }
    /// The tab whose page this is (nil off the tab pages): tapping that tab
    /// again takes this page, and only this one, back to the top.
    var pageTab: Page? {
        get { self[PageTabKey.self] }
        set { self[PageTabKey.self] = newValue }
    }
}
