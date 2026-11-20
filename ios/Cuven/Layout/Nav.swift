import SwiftUI

/// The four columns, in the order they sit on the strip (ui/strip.js).
enum Column: Int, CaseIterable, Comparable {
    case sidebar = 0, list, chat, detail
    static func < (a: Column, b: Column) -> Bool { a.rawValue < b.rawValue }
}

enum DetailKind: Equatable {
    case info
    case draw
}

/// The pages of the capsule (ui/pages.js): Chats and Menu are the strip;
/// the rest open over it.
enum Page: String, CaseIterable, Identifiable {
    case chats, moments, memories, friends, me
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
    var sym: Sym {
        switch self {
        case .all: return .bubble
        case .unread: return .unread
        case .direct: return .person
        case .groups: return .people
        }
    }
}

/// Closed (the outer display), half (partly open like a book: two equal
/// panes at the fold) or open flat (navigation narrow, conversation wide).
enum Posture: String {
    case closed, half, flat
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
    var page: Page = .chats
    var filter: ListFilter = .all
    var searching = false

    // Overlays
    var viewer: ViewerItem?
    var profile: String?
    var settingsOpen = false
    var composeMoment = false
    var noteEditor = false
    var openNote: FriendNote?
    var newGroup = false

    var visibleColumns: [Column] {
        (0..<columns).compactMap { Column(rawValue: leading.rawValue + $0) }
    }

    func isVisible(_ c: Column) -> Bool { visibleColumns.contains(c) }
    var rightmost: Column { visibleColumns.last ?? leading }

    /// A sheet is up over the strip (the page capsule stays, the strip recedes).
    var sheeted: Bool { page != .chats || settingsOpen || profile != nil }

    func setColumns(_ n: Int) {
        guard n != columns else { return }
        columns = n
        if n == 1 {
            leading = active
        } else {
            switch active {
            case .sidebar: leading = .sidebar
            case .detail: leading = .chat
            default: leading = .list
            }
        }
        let maxLead = Column.allCases.count - columns
        if leading.rawValue > maxLead { leading = Column(rawValue: maxLead)! }
    }

    func go(_ change: () -> Void) {
        withAnimation(Motion.move) { change() }
    }

    func open(room id: String) {
        go {
            if room != id { detail = nil }
            room = id
            page = .chats
            active = .chat
            leading = columns == 1 ? .chat : (detail != nil ? .chat : .list)
            searching = false
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

    func toSidebar() {
        go {
            page = .chats
            active = .sidebar
            leading = .sidebar
        }
    }

    func toList(filter f: ListFilter? = nil) {
        go {
            if let f { filter = f }
            page = .chats
            active = .list
            leading = .list
        }
    }

    /// The edge swipe and the window's own back: one column toward the start.
    var canGoBack: Bool {
        if columns == 1 { return active != .sidebar }
        return leading != .sidebar
    }

    func back() {
        if columns == 1 {
            switch active {
            case .detail: closeDetail()
            case .chat: backFromChat()
            case .list: toSidebar()
            case .sidebar: break
            }
        } else {
            switch leading {
            case .chat: closeDetail()
            case .list: toSidebar()
            default: break
            }
        }
        Haptics.tap()
    }

    /// The capsule: the new page fades in where the old one fades out.
    func switchPage(_ p: Page) {
        if p == .chats {
            withAnimation(Motion.move) {
                page = .chats
                if active == .sidebar { active = .list; leading = .list }
            }
        } else {
            withAnimation(.easeInOut(duration: 0.24)) { page = p }
        }
        Haptics.selection()
    }

    func menu() {
        withAnimation(Motion.move) {
            page = .chats
            active = .sidebar
            leading = .sidebar
        }
        Haptics.selection()
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

    /// Controls stand in the system's column on the trailing edge (iPhone Duo).
    var usesRail: Bool { rail != nil && isRightmost }
    /// Where content stops on the trailing side: the column, or the margin.
    var trailingContent: CGFloat { insets.trailing }
}

private struct ColumnContextKey: EnvironmentKey {
    static let defaultValue = ColumnContext()
}

extension EnvironmentValues {
    var column: ColumnContext {
        get { self[ColumnContextKey.self] }
        set { self[ColumnContextKey.self] = newValue }
    }
}
