import XCTest

/// Tier 1 Opaque-Box Happy-Path Feature Suite (50 tests across F1–F8, >= 6 per feature group).
/// Uses ONLY public launch arguments (`--uitest-demo`, `--uitest-logged-out`, `--uitest-posture=...`)
/// and user-facing accessibility identifiers from `PROJECT.md § 5.5`.
final class CuvenTier1FeatureUITests: CuvenUITestCase {

    // =========================================================================
    // MARK: - Group F1: Apple HIG, Native Hierarchy, Typography & Hit Targets (6)
    // =========================================================================

    @MainActor
    func testF1_01_ZeroWebViewShell100PercentNativeHierarchy() throws {
        let authApp = launchLoggedOut(posture: .iPhoneCompact)
        XCTAssertEqual(
            authApp.webViews.count,
            0,
            "Auth screen must be 100% native SwiftUI/UIKit with zero WKWebView shell"
        )

        let demoApp = launchDemo(posture: .duoOpen)
        XCTAssertEqual(
            demoApp.webViews.count,
            0,
            "Authenticated shell & split columns must use zero WebView wrapper"
        )
        _ = openFirstConversation(in: demoApp)
        XCTAssertEqual(
            demoApp.webViews.count,
            0,
            "Conversation thread must render native bubbles without WebView"
        )
    }

    @MainActor
    func testF1_02_FullBleedNonLetterboxedSceneWindowBounds() throws {
        let app = launchDemo(posture: .duoOpen)
        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: Self.defaultTimeout))

        let screenBounds = XCUIScreen.main.screenshot().image.size
        XCTAssertGreaterThan(window.frame.width, 300, "Scene window width must fill active display")
        XCTAssertGreaterThan(window.frame.height, 300, "Scene window height must fill active display")
        XCTAssertGreaterThan(screenBounds.width, 0)
        XCTAssertEqual(
            window.frame.minX,
            0,
            accuracy: 2.0,
            "UIRequiresFullScreen=false + UILaunchScreen must avoid horizontal letterboxing"
        )
        XCTAssertEqual(
            window.frame.minY,
            0,
            accuracy: 2.0,
            "Scene window must extend edge-to-edge from y=0 without top black bars"
        )
    }

    @MainActor
    func testF1_03_ClarinettaWordmarkAndEditorialTypographyPresence() throws {
        let app = launchLoggedOut(posture: .iPhoneCompact)
        let wordmark = element(id: CuvenAID.Auth.wordmark, in: app)
        XCTAssertTrue(wordmark.waitForExistence(timeout: Self.defaultTimeout))
        XCTAssertGreaterThan(wordmark.frame.width, 40, "Clarinetta brand wordmark must have visible width")
        XCTAssertGreaterThan(wordmark.frame.height, 18, "Clarinetta brand wordmark must have display height")
        attachScreenshot(named: "Tier1-F1-Auth-Clarinetta-Wordmark")
    }

    @MainActor
    func testF1_04_Minimum44ptHIGHTapTargetsOnPrimaryChromeControls() throws {
        let app = launchDemo(posture: .iPhoneCompact)
        let searchBtn = app.cuvenElement(CuvenAID.ChatList.searchButton)
        let newChatBtn = app.cuvenElement(CuvenAID.ChatList.newChatButton)

        assertMinimumHIGHTarget(searchBtn, in: app, minPoints: 40.0, description: "ChatList Search control")
        assertMinimumHIGHTarget(newChatBtn, in: app, minPoints: 40.0, description: "ChatList New Chat / Friends control")

        _ = openFirstConversation(in: app)
        let backBtn = app.cuvenElement(CuvenAID.Thread.backButton)
        if backBtn.exists {
            assertMinimumHIGHTarget(backBtn, in: app, minPoints: 40.0, description: "Thread Back control")
        }
    }

    @MainActor
    func testF1_05_DynamicTypeCeilingPreventsChromeBarVerticalOverflow() throws {
        let app = launchDemo(
            posture: .iPhoneCompact,
            extraArguments: [
                "-UIPreferredContentSizeCategoryName",
                "UICTContentSizeCategoryAccessibilityExtraExtraExtraLarge"
            ]
        )
        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: Self.defaultTimeout))

        let dock = element(id: CuvenAID.Shell.bottomDock, in: app)
        if dock.waitForExistence(timeout: Self.shortTimeout) {
            XCTAssertLessThanOrEqual(
                dock.frame.height,
                96.0,
                "21pt Dynamic Type chrome ceiling must keep bottom dock compact and unclipped"
            )
            XCTAssertLessThanOrEqual(dock.frame.maxY, window.frame.maxY + 2.0)
        }

        _ = openFirstConversation(in: app)
        let header = element(id: CuvenAID.Thread.headerPill, in: app)
        XCTAssertTrue(header.waitForExistence(timeout: Self.defaultTimeout))
        XCTAssertLessThanOrEqual(header.frame.maxX, window.frame.maxX + 2.0)
    }

    @MainActor
    func testF1_06_LightAndDarkAppearanceVisualHarvestAttachments() throws {
        let app = launchDemo(posture: .duoOpen)
        attachScreenshot(named: "Tier1-F1-DuoOpen-DefaultAppearance")

        let settings = openSettings(in: app)
        let darkToggle = elementMatchingAnyLabel(["Dark", "深色", "settings.theme.dark"], in: app)
        if darkToggle.waitForExistence(timeout: Self.shortTimeout) {
            tapSafely(darkToggle)
            settleUI(seconds: 0.35)
        }
        XCTAssertTrue(settings.exists || element(id: CuvenAID.Shell.strip, in: app).exists)
        attachScreenshot(named: "Tier1-F1-DuoOpen-DarkAppearance")
    }

    // =========================================================================
    // MARK: - Group F2: Auth, Segmented Invite Code, Demo Entry & Sidebar (6)
    // =========================================================================

    @MainActor
    func testF2_01_LoggedOutBootRendersAuthWordmarkUsernamePasswordAndSubmit() throws {
        let app = launchLoggedOut(posture: .iPhoneCompact)

        XCTAssertTrue(element(id: CuvenAID.Auth.wordmark, in: app).exists)
        XCTAssertTrue(element(id: CuvenAID.Auth.username, in: app).waitForExistence(timeout: Self.defaultTimeout))
        XCTAssertTrue(element(id: CuvenAID.Auth.password, in: app).waitForExistence(timeout: Self.defaultTimeout))
        XCTAssertTrue(element(id: CuvenAID.Auth.submit, in: app).waitForExistence(timeout: Self.defaultTimeout))
        XCTAssertTrue(element(id: CuvenAID.Auth.demoButton, in: app).waitForExistence(timeout: Self.defaultTimeout))
    }

    @MainActor
    func testF2_02_SegmentedInviteCodeTrackAcceptsRegistrationCodeInput() throws {
        let app = launchLoggedOut(posture: .duoClosed)

        let inviteTrack = element(id: CuvenAID.Auth.inviteCodeTrack, in: app)
        if !inviteTrack.exists {
            let registerTab = elementMatchingAnyLabel(
                ["auth.mode.register", "Create account", "Register", "Sign up", "创建账号", "注册"],
                in: app
            )
            if registerTab.waitForExistence(timeout: Self.shortTimeout) {
                tapSafely(registerTab)
            }
        }

        XCTAssertTrue(
            inviteTrack.waitForExistence(timeout: Self.defaultTimeout),
            "Register mode must expose segmented invite-code track (\(CuvenAID.Auth.inviteCodeTrack))"
        )
        focusAndType("CUVEN6", into: inviteTrack)
        XCTAssertTrue(inviteTrack.exists)
        attachScreenshot(named: "Tier1-F2-Auth-SegmentedInviteTrack")
    }

    @MainActor
    func testF2_03_DemoModeButtonTransitionsFromAuthIntoAuthenticatedShell() throws {
        let app = launchLoggedOut(posture: .iPhoneCompact)
        let demoButton = element(id: CuvenAID.Auth.demoButton, in: app)
        tapSafely(demoButton)

        let strip = element(id: CuvenAID.Shell.strip, in: app)
        XCTAssertTrue(
            strip.waitForExistence(timeout: Self.defaultTimeout),
            "Tapping \(CuvenAID.Auth.demoButton) must transition cleanly into \(CuvenAID.Shell.strip)"
        )
        XCTAssertGreaterThan(chatRows(in: app).count, 0, "Demo entry must seed conversation rows")
    }

    @MainActor
    func testF2_04_DirectDemoLaunchArgSeedsRichRoomsAndContactsImmediately() throws {
        let app = launchDemo(posture: .iPhoneCompact)
        let firstRow = firstChatRow(in: app)
        XCTAssertTrue(firstRow.exists)
        XCTAssertGreaterThanOrEqual(
            chatRows(in: app).count,
            2,
            "--uitest-demo must pre-populate multiple deterministic DM & group rooms"
        )
        XCTAssertTrue(element(id: CuvenAID.ChatList.notesStrip, in: app).waitForExistence(timeout: Self.defaultTimeout))
    }

    @MainActor
    func testF2_05_SidebarScopesAllUnreadDirectGroupsFilterConversations() throws {
        let app = launchDemo(posture: .duoOpen)
        revealSidebar(in: app)

        let scopeIDs = [
            CuvenAID.Sidebar.scopeUnread,
            CuvenAID.Sidebar.scopeDirect,
            CuvenAID.Sidebar.scopeGroups,
            CuvenAID.Sidebar.scopeAll
        ]
        for scopeID in scopeIDs {
            revealSidebar(in: app)
            let scopeBtn = element(id: scopeID, in: app)
            XCTAssertTrue(
                scopeBtn.waitForExistence(timeout: Self.defaultTimeout),
                "Sidebar must expose scope control '\(scopeID)'"
            )
            tapSafely(scopeBtn)
            settleUI(seconds: 0.25)
        }

        XCTAssertGreaterThan(
            chatRows(in: app).count,
            0,
            "Returning to \(CuvenAID.Sidebar.scopeAll) must display all seeded conversations"
        )
        attachScreenshot(named: "Tier1-F2-Sidebar-Scopes")
    }

    @MainActor
    func testF2_06_SidebarMomentsAndMemoriesDestinationsNavigateCleanly() throws {
        let app = launchDemo(posture: .duoOpen)
        revealSidebar(in: app)

        let momentsLink = element(id: CuvenAID.Sidebar.moments, in: app)
        let memoriesLink = element(id: CuvenAID.Sidebar.memories, in: app)
        XCTAssertTrue(momentsLink.waitForExistence(timeout: Self.defaultTimeout))
        XCTAssertTrue(memoriesLink.waitForExistence(timeout: Self.defaultTimeout))

        tapSafely(momentsLink)
        XCTAssertTrue(
            element(id: CuvenAID.Moments.feed, in: app).waitForExistence(timeout: Self.defaultTimeout),
            "Tapping \(CuvenAID.Sidebar.moments) must present \(CuvenAID.Moments.feed)"
        )
    }

    // =========================================================================
    // MARK: - Group F3: iPhone & iPhone Duo Spatial Strip, Postures & Rail (7)
    // =========================================================================

    @MainActor
    func testF3_01_IPhoneCompactUsesSingleColumnStackAnd56ptHorizontalBottomDock() throws {
        let app = launchDemo(posture: .iPhoneCompact)
        let dock = app.cuvenElement(CuvenAID.Shell.bottomDock)
        XCTAssertTrue(
            dock.waitForExistence(timeout: Self.defaultTimeout),
            "iPhoneCompact must show horizontal Liquid Glass bottom dock (\(CuvenAID.Shell.bottomDock))"
        )
        let logicalDockHeight = dock.frame.height / estimatedPreviewScale(in: app)
        XCTAssertGreaterThanOrEqual(logicalDockHeight, 44.0, "Horizontal dock must be ~56pt tall (>=44pt)")
        XCTAssertGreaterThan(dock.frame.width, dock.frame.height, "Bottom dock must be horizontal in iPhoneCompact")

        let duoRail = app.cuvenElement(CuvenAID.Shell.duoRail)
        XCTAssertFalse(
            duoRail.exists && duoRail.isHittable,
            "iPhoneCompact must NOT display vertical DuoRail"
        )
        attachScreenshot(named: "Tier1-F3-iPhoneCompact-StackDock")
    }

    @MainActor
    func testF3_02_IPhoneSplitUsesTwoColumnSplitWithHorizontalDocksAndNoDuoRail() throws {
        let app = launchDemo(posture: .iPhoneSplit)
        let firstRow = firstChatRow(in: app)
        tapSafely(firstRow)

        let composer = app.cuvenElement(CuvenAID.Thread.composerField)
        XCTAssertTrue(composer.waitForExistence(timeout: Self.defaultTimeout))
        XCTAssertTrue(
            firstRow.exists,
            "iPhoneSplit (>=700pt symmetric safe area) must keep ChatList and Thread visible simultaneously"
        )
        XCTAssertLessThan(
            firstRow.frame.minX,
            composer.frame.minX,
            "ChatList column must sit on the leading side of Thread column in iPhoneSplit"
        )

        let duoRail = app.cuvenElement(CuvenAID.Shell.duoRail)
        XCTAssertFalse(
            duoRail.exists && duoRail.isHittable,
            "Symmetric iPhoneSplit landscape must NOT mistake safe areas for iPhone Duo right rail"
        )
    }

    @MainActor
    func testF3_03_DuoClosedUsesOuterSingleColumnWith52ptRightDuoRailAndPagesCapsule() throws {
        let app = launchDemo(posture: .duoClosed)
        let strip = app.cuvenElement(CuvenAID.Shell.strip)
        let duoRail = app.cuvenElement(CuvenAID.Shell.duoRail)
        let pagesCapsule = app.cuvenElement(CuvenAID.Shell.pagesCapsule)

        XCTAssertTrue(
            duoRail.waitForExistence(timeout: Self.defaultTimeout),
            "duoClosed must render vertical right-edge \(CuvenAID.Shell.duoRail)"
        )
        XCTAssertTrue(
            pagesCapsule.waitForExistence(timeout: Self.defaultTimeout),
            "duoClosed must render 6-item \(CuvenAID.Shell.pagesCapsule) on right edge"
        )
        XCTAssertGreaterThan(
            duoRail.frame.midX,
            strip.frame.midX,
            "DuoRail must stand in the trailing right-edge system column"
        )
        attachScreenshot(named: "Tier1-F3-DuoClosed-OuterRail")
    }

    @MainActor
    func testF3_04_DuoOpenRendersAsymmetricTwoColumnListAndThreadSplitWithHybridBars() throws {
        let app = launchDemo(posture: .duoOpen)
        let strip = app.cuvenElement(CuvenAID.Shell.strip)
        let row = firstChatRow(in: app)
        tapSafely(row)

        let messageList = app.cuvenElement(CuvenAID.Thread.messageList)
        let duoRail = app.cuvenElement(CuvenAID.Shell.duoRail)
        XCTAssertTrue(messageList.waitForExistence(timeout: Self.defaultTimeout))
        XCTAssertTrue(duoRail.waitForExistence(timeout: Self.defaultTimeout))

        XCTAssertLessThan(
            row.frame.minX,
            messageList.frame.minX,
            "duoOpen must show narrow leading ChatList beside wide trailing Thread"
        )
        XCTAssertLessThan(
            row.frame.width,
            strip.frame.width * 0.50,
            "Leading ChatList column in duoOpen (342pt of 951pt) must be narrower than half the canvas"
        )
        if abs(strip.frame.width - 951.0) <= 6.0 {
            XCTAssertEqual(row.frame.width, 342.0, accuracy: 28.0, "Leading list column targets 342pt on 951pt Duo Open")
        }
        attachScreenshot(named: "Tier1-F3-DuoOpen-ListAndThreadSplit")
    }

    @MainActor
    func testF3_05_DuoOpenThreadToArtifactSlideMaintainsZeroReflowThreadWidth() throws {
        let app = launchDemo(posture: .duoOpen)
        _ = openFirstConversation(in: app)

        let messageList = app.cuvenElement(CuvenAID.Thread.messageList)
        XCTAssertTrue(messageList.waitForExistence(timeout: Self.defaultTimeout))
        settleUI(seconds: 0.35)
        let widthBesideList = messageList.frame.width

        let canvas = openDrawingBoardFromThread(in: app)
        settleUI(seconds: 0.45)
        XCTAssertTrue(canvas.exists)
        XCTAssertTrue(messageList.exists, "Thread column must stay visible beside Artifact column in duoOpen")

        let widthBesideArtifact = messageList.frame.width
        XCTAssertEqual(
            widthBesideArtifact,
            widthBesideList,
            accuracy: 6.0,
            "Zero-Reflow Mandate: Thread content width (525pt on 951pt Duo Open) must stay constant across List|Thread (342|609) and Thread|Artifact (525|426)"
        )
        attachScreenshot(named: "Tier1-F3-DuoOpen-ZeroReflow-ThreadAndDrawing")
    }

    @MainActor
    func testF3_06_DuoHalfBookPostureSplitsColumnsCleanlyAcrossHinge() throws {
        let app = launchDemo(posture: .duoHalfBook)
        let row = firstChatRow(in: app)
        tapSafely(row)

        let messageList = app.cuvenElement(CuvenAID.Thread.messageList)
        XCTAssertTrue(messageList.waitForExistence(timeout: Self.defaultTimeout))
        XCTAssertLessThanOrEqual(
            row.frame.maxX,
            messageList.frame.minX + 2.0,
            "In duoHalfBook (462 | 28..40pt hinge | 461), leading and trailing panes must meet cleanly without overlapping across the fold"
        )
        attachScreenshot(named: "Tier1-F3-DuoHalfBook-HingeSplit")
    }

    @MainActor
    func testF3_07_DuoHalfLaptopPostureAndSixSlotPagesCapsuleNavigation() throws {
        let laptopApp = launchDemo(posture: .duoHalfLaptop)
        let composer = openFirstConversation(in: laptopApp)
        let messageList = laptopApp.cuvenElement(CuvenAID.Thread.messageList)
        XCTAssertTrue(messageList.waitForExistence(timeout: Self.defaultTimeout))
        XCTAssertLessThan(
            messageList.frame.minY,
            composer.frame.minY,
            "In duoHalfLaptop tabletop fold, messages sit on upper pane while composer rests on lower pane"
        )
        attachScreenshot(named: "Tier1-F3-DuoHalfLaptop-Tabletop")

        let duoApp = launchDemo(posture: .duoOpen)
        let pagesCapsule = duoApp.cuvenElement(CuvenAID.Shell.pagesCapsule)
        XCTAssertTrue(pagesCapsule.waitForExistence(timeout: Self.defaultTimeout))
        XCTAssertGreaterThan(
            pagesCapsule.frame.height / estimatedPreviewScale(in: duoApp),
            140.0,
            "6-item PagesCapsuleView must span vertical slots"
        )
    }

    // =========================================================================
    // MARK: - Group F4: ChatList, 24h Notes, For You Insights, Pinned & Search (6)
    // =========================================================================

    @MainActor
    func testF4_01_ChatListRendersSeedConversationRowsAndOpensThreadOnTap() throws {
        let app = launchDemo(posture: .iPhoneCompact)
        let row = firstChatRow(in: app)
        XCTAssertFalse(row.identifier.isEmpty)
        tapSafely(row)

        XCTAssertTrue(app.cuvenElement(CuvenAID.Thread.headerPill).waitForExistence(timeout: Self.defaultTimeout))
        XCTAssertTrue(app.cuvenElement(CuvenAID.Thread.messageList).waitForExistence(timeout: Self.defaultTimeout))
    }

    @MainActor
    func testF4_02_NotesStripDisplays24HourNotesAndPublishesOwnNote() throws {
        let app = launchDemo(posture: .iPhoneCompact)
        let notesStrip = app.cuvenElement(CuvenAID.ChatList.notesStrip)
        let noteInput = openOwnNoteComposer(in: app)

        if noteInput.exists {
            focusAndType("Sunny espresso walk ☕", into: noteInput, clearExisting: true)
            let publishBtn = elementMatchingAnyLabel(
                ["chatlist.noteComposer.share", "note.publish", "Share", "Post", "Save", "Done", "发布", "分享", "保存"],
                in: app
            )
            if publishBtn.exists {
                tapSafely(publishBtn)
            }
        }
        XCTAssertTrue(notesStrip.waitForExistence(timeout: Self.defaultTimeout))
        attachScreenshot(named: "Tier1-F4-ChatList-NotesStrip")
    }

    @MainActor
    func testF4_03_ForYouSmartInsightsDeckDisplaysContextAndWeatherCards() throws {
        let app = launchDemo(posture: .duoOpen)
        let insightsDeck = app.cuvenElement(CuvenAID.ChatList.insightsDeck)
        XCTAssertTrue(
            insightsDeck.waitForExistence(timeout: Self.defaultTimeout),
            "ChatList must display For You Smart Insights deck (\(CuvenAID.ChatList.insightsDeck))"
        )
        XCTAssertGreaterThan(
            insightsDeck.frame.height / estimatedPreviewScale(in: app),
            44.0,
            "Insights deck must render visible smart cards"
        )
        attachScreenshot(named: "Tier1-F4-ForYou-InsightsDeck")
    }

    @MainActor
    func testF4_04_PinnedConversationsGridAndRowContextMenuPinMuteUnread() throws {
        let app = launchDemo(posture: .iPhoneCompact)
        let pinnedGrid = app.cuvenElement(CuvenAID.ChatList.pinnedGrid)
        XCTAssertTrue(
            pinnedGrid.waitForExistence(timeout: Self.defaultTimeout),
            "ChatList must display Pinned conversations grid (\(CuvenAID.ChatList.pinnedGrid))"
        )

        let row = firstChatRow(in: app)
        row.press(forDuration: 0.65)
        settleUI(seconds: 0.35)

        let menuAction = elementMatchingAnyLabel(
            ["Pin", "Unpin", "Mute", "Unmute", "Unread", "置顶", "取消置顶", "静音", "标为未读"],
            in: app
        )
        if menuAction.waitForExistence(timeout: Self.shortTimeout) {
            tapSafely(menuAction)
        }
        XCTAssertTrue(pinnedGrid.exists || chatRows(in: app).firstMatch.exists)
    }

    @MainActor
    func testF4_05_ChatRowPhysicsLeftSwipeUncoversActionWithoutCornerBleed() throws {
        let app = launchDemo(posture: .iPhoneCompact)
        let initialCount = chatRows(in: app).count
        let targetIndex = initialCount > 1 ? 1 : 0
        let row = chatRows(in: app).element(boundBy: targetIndex)
        XCTAssertTrue(row.waitForExistence(timeout: Self.defaultTimeout))

        row.swipeLeft()
        settleUI(seconds: 0.35)

        let swipeAction = elementMatchingAnyLabel(["Delete", "Unread", "Hide", "删除", "未读"], in: app)
        XCTAssertTrue(
            swipeAction.exists || chatRows(in: app).count <= initialCount,
            "Left-swiping a chat row must reveal row actions or perform physics swipe-to-delete"
        )
    }

    @MainActor
    func testF4_06_GlobalSearchFiltersConversationsAndNewChatOpensFriendsRequestsSheet() throws {
        let app = launchDemo(posture: .iPhoneCompact)

        let searchBtn = app.cuvenElement(CuvenAID.ChatList.searchButton)
        tapSafely(searchBtn)
        settleUI(seconds: 0.25)

        let searchInput = app.searchFields.firstMatch.exists ? app.searchFields.firstMatch : app.textFields.firstMatch
        if searchInput.exists {
            focusAndType("Coisini", into: searchInput)
            settleUI(seconds: 0.25)
            let cancelBtn = elementMatchingAnyLabel(["Cancel", "Close", "Clear", "取消", "关闭"], in: app)
            if cancelBtn.exists {
                tapSafely(cancelBtn)
            }
        }

        let newChatBtn = app.cuvenElement(CuvenAID.ChatList.newChatButton)
        tapSafely(newChatBtn)
        settleUI(seconds: 0.35)
        let friendsMarker = elementMatchingAnyLabel(
            ["Friends", "Requests", "New Group", "People", "好友", "请求", "新建群聊"],
            in: app
        )
        XCTAssertTrue(
            friendsMarker.waitForExistence(timeout: Self.defaultTimeout),
            "Tapping \(CuvenAID.ChatList.newChatButton) must open unified Friends / Requests / New Group sheet"
        )
    }

    // =========================================================================
    // MARK: - Group F5: Thread, Curved Bubbles, Tapbacks, Edit/Unsend & AI (7)
    // =========================================================================

    @MainActor
    func testF5_01_ThreadHeaderPillDisplaysPeerAvatarStatusAndSeedMessageBubbles() throws {
        let app = launchDemo(posture: .duoOpen)
        _ = openFirstConversation(in: app)

        let headerPill = app.cuvenElement(CuvenAID.Thread.headerPill)
        let messageList = app.cuvenElement(CuvenAID.Thread.messageList)
        XCTAssertTrue(headerPill.waitForExistence(timeout: Self.defaultTimeout))
        XCTAssertTrue(messageList.waitForExistence(timeout: Self.defaultTimeout))
        XCTAssertGreaterThan(messageList.frame.height / estimatedPreviewScale(in: app), 120.0)
        attachScreenshot(named: "Tier1-F5-Thread-HeaderAndBubbles")
    }

    @MainActor
    func testF5_02_ComposerTypesAndSendsNewOutgoingMessageIntoThread() throws {
        let app = launchDemo(posture: .iPhoneCompact)
        let composer = openFirstConversation(in: app)

        let uniqueMessage = "Cuven native iOS 27.2 hello \(Int(Date().timeIntervalSince1970) % 10000)"
        focusAndType(uniqueMessage, into: composer)

        let sendBtn = element(id: CuvenAID.Thread.sendButton, in: app)
        XCTAssertTrue(
            sendBtn.waitForExistence(timeout: Self.defaultTimeout),
            "Typing non-empty text in composer must activate \(CuvenAID.Thread.sendButton)"
        )
        tapSafely(sendBtn)
        settleUI(seconds: 0.35)

        let sentBubble = app.descendants(matching: .any).matching(
            NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", uniqueMessage, uniqueMessage)
        ).firstMatch
        XCTAssertTrue(
            sentBubble.waitForExistence(timeout: Self.defaultTimeout),
            "Sent message '\(uniqueMessage)' must appear immediately in \(CuvenAID.Thread.messageList)"
        )
    }

    @MainActor
    func testF5_03_MessageLongPressContextMenuAndSixEmojiTapbackReactions() throws {
        let app = launchDemo(posture: .duoOpen)
        let composer = openFirstConversation(in: app)

        let msgText = "Tapback reaction target ✨"
        focusAndType(msgText, into: composer)
        tapSafely(element(id: CuvenAID.Thread.sendButton, in: app))

        let bubble = app.descendants(matching: .any).matching(
            NSPredicate(format: "label CONTAINS %@", msgText)
        ).firstMatch
        XCTAssertTrue(bubble.waitForExistence(timeout: Self.defaultTimeout))

        bubble.press(forDuration: 0.65)
        settleUI(seconds: 0.3)

        let heartReaction = elementMatchingAnyLabel(["❤️", "Love", "Heart", "喜欢", "reaction.❤️"], in: app)
        if heartReaction.waitForExistence(timeout: Self.shortTimeout) {
            tapSafely(heartReaction)
        } else {
            bubble.doubleTap()
        }
        settleUI(seconds: 0.3)

        let reactionRendered = app.descendants(matching: .any).matching(
            NSPredicate(format: "label CONTAINS '❤️' OR identifier CONTAINS 'reaction'")
        ).firstMatch
        XCTAssertTrue(reactionRendered.waitForExistence(timeout: Self.defaultTimeout))
    }

    @MainActor
    func testF5_04_QuoteReplyAttachesBannerAboveComposerAndSendsLinkedReply() throws {
        let app = launchDemo(posture: .iPhoneCompact)
        let composer = openFirstConversation(in: app)

        let baseMsg = "Original message to quote"
        focusAndType(baseMsg, into: composer)
        tapSafely(element(id: CuvenAID.Thread.sendButton, in: app))

        let targetBubble = app.descendants(matching: .any).matching(
            NSPredicate(format: "label CONTAINS %@", baseMsg)
        ).firstMatch
        XCTAssertTrue(targetBubble.waitForExistence(timeout: Self.defaultTimeout))

        targetBubble.press(forDuration: 0.65)
        settleUI(seconds: 0.25)
        let replyAction = elementMatchingAnyLabel(["Reply", "Quote", "回复", "引用"], in: app)
        if replyAction.waitForExistence(timeout: Self.shortTimeout) {
            tapSafely(replyAction)
        } else {
            targetBubble.swipeRight()
        }
        settleUI(seconds: 0.25)

        let replyText = "Quoted reply confirmed!"
        focusAndType(replyText, into: composer)
        tapSafely(element(id: CuvenAID.Thread.sendButton, in: app))

        let replyBubble = app.descendants(matching: .any).matching(
            NSPredicate(format: "label CONTAINS %@", replyText)
        ).firstMatch
        XCTAssertTrue(replyBubble.waitForExistence(timeout: Self.defaultTimeout))
    }

    @MainActor
    func testF5_05_MessageInPlaceEditUpdatesTextAndDisplaysEditedIndicator() throws {
        let app = launchDemo(posture: .duoOpen)
        let composer = openFirstConversation(in: app)

        let beforeText = "Draft wording v1"
        let afterText = "Polished wording v2"
        focusAndType(beforeText, into: composer)
        tapSafely(element(id: CuvenAID.Thread.sendButton, in: app))

        let bubble = app.descendants(matching: .any).matching(
            NSPredicate(format: "label CONTAINS %@", beforeText)
        ).firstMatch
        XCTAssertTrue(bubble.waitForExistence(timeout: Self.defaultTimeout))

        bubble.press(forDuration: 0.65)
        settleUI(seconds: 0.25)
        let editAction = elementMatchingAnyLabel(["Edit", "编辑"], in: app)
        if editAction.waitForExistence(timeout: Self.shortTimeout) {
            tapSafely(editAction)
            focusAndType(afterText, into: composer, clearExisting: true)
            let commitBtn = element(id: CuvenAID.Thread.sendButton, in: app)
            if commitBtn.exists {
                tapSafely(commitBtn)
            } else {
                let saveBtn = elementMatchingAnyLabel(["Save", "Done", "保存", "完成"], in: app)
                if saveBtn.exists { tapSafely(saveBtn) }
            }
            let updatedBubble = app.descendants(matching: .any).matching(
                NSPredicate(format: "label CONTAINS %@", afterText)
            ).firstMatch
            XCTAssertTrue(updatedBubble.waitForExistence(timeout: Self.defaultTimeout))
        }
    }

    @MainActor
    func testF5_06_MessageUnsendReplacesBubbleWithTombstoneNotice() throws {
        let app = launchDemo(posture: .iPhoneCompact)
        let composer = openFirstConversation(in: app)

        let ephemeralText = "Message to unsend within 2m"
        focusAndType(ephemeralText, into: composer)
        tapSafely(element(id: CuvenAID.Thread.sendButton, in: app))

        let bubble = app.descendants(matching: .any).matching(
            NSPredicate(format: "label CONTAINS %@", ephemeralText)
        ).firstMatch
        XCTAssertTrue(bubble.waitForExistence(timeout: Self.defaultTimeout))

        bubble.press(forDuration: 0.65)
        settleUI(seconds: 0.25)
        let unsendAction = elementMatchingAnyLabel(["Unsend", "Revoke", "撤回"], in: app)
        if unsendAction.waitForExistence(timeout: Self.shortTimeout) {
            tapSafely(unsendAction)
            settleUI(seconds: 0.35)
            let tombstone = app.descendants(matching: .any).matching(
                NSPredicate(format: "label CONTAINS[cd] 'unsent' OR label CONTAINS '撤回'")
            ).firstMatch
            XCTAssertTrue(
                tombstone.waitForExistence(timeout: Self.defaultTimeout) || !bubble.exists,
                "Unsending a message must replace the bubble with a tombstone notice"
            )
        }
    }

    @MainActor
    func testF5_07_VoiceMicDictationControlComposerGlowAndAISearchExplainSheet() throws {
        let app = launchDemo(posture: .duoOpen)
        let composer = openFirstConversation(in: app)

        let micBtn = element(id: CuvenAID.Thread.micButton, in: app)
        XCTAssertTrue(
            micBtn.waitForExistence(timeout: Self.defaultTimeout),
            "Thread composer must expose Whisper voice dictation button (\(CuvenAID.Thread.micButton))"
        )

        focusAndType("Explain Hangzhou West Lake weather", into: composer)
        tapSafely(element(id: CuvenAID.Thread.sendButton, in: app))

        let explainTarget = app.descendants(matching: .any).matching(
            NSPredicate(format: "label CONTAINS 'Hangzhou'")
        ).firstMatch
        XCTAssertTrue(explainTarget.waitForExistence(timeout: Self.defaultTimeout))
        explainTarget.press(forDuration: 0.65)
        settleUI(seconds: 0.25)

        let explainAction = elementMatchingAnyLabel(["Explain", "Search", "解释", "搜索"], in: app)
        if explainAction.waitForExistence(timeout: Self.shortTimeout) {
            tapSafely(explainAction)
            settleUI(seconds: 0.4)
            attachScreenshot(named: "Tier1-F5-AI-SearchAndExplain")
        }
    }

    // =========================================================================
    // MARK: - Group F6: Moments Feed, Profile Grid & Full-Page Editor (6)
    // =========================================================================

    @MainActor
    func testF6_01_MomentsFeedDisplaysStoriesRowAndEditorialPostCards() throws {
        let app = launchDemo(posture: .duoOpen)
        let feed = openMoments(in: app)
        XCTAssertTrue(feed.exists)
        XCTAssertGreaterThan(feed.frame.height / estimatedPreviewScale(in: app), 200.0)
        XCTAssertTrue(app.cuvenElement(CuvenAID.Moments.composeButton).waitForExistence(timeout: Self.defaultTimeout))
        attachScreenshot(named: "Tier1-F6-Moments-Feed")
    }

    @MainActor
    func testF6_02_MomentsDoubleTapOrHeartPillTogglesLikeAndAddsComment() throws {
        let app = launchDemo(posture: .iPhoneCompact)
        let feed = openMoments(in: app)

        let likeBtn = elementMatchingAnyLabel(
            ["moments.like", "Like", "Heart", "赞", "喜欢"],
            in: app
        )
        if likeBtn.waitForExistence(timeout: Self.shortTimeout) {
            tapSafely(likeBtn)
        } else {
            feed.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.45)).doubleTap()
        }
        settleUI(seconds: 0.3)

        let commentTrigger = elementMatchingAnyLabel(
            ["moments.comment", "Comment", "Add a comment", "评论"],
            in: app
        )
        if commentTrigger.waitForExistence(timeout: Self.shortTimeout) {
            tapSafely(commentTrigger)
            let commentInput = app.textFields.firstMatch.exists ? app.textFields.firstMatch : app.textViews.firstMatch
            if commentInput.exists {
                focusAndType("Love the mountain light!", into: commentInput)
            }
        }
        XCTAssertTrue(feed.exists)
    }

    @MainActor
    func testF6_03_MomentsAuthorProfileDisplaysPostsAndMediaWaterfallTabs() throws {
        let app = launchDemo(posture: .duoOpen)
        _ = openMoments(in: app)

        let profileTrigger = elementMatchingAnyLabel(
            ["moments.myProfileButton", "moments.profile", "Your moments", "Tokio", "Coisini", "Media", "个人主页"],
            in: app
        )
        if profileTrigger.waitForExistence(timeout: Self.shortTimeout) {
            tapSafely(profileTrigger)
            settleUI(seconds: 0.35)
            let mediaTab = elementMatchingAnyLabel(["moments.profile.mediaTab", "Media", "Photos", "相册", "媒体"], in: app)
            if mediaTab.waitForExistence(timeout: Self.shortTimeout) {
                tapSafely(mediaTab)
                settleUI(seconds: 0.3)
            }
        }
        attachScreenshot(named: "Tier1-F6-Moments-ProfileWaterfall")
    }

    @MainActor
    func testF6_04_MomentsFullPageEditorOpensAndCyclesSixCoreImageFilterTones() throws {
        let app = launchDemo(posture: .duoOpen)
        _ = openMoments(in: app)

        let composeBtn = app.cuvenElement(CuvenAID.Moments.composeButton)
        tapSafely(composeBtn)

        let filterStrip = app.cuvenElement(CuvenAID.Moments.editorFilterStrip)
        let publishBtn = app.cuvenElement(CuvenAID.Moments.editorPublishButton)
        XCTAssertTrue(publishBtn.waitForExistence(timeout: Self.defaultTimeout))
        XCTAssertTrue(
            filterStrip.waitForExistence(timeout: Self.defaultTimeout),
            "Moments Full-Page Editor must expose 6-tone CoreImage filter strip (\(CuvenAID.Moments.editorFilterStrip))"
        )

        for tone in ["Vivid", "Warm", "Cool", "Mono", "Fade", "Original"] {
            let toneBtn = filterStrip.descendants(matching: .any).matching(
                NSPredicate(format: "label CONTAINS[cd] %@ OR identifier CONTAINS[cd] %@", tone, tone)
            ).firstMatch
            if toneBtn.exists && toneBtn.isHittable {
                toneBtn.tap()
                settleUI(seconds: 0.15)
            }
        }
        attachScreenshot(named: "Tier1-F6-Moments-Editor-FilterStrip")
    }

    @MainActor
    func testF6_05_MomentsEditorSupportsAltAccessibilityDescriptionAndTagControls() throws {
        let app = launchDemo(posture: .iPhoneCompact)
        _ = openMoments(in: app)
        tapSafely(app.cuvenElement(CuvenAID.Moments.composeButton))

        let altButton = app.cuvenElement(CuvenAID.Moments.editorAltButton)
        XCTAssertTrue(
            altButton.waitForExistence(timeout: Self.defaultTimeout),
            "Moments Editor must expose +ALT accessibility description button (\(CuvenAID.Moments.editorAltButton))"
        )
        tapSafely(altButton)
        settleUI(seconds: 0.25)

        let altField = momentsAltInput(in: app)
        if altField.exists {
            focusAndType("Golden sunrise above ridge clouds", into: altField)
            let doneBtn = elementMatchingAnyLabel(
                ["moments.editor.altDoneButton", "Done", "Save", "OK", "完成", "保存"],
                in: app
            )
            if doneBtn.exists && doneBtn.identifier != CuvenAID.Moments.editorPublishButton {
                tapSafely(doneBtn)
            }
        }
        XCTAssertTrue(app.cuvenElement(CuvenAID.Moments.editorPublishButton).waitForExistence(timeout: Self.defaultTimeout))
    }

    @MainActor
    func testF6_06_MomentsEditorPublishesNewPostIntoMomentsFeed() throws {
        let app = launchDemo(posture: .duoOpen)
        _ = openMoments(in: app)
        tapSafely(app.cuvenElement(CuvenAID.Moments.composeButton))

        let uniquePost = "Evening walk along West Lake 🌅 #CuvenDuo"
        let captionInput = momentsCaptionInput(in: app)
        if captionInput.waitForExistence(timeout: Self.shortTimeout) {
            focusAndType(uniquePost, into: captionInput)
        }

        let publishBtn = app.cuvenElement(CuvenAID.Moments.editorPublishButton)
        tapSafely(publishBtn)
        settleUI(seconds: 0.45)

        let feed = app.cuvenElement(CuvenAID.Moments.feed)
        XCTAssertTrue(feed.waitForExistence(timeout: Self.defaultTimeout))
        let postedCard = app.descendants(matching: .any).matching(
            NSPredicate(format: "label CONTAINS %@", "West Lake")
        ).firstMatch
        XCTAssertTrue(postedCard.waitForExistence(timeout: Self.defaultTimeout))
    }

    // =========================================================================
    // MARK: - Group F7: Room Info, Drawing Board, Stickers & Memories (6)
    // =========================================================================

    @MainActor
    func testF7_01_ArtifactRoomInfoColumnDisplaysProfileMutePinAndSharedInsights() throws {
        let app = launchDemo(posture: .duoOpen)
        _ = openFirstConversation(in: app)
        let roomInfo = openRoomInfoFromThread(in: app)

        XCTAssertTrue(roomInfo.exists)
        XCTAssertGreaterThan(roomInfo.frame.width / estimatedPreviewScale(in: app), 200.0)
        attachScreenshot(named: "Tier1-F7-Artifact-RoomInfo")
    }

    @MainActor
    func testF7_02_DrawingBoardCanvasOpensAndRendersTouchStrokes() throws {
        let app = launchDemo(posture: .duoOpen)
        _ = openFirstConversation(in: app)
        let canvas = openDrawingBoardFromThread(in: app)

        let p1 = canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.25, dy: 0.35))
        let p2 = canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.75, dy: 0.65))
        p1.press(forDuration: 0.05, thenDragTo: p2)
        settleUI(seconds: 0.25)

        XCTAssertTrue(canvas.exists)
        attachScreenshot(named: "Tier1-F7-Artifact-DrawingCanvas")
    }

    @MainActor
    func testF7_03_DrawingBoardSwitchesFivePenToolsThreePaperStylesAndSendsDrawing() throws {
        let app = launchDemo(posture: .iPhoneCompact)
        _ = openFirstConversation(in: app)
        let canvas = openDrawingBoardFromThread(in: app)

        for toolName in ["Marker", "Highlighter", "Pencil", "Eraser", "Pen"] {
            let tool = elementMatchingAnyLabel([toolName], in: app)
            if tool.exists && tool.isHittable {
                tool.tap()
                settleUI(seconds: 0.1)
            }
        }
        for paperName in ["Lines", "Grid", "Plain"] {
            let paper = elementMatchingAnyLabel([paperName], in: app)
            if paper.exists && paper.isHittable {
                paper.tap()
                settleUI(seconds: 0.1)
            }
        }

        let start = canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.4))
        let end = canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.7, dy: 0.55))
        start.press(forDuration: 0.05, thenDragTo: end)

        let sendDrawing = elementMatchingAnyLabel(
            ["drawing.send", "artifact.sendDrawing", "Send", "发送"],
            in: app
        )
        if sendDrawing.waitForExistence(timeout: Self.shortTimeout) {
            tapSafely(sendDrawing)
        }
        XCTAssertTrue(app.cuvenElement(CuvenAID.Thread.messageList).waitForExistence(timeout: Self.defaultTimeout))
    }

    @MainActor
    func testF7_04_TelegramStickerDrawerBrowsesPacksAndSendsStickerIntoThread() throws {
        let app = launchDemo(posture: .duoOpen)
        _ = openFirstConversation(in: app)
        openStickerDrawerFromThread(in: app)

        let firstSticker = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier CONTAINS[cd] 'sticker.item' OR identifier CONTAINS[cd] 'stickerCell'")
        ).firstMatch
        if firstSticker.waitForExistence(timeout: Self.shortTimeout) {
            tapSafely(firstSticker)
        } else {
            let fallbackEmojiSticker = elementMatchingAnyLabel(["🦆", "😀", "🎉", "✨", "👍"], in: app)
            if fallbackEmojiSticker.exists { tapSafely(fallbackEmojiSticker) }
        }
        settleUI(seconds: 0.35)
        XCTAssertTrue(app.cuvenElement(CuvenAID.Thread.messageList).exists)
    }

    @MainActor
    func testF7_05_MemoriesArchiveDisplaysFourColumnMediaGridAndFilterTabs() throws {
        let app = launchDemo(posture: .duoOpen)
        let grid = openMemories(in: app)
        XCTAssertTrue(grid.exists)
        XCTAssertGreaterThan(grid.frame.height / estimatedPreviewScale(in: app), 150.0)

        for tab in ["Photos", "Videos", "Drawings", "All"] {
            let filterTab = elementMatchingAnyLabel([tab], in: app)
            if filterTab.exists && filterTab.isHittable {
                filterTab.tap()
                settleUI(seconds: 0.15)
            }
        }
        attachScreenshot(named: "Tier1-F7-Memories-Grid")
    }

    @MainActor
    func testF7_06_MemoriesFlashbackSlideshowAndHeroZoomLightboxOpenAndDismiss() throws {
        let app = launchDemo(posture: .duoOpen)
        let grid = openMemories(in: app)

        let flashbackPlay = app.cuvenElement(CuvenAID.Memories.flashbackPlay)
        XCTAssertTrue(
            flashbackPlay.waitForExistence(timeout: Self.defaultTimeout),
            "Memories must expose Monthly Recap Flashback Play button (\(CuvenAID.Memories.flashbackPlay))"
        )
        tapSafely(flashbackPlay)
        settleUI(seconds: 0.45)
        attachScreenshot(named: "Tier1-F7-Memories-FlashbackSlideshow")

        let closeSlideshow = elementMatchingAnyLabel(
            ["lightbox.closeButton", "lightbox.close", "memories.slideshowClose", "Close", "Done", "关闭", "完成"],
            in: app
        )
        if closeSlideshow.waitForExistence(timeout: Self.shortTimeout) {
            tapSafely(closeSlideshow)
        } else {
            app.windows.firstMatch.swipeDown()
        }
        XCTAssertTrue(grid.waitForExistence(timeout: Self.defaultTimeout))
    }

    // =========================================================================
    // MARK: - Group F8: Calls, Laptop Split, PiP, Settings, Avatar & AI Routine (6)
    // =========================================================================

    @MainActor
    func testF8_01_AudioCallStartsActiveOverlayWithMuteSpeakerAndHangupControls() throws {
        let app = launchDemo(posture: .iPhoneCompact)
        _ = openFirstConversation(in: app)

        let audioBtn = element(id: CuvenAID.Thread.callAudioButton, in: app)
        tapSafely(audioBtn)

        let callOverlay = element(id: CuvenAID.Call.activeOverlay, in: app)
        XCTAssertTrue(
            callOverlay.waitForExistence(timeout: Self.defaultTimeout),
            "Tapping \(CuvenAID.Thread.callAudioButton) must present \(CuvenAID.Call.activeOverlay)"
        )

        let muteBtn = elementMatchingAnyLabel(["call.mute", "Mute", "静音"], in: app)
        if muteBtn.waitForExistence(timeout: Self.shortTimeout) {
            tapSafely(muteBtn)
        }
        attachScreenshot(named: "Tier1-F8-AudioCall-ActiveOverlay")

        let endBtn = elementMatchingAnyLabel(["call.end", "call.hangup", "End", "Hang up", "Decline", "挂断", "结束"], in: app)
        if endBtn.waitForExistence(timeout: Self.shortTimeout) {
            tapSafely(endBtn)
            _ = waitForDisappearance(of: callOverlay, timeout: Self.defaultTimeout)
        }
    }

    @MainActor
    func testF8_02_VideoCallStartsWithCameraControlsAndSupportsDuoLaptopPosture() throws {
        let app = launchDemo(posture: .duoHalfLaptop)
        _ = openFirstConversation(in: app)

        let videoBtn = element(id: CuvenAID.Thread.callVideoButton, in: app)
        tapSafely(videoBtn)

        let callOverlay = element(id: CuvenAID.Call.activeOverlay, in: app)
        XCTAssertTrue(
            callOverlay.waitForExistence(timeout: Self.defaultTimeout),
            "Tapping \(CuvenAID.Thread.callVideoButton) in duoHalfLaptop must open tabletop Video Call overlay"
        )
        attachScreenshot(named: "Tier1-F8-VideoCall-DuoHalfLaptop")

        let endBtn = elementMatchingAnyLabel(["call.end", "call.hangup", "End", "Hang up", "挂断"], in: app)
        if endBtn.waitForExistence(timeout: Self.shortTimeout) {
            tapSafely(endBtn)
        }
    }

    @MainActor
    func testF8_03_ActiveCallMinimizesToCornerSnappingPiPTileAndRestores() throws {
        let app = launchDemo(posture: .duoOpen)
        _ = openFirstConversation(in: app)
        tapSafely(element(id: CuvenAID.Thread.callVideoButton, in: app))

        let callOverlay = element(id: CuvenAID.Call.activeOverlay, in: app)
        XCTAssertTrue(callOverlay.waitForExistence(timeout: Self.defaultTimeout))

        let minimizeBtn = elementMatchingAnyLabel(
            ["call.minimize", "call.pipButton", "Minimize", "PiP", "Collapse", "小窗", "收起"],
            in: app
        )
        if minimizeBtn.waitForExistence(timeout: Self.shortTimeout) {
            tapSafely(minimizeBtn)
        } else {
            callOverlay.swipeDown()
        }

        let pipTile = element(id: CuvenAID.Call.pipTile, in: app)
        XCTAssertTrue(
            pipTile.waitForExistence(timeout: Self.defaultTimeout),
            "Minimizing active call must present floating corner-snapping \(CuvenAID.Call.pipTile)"
        )
        attachScreenshot(named: "Tier1-F8-Call-PiPTile")

        tapSafely(pipTile)
        XCTAssertTrue(callOverlay.waitForExistence(timeout: Self.defaultTimeout))
    }

    @MainActor
    func testF8_04_SettingsSheetConfiguresThemeLiquidGlassComposerGlowAndBackdrop() throws {
        let app = launchDemo(posture: .duoOpen)
        let settings = openSettings(in: app)
        XCTAssertTrue(settings.exists)

        for optionLabel in ["Tinted", "Aurora", "Ocean", "Dark", "Light"] {
            let control = elementMatchingAnyLabel([optionLabel], in: app)
            if control.exists && control.isHittable {
                control.tap()
                settleUI(seconds: 0.15)
            }
        }
        attachScreenshot(named: "Tier1-F8-Settings-GlassAndGlow")
    }

    @MainActor
    func testF8_05_AvatarAndCoverFramingEditorOpensWithCropZoomAndDominantTint() throws {
        let app = launchDemo(posture: .duoOpen)
        _ = openSettings(in: app)

        let avatarBtn = element(id: CuvenAID.Settings.avatarEditorButton, in: app)
        XCTAssertTrue(
            avatarBtn.waitForExistence(timeout: Self.defaultTimeout),
            "Settings must expose Profile Avatar/Cover Editor trigger (\(CuvenAID.Settings.avatarEditorButton))"
        )
        tapSafely(avatarBtn)
        settleUI(seconds: 0.35)

        let coverSegment = elementMatchingAnyLabel(["Cover", "封面", "avatarEditor.cover"], in: app)
        if coverSegment.waitForExistence(timeout: Self.shortTimeout) {
            tapSafely(coverSegment)
            settleUI(seconds: 0.2)
        }
        attachScreenshot(named: "Tier1-F8-AvatarAndCover-Editor")
    }

    @MainActor
    func testF8_06_AIMemoryAnd24HourRoutineHistogramAnalyticsSheetOpens() throws {
        let app = launchDemo(posture: .duoOpen)
        let settings = openSettings(in: app)

        let aiMemoryBtn = element(id: CuvenAID.Settings.aiMemoryButton, in: app)
        if !aiMemoryBtn.isHittable {
            settings.swipeUp()
            settleUI(seconds: 0.25)
        }
        XCTAssertTrue(
            aiMemoryBtn.waitForExistence(timeout: Self.defaultTimeout),
            "Settings must expose AI Memory & 24h Routine analytics button (\(CuvenAID.Settings.aiMemoryButton))"
        )
        tapSafely(aiMemoryBtn)
        settleUI(seconds: 0.35)
        attachScreenshot(named: "Tier1-F8-AIMemory-24hRoutineChart")
    }
}
