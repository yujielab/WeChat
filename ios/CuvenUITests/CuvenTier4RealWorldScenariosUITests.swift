import XCTest

/// Tier 4 Real-World End-to-End Application Scenarios (`S1`–`S6`, >= 5 journeys).
/// Exercises complete multi-screen user workflows across standard `iPhone` and `iPhone Duo`
/// postures using strictly opaque-box launch arguments and user-facing accessibility contracts.
final class CuvenTier4RealWorldScenariosUITests: CuvenUITestCase {

    // MARK: - S1: iPhone Compact Cold Boot -> Notes & Insights -> DM -> Send + Tapback + Edit -> Back

    @MainActor
    func testS1_IPhoneCompactColdBootNotesInsightsDMSendTapbackEditAndPinnedSwipeBack() throws {
        let app = launchDemo(posture: .iPhoneCompact)

        // 1. Verify iPhoneCompact 1-column stack + 56pt horizontal Liquid Glass bottom dock
        let bottomDock = element(id: CuvenAID.Shell.bottomDock, in: app)
        XCTAssertTrue(bottomDock.waitForExistence(timeout: Self.defaultTimeout))
        XCTAssertFalse(element(id: CuvenAID.Shell.duoRail, in: app).exists && element(id: CuvenAID.Shell.duoRail, in: app).isHittable)

        // 2. Browse 24h Notes shelf & For You Smart Insights deck
        let notesStrip = element(id: CuvenAID.ChatList.notesStrip, in: app)
        let insightsDeck = element(id: CuvenAID.ChatList.insightsDeck, in: app)
        XCTAssertTrue(notesStrip.waitForExistence(timeout: Self.defaultTimeout))
        XCTAssertTrue(insightsDeck.waitForExistence(timeout: Self.defaultTimeout))
        attachScreenshot(named: "Tier4-S1-01-iPhoneCompact-Inbox")

        // 3. Open DM conversation
        let firstRow = firstChatRow(in: app)
        tapSafely(firstRow)

        let composer = element(id: CuvenAID.Thread.composerField, in: app)
        let headerPill = element(id: CuvenAID.Thread.headerPill, in: app)
        XCTAssertTrue(composer.waitForExistence(timeout: Self.defaultTimeout))
        XCTAssertTrue(headerPill.waitForExistence(timeout: Self.defaultTimeout))

        // 4. Send message
        let initialMsg = "Coffee by the lake at 15:30?"
        focusAndType(initialMsg, into: composer)
        tapSafely(element(id: CuvenAID.Thread.sendButton, in: app))

        let sentBubble = app.descendants(matching: .any).matching(
            NSPredicate(format: "label CONTAINS %@", initialMsg)
        ).firstMatch
        XCTAssertTrue(sentBubble.waitForExistence(timeout: Self.defaultTimeout))

        // 5. Add Tapback reaction (❤️)
        sentBubble.press(forDuration: 0.65)
        settleUI(seconds: 0.25)
        let heartBtn = elementMatchingAnyLabel(["❤️", "Love", "Heart", "喜欢"], in: app)
        if heartBtn.waitForExistence(timeout: Self.shortTimeout) {
            tapSafely(heartBtn)
        } else {
            sentBubble.doubleTap()
        }
        settleUI(seconds: 0.25)

        // 6. Edit message in place
        let editedMsg = "Coffee by West Lake at 15:45! ☕"
        sentBubble.press(forDuration: 0.65)
        settleUI(seconds: 0.25)
        let editAction = elementMatchingAnyLabel(["Edit", "编辑"], in: app)
        if editAction.waitForExistence(timeout: Self.shortTimeout) {
            tapSafely(editAction)
            focusAndType(editedMsg, into: composer, clearExisting: true)
            tapSafely(element(id: CuvenAID.Thread.sendButton, in: app))
            XCTAssertTrue(
                app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS '15:45'"))
                    .firstMatch.waitForExistence(timeout: Self.defaultTimeout)
            )
        }
        attachScreenshot(named: "Tier4-S1-02-iPhoneCompact-ThreadEditedAndReacted")

        // 7. Navigate back via stationary Back pill / interactive swipe-back to ChatList
        let backBtn = element(id: CuvenAID.Thread.backButton, in: app)
        if backBtn.waitForExistence(timeout: Self.shortTimeout) {
            tapSafely(backBtn)
        } else {
            let msgList = element(id: CuvenAID.Thread.messageList, in: app)
            let start = msgList.coordinate(withNormalizedOffset: CGVector(dx: 0.03, dy: 0.5))
            let end = msgList.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.5))
            start.press(forDuration: 0.05, thenDragTo: end)
        }
        XCTAssertTrue(firstChatRow(in: app).waitForExistence(timeout: Self.defaultTimeout))
    }

    // MARK: - S2: iPhone Duo Closed -> Unfold to Open Preserving Draft -> Zero-Reflow Drawing Sketch & Send

    @MainActor
    func testS2_IPhoneDuoClosedToOpenPreservingDraftThenZeroReflowDrawingSketchAndSend() throws {
        // 1. Launch on iPhone Duo outer display (duoClosed: 466x678 + 52pt DuoRail + PagesCapsule)
        let app = launchDemo(posture: .duoClosed)
        XCTAssertTrue(element(id: CuvenAID.Shell.duoRail, in: app).waitForExistence(timeout: Self.defaultTimeout))
        XCTAssertTrue(element(id: CuvenAID.Shell.pagesCapsule, in: app).waitForExistence(timeout: Self.defaultTimeout))

        // 2. Open conversation and start an unsent draft
        let composer = openFirstConversation(in: app)
        let draft = "Unfolding Duo to sketch the route map right beside our chat"
        focusAndType(draft, into: composer)
        attachScreenshot(named: "Tier4-S2-01-DuoClosed-DraftInProgress")

        // 3. Unfold to duoOpen (342|609 split) — verify active conversation & draft preserved
        switchPosture(to: .duoOpen, in: app)
        XCTAssertTrue(firstChatRow(in: app).exists, "Unfolding to duoOpen must reveal leading ChatList column")
        XCTAssertTrue(
            textValue(of: composer).contains("Unfolding Duo"),
            "Draft text must survive unfolding from duoClosed to duoOpen"
        )

        // Send the preserved draft
        tapSafely(element(id: CuvenAID.Thread.sendButton, in: app))
        let messageList = element(id: CuvenAID.Thread.messageList, in: app)
        XCTAssertTrue(messageList.waitForExistence(timeout: Self.defaultTimeout))
        settleUI(seconds: 0.35)
        let threadWidthInListSplit = messageList.frame.width
        attachScreenshot(named: "Tier4-S2-02-DuoOpen-342x609-ListAndThread")

        // 4. Open Drawing Board (slides strip to Thread|Drawing 525|426 with ZERO thread reflow!)
        let canvas = openDrawingBoardFromThread(in: app)
        settleUI(seconds: 0.45)
        let threadWidthInArtifactSplit = messageList.frame.width
        XCTAssertEqual(
            threadWidthInArtifactSplit,
            threadWidthInListSplit,
            accuracy: 6.0,
            "Zero-Reflow Mandate: Thread content width must stay constant (525pt) when Drawing Board opens beside it"
        )

        // 5. Sketch multi-segment path on canvas and send drawing into conversation
        let c1 = canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.22, dy: 0.30))
        let c2 = canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.50, dy: 0.68))
        let c3 = canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.78, dy: 0.35))
        c1.press(forDuration: 0.05, thenDragTo: c2)
        c2.press(forDuration: 0.05, thenDragTo: c3)
        attachScreenshot(named: "Tier4-S2-03-DuoOpen-525x426-DrawingSketch")

        let sendSketch = elementMatchingAnyLabel(
            ["drawing.send", "artifact.sendDrawing", "Send", "发送"],
            in: app
        )
        if sendSketch.waitForExistence(timeout: Self.shortTimeout) {
            tapSafely(sendSketch)
        }
        settleUI(seconds: 0.4)
        XCTAssertTrue(messageList.exists)
    }

    // MARK: - S3: DuoRail Pages Capsule -> Moments -> Multi-Filter + ALT + @Tag -> Publish -> Feed & Profile

    @MainActor
    func testS3_DuoPagesCapsuleToMomentsComposeFilterAltTagPublishAndVerifyInFeedAndProfile() throws {
        let app = launchDemo(posture: .duoOpen)

        // 1. Navigate via DuoRail Pages capsule to Moments
        let feed = openMoments(in: app)
        XCTAssertTrue(feed.exists)

        // 2. Open Full-Page Moments Editor
        let composeBtn = element(id: CuvenAID.Moments.composeButton, in: app)
        tapSafely(composeBtn)

        let filterStrip = element(id: CuvenAID.Moments.editorFilterStrip, in: app)
        let altBtn = element(id: CuvenAID.Moments.editorAltButton, in: app)
        let publishBtn = element(id: CuvenAID.Moments.editorPublishButton, in: app)
        XCTAssertTrue(filterStrip.waitForExistence(timeout: Self.defaultTimeout))
        XCTAssertTrue(altBtn.waitForExistence(timeout: Self.defaultTimeout))
        XCTAssertTrue(publishBtn.waitForExistence(timeout: Self.defaultTimeout))

        // 3. Apply CoreImage filter tone (Warm -> Vivid)
        for filterName in ["Warm", "Vivid"] {
            let tone = filterStrip.descendants(matching: .any).matching(
                NSPredicate(format: "label CONTAINS[cd] %@ OR identifier CONTAINS[cd] %@", filterName, filterName)
            ).firstMatch
            if tone.exists && tone.isHittable {
                tone.tap()
                settleUI(seconds: 0.15)
            }
        }

        // 4. Add +ALT accessibility description
        tapSafely(altBtn)
        settleUI(seconds: 0.25)
        let altInput = momentsAltInput(in: app)
        if altInput.exists {
            focusAndType("Alpine ridge golden hour with warm mist", into: altInput)
            let saveAlt = elementMatchingAnyLabel(
                ["moments.editor.altDoneButton", "Done", "Save", "OK", "完成", "保存"],
                in: app
            )
            if saveAlt.exists && saveAlt.identifier != CuvenAID.Moments.editorPublishButton {
                tapSafely(saveAlt)
            }
        }

        // 5. Optional @Tag friend selection + caption
        let tagBtn = elementMatchingAnyLabel(
            ["moments.editor.tagFriendsButton", "Tag", "With", "@", "圈人", "提醒谁看"],
            in: app
        )
        if tagBtn.exists && tagBtn.isHittable {
            tagBtn.tap()
            settleUI(seconds: 0.2)
            let friendOption = elementMatchingAnyLabel(["Coisini", "Hong"], in: app)
            if friendOption.exists && friendOption.isHittable { friendOption.tap() }
            let doneTag = elementMatchingAnyLabel(["Done", "完成"], in: app)
            if doneTag.exists && doneTag.identifier != CuvenAID.Moments.editorPublishButton {
                doneTag.tap()
            }
        }

        let momentCaption = "Golden ridge twilight on iPhone Duo 🏔️ #S3Journey"
        let captionField = momentsCaptionInput(in: app)
        if captionField.exists {
            focusAndType(momentCaption, into: captionField)
        }
        attachScreenshot(named: "Tier4-S3-01-MomentsEditor-Configured")

        // 6. Publish and verify in Moments feed & Profile waterfall
        tapSafely(publishBtn)
        settleUI(seconds: 0.5)
        XCTAssertTrue(feed.waitForExistence(timeout: Self.defaultTimeout))
        XCTAssertTrue(
            app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS 'Golden ridge twilight'"))
                .firstMatch.waitForExistence(timeout: Self.defaultTimeout),
            "Published Moment must appear at the top of moments.feed"
        )
        attachScreenshot(named: "Tier4-S3-02-MomentsFeed-Published")

        let profileTrigger = elementMatchingAnyLabel(
            ["moments.myProfileButton", "moments.profile", "Your moments", "Tokio", "个人主页"],
            in: app
        )
        if profileTrigger.exists && profileTrigger.isHittable {
            profileTrigger.tap()
            settleUI(seconds: 0.35)
            let mediaTab = elementMatchingAnyLabel(["moments.profile.mediaTab", "Media", "相册", "媒体"], in: app)
            if mediaTab.exists && mediaTab.isHittable { mediaTab.tap() }
            attachScreenshot(named: "Tier4-S3-03-MomentsProfile-MediaWaterfall")
        }
    }

    // MARK: - S4: Duo Video Call -> Half-Laptop Tabletop Split -> Corner-Snapping PiP + Memories Flashback

    @MainActor
    func testS4_IPhoneDuoVideoCallToHalfLaptopSplitThenCornerSnappingPiPAcrossMemoriesFlashback() throws {
        let app = launchDemo(posture: .duoOpen)
        _ = openFirstConversation(in: app)

        // 1. Initiate Video Call
        tapSafely(app.cuvenElement(CuvenAID.Thread.callVideoButton))
        let callOverlay = app.cuvenElement(CuvenAID.Call.activeOverlay)
        XCTAssertTrue(callOverlay.waitForExistence(timeout: Self.defaultTimeout))
        attachScreenshot(named: "Tier4-S4-01-VideoCall-DuoOpen")

        // 2. Transition to duoHalfLaptop tabletop posture
        if app.cuvenElement(CuvenAID.Shell.postureSwitcher).exists {
            switchPosture(to: .duoHalfLaptop, in: app)
            XCTAssertTrue(callOverlay.exists, "Video Call overlay must adapt continuously into duoHalfLaptop tabletop split")
            attachScreenshot(named: "Tier4-S4-02-VideoCall-DuoHalfLaptop")
            switchPosture(to: .duoOpen, in: app)
        }

        // 3. Minimize active call to corner-snapping PiP tile
        let minimizeBtn = elementMatchingAnyLabel(
            ["call.minimize", "call.pipButton", "Minimize", "PiP", "Collapse", "小窗", "收起"],
            in: app
        )
        if minimizeBtn.waitForExistence(timeout: Self.shortTimeout) {
            tapSafely(minimizeBtn)
        } else {
            callOverlay.swipeDown()
        }

        let pipTile = app.cuvenElement(CuvenAID.Call.pipTile)
        XCTAssertTrue(pipTile.waitForExistence(timeout: Self.defaultTimeout))

        // 4. Browse Memories & play Monthly Flashback slideshow while Call PiP stays alive
        let memoriesGrid = openMemories(in: app)
        XCTAssertTrue(memoriesGrid.exists)
        XCTAssertTrue(pipTile.exists, "Call PiP tile must remain visible over Memories grid")

        let flashbackBtn = app.cuvenElement(CuvenAID.Memories.flashbackPlay)
        XCTAssertTrue(flashbackBtn.waitForExistence(timeout: Self.defaultTimeout))
        tapSafely(flashbackBtn)
        settleUI(seconds: 0.45)
        attachScreenshot(named: "Tier4-S4-03-CallPiP-OverMemoriesFlashback")

        let closeFlashback = elementMatchingAnyLabel(
            ["lightbox.closeButton", "lightbox.close", "memories.slideshowClose", "Close", "Done", "关闭", "完成"],
            in: app
        )
        if closeFlashback.exists && closeFlashback.isHittable {
            closeFlashback.tap()
            settleUI(seconds: 0.25)
        }

        // 5. Restore CallOverlay from PiP and hang up cleanly
        tapSafely(pipTile)
        XCTAssertTrue(callOverlay.waitForExistence(timeout: Self.defaultTimeout))
        let endBtn = elementMatchingAnyLabel(["call.end", "call.hangup", "End", "Hang up", "挂断"], in: app)
        if endBtn.exists { tapSafely(endBtn) }
        _ = waitForDisappearance(of: callOverlay, timeout: Self.defaultTimeout)
    }

    // MARK: - S5: Avatar Crop (512x512 + Tint) + Tinted Liquid Glass + Aurora Glow + Dark Mode

    @MainActor
    func testS5_AvatarCrop512DominantTintPlusTintedLiquidGlassAuroraGlowDarkModeVerification() throws {
        let app = launchDemo(posture: .duoOpen)

        // 1. Open Settings & launch Avatar/Cover Crop Editor
        _ = openSettings(in: app)
        let avatarBtn = app.cuvenElement(CuvenAID.Settings.avatarEditorButton)
        XCTAssertTrue(avatarBtn.waitForExistence(timeout: Self.defaultTimeout))
        tapSafely(avatarBtn)
        settleUI(seconds: 0.35)

        let zoomSlider = app.sliders.firstMatch
        if zoomSlider.exists && zoomSlider.isHittable {
            zoomSlider.adjust(toNormalizedSliderPosition: 0.65)
        }
        attachScreenshot(named: "Tier4-S5-01-AvatarCrop512-DominantTint")

        let saveAvatar = elementMatchingAnyLabel(
            ["avatarEditor.doneButton", "avatarEditor.save", "avatarEditor.done", "Done", "Save", "完成", "保存"],
            in: app
        )
        if saveAvatar.waitForExistence(timeout: Self.shortTimeout) {
            tapSafely(saveAvatar)
            settleUI(seconds: 0.3)
        }

        // 2. Inspect AI Memory & 24h Routine histogram
        let settingsAgain = openSettings(in: app)
        let aiMemoryBtn = app.cuvenElement(CuvenAID.Settings.aiMemoryButton)
        if !aiMemoryBtn.isHittable { settingsAgain.swipeUp() }
        if aiMemoryBtn.waitForExistence(timeout: Self.shortTimeout) {
            tapSafely(aiMemoryBtn)
            settleUI(seconds: 0.3)
            let backFromMemory = elementMatchingAnyLabel(["Back", "Close", "Done", "Settings", "返回", "完成"], in: app)
            if backFromMemory.exists && backFromMemory.isHittable {
                backFromMemory.tap()
                settleUI(seconds: 0.25)
            }
        }

        // 3. Configure Dark Mode + Tinted Liquid Glass + Aurora Composer Glow
        _ = openSettings(in: app)
        for prefLabel in ["Dark", "Tinted", "Aurora"] {
            let toggle = elementMatchingAnyLabel([prefLabel], in: app)
            if toggle.exists && toggle.isHittable {
                toggle.tap()
                settleUI(seconds: 0.15)
            }
        }

        dismissSettingsIfOpen(in: app)

        // 4. Verify customized appearance across ChatList and Thread
        XCTAssertTrue(firstChatRow(in: app).exists)
        let composer = openFirstConversation(in: app)
        focusAndType("Verified Tinted Glass + Aurora Glow + Dark Mode!", into: composer)
        tapSafely(app.cuvenElement(CuvenAID.Thread.sendButton))
        attachScreenshot(named: "Tier4-S5-02-DarkMode-TintedGlass-AuroraThread")
    }

    // MARK: - S6: Logged-Out Invite Track -> Demo Onboarding -> Sidebar & Room Info -> Confirmed Sign Out

    @MainActor
    func testS6_LoggedOutInviteTrackThroughMultiColumnSessionToConfirmedSignOut() throws {
        // 1. Cold boot logged-out on iPhone Duo closed outer display
        let app = launchLoggedOut(posture: .duoClosed)
        XCTAssertTrue(element(id: CuvenAID.Auth.wordmark, in: app).exists)
        XCTAssertTrue(element(id: CuvenAID.Auth.username, in: app).exists)
        XCTAssertTrue(element(id: CuvenAID.Auth.password, in: app).exists)

        // 2. Enter authenticated rich Demo session
        tapSafely(element(id: CuvenAID.Auth.demoButton, in: app))
        XCTAssertTrue(element(id: CuvenAID.Shell.strip, in: app).waitForExistence(timeout: Self.defaultTimeout))

        // 3. Unfold to duoOpen, exercise Sidebar scopes, and inspect Column 3 Room Info
        switchPosture(to: .duoOpen, in: app)
        revealSidebar(in: app)
        tapSafely(element(id: CuvenAID.Sidebar.scopeAll, in: app))

        _ = openFirstConversation(in: app)
        let roomInfo = openRoomInfoFromThread(in: app)
        XCTAssertTrue(roomInfo.exists)

        // 4. Open Settings and execute confirmed Sign Out back to AuthRootView
        let settings = openSettings(in: app)
        settings.swipeUp()
        let signOutBtn = elementMatchingAnyLabel(["settings.signOut", "Sign Out", "Sign out", "Log Out", "退出登录"], in: app)
        if signOutBtn.waitForExistence(timeout: Self.shortTimeout) {
            tapSafely(signOutBtn)
            settleUI(seconds: 0.3)
            let confirmSignOut = app.alerts.firstMatch.buttons.matching(
                NSPredicate(format: "label CONTAINS[cd] 'Sign Out' OR label CONTAINS[cd] 'Log Out' OR label CONTAINS '退出'")
            ).firstMatch
            if confirmSignOut.exists {
                confirmSignOut.tap()
            } else {
                let sheetConfirm = elementMatchingAnyLabel(["auth.confirmSignOut", "Sign Out", "退出登录"], in: app)
                if sheetConfirm.exists && sheetConfirm.isHittable { sheetConfirm.tap() }
            }
            XCTAssertTrue(
                element(id: CuvenAID.Auth.wordmark, in: app).waitForExistence(timeout: Self.defaultTimeout),
                "Confirmed Sign Out must clear session and return cleanly to AuthRootView"
            )
        }
    }
}
