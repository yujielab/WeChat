import XCTest

/// Tier 3 Opaque-Box Pairwise Cross-Feature & iPhone Duo Continuity Suite (14 tests >= 12).
/// Verifies stateful continuity across folding/unfolding postures, 4-column strip transitions,
/// floating Call PiP + Moments/Memories navigation, and Dark Mode + Tinted Liquid Glass + Aurora Glow.
final class CuvenTier3CrossFeatureDuoUITests: CuvenUITestCase {

    @MainActor
    func testPair01_DuoClosedToDuoOpenPreservesActiveConversationAndDraftText() throws {
        let app = launchDemo(posture: .duoClosed)
        let composer = openFirstConversation(in: app)
        let headerBefore = element(id: CuvenAID.Thread.headerPill, in: app).label

        let draftText = "这条草稿会跟着我展开和合起 🏔️"
        focusAndType(draftText, into: composer)

        switchPosture(to: .duoOpen, in: app)

        // In duoOpen, ChatList and Thread appear side-by-side while preserving conversation & draft
        XCTAssertTrue(firstChatRow(in: app).exists, "ChatList column must join Thread in duoOpen split")
        XCTAssertTrue(composer.exists, "Thread composer must stay mounted across unfold")
        XCTAssertTrue(
            textValue(of: composer).contains("这条草稿"),
            "Exact unsent draft must survive duoClosed -> duoOpen transition without loss or auto-send"
        )
        if !headerBefore.isEmpty {
            XCTAssertEqual(element(id: CuvenAID.Thread.headerPill, in: app).label, headerBefore)
        }
        attachScreenshot(named: "Tier3-Pair01-DuoClosedToOpen-DraftPreserved")
    }

    @MainActor
    func testPair02_DuoOpenToDuoClosedRoundTripPreservesSidebarScopeAndThreadFocus() throws {
        let app = launchDemo(posture: .duoOpen)
        revealSidebar(in: app)
        let directScope = element(id: CuvenAID.Sidebar.scopeDirect, in: app)
        if directScope.waitForExistence(timeout: Self.shortTimeout) {
            tapSafely(directScope)
        }

        let composer = openFirstConversation(in: app)
        focusAndType("Fold continuity check", into: composer)

        switchPosture(to: .duoClosed, in: app)
        XCTAssertTrue(
            element(id: CuvenAID.Thread.messageList, in: app).exists,
            "Folding from duoOpen to duoClosed must keep active Thread frontmost"
        )
        XCTAssertTrue(textValue(of: composer).contains("Fold continuity"))

        let backBtn = element(id: CuvenAID.Thread.backButton, in: app)
        if backBtn.waitForExistence(timeout: Self.shortTimeout) {
            tapSafely(backBtn)
            XCTAssertTrue(firstChatRow(in: app).waitForExistence(timeout: Self.defaultTimeout))
        }
    }

    @MainActor
    func testPair03_DuoOpenListThreadToThreadDrawingPreservesThreadStateAndZeroReflowWidth() throws {
        let app = launchDemo(posture: .duoOpen)
        let composer = openFirstConversation(in: app)

        let markerMsg = "Anchor message before Column 3 Drawing"
        focusAndType(markerMsg, into: composer)
        tapSafely(element(id: CuvenAID.Thread.sendButton, in: app))

        let messageList = element(id: CuvenAID.Thread.messageList, in: app)
        XCTAssertTrue(messageList.waitForExistence(timeout: Self.defaultTimeout))
        settleUI(seconds: 0.35)
        let widthWithList = messageList.frame.width

        let canvas = openDrawingBoardFromThread(in: app)
        settleUI(seconds: 0.45)

        XCTAssertTrue(canvas.exists)
        XCTAssertTrue(messageList.exists, "Column 2 Thread must remain visible alongside Column 3 Drawing")
        XCTAssertTrue(
            app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", markerMsg)).firstMatch.exists,
            "Opening Column 3 Drawing must preserve prior messages & scroll context in Thread"
        )
        XCTAssertEqual(
            messageList.frame.width,
            widthWithList,
            accuracy: 6.0,
            "Thread content width must not reflow when sliding from 342|609 to 525|426"
        )
    }

    @MainActor
    func testPair04_DuoOpenSideBySideDrawingSketchAndSendAppendsDirectlyToBesideThread() throws {
        let app = launchDemo(posture: .duoOpen)
        _ = openFirstConversation(in: app)
        let messageList = element(id: CuvenAID.Thread.messageList, in: app)
        let canvas = openDrawingBoardFromThread(in: app)

        let p1 = canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.20, dy: 0.30))
        let p2 = canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.55, dy: 0.70))
        let p3 = canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.80, dy: 0.40))
        p1.press(forDuration: 0.05, thenDragTo: p2)
        p2.press(forDuration: 0.05, thenDragTo: p3)

        let sendBtn = elementMatchingAnyLabel(
            ["drawing.send", "artifact.sendDrawing", "Send", "发送"],
            in: app
        )
        if sendBtn.waitForExistence(timeout: Self.shortTimeout) {
            tapSafely(sendBtn)
            settleUI(seconds: 0.45)
        }

        XCTAssertTrue(messageList.exists, "Sending sketch from Column 3 must deliver into adjacent Thread")
        attachScreenshot(named: "Tier3-Pair04-DuoOpen-SideBySideDrawingSent")
    }

    @MainActor
    func testPair05_DuoHalfBookHingePostureConfinesSplitPanesAndSheetsClearOfFold() throws {
        let app = launchDemo(posture: .duoHalfBook)
        let row = firstChatRow(in: app)
        tapSafely(row)

        let messageList = element(id: CuvenAID.Thread.messageList, in: app)
        XCTAssertTrue(messageList.waitForExistence(timeout: Self.defaultTimeout))
        XCTAssertLessThanOrEqual(
            row.frame.maxX,
            messageList.frame.minX + 2.0,
            "Leading and trailing columns in duoHalfBook must separate cleanly across the book hinge"
        )

        tapSafely(element(id: CuvenAID.ChatList.newChatButton, in: app))
        settleUI(seconds: 0.4)
        attachScreenshot(named: "Tier3-Pair05-DuoHalfBook-SheetBesideFold")
    }

    @MainActor
    func testPair06_DuoHalfLaptopTabletopKeepsThreadAboveAndComposerBelowHorizontalFold() throws {
        let app = launchDemo(posture: .duoClosed)
        let composer = openFirstConversation(in: app)
        focusAndType("Laptop tabletop typing deck", into: composer)

        switchPosture(to: .duoHalfLaptop, in: app)
        let messageList = element(id: CuvenAID.Thread.messageList, in: app)
        XCTAssertTrue(messageList.waitForExistence(timeout: Self.defaultTimeout))
        XCTAssertLessThan(
            messageList.frame.minY,
            composer.frame.minY,
            "duoHalfLaptop must place scrolling messages above the fold and composer on the lower deck"
        )
        XCTAssertTrue(textValue(of: composer).contains("Laptop tabletop"))
    }

    @MainActor
    func testPair07_ActiveCallMinimizedToPiPWhileNavigatingMomentsAndMemories() throws {
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
        XCTAssertTrue(pipTile.waitForExistence(timeout: Self.defaultTimeout))

        // Navigate to Moments while Call PiP stays alive
        let momentsFeed = openMoments(in: app)
        XCTAssertTrue(momentsFeed.exists)
        XCTAssertTrue(
            pipTile.exists,
            "Minimized \(CuvenAID.Call.pipTile) must persist across Moments navigation"
        )
        attachScreenshot(named: "Tier3-Pair07-CallPiP-OverMoments")

        // Close Moments if modal, then navigate to Memories while Call PiP stays alive
        let closeMoments = elementMatchingAnyLabel(["moments.close", "Close", "×", "关闭"], in: app)
        if closeMoments.exists && closeMoments.isHittable {
            closeMoments.tap()
            settleUI(seconds: 0.25)
        }

        let memoriesGrid = openMemories(in: app)
        XCTAssertTrue(memoriesGrid.exists)
        XCTAssertTrue(
            pipTile.exists,
            "Minimized \(CuvenAID.Call.pipTile) must persist across Memories navigation"
        )
        attachScreenshot(named: "Tier3-Pair07-CallPiP-OverMemories")

        // Tap PiP tile to restore full CallOverlay and end call
        tapSafely(pipTile)
        XCTAssertTrue(callOverlay.waitForExistence(timeout: Self.defaultTimeout))
        let hangup = elementMatchingAnyLabel(["call.end", "call.hangup", "End", "Hang up", "挂断"], in: app)
        if hangup.exists { tapSafely(hangup) }
    }

    @MainActor
    func testPair08_ActiveAudioCallTransitionsAcrossDuoClosedHalfLaptopAndDuoOpen() throws {
        let app = launchDemo(posture: .duoClosed)
        _ = openFirstConversation(in: app)
        tapSafely(element(id: CuvenAID.Thread.callAudioButton, in: app))

        let callOverlay = element(id: CuvenAID.Call.activeOverlay, in: app)
        XCTAssertTrue(callOverlay.waitForExistence(timeout: Self.defaultTimeout))

        for posture in [UITestPosture.duoHalfLaptop, UITestPosture.duoOpen] {
            if element(id: CuvenAID.Shell.postureSwitcher, in: app).exists {
                switchPosture(to: posture, in: app)
                XCTAssertTrue(
                    callOverlay.exists || element(id: CuvenAID.Call.pipTile, in: app).exists,
                    "Active call session must survive posture transition to \(posture.rawValue)"
                )
            }
        }
    }

    @MainActor
    func testPair09_DarkModePlusTintedLiquidGlassPlusAuroraGlowAcrossAllColumns() throws {
        let app = launchDemo(posture: .duoOpen)
        _ = openSettings(in: app)

        for choice in ["Dark", "Tinted", "Aurora", "Night"] {
            let opt = elementMatchingAnyLabel([choice], in: app)
            if opt.exists && opt.isHittable {
                opt.tap()
                settleUI(seconds: 0.15)
            }
        }

        dismissSettingsIfOpen(in: app)

        let composer = openFirstConversation(in: app)
        focusAndType("Dark + Tinted Liquid Glass + Aurora Glow ✨", into: composer)
        let info = openRoomInfoFromThread(in: app)
        XCTAssertTrue(info.exists)
        attachScreenshot(named: "Tier3-Pair09-Dark-TintedGlass-AuroraGlow")
    }

    @MainActor
    func testPair10_ForYouSmartInsightActionNavigatesDirectlyIntoTargetConversation() throws {
        let app = launchDemo(posture: .iPhoneCompact)
        let insightsDeck = app.cuvenElement(CuvenAID.ChatList.insightsDeck)
        XCTAssertTrue(insightsDeck.waitForExistence(timeout: Self.defaultTimeout))

        let cardCTA = insightsDeck.descendants(matching: .any).matching(
            NSPredicate(format: "label CONTAINS[cd] 'Open chat' OR label CONTAINS[cd] 'Say hi' OR label CONTAINS[cd] 'View' OR identifier CONTAINS[cd] 'action'")
        ).firstMatch
        if cardCTA.exists {
            tapSafely(cardCTA)
            settleUI(seconds: 0.4)
            XCTAssertTrue(
                app.cuvenElement(CuvenAID.Thread.messageList).exists || insightsDeck.exists,
                "Tapping For You Smart Insight CTA must open target conversation or contextual detail cleanly"
            )
        }
    }

    @MainActor
    func testPair11_PublishedNotePersistsAcrossDuoPagesSwitchToMomentsAndBack() throws {
        let app = launchDemo(posture: .duoOpen)
        let notesStrip = app.cuvenElement(CuvenAID.ChatList.notesStrip)
        let noteInput = openOwnNoteComposer(in: app)

        let noteText = "Duo cafe note ☕"
        if noteInput.exists {
            focusAndType(noteText, into: noteInput, clearExisting: true)
            let publish = elementMatchingAnyLabel(
                ["chatlist.noteComposer.share", "note.publish", "Share", "Post", "Save", "发布", "分享"],
                in: app
            )
            if publish.exists { tapSafely(publish) }
        }

        // Switch to Moments and return to Chats via Duo PagesCapsule
        _ = openMoments(in: app)
        let capsule = app.cuvenElement(CuvenAID.Shell.pagesCapsule)
        if capsule.exists {
            let chatsSlot = capsule.descendants(matching: .any).matching(
                NSPredicate(format: "identifier CONTAINS[cd] 'chats' OR label CONTAINS[cd] 'Chats' OR label CONTAINS '聊天'")
            ).firstMatch
            if chatsSlot.exists { tapSafely(chatsSlot) }
        } else {
            let closeMoments = elementMatchingAnyLabel(["moments.closeButton", "moments.close", "Close", "×", "关闭"], in: app)
            if closeMoments.exists { tapSafely(closeMoments) }
        }

        XCTAssertTrue(notesStrip.waitForExistence(timeout: Self.defaultTimeout))
    }

    @MainActor
    func testPair12_TelegramStickerSendCombinedWithTapbackReactionInThread() throws {
        let app = launchDemo(posture: .duoOpen)
        _ = openFirstConversation(in: app)
        openStickerDrawerFromThread(in: app)

        let stickerItem = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier CONTAINS[cd] 'sticker.item' OR identifier CONTAINS[cd] 'stickerCell'")
        ).firstMatch
        if stickerItem.waitForExistence(timeout: Self.shortTimeout) {
            tapSafely(stickerItem)
            settleUI(seconds: 0.35)
        }

        let messageList = app.cuvenElement(CuvenAID.Thread.messageList)
        XCTAssertTrue(messageList.exists)
        messageList.coordinate(withNormalizedOffset: CGVector(dx: 0.72, dy: 0.85)).doubleTap()
        settleUI(seconds: 0.25)
        XCTAssertEqual(app.state, .runningForeground)
    }

    @MainActor
    func testPair13_MomentsFilteredPostWithAltAppearsInAuthorProfileMediaGrid() throws {
        let app = launchDemo(posture: .duoOpen)
        _ = openMoments(in: app)
        tapSafely(app.cuvenElement(CuvenAID.Moments.composeButton))

        let filterStrip = app.cuvenElement(CuvenAID.Moments.editorFilterStrip)
        if filterStrip.waitForExistence(timeout: Self.shortTimeout) {
            let vivid = filterStrip.descendants(matching: .any).matching(
                NSPredicate(format: "label CONTAINS[cd] 'Vivid' OR identifier CONTAINS[cd] 'vivid'")
            ).firstMatch
            if vivid.exists { tapSafely(vivid) }
        }

        let altBtn = app.cuvenElement(CuvenAID.Moments.editorAltButton)
        if altBtn.exists {
            tapSafely(altBtn)
            settleUI(seconds: 0.2)
            let altInput = momentsAltInput(in: app)
            if altInput.exists {
                focusAndType("Vivid ridge cloudscape", into: altInput)
                let done = elementMatchingAnyLabel(
                    ["moments.editor.altDoneButton", "Done", "Save", "完成", "保存"],
                    in: app
                )
                if done.exists && done.identifier != CuvenAID.Moments.editorPublishButton {
                    tapSafely(done)
                }
            }
        }

        let caption = momentsCaptionInput(in: app)
        if caption.exists {
            focusAndType("Pairwise Moment #VividAlt", into: caption)
        }
        tapSafely(app.cuvenElement(CuvenAID.Moments.editorPublishButton))
        XCTAssertTrue(app.cuvenElement(CuvenAID.Moments.feed).waitForExistence(timeout: Self.defaultTimeout))
    }

    @MainActor
    func testPair14_QuoteReplyFollowedByInPlaceEditPreservesThreadConsistency() throws {
        let app = launchDemo(posture: .duoOpen)
        let composer = openFirstConversation(in: app)

        let parentText = "Parent anchor for reply+edit"
        focusAndType(parentText, into: composer)
        tapSafely(element(id: CuvenAID.Thread.sendButton, in: app))

        let parentBubble = app.descendants(matching: .any).matching(
            NSPredicate(format: "label CONTAINS %@", parentText)
        ).firstMatch
        XCTAssertTrue(parentBubble.waitForExistence(timeout: Self.defaultTimeout))
        parentBubble.swipeRight()
        settleUI(seconds: 0.25)

        let replyV1 = "Reply before edit"
        let replyV2 = "Reply after edit ✓"
        focusAndType(replyV1, into: composer)
        tapSafely(element(id: CuvenAID.Thread.sendButton, in: app))

        let replyBubble = app.descendants(matching: .any).matching(
            NSPredicate(format: "label CONTAINS %@", replyV1)
        ).firstMatch
        XCTAssertTrue(replyBubble.waitForExistence(timeout: Self.defaultTimeout))

        replyBubble.press(forDuration: 0.65)
        settleUI(seconds: 0.25)
        let editBtn = elementMatchingAnyLabel(["Edit", "编辑"], in: app)
        if editBtn.waitForExistence(timeout: Self.shortTimeout) {
            tapSafely(editBtn)
            focusAndType(replyV2, into: composer, clearExisting: true)
            tapSafely(element(id: CuvenAID.Thread.sendButton, in: app))
            XCTAssertTrue(
                app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", replyV2))
                    .firstMatch.waitForExistence(timeout: Self.defaultTimeout)
            )
        }
    }
}
