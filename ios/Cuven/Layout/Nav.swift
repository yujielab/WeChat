import SwiftUI

/// The four columns, in the order they sit on the strip.
enum Column: Int, CaseIterable, Comparable {
    case sidebar = 0, list, chat, detail
    static func < (a: Column, b: Column) -> Bool { a.rawValue < b.rawValue }
    var previous: Column? { Column(rawValue: rawValue - 1) }
}

enum DetailKind: Equatable {
    case info
    case draw
}

enum Page: String, CaseIterable, Identifiable {
    case chats, moments, memories, requests, me
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
    var symbol: String {
        switch self {
        case .all: return "bubble.left.and.bubble.right"
        case .unread: return "circlebadge"
        case .direct: return "person"
        case .groups: return "person.2"
        }
    }
}

enum Posture: String {
    /// Folded: the outer display, one column.
    case closed
    /// Partially folded like a book: two equal panes, one each side of the fold.
    case book
    /// Open flat: navigation narrow (about a third), conversation wide.
    case flat
}

struct ViewerItem: Identifiable, Equatable {
    var id: String { path }
    var path: String
    var aspect: CGFloat
    var source: CGRect
    var isVideo = false
    var caption: String = ""
}

/// Where the window on the strip is and what each column holds. The strip
/// moves one column forward or back; folding and unfolding keep the column
/// in use on screen (README: 一条横向的栏带).
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
    var newChatOpen = false
    var composeMoment = false
    var noteEditor = false
    var openNote: FriendNote?

    var visibleColumns: [Column] {
        (0..<columns).compactMap { Column(rawValue: leading.rawValue + $0) }
    }

    func isVisible(_ c: Column) -> Bool { visibleColumns.contains(c) }

    var rightmost: Column { visibleColumns.last ?? leading }

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
        clampLeading()
    }

    private func clampLeading() {
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
            try? await Task.sleep(for: .milliseconds(450))
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

    func switchPage(_ p: Page) {
        guard p != page else {
            if p == .chats { toList() }
            return
        }
        withAnimation(.easeInOut(duration: 0.24)) { page = p }
        Haptics.selection()
    }
}

// MARK: - Column context (insets and where the controls go)

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

    /// Controls go in the system column on the trailing edge (iPhone Duo).
    var usesRail: Bool { rail != nil && isRightmost }
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
