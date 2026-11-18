import XCTest

// MARK: - Public Launch Postures (PROJECT.md § 5.1 & § 5.5)

enum UITestPosture: String, CaseIterable, Sendable {
    case iPhoneCompact
    case iPhoneSplit
    case duoClosed
    case duoHalfBook
    case duoHalfLaptop
    case duoOpen

    var displayCandidates: [String] {
        switch self {
        case .iPhoneCompact:
            return ["iPhoneCompact", "iPhone Compact", "Compact", "紧凑", "iPhone"]
        case .iPhoneSplit:
            return ["iPhoneSplit", "iPhone Split", "Split", "横屏分栏"]
        case .duoClosed:
            return ["duoClosed", "Duo Closed", "Closed", "合上", "折叠", "Outer"]
        case .duoHalfBook:
            return ["duoHalfBook", "Duo Half Book", "Half Book", "Book", "书本", "半开"]
        case .duoHalfLaptop:
            return ["duoHalfLaptop", "Duo Half Laptop", "Half Laptop", "Laptop", "Tabletop", "笔记本"]
        case .duoOpen:
            return ["duoOpen", "Duo Open", "Open", "展开", "Inner"]
        }
    }

    var expectsRightDuoRail: Bool {
        switch self {
        case .duoClosed, .duoHalfBook, .duoOpen:
            return true
        case .iPhoneCompact, .iPhoneSplit, .duoHalfLaptop:
            return false
        }
    }

    var expectsTwoColumns: Bool {
        switch self {
        case .iPhoneSplit, .duoHalfBook, .duoOpen:
            return true
        case .iPhoneCompact, .duoClosed, .duoHalfLaptop:
            return false
        }
    }
}

// MARK: - Canonical Public Accessibility Identifiers (PROJECT.md § 5.5)

enum CuvenAID {
    enum LaunchArg {
        static let demo = "--uitest-demo"
        static let loggedOut = "--uitest-logged-out"
        static func posture(_ posture: UITestPosture) -> String {
            "--uitest-posture=\(posture.rawValue)"
        }
    }

    enum Auth {
        static let wordmark = "auth.wordmark"
        static let username = "auth.username"
        static let password = "auth.password"
        static let submit = "auth.submit"
        static let demoButton = "auth.demoButton"
        static let inviteCodeTrack = "auth.inviteCodeTrack"
    }

    enum Shell {
        static let strip = "shell.strip"
        static let bottomDock = "shell.bottomDock"
        static let duoRail = "shell.duoRail"
        static let pagesCapsule = "shell.pagesCapsule"
        static let postureSwitcher = "shell.postureSwitcher"
    }

    enum Sidebar {
        static let scopeAll = "sidebar.scope.all"
        static let scopeUnread = "sidebar.scope.unread"
        static let scopeDirect = "sidebar.scope.direct"
        static let scopeGroups = "sidebar.scope.groups"
        static let moments = "sidebar.moments"
        static let memories = "sidebar.memories"
    }

    enum ChatList {
        static let notesStrip = "chatlist.notesStrip"
        static let insightsDeck = "chatlist.insightsDeck"
        static let pinnedGrid = "chatlist.pinnedGrid"
        static let searchButton = "chatlist.searchButton"
        static let newChatButton = "chatlist.newChatButton"
        static let rowPrefix = "chatlist.row."
    }

    enum Thread {
        static let headerPill = "thread.headerPill"
        static let backButton = "thread.backButton"
        static let messageList = "thread.messageList"
        static let composerField = "thread.composerField"
        static let sendButton = "thread.sendButton"
        static let micButton = "thread.micButton"
        static let plusButton = "thread.plusButton"
        static let stickerButton = "thread.stickerButton"
        static let drawButton = "thread.drawButton"
        static let callAudioButton = "thread.callAudioButton"
        static let callVideoButton = "thread.callVideoButton"
    }

    enum Moments {
        static let feed = "moments.feed"
        static let composeButton = "moments.composeButton"
        static let editorPublishButton = "moments.editor.publishButton"
        static let editorFilterStrip = "moments.editor.filterStrip"
        static let editorAltButton = "moments.editor.altButton"
    }

    enum Artifact {
        static let drawingCanvas = "artifact.drawingCanvas"
        static let roomInfo = "artifact.roomInfo"
    }

    enum Memories {
        static let grid = "memories.grid"
        static let flashbackPlay = "memories.flashbackPlay"
    }

    enum Call {
        static let activeOverlay = "call.activeOverlay"
        static let pipTile = "call.pipTile"
    }

    enum Settings {
        static let root = "settings.root"
        static let avatarEditorButton = "settings.avatarEditorButton"
        static let aiMemoryButton = "settings.aiMemoryButton"
    }
}

// MARK: - SwiftUI Container-Type Agnostic Element Lookup (PROJECT.md § 5.5)

extension XCUIApplication {
    /// Resolves any element matching `accessibilityIdentifier == id` regardless of how SwiftUI
    /// surfaces the view in UIAccessibility (`buttons`, `otherElements`, `textFields`, `textViews`,
    /// `staticTexts`, `scrollViews`, `switches`, etc.).
    @MainActor
    func cuvenElement(_ id: String) -> XCUIElement {
        descendants(matching: .any).matching(identifier: id).firstMatch
    }

    /// Resolves `cuvenElement(id)` and waits up to `timeout` seconds for existence.
    @MainActor
    @discardableResult
    func waitForCuvenElement(
        _ id: String,
        timeout: TimeInterval = CuvenUITestCase.defaultTimeout
    ) -> XCUIElement {
        let match = cuvenElement(id)
        _ = match.waitForExistence(timeout: timeout)
        return match
    }
}

// MARK: - Opaque-Box Base Test Case

class CuvenUITestCase: XCTestCase {

    nonisolated static let defaultTimeout: TimeInterval = 8.0
    nonisolated static let shortTimeout: TimeInterval = 3.0

    override func setUpWithError() throws {
        try super.setUpWithError()
        continueAfterFailure = false
    }

    // MARK: Launch Helpers

    @MainActor
    @discardableResult
    func launchDemo(
        posture: UITestPosture? = nil,
        extraArguments: [String] = [],
        environment: [String: String] = [:],
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> XCUIApplication {
        let app = XCUIApplication()
        var args = [CuvenAID.LaunchArg.demo]
        if let posture {
            args.append(CuvenAID.LaunchArg.posture(posture))
        }
        args.append(contentsOf: extraArguments)
        app.launchArguments = args
        for (k, v) in environment {
            app.launchEnvironment[k] = v
        }
        app.launch()

        let strip = app.cuvenElement(CuvenAID.Shell.strip)
        XCTAssertTrue(
            strip.waitForExistence(timeout: Self.defaultTimeout),
            "Authenticated shell (\(CuvenAID.Shell.strip)) must appear when launched with \(CuvenAID.LaunchArg.demo)",
            file: file,
            line: line
        )
        dismissOnboardingGuideIfPresent(in: app)
        return app
    }

    @MainActor
    @discardableResult
    func launchLoggedOut(
        posture: UITestPosture? = nil,
        extraArguments: [String] = [],
        environment: [String: String] = [:],
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> XCUIApplication {
        let app = XCUIApplication()
        var args = [CuvenAID.LaunchArg.loggedOut]
        if let posture {
            args.append(CuvenAID.LaunchArg.posture(posture))
        }
        args.append(contentsOf: extraArguments)
        app.launchArguments = args
        for (k, v) in environment {
            app.launchEnvironment[k] = v
        }
        app.launch()

        let wordmark = app.cuvenElement(CuvenAID.Auth.wordmark)
        XCTAssertTrue(
            wordmark.waitForExistence(timeout: Self.defaultTimeout),
            "Auth screen (\(CuvenAID.Auth.wordmark)) must appear when launched with \(CuvenAID.LaunchArg.loggedOut)",
            file: file,
            line: line
        )
        return app
    }

    // MARK: Element Queries (Container-Type Agnostic for SwiftUI Accessibility Hierarchy)

    @MainActor
    func element(id: String, in app: XCUIApplication) -> XCUIElement {
        app.cuvenElement(id)
    }

    @MainActor
    func elementsWithPrefix(_ prefix: String, in app: XCUIApplication) -> XCUIElementQuery {
        let predicate = NSPredicate(format: "identifier BEGINSWITH %@", prefix)
        return app.descendants(matching: .any).matching(predicate)
    }

    @MainActor
    func elementMatchingAnyLabel(
        _ candidates: [String],
        in app: XCUIApplication
    ) -> XCUIElement {
        for candidate in candidates {
            let exact = app.buttons[candidate]
            if exact.exists { return exact }
        }
        var subpredicates: [NSPredicate] = []
        for candidate in candidates {
            subpredicates.append(NSPredicate(format: "label CONTAINS[cd] %@", candidate))
            subpredicates.append(NSPredicate(format: "identifier CONTAINS[cd] %@", candidate))
        }
        let compound = NSCompoundPredicate(orPredicateWithSubpredicates: subpredicates)
        let buttonMatch = app.buttons.matching(compound).firstMatch
        if buttonMatch.exists { return buttonMatch }
        return app.descendants(matching: .any).matching(compound).firstMatch
    }

    @MainActor
    func chatRows(in app: XCUIApplication) -> XCUIElementQuery {
        elementsWithPrefix(CuvenAID.ChatList.rowPrefix, in: app)
    }

    @MainActor
    func firstChatRow(
        in app: XCUIApplication,
        timeout: TimeInterval = CuvenUITestCase.defaultTimeout,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> XCUIElement {
        let row = chatRows(in: app).firstMatch
        XCTAssertTrue(
            row.waitForExistence(timeout: timeout),
            "Expected at least one chat row matching prefix '\(CuvenAID.ChatList.rowPrefix)'",
            file: file,
            line: line
        )
        return row
    }

    // MARK: Synchronization & Waits

    @MainActor
    @discardableResult
    func waitForDisappearance(
        of target: XCUIElement,
        timeout: TimeInterval = CuvenUITestCase.defaultTimeout
    ) -> Bool {
        if !target.exists { return true }
        let predicate = NSPredicate(format: "exists == false")
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: target)
        let result = XCTWaiter().wait(for: [expectation], timeout: timeout)
        return result == .completed
    }

    @MainActor
    func settleUI(seconds: TimeInterval = 0.35) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }

    // MARK: Resilient Interaction Helpers

    @MainActor
    func tapSafely(
        _ target: XCUIElement,
        timeout: TimeInterval = CuvenUITestCase.defaultTimeout,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertTrue(
            target.waitForExistence(timeout: timeout),
            "Element '\(target.identifier)' should exist before tapping",
            file: file,
            line: line
        )
        if target.isHittable {
            target.tap()
        } else {
            let center = target.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            center.tap()
        }
    }

    @MainActor
    func focusAndType(
        _ text: String,
        into target: XCUIElement,
        clearExisting: Bool = false,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertTrue(
            target.waitForExistence(timeout: Self.defaultTimeout),
            "Input element '\(target.identifier)' must exist before typing",
            file: file,
            line: line
        )

        let actualInput: XCUIElement = {
            if target.elementType == .textField ||
                target.elementType == .secureTextField ||
                target.elementType == .textView ||
                target.elementType == .searchField {
                return target
            }
            let childTextField = target.textFields.firstMatch
            if childTextField.exists { return childTextField }
            let childSecure = target.secureTextFields.firstMatch
            if childSecure.exists { return childSecure }
            let childTextView = target.textViews.firstMatch
            if childTextView.exists { return childTextView }
            return target
        }()

        tapSafely(actualInput, file: file, line: line)
        settleUI(seconds: 0.15)

        if clearExisting, let current = actualInput.value as? String, !current.isEmpty {
            let placeholder = actualInput.placeholderValue ?? ""
            if current != placeholder {
                let deleteSeq = String(repeating: XCUIKeyboardKey.delete.rawValue, count: min(current.count + 4, 120))
                actualInput.typeText(deleteSeq)
            }
        }

        if !text.isEmpty {
            actualInput.typeText(text)
        }
    }

    @MainActor
    func textValue(of target: XCUIElement) -> String {
        if let direct = target.value as? String, !direct.isEmpty {
            let placeholder = target.placeholderValue ?? ""
            if direct != placeholder {
                return direct
            }
        }
        for child in [target.textViews.firstMatch, target.textFields.firstMatch] where child.exists {
            if let val = child.value as? String {
                let placeholder = child.placeholderValue ?? ""
                if val != placeholder {
                    return val
                }
            }
        }
        return (target.value as? String) ?? ""
    }

    @MainActor
    func dismissOnboardingGuideIfPresent(in app: XCUIApplication) {
        let idCandidates = [
            "welcome.skipButton", "sidebar.guideDismissButton", "guide.dismiss", "guide.skip"
        ]
        for id in idCandidates {
            let el = app.cuvenElement(id)
            if el.exists && el.isHittable {
                el.tap()
                settleUI(seconds: 0.2)
                return
            }
        }
        let labelCandidates = ["Skip", "Got it", "Start", "跳过", "知道了", "开始使用"]
        for label in labelCandidates {
            let btn = app.buttons[label]
            if btn.exists && btn.isHittable {
                btn.tap()
                settleUI(seconds: 0.2)
                return
            }
        }
    }

    // MARK: High-Level Navigation Workflows (Opaque-Box User Actions)

    @MainActor
    @discardableResult
    func openFirstConversation(
        in app: XCUIApplication,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> XCUIElement {
        let composer = app.cuvenElement(CuvenAID.Thread.composerField)
        let rows = chatRows(in: app)
        if rows.firstMatch.waitForExistence(timeout: Self.shortTimeout) {
            tapSafely(rows.firstMatch, file: file, line: line)
        }
        XCTAssertTrue(
            composer.waitForExistence(timeout: Self.defaultTimeout),
            "Opening a conversation must present \(CuvenAID.Thread.composerField)",
            file: file,
            line: line
        )
        return composer
    }

    @MainActor
    func revealSidebar(
        in app: XCUIApplication,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let allScope = app.cuvenElement(CuvenAID.Sidebar.scopeAll)
        if allScope.exists && allScope.isHittable {
            return
        }

        // Try Duo PagesCapsule "Menu" / "Home" slot first if visible
        let capsule = app.cuvenElement(CuvenAID.Shell.pagesCapsule)
        if capsule.exists {
            for candidate in ["shell.pagesCapsule.menu", "Menu", "Home", "Sidebar", "菜单", "主页", "pages.menu", "shell.page.menu"] {
                let item = capsule.descendants(matching: .any).matching(
                    NSPredicate(format: "identifier CONTAINS[cd] %@ OR label CONTAINS[cd] %@", candidate, candidate)
                ).firstMatch
                if item.exists {
                    tapSafely(item, file: file, line: line)
                    if allScope.waitForExistence(timeout: Self.shortTimeout) { return }
                }
            }
        }

        // If inside Thread on compact/closed, step back to ChatList first
        let threadBack = app.cuvenElement(CuvenAID.Thread.backButton)
        if threadBack.exists && threadBack.isHittable {
            threadBack.tap()
            settleUI(seconds: 0.35)
        }

        // Try explicit Sidebar / Home / Menu button in ChatList header or bottom dock
        let sidebarBtn = elementMatchingAnyLabel(
            ["sidebar.toggle", "shell.sidebarButton", "shell.bottomDock.back", "Home", "Menu", "Sidebar", "Back", "主页", "侧栏"],
            in: app
        )
        if sidebarBtn.exists && sidebarBtn.isHittable {
            sidebarBtn.tap()
            if allScope.waitForExistence(timeout: Self.shortTimeout) { return }
        }

        // Swipe right from leading edge of strip to slide Column 0 (Sidebar) into view
        let strip = app.cuvenElement(CuvenAID.Shell.strip)
        if strip.exists {
            let start = strip.coordinate(withNormalizedOffset: CGVector(dx: 0.05, dy: 0.5))
            let end = strip.coordinate(withNormalizedOffset: CGVector(dx: 0.82, dy: 0.5))
            start.press(forDuration: 0.05, thenDragTo: end)
            settleUI(seconds: 0.4)
        }

        XCTAssertTrue(
            allScope.waitForExistence(timeout: Self.defaultTimeout),
            "Sidebar scope (\(CuvenAID.Sidebar.scopeAll)) should be reachable via user navigation",
            file: file,
            line: line
        )
    }

    @MainActor
    @discardableResult
    func openMoments(
        in app: XCUIApplication,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> XCUIElement {
        let feed = app.cuvenElement(CuvenAID.Moments.feed)
        if feed.exists && feed.isHittable { return feed }

        let capsule = app.cuvenElement(CuvenAID.Shell.pagesCapsule)
        if capsule.exists {
            let momentsSlot = capsule.descendants(matching: .any).matching(
                NSPredicate(format: "identifier CONTAINS[cd] 'moments' OR label CONTAINS[cd] 'Moments' OR label CONTAINS '朋友圈'")
            ).firstMatch
            if momentsSlot.exists {
                tapSafely(momentsSlot, file: file, line: line)
                if feed.waitForExistence(timeout: Self.shortTimeout) { return feed }
            }
        }

        let directMoments = app.cuvenElement(CuvenAID.Sidebar.moments)
        if directMoments.exists && directMoments.isHittable {
            directMoments.tap()
            if feed.waitForExistence(timeout: Self.shortTimeout) { return feed }
        }

        let anyMomentsTrigger = elementMatchingAnyLabel(["Moments", "朋友圈", "moments"], in: app)
        if anyMomentsTrigger.exists && anyMomentsTrigger.isHittable {
            anyMomentsTrigger.tap()
            if feed.waitForExistence(timeout: Self.shortTimeout) { return feed }
        }

        revealSidebar(in: app, file: file, line: line)
        tapSafely(app.cuvenElement(CuvenAID.Sidebar.moments), file: file, line: line)
        XCTAssertTrue(
            feed.waitForExistence(timeout: Self.defaultTimeout),
            "Moments feed (\(CuvenAID.Moments.feed)) must open",
            file: file,
            line: line
        )
        return feed
    }

    @MainActor
    @discardableResult
    func openMemories(
        in app: XCUIApplication,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> XCUIElement {
        let grid = app.cuvenElement(CuvenAID.Memories.grid)
        if grid.exists && grid.isHittable { return grid }

        let capsule = app.cuvenElement(CuvenAID.Shell.pagesCapsule)
        if capsule.exists {
            let memSlot = capsule.descendants(matching: .any).matching(
                NSPredicate(format: "identifier CONTAINS[cd] 'memories' OR label CONTAINS[cd] 'Memories' OR label CONTAINS '回忆'")
            ).firstMatch
            if memSlot.exists {
                tapSafely(memSlot, file: file, line: line)
                if grid.waitForExistence(timeout: Self.shortTimeout) { return grid }
            }
        }

        let directMemories = app.cuvenElement(CuvenAID.Sidebar.memories)
        if directMemories.exists && directMemories.isHittable {
            directMemories.tap()
            if grid.waitForExistence(timeout: Self.shortTimeout) { return grid }
        }

        let anyMemoriesTrigger = elementMatchingAnyLabel(["Memories", "回忆", "memories"], in: app)
        if anyMemoriesTrigger.exists && anyMemoriesTrigger.isHittable {
            anyMemoriesTrigger.tap()
            if grid.waitForExistence(timeout: Self.shortTimeout) { return grid }
        }

        revealSidebar(in: app, file: file, line: line)
        tapSafely(app.cuvenElement(CuvenAID.Sidebar.memories), file: file, line: line)
        XCTAssertTrue(
            grid.waitForExistence(timeout: Self.defaultTimeout),
            "Memories grid (\(CuvenAID.Memories.grid)) must open",
            file: file,
            line: line
        )
        return grid
    }

    @MainActor
    @discardableResult
    func openSettings(
        in app: XCUIApplication,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> XCUIElement {
        let settings = app.cuvenElement(CuvenAID.Settings.root)
        if settings.exists { return settings }

        let capsuleYou = app.cuvenElement("shell.pagesCapsule.you")
        if capsuleYou.exists && capsuleYou.isHittable {
            capsuleYou.tap()
            if settings.waitForExistence(timeout: Self.shortTimeout) { return settings }
        }

        for candidate in [
            "settings.openButton", "chatlist.profileButton", "sidebar.profileCard", "sidebar.profileButton",
            "Settings", "Profile", "You", "Tokio", "设置", "个人资料"
        ] {
            let trigger = elementMatchingAnyLabel([candidate], in: app)
            if trigger.exists && trigger.isHittable {
                trigger.tap()
                if settings.waitForExistence(timeout: Self.shortTimeout) { return settings }
            }
        }

        revealSidebar(in: app, file: file, line: line)
        let sidebarTrigger = elementMatchingAnyLabel(
            ["sidebar.profileCard", "Settings", "Tokio", "Profile", "设置", "sidebar.profile"],
            in: app
        )
        if sidebarTrigger.exists {
            tapSafely(sidebarTrigger, file: file, line: line)
        }
        XCTAssertTrue(
            settings.waitForExistence(timeout: Self.defaultTimeout),
            "Settings sheet (\(CuvenAID.Settings.root)) must open",
            file: file,
            line: line
        )
        return settings
    }

    @MainActor
    func dismissSettingsIfOpen(in app: XCUIApplication) {
        let settings = app.cuvenElement(CuvenAID.Settings.root)
        guard settings.exists else { return }
        let doneByID = app.cuvenElement("settings.doneButton")
        if doneByID.exists && doneByID.isHittable {
            doneByID.tap()
            settleUI(seconds: 0.35)
            return
        }
        let closeBtn = elementMatchingAnyLabel(["settings.close", "Done", "Close", "完成", "关闭"], in: app)
        if closeBtn.exists && closeBtn.isHittable {
            closeBtn.tap()
        } else {
            settings.swipeDown()
        }
        settleUI(seconds: 0.35)
    }

    @MainActor
    @discardableResult
    func openOwnNoteComposer(
        in app: XCUIApplication,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> XCUIElement {
        let notesStrip = app.cuvenElement(CuvenAID.ChatList.notesStrip)
        XCTAssertTrue(
            notesStrip.waitForExistence(timeout: Self.defaultTimeout),
            "ChatList must display 24-hour Notes shelf (\(CuvenAID.ChatList.notesStrip))",
            file: file,
            line: line
        )

        let mineByID = app.cuvenElement("chatlist.notesStrip.mine")
        if mineByID.exists {
            tapSafely(mineByID, file: file, line: line)
        } else {
            let ownNoteTrigger = notesStrip.descendants(matching: .any).matching(
                NSPredicate(format: "label CONTAINS[cd] 'note' OR label CONTAINS[cd] 'Share' OR label CONTAINS '便签' OR label CONTAINS '想法' OR identifier CONTAINS[cd] 'mine' OR identifier CONTAINS[cd] 'myNote' OR identifier CONTAINS[cd] 'compose'")
            ).firstMatch
            if ownNoteTrigger.exists {
                tapSafely(ownNoteTrigger, file: file, line: line)
            } else {
                notesStrip.coordinate(withNormalizedOffset: CGVector(dx: 0.12, dy: 0.5)).tap()
            }
        }
        settleUI(seconds: 0.3)

        let composerByID = app.cuvenElement("chatlist.noteComposer.input")
        if composerByID.waitForExistence(timeout: Self.shortTimeout) {
            return composerByID
        }
        return app.textFields.firstMatch.exists ? app.textFields.firstMatch : app.textViews.firstMatch
    }

    @MainActor
    func momentsCaptionInput(in app: XCUIApplication) -> XCUIElement {
        let explicit = app.cuvenElement("moments.editor.textField")
        if explicit.exists { return explicit }
        return app.textViews.firstMatch.exists ? app.textViews.firstMatch : app.textFields.firstMatch
    }

    @MainActor
    func momentsAltInput(in app: XCUIApplication) -> XCUIElement {
        let explicit = app.cuvenElement("moments.editor.altTextField")
        if explicit.waitForExistence(timeout: Self.shortTimeout) {
            return explicit
        }
        if app.sheets.firstMatch.textViews.firstMatch.exists {
            return app.sheets.firstMatch.textViews.firstMatch
        }
        let tvCount = app.textViews.count
        if tvCount > 1 {
            return app.textViews.element(boundBy: tvCount - 1)
        }
        return app.textViews.firstMatch.exists ? app.textViews.firstMatch : app.textFields.firstMatch
    }

    @MainActor
    @discardableResult
    func openDrawingBoardFromThread(
        in app: XCUIApplication,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> XCUIElement {
        let canvas = app.cuvenElement(CuvenAID.Artifact.drawingCanvas)
        if canvas.exists && canvas.isHittable { return canvas }

        let drawBtn = app.cuvenElement(CuvenAID.Thread.drawButton)
        if drawBtn.exists && drawBtn.isHittable {
            drawBtn.tap()
        } else {
            let plusBtn = app.cuvenElement(CuvenAID.Thread.plusButton)
            if plusBtn.exists {
                tapSafely(plusBtn, file: file, line: line)
                settleUI(seconds: 0.25)
            }
            if drawBtn.waitForExistence(timeout: Self.shortTimeout) {
                tapSafely(drawBtn, file: file, line: line)
            } else {
                let menuDraw = elementMatchingAnyLabel(["Draw", "Drawing", "手绘", "涂鸦"], in: app)
                tapSafely(menuDraw, file: file, line: line)
            }
        }

        XCTAssertTrue(
            canvas.waitForExistence(timeout: Self.defaultTimeout),
            "Drawing board (\(CuvenAID.Artifact.drawingCanvas)) must appear in Column 3",
            file: file,
            line: line
        )
        return canvas
    }

    @MainActor
    @discardableResult
    func openRoomInfoFromThread(
        in app: XCUIApplication,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> XCUIElement {
        let info = app.cuvenElement(CuvenAID.Artifact.roomInfo)
        if info.exists && info.isHittable { return info }

        let explicitInfoBtn = elementMatchingAnyLabel(
            ["thread.infoButton", "thread.roomInfoButton", "Info", "Details", "聊天信息", "详情"],
            in: app
        )
        if explicitInfoBtn.exists && explicitInfoBtn.isHittable {
            explicitInfoBtn.tap()
            if info.waitForExistence(timeout: Self.shortTimeout) { return info }
        }

        let headerPill = app.cuvenElement(CuvenAID.Thread.headerPill)
        if headerPill.exists {
            // Tap trailing (i) info region of header pill first, then center if needed
            let trailing = headerPill.coordinate(withNormalizedOffset: CGVector(dx: 0.90, dy: 0.5))
            trailing.tap()
            if info.waitForExistence(timeout: Self.shortTimeout) { return info }
            tapSafely(headerPill, file: file, line: line)
        }

        XCTAssertTrue(
            info.waitForExistence(timeout: Self.defaultTimeout),
            "Room Info column (\(CuvenAID.Artifact.roomInfo)) must appear",
            file: file,
            line: line
        )
        return info
    }

    @MainActor
    func openStickerDrawerFromThread(
        in app: XCUIApplication,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let stickerBtn = app.cuvenElement(CuvenAID.Thread.stickerButton)
        if stickerBtn.exists && stickerBtn.isHittable {
            stickerBtn.tap()
            settleUI(seconds: 0.35)
            return
        }
        let plusBtn = app.cuvenElement(CuvenAID.Thread.plusButton)
        if plusBtn.exists {
            tapSafely(plusBtn, file: file, line: line)
            settleUI(seconds: 0.25)
        }
        if stickerBtn.waitForExistence(timeout: Self.shortTimeout) {
            tapSafely(stickerBtn, file: file, line: line)
        } else {
            let menuSticker = elementMatchingAnyLabel(["Sticker", "Stickers", "表情", "贴纸"], in: app)
            tapSafely(menuSticker, file: file, line: line)
        }
        settleUI(seconds: 0.35)
    }

    // MARK: Live Posture Switching via `shell.postureSwitcher` (Zero XCUIDevice.orientation!)

    @MainActor
    func switchPosture(
        to target: UITestPosture,
        in app: XCUIApplication,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let directChild = app.cuvenElement("shell.posture.\(target.rawValue)")
        if directChild.exists && directChild.isHittable {
            directChild.tap()
            settleUI(seconds: 0.45)
            return
        }

        let switcher = app.cuvenElement(CuvenAID.Shell.postureSwitcher)
        XCTAssertTrue(
            switcher.waitForExistence(timeout: Self.defaultTimeout),
            "Posture switcher (\(CuvenAID.Shell.postureSwitcher)) must exist for live posture continuity",
            file: file,
            line: line
        )

        // Check if option already sits inside segmented switcher
        for candidate in target.displayCandidates {
            let seg = switcher.descendants(matching: .any).matching(
                NSPredicate(format: "identifier == %@ OR label CONTAINS[cd] %@", candidate, candidate)
            ).firstMatch
            if seg.exists && seg.isHittable {
                seg.tap()
                settleUI(seconds: 0.45)
                return
            }
        }

        // Open Menu / Picker attached to shell.postureSwitcher
        tapSafely(switcher, file: file, line: line)
        settleUI(seconds: 0.25)

        let option = elementMatchingAnyLabel(
            ["shell.posture.\(target.rawValue)", "settings.posture.\(target.rawValue)"] + target.displayCandidates,
            in: app
        )
        if option.waitForExistence(timeout: Self.shortTimeout) {
            tapSafely(option, file: file, line: line)
        }
        settleUI(seconds: 0.45)
    }

    // MARK: HIG Hit-Target & Screenshot Evidence Helpers

    /// Estimates any active framed-posture preview scale (`<= 1.0`) when a tall/wide canonical
    /// posture (e.g., `393×852` `iPhoneCompact` or `951×669` `duoOpen`) is previewed inside a
    /// smaller Simulator host window; equals `1.0` whenever running 1:1 full-bleed natively.
    @MainActor
    func estimatedPreviewScale(in app: XCUIApplication) -> CGFloat {
        let strip = app.cuvenElement(CuvenAID.Shell.strip)
        let window = app.windows.firstMatch
        guard strip.exists, window.exists, window.frame.width > 0, window.frame.height > 0 else {
            return 1.0
        }
        // If `strip` occupies full window width & height (`isFramedPreview == false`), scale is 1.0 unless
        // a 951pt wide layout is fitted inside a <500pt portrait window (height ~ windowWidth * 669/951).
        let widthRatio = strip.frame.width / window.frame.width
        let heightRatio = strip.frame.height / window.frame.height
        if widthRatio < 0.92 {
            // Portrait posture (e.g. 393x852 or 466x678) fitted inside wider/shorter landscape Duo window
            return max(0.5, min(1.0, strip.frame.width / 393.0))
        }
        if heightRatio < 0.85 {
            // Landscape posture (e.g. 951x669 or 956x440) fitted inside taller/narrower portrait iPhone window
            return max(0.38, min(1.0, strip.frame.width / 951.0))
        }
        return 1.0
    }

    @MainActor
    func assertMinimumHIGHTarget(
        _ target: XCUIElement,
        in app: XCUIApplication? = nil,
        minPoints: CGFloat = 43.0,
        description: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertTrue(
            target.waitForExistence(timeout: Self.defaultTimeout),
            "\(description) must exist before measuring HIG hit target",
            file: file,
            line: line
        )
        let scale = app.map { estimatedPreviewScale(in: $0) } ?? 1.0
        let logicalWidth = target.frame.width / scale
        let logicalHeight = target.frame.height / scale
        XCTAssertGreaterThanOrEqual(
            logicalWidth,
            minPoints,
            "\(description) logical width (\(logicalWidth)pt, scale=\(scale)) must satisfy Apple HIG >= 44pt tap target",
            file: file,
            line: line
        )
        XCTAssertGreaterThanOrEqual(
            logicalHeight,
            minPoints,
            "\(description) logical height (\(logicalHeight)pt, scale=\(scale)) must satisfy Apple HIG >= 44pt tap target",
            file: file,
            line: line
        )
    }

    @MainActor
    func attachScreenshot(named name: String) {
        let screenshot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
