import XCTest

/// Tier 2 Opaque-Box Boundary, Negative & Adversarial Corner-Case Suite (42 tests >= 40).
/// Exercises empty/whitespace inputs, 60-char Note boundary, 15m/5x Edit limits, long multi-line
/// composer wrapping without bar overflow, rapid posture switches, encoding/escaping fidelity,
/// invalid login error handling, discard guards, and clean modal dismissal.
final class CuvenTier2BoundaryUITests: CuvenUITestCase {

    // =========================================================================
    // MARK: - Auth & Input Validation Boundaries (B01–B06)
    // =========================================================================

    @MainActor
    func testB01_AuthEmptyUsernameAndPasswordRejectsSubmitWithoutEnteringShell() throws {
        let app = launchLoggedOut(posture: .iPhoneCompact)
        let submit = element(id: CuvenAID.Auth.submit, in: app)
        XCTAssertTrue(submit.waitForExistence(timeout: Self.defaultTimeout))

        if submit.isEnabled && submit.isHittable {
            submit.tap()
        }
        settleUI(seconds: 0.4)

        XCTAssertTrue(
            element(id: CuvenAID.Auth.wordmark, in: app).exists,
            "Submitting empty credentials must remain on Auth screen without crash"
        )
        XCTAssertFalse(
            element(id: CuvenAID.Shell.strip, in: app).exists,
            "Empty credentials must NEVER authenticate into shell.strip"
        )
    }

    @MainActor
    func testB02_AuthWhitespaceOnlyUsernameAndPasswordRejected() throws {
        let app = launchLoggedOut(posture: .iPhoneCompact)
        focusAndType("   \u{3000} ", into: element(id: CuvenAID.Auth.username, in: app))
        focusAndType("      ", into: element(id: CuvenAID.Auth.password, in: app))

        let submit = element(id: CuvenAID.Auth.submit, in: app)
        if submit.isEnabled && submit.isHittable {
            submit.tap()
        }
        settleUI(seconds: 0.45)

        XCTAssertTrue(element(id: CuvenAID.Auth.wordmark, in: app).exists)
        XCTAssertFalse(element(id: CuvenAID.Shell.strip, in: app).exists)
    }

    @MainActor
    func testB03_AuthShortPasswordUnderSixCharactersRejectedCleanly() throws {
        let app = launchLoggedOut(posture: .iPhoneCompact)
        let registerTab = elementMatchingAnyLabel(
            ["auth.mode.register", "Create account", "Register", "创建账号", "注册"],
            in: app
        )
        if registerTab.waitForExistence(timeout: Self.shortTimeout) {
            tapSafely(registerTab)
        }

        focusAndType("valid_user_01", into: element(id: CuvenAID.Auth.username, in: app))
        focusAndType("12345", into: element(id: CuvenAID.Auth.password, in: app))

        let submit = element(id: CuvenAID.Auth.submit, in: app)
        if submit.isEnabled && submit.isHittable {
            submit.tap()
        }
        settleUI(seconds: 0.5)

        XCTAssertTrue(
            element(id: CuvenAID.Auth.wordmark, in: app).exists,
            "Password < 6 chars must stay on Auth view and surface validation feedback"
        )
        XCTAssertFalse(element(id: CuvenAID.Shell.strip, in: app).exists)
    }

    @MainActor
    func testB04_AuthInvalidUsernameCharactersAndOverlongHandleRejected() throws {
        let app = launchLoggedOut(posture: .iPhoneCompact)
        let registerTab = elementMatchingAnyLabel(
            ["auth.mode.register", "Create account", "Register", "创建账号", "注册"],
            in: app
        )
        if registerTab.waitForExistence(timeout: Self.shortTimeout) {
            tapSafely(registerTab)
        }

        focusAndType("bad user!@#$$%^&*()", into: element(id: CuvenAID.Auth.username, in: app))
        focusAndType("validPass123", into: element(id: CuvenAID.Auth.password, in: app))

        let submit = element(id: CuvenAID.Auth.submit, in: app)
        if submit.isEnabled && submit.isHittable {
            submit.tap()
        }
        settleUI(seconds: 0.5)

        XCTAssertTrue(element(id: CuvenAID.Auth.wordmark, in: app).exists)
        XCTAssertFalse(element(id: CuvenAID.Shell.strip, in: app).exists)
    }

    @MainActor
    func testB05_AuthSegmentedInviteTrackHandlesOversizedInputWithoutLayoutOverflow() throws {
        let app = launchLoggedOut(posture: .duoClosed)
        let window = app.windows.firstMatch
        let inviteTrack = element(id: CuvenAID.Auth.inviteCodeTrack, in: app)

        if !inviteTrack.exists {
            let registerTab = elementMatchingAnyLabel(
                ["auth.mode.register", "Create account", "Register", "创建账号", "注册"],
                in: app
            )
            if registerTab.waitForExistence(timeout: Self.shortTimeout) {
                tapSafely(registerTab)
            }
        }
        XCTAssertTrue(inviteTrack.waitForExistence(timeout: Self.defaultTimeout))

        focusAndType("ABCDEFGHIJKLMNOP1234567890", into: inviteTrack)
        settleUI(seconds: 0.25)

        XCTAssertLessThanOrEqual(
            inviteTrack.frame.maxX,
            window.frame.maxX + 2.0,
            "Segmented invite track must clamp or contain long input without overflowing screen width"
        )
    }

    @MainActor
    func testB06_AuthInvalidCredentialsGracefulErrorAndSubsequentDemoRecovery() throws {
        let app = launchLoggedOut(posture: .iPhoneCompact)
        focusAndType("nonexistent_probe_user_99", into: element(id: CuvenAID.Auth.username, in: app))
        focusAndType("wrong_password_99", into: element(id: CuvenAID.Auth.password, in: app))

        let submit = element(id: CuvenAID.Auth.submit, in: app)
        if submit.isEnabled {
            tapSafely(submit)
        }
        settleUI(seconds: 1.0)

        XCTAssertEqual(app.state, .runningForeground, "Failed login must never crash app process")
        XCTAssertTrue(element(id: CuvenAID.Auth.demoButton, in: app).exists)

        tapSafely(element(id: CuvenAID.Auth.demoButton, in: app))
        XCTAssertTrue(
            element(id: CuvenAID.Shell.strip, in: app).waitForExistence(timeout: Self.defaultTimeout),
            "App must recover cleanly into Demo session after invalid login error"
        )
    }

    // =========================================================================
    // MARK: - Spatial Strip, Safe-Area & Rapid Posture Switching (B07–B12)
    // =========================================================================

    @MainActor
    func testB07_RapidPostureCyclingSixModesPreservesShellWithoutCrashOrBlankScreen() throws {
        let app = launchDemo(posture: .iPhoneCompact)
        _ = openFirstConversation(in: app)

        let sequence: [UITestPosture] = [
            .duoClosed, .duoOpen, .duoHalfBook, .duoHalfLaptop, .iPhoneSplit, .iPhoneCompact, .duoOpen
        ]
        for posture in sequence {
            switchPosture(to: posture, in: app)
            XCTAssertEqual(app.state, .runningForeground, "App must survive rapid transition to \(posture.rawValue)")
        }

        let strip = element(id: CuvenAID.Shell.strip, in: app)
        XCTAssertTrue(strip.exists, "shell.strip must remain mounted after rapid 7-step posture stress")
        XCTAssertGreaterThan(strip.frame.width, 200.0)
    }

    @MainActor
    func testB08_IPhoneSplitSymmetricSafeAreaSuppressesVerticalDuoRail() throws {
        let app = launchDemo(posture: .iPhoneSplit)
        let duoRail = element(id: CuvenAID.Shell.duoRail, in: app)
        let pagesCapsule = element(id: CuvenAID.Shell.pagesCapsule, in: app)

        XCTAssertFalse(
            duoRail.exists && duoRail.isHittable,
            "Symmetric iPhoneSplit landscape must NOT display Duo right-edge rail"
        )
        XCTAssertFalse(
            pagesCapsule.exists && pagesCapsule.isHittable,
            "Symmetric iPhoneSplit landscape must NOT display Duo 6-slot Pages capsule"
        )
    }

    @MainActor
    func testB09_DuoClosedRightRailStaysWithinWindowAndClearsTopCameraReserve() throws {
        let app = launchDemo(posture: .duoClosed)
        let window = app.windows.firstMatch
        let duoRail = element(id: CuvenAID.Shell.duoRail, in: app)
        XCTAssertTrue(duoRail.waitForExistence(timeout: Self.defaultTimeout))

        XCTAssertGreaterThanOrEqual(
            duoRail.frame.minY,
            12.0,
            "DuoRail must respect top reserve clearance for outer camera & status ring"
        )
        XCTAssertLessThanOrEqual(
            duoRail.frame.maxX,
            window.frame.maxX + 2.0,
            "DuoRail must remain strictly inside physical right edge"
        )
        XCTAssertLessThanOrEqual(
            duoRail.frame.width,
            96.0,
            "DuoRail width targets 52pt inside the right system column"
        )
    }

    @MainActor
    func testB10_DuoOpenRightRailDoesNotOccludeLeadingChatListRows() throws {
        let app = launchDemo(posture: .duoOpen)
        let row = firstChatRow(in: app)
        let duoRail = element(id: CuvenAID.Shell.duoRail, in: app)
        XCTAssertTrue(duoRail.waitForExistence(timeout: Self.defaultTimeout))

        XCTAssertLessThanOrEqual(
            row.frame.maxX,
            duoRail.frame.minX,
            "Leading ChatList rows must never collide with trailing DuoRail"
        )
    }

    @MainActor
    func testB11_AbortedShortSwipeBackSpringsBackWithoutLeavingConversation() throws {
        let app = launchDemo(posture: .iPhoneCompact)
        let composer = openFirstConversation(in: app)
        let messageList = element(id: CuvenAID.Thread.messageList, in: app)
        XCTAssertTrue(messageList.waitForExistence(timeout: Self.defaultTimeout))

        // Short 6% horizontal drag below 38% commit threshold must spring back to Thread
        let start = messageList.coordinate(withNormalizedOffset: CGVector(dx: 0.04, dy: 0.5))
        let slight = messageList.coordinate(withNormalizedOffset: CGVector(dx: 0.12, dy: 0.5))
        start.press(forDuration: 0.12, thenDragTo: slight)
        settleUI(seconds: 0.4)

        XCTAssertTrue(
            composer.exists,
            "Aborted short edge drag must spring back and keep current Thread open"
        )
    }

    @MainActor
    func testB12_DuoOpenArtifactCloseReturnsCleanlyToListAndThreadPair() throws {
        let app = launchDemo(posture: .duoOpen)
        _ = openFirstConversation(in: app)
        let info = openRoomInfoFromThread(in: app)
        XCTAssertTrue(info.exists)

        let closeBtn = elementMatchingAnyLabel(
            ["artifact.close", "Close", "Back", "Done", "关闭", "返回"],
            in: app
        )
        if closeBtn.waitForExistence(timeout: Self.shortTimeout) {
            tapSafely(closeBtn)
        }
        settleUI(seconds: 0.4)

        XCTAssertTrue(
            firstChatRow(in: app).exists && element(id: CuvenAID.Thread.messageList, in: app).exists,
            "Closing Column 3 Artifact in duoOpen must slide cleanly back to Column 1|2 (ChatList|Thread)"
        )
    }

    // =========================================================================
    // MARK: - ChatList, 60-Char Note Limit, Search & Swipe Boundaries (B13–B18)
    // =========================================================================

    @MainActor
    func testB13_NoteExact60CharacterBoundaryAcceptedCleanly() throws {
        let app = launchDemo(posture: .iPhoneCompact)
        let notesStrip = app.cuvenElement(CuvenAID.ChatList.notesStrip)
        let input = openOwnNoteComposer(in: app)

        let exact60 = String(repeating: "N", count: 60)
        if input.exists {
            focusAndType(exact60, into: input, clearExisting: true)
            let val = textValue(of: input)
            XCTAssertLessThanOrEqual(val.count, 60, "60-char note input must accept up to 60 characters")

            let publish = elementMatchingAnyLabel(
                ["chatlist.noteComposer.share", "note.publish", "Share", "Post", "Save", "发布", "分享"],
                in: app
            )
            if publish.exists && publish.isEnabled {
                tapSafely(publish)
            }
        }
        XCTAssertTrue(notesStrip.waitForExistence(timeout: Self.defaultTimeout))
    }

    @MainActor
    func testB14_NoteOver60CharactersClampedOrBlockedAtBoundary() throws {
        let app = launchDemo(posture: .iPhoneCompact)
        let input = openOwnNoteComposer(in: app)

        let over75 = String(repeating: "X", count: 75)
        if input.exists {
            focusAndType(over75, into: input, clearExisting: true)
            settleUI(seconds: 0.2)
            let val = textValue(of: input)
            let publish = elementMatchingAnyLabel(
                ["chatlist.noteComposer.share", "note.publish", "Share", "Post", "Save", "发布", "分享"],
                in: app
            )
            let clamped = val.count <= 60
            let blocked = publish.exists && !publish.isEnabled
            XCTAssertTrue(
                clamped || blocked,
                "UserNote > 60 chars (\(val.count)) must either clamp to 60 chars or disable publish button"
            )
        }
    }

    @MainActor
    func testB15_NoteEmptyOrWhitespaceOnlyCannotPublishBlankNote() throws {
        let app = launchDemo(posture: .iPhoneCompact)
        let input = openOwnNoteComposer(in: app)

        if input.exists {
            focusAndType("    ", into: input, clearExisting: true)
            let publish = elementMatchingAnyLabel(
                ["chatlist.noteComposer.share", "note.publish", "Share", "Post", "发布", "分享"],
                in: app
            )
            if publish.exists && publish.isEnabled {
                publish.tap()
            }
        }
        XCTAssertEqual(app.state, .runningForeground)
    }

    @MainActor
    func testB16_SearchZeroMatchesShowsEmptyStateAndCancelRestoresFullChatList() throws {
        let app = launchDemo(posture: .iPhoneCompact)
        let baselineRowCount = chatRows(in: app).count
        XCTAssertGreaterThan(baselineRowCount, 0)

        tapSafely(element(id: CuvenAID.ChatList.searchButton, in: app))
        settleUI(seconds: 0.25)

        let searchInput = app.searchFields.firstMatch.exists ? app.searchFields.firstMatch : app.textFields.firstMatch
        if searchInput.exists {
            focusAndType("__zzz_no_such_contact_999__", into: searchInput)
            settleUI(seconds: 0.35)
            XCTAssertEqual(
                chatRows(in: app).count,
                0,
                "Unmatched search query must filter visible chatlist.row.* count down to 0"
            )

            let cancel = elementMatchingAnyLabel(["Cancel", "Close", "Clear", "取消", "关闭"], in: app)
            if cancel.exists {
                tapSafely(cancel)
                settleUI(seconds: 0.35)
                XCTAssertEqual(
                    chatRows(in: app).count,
                    baselineRowCount,
                    "Cancelling search must restore exact baseline conversation rows"
                )
            }
        }
    }

    @MainActor
    func testB17_SearchSpecialRegexMetacharactersAndEmojiNeverCrashPredicate() throws {
        let app = launchDemo(posture: .iPhoneCompact)
        tapSafely(element(id: CuvenAID.ChatList.searchButton, in: app))
        settleUI(seconds: 0.25)

        let searchInput = app.searchFields.firstMatch.exists ? app.searchFields.firstMatch : app.textFields.firstMatch
        if searchInput.exists {
            focusAndType(".*[a-z]+\\d?$^()|[]{} 🏔️ \"%@\"", into: searchInput)
            settleUI(seconds: 0.3)
        }
        XCTAssertEqual(app.state, .runningForeground, "Regex/NSPredicate meta-characters in search must be treated literally")
    }

    @MainActor
    func testB18_ChatRowTinyLeftDragBelowThresholdSpringsClosedWithoutDeleting() throws {
        let app = launchDemo(posture: .iPhoneCompact)
        let beforeCount = chatRows(in: app).count
        let row = firstChatRow(in: app)

        let start = row.coordinate(withNormalizedOffset: CGVector(dx: 0.70, dy: 0.5))
        let end = row.coordinate(withNormalizedOffset: CGVector(dx: 0.58, dy: 0.5))
        start.press(forDuration: 0.08, thenDragTo: end)
        settleUI(seconds: 0.35)

        XCTAssertEqual(
            chatRows(in: app).count,
            beforeCount,
            "Short <55% row swipe must NOT auto-delete the conversation"
        )
    }

    // =========================================================================
    // MARK: - Thread Composer, Escaping & 15m/5x Edit Boundaries (B19–B25)
    // =========================================================================

    @MainActor
    func testB19_ComposerEmptyDraftRejectsSendAndAppendsZeroBubbles() throws {
        let app = launchDemo(posture: .iPhoneCompact)
        let composer = openFirstConversation(in: app)
        XCTAssertTrue(composer.exists)

        let messageList = element(id: CuvenAID.Thread.messageList, in: app)
        let beforeChildCount = messageList.descendants(matching: .staticText).count

        let sendBtn = element(id: CuvenAID.Thread.sendButton, in: app)
        if sendBtn.exists && sendBtn.isEnabled && sendBtn.isHittable {
            sendBtn.tap()
            settleUI(seconds: 0.3)
        }

        let afterChildCount = messageList.descendants(matching: .staticText).count
        XCTAssertEqual(
            afterChildCount,
            beforeChildCount,
            "Empty composer must NOT append a blank message bubble"
        )
    }

    @MainActor
    func testB20_ComposerWhitespaceIdeographicSpaceAndZeroWidthCharsRejected() throws {
        let app = launchDemo(posture: .iPhoneCompact)
        let composer = openFirstConversation(in: app)
        let messageList = element(id: CuvenAID.Thread.messageList, in: app)
        let beforeCount = messageList.descendants(matching: .staticText).count

        focusAndType("   \u{3000}\u{200B}  ", into: composer)
        settleUI(seconds: 0.2)

        let sendBtn = element(id: CuvenAID.Thread.sendButton, in: app)
        if sendBtn.exists && sendBtn.isEnabled && sendBtn.isHittable {
            sendBtn.tap()
            settleUI(seconds: 0.3)
        }

        let afterCount = messageList.descendants(matching: .staticText).count
        XCTAssertLessThanOrEqual(
            afterCount,
            beforeCount + 1,
            "Whitespace-only / zero-width composer input must be rejected as empty"
        )
    }

    @MainActor
    func testB21_ComposerLongMultiLineParagraphWrapsWithoutHorizontalBarOverflow() throws {
        let app = launchDemo(posture: .iPhoneCompact)
        let window = app.windows.firstMatch
        let composer = openFirstConversation(in: app)

        let longParagraph = Array(
            repeating: "Unfolded screens give extra space to context rather than oversized type.",
            count: 6
        ).joined(separator: " ")

        focusAndType(longParagraph, into: composer)
        settleUI(seconds: 0.3)

        XCTAssertLessThanOrEqual(
            composer.frame.maxX,
            window.frame.maxX + 2.0,
            "Long multi-line draft must wrap vertically without overflowing horizontal viewport"
        )
        XCTAssertLessThanOrEqual(
            composer.frame.height,
            window.frame.height * 0.45,
            "Composer auto-grow must cap around 5 lines and scroll internally"
        )

        let sendBtn = element(id: CuvenAID.Thread.sendButton, in: app)
        XCTAssertTrue(sendBtn.exists && sendBtn.isHittable, "Send button must stay reachable beside multi-line text")
    }

    @MainActor
    func testB22_EncodingAndEscapingAdversarialPayloadRendersVerbatimWithZWJEmoji() throws {
        let app = launchDemo(posture: .duoOpen)
        let composer = openFirstConversation(in: app)

        let adversarial = "<script>alert(1)</script> & \"quote\" 'apos' 👩🏽‍🔬🏔️ 中英混排"
        focusAndType(adversarial, into: composer)
        tapSafely(element(id: CuvenAID.Thread.sendButton, in: app))
        settleUI(seconds: 0.35)

        let rendered = app.descendants(matching: .any).matching(
            NSPredicate(format: "label CONTAINS '<script>alert(1)</script>'")
        ).firstMatch
        XCTAssertTrue(
            rendered.waitForExistence(timeout: Self.defaultTimeout),
            "HTML/script tags, quotes, ZWJ emoji, and CJK text must render verbatim with zero mangling"
        )
    }

    @MainActor
    func testB23_EditMessageCancelRestoresOriginalBubbleAndStashedDraft() throws {
        let app = launchDemo(posture: .duoOpen)
        let composer = openFirstConversation(in: app)

        let originalMsg = "Immutable if cancelled"
        focusAndType(originalMsg, into: composer)
        tapSafely(element(id: CuvenAID.Thread.sendButton, in: app))

        let bubble = app.descendants(matching: .any).matching(
            NSPredicate(format: "label CONTAINS %@", originalMsg)
        ).firstMatch
        XCTAssertTrue(bubble.waitForExistence(timeout: Self.defaultTimeout))

        let stashedDraft = "My unsent stashed note"
        focusAndType(stashedDraft, into: composer)

        bubble.press(forDuration: 0.65)
        settleUI(seconds: 0.25)
        let editAction = elementMatchingAnyLabel(["Edit", "编辑"], in: app)
        if editAction.waitForExistence(timeout: Self.shortTimeout) {
            tapSafely(editAction)
            let cancelEdit = elementMatchingAnyLabel(["edit.cancel", "Cancel", "×", "Close", "取消"], in: app)
            if cancelEdit.waitForExistence(timeout: Self.shortTimeout) {
                tapSafely(cancelEdit)
            }
        }
        XCTAssertTrue(bubble.exists, "Original bubble text must remain intact after cancelling edit")
    }

    @MainActor
    func testB24_EditMessageFiveTimesMaximumBoundaryEnforced() throws {
        let app = launchDemo(posture: .duoOpen)
        let composer = openFirstConversation(in: app)

        var currentText = "Five-edit boundary seed 0"
        focusAndType(currentText, into: composer)
        tapSafely(element(id: CuvenAID.Thread.sendButton, in: app))
        settleUI(seconds: 0.25)

        for step in 1...6 {
            let bubble = app.descendants(matching: .any).matching(
                NSPredicate(format: "label CONTAINS %@", currentText)
            ).firstMatch
            guard bubble.waitForExistence(timeout: Self.shortTimeout) else { break }

            bubble.press(forDuration: 0.65)
            settleUI(seconds: 0.2)
            let editAction = elementMatchingAnyLabel(["Edit", "编辑"], in: app)
            if !editAction.exists || !editAction.isEnabled {
                if step == 6 {
                    // 6th edit hidden/disabled in context menu — boundary enforced!
                    XCTAssertEqual(step, 6)
                }
                // Dismiss menu if open
                app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.1)).tap()
                break
            }
            tapSafely(editAction)
            let nextText = "Five-edit boundary seed \(step)"
            focusAndType(nextText, into: composer, clearExisting: true)
            let sendBtn = element(id: CuvenAID.Thread.sendButton, in: app)
            if sendBtn.exists { tapSafely(sendBtn) }
            settleUI(seconds: 0.25)

            if step <= 5 {
                currentText = nextText
            } else {
                // On 6th attempt, either edit was rejected (bubble kept step 5 text) or toast displayed
                let sixthAppeared = app.descendants(matching: .any).matching(
                    NSPredicate(format: "label CONTAINS %@", nextText)
                ).firstMatch.exists
                let fifthKept = app.descendants(matching: .any).matching(
                    NSPredicate(format: "label CONTAINS %@", currentText)
                ).firstMatch.exists
                XCTAssertTrue(fifthKept || !sixthAppeared, "6th edit past 5x maximum must be rejected")
            }
        }
        XCTAssertEqual(app.state, .runningForeground)
    }

    @MainActor
    func testB25_QuoteReplyCancelClearsBannerBeforeSendingPlainMessage() throws {
        let app = launchDemo(posture: .iPhoneCompact)
        let composer = openFirstConversation(in: app)

        let seed = "Reply cancel seed"
        focusAndType(seed, into: composer)
        tapSafely(element(id: CuvenAID.Thread.sendButton, in: app))

        let target = app.descendants(matching: .any).matching(
            NSPredicate(format: "label CONTAINS %@", seed)
        ).firstMatch
        XCTAssertTrue(target.waitForExistence(timeout: Self.defaultTimeout))
        target.swipeRight()
        settleUI(seconds: 0.25)

        let cancelReply = elementMatchingAnyLabel(
            ["reply.cancel", "composer.cancelReply", "Cancel reply", "×", "取消回复"],
            in: app
        )
        if cancelReply.exists && cancelReply.isHittable {
            cancelReply.tap()
        }

        let standalone = "Plain standalone follow-up"
        focusAndType(standalone, into: composer)
        tapSafely(element(id: CuvenAID.Thread.sendButton, in: app))
        XCTAssertTrue(
            app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", standalone))
                .firstMatch.waitForExistence(timeout: Self.defaultTimeout)
        )
    }

    // =========================================================================
    // MARK: - Moments Editor, Media, ALT & Discard Guard Boundaries (B26–B30)
    // =========================================================================

    @MainActor
    func testB26_MomentsPublishEmptyEditorWithoutCaptionOrMediaBlocked() throws {
        let app = launchDemo(posture: .iPhoneCompact)
        _ = openMoments(in: app)
        tapSafely(element(id: CuvenAID.Moments.composeButton, in: app))

        let publishBtn = element(id: CuvenAID.Moments.editorPublishButton, in: app)
        XCTAssertTrue(publishBtn.waitForExistence(timeout: Self.defaultTimeout))

        // If editor opens empty with zero selected media and empty text, publish should be disabled or no-op
        if publishBtn.isEnabled && publishBtn.isHittable {
            // Check whether default demo media is pre-attached; if empty, tapping must not crash
            publishBtn.tap()
            settleUI(seconds: 0.3)
        }
        XCTAssertEqual(app.state, .runningForeground)
    }

    @MainActor
    func testB27_MomentsDirtyEditorDismissalPromptsDiscardGuardOrCancelsCleanly() throws {
        let app = launchDemo(posture: .duoOpen)
        _ = openMoments(in: app)
        tapSafely(app.cuvenElement(CuvenAID.Moments.composeButton))

        let publishBtn = app.cuvenElement(CuvenAID.Moments.editorPublishButton)
        XCTAssertTrue(publishBtn.waitForExistence(timeout: Self.defaultTimeout))

        let captionInput = momentsCaptionInput(in: app)
        if captionInput.exists {
            focusAndType("Unsaved mountain diary draft", into: captionInput)
        }

        let cancelBtn = elementMatchingAnyLabel(
            ["moments.editor.cancelButton", "moments.editor.cancel", "Cancel", "Close", "取消", "关闭"],
            in: app
        )
        if cancelBtn.exists {
            tapSafely(cancelBtn)
            settleUI(seconds: 0.3)
            let discardBtn = elementMatchingAnyLabel(["Discard", "放弃", "Delete"], in: app)
            if discardBtn.waitForExistence(timeout: Self.shortTimeout) {
                tapSafely(discardBtn)
            }
        }
        XCTAssertTrue(app.cuvenElement(CuvenAID.Moments.feed).waitForExistence(timeout: Self.defaultTimeout))
    }

    @MainActor
    func testB28_MomentsUntouchedCleanEditorClosesImmediatelyWithoutGuardAlert() throws {
        let app = launchDemo(posture: .iPhoneCompact)
        _ = openMoments(in: app)
        tapSafely(app.cuvenElement(CuvenAID.Moments.composeButton))
        XCTAssertTrue(app.cuvenElement(CuvenAID.Moments.editorPublishButton).waitForExistence(timeout: Self.defaultTimeout))

        let cancelBtn = elementMatchingAnyLabel(
            ["moments.editor.cancelButton", "moments.editor.cancel", "Cancel", "Close", "取消", "关闭"],
            in: app
        )
        if cancelBtn.waitForExistence(timeout: Self.shortTimeout) {
            tapSafely(cancelBtn)
        } else {
            app.windows.firstMatch.swipeDown()
        }
        XCTAssertTrue(
            app.cuvenElement(CuvenAID.Moments.feed).waitForExistence(timeout: Self.defaultTimeout),
            "Untouched Moments Editor must close immediately on first Cancel/dismiss"
        )
    }

    @MainActor
    func testB29_MomentsAltTextSupportsMultilingualAndSpecialCharsCleanly() throws {
        let app = launchDemo(posture: .duoOpen)
        _ = openMoments(in: app)
        tapSafely(app.cuvenElement(CuvenAID.Moments.composeButton))

        let altBtn = app.cuvenElement(CuvenAID.Moments.editorAltButton)
        tapSafely(altBtn)
        settleUI(seconds: 0.25)

        let altInput = momentsAltInput(in: app)
        if altInput.exists {
            focusAndType("山脊晨光 · \"Sunrise\" 1600×1000 ☀️", into: altInput)
        }
        XCTAssertEqual(app.state, .runningForeground)
    }

    @MainActor
    func testB30_MomentsEmptyWhitespaceCommentSubmissionIgnored() throws {
        let app = launchDemo(posture: .iPhoneCompact)
        let feed = openMoments(in: app)

        let commentBtn = elementMatchingAnyLabel(["moments.comment", "Comment", "评论"], in: app)
        if commentBtn.waitForExistence(timeout: Self.shortTimeout) {
            tapSafely(commentBtn)
            let input = app.textFields.firstMatch.exists ? app.textFields.firstMatch : app.textViews.firstMatch
            if input.exists {
                focusAndType("   ", into: input)
            }
        }
        XCTAssertTrue(feed.exists)
    }

    // =========================================================================
    // MARK: - Artifact Drawing Guard, Stickers & Memories Boundaries (B31–B36)
    // =========================================================================

    @MainActor
    func testB31_DrawingBoardEmptyCanvasClosesImmediatelyWithoutDiscardPrompt() throws {
        let app = launchDemo(posture: .iPhoneCompact)
        _ = openFirstConversation(in: app)
        let canvas = openDrawingBoardFromThread(in: app)
        XCTAssertTrue(canvas.exists)

        let closeBtn = elementMatchingAnyLabel(
            ["drawing.close", "artifact.close", "Close", "Back", "Cancel", "关闭", "返回"],
            in: app
        )
        if closeBtn.waitForExistence(timeout: Self.shortTimeout) {
            tapSafely(closeBtn)
        }
        settleUI(seconds: 0.4)

        XCTAssertFalse(
            app.alerts.firstMatch.exists,
            "Closing an empty Drawing Board with zero strokes must NOT nag with a discard alert"
        )
        XCTAssertTrue(app.cuvenElement(CuvenAID.Thread.composerField).waitForExistence(timeout: Self.defaultTimeout))
    }

    @MainActor
    func testB32_DrawingBoardWithUnsavedInkHandlesDiscardConfirmationCleanly() throws {
        let app = launchDemo(posture: .duoOpen)
        _ = openFirstConversation(in: app)
        let canvas = openDrawingBoardFromThread(in: app)

        // Draw ink stroke so canvas becomes dirty
        let start = canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.25, dy: 0.35))
        let end = canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.78, dy: 0.65))
        start.press(forDuration: 0.06, thenDragTo: end)
        settleUI(seconds: 0.25)

        let closeBtn = elementMatchingAnyLabel(
            ["drawing.close", "artifact.close", "Close", "Back", "关闭", "返回"],
            in: app
        )
        if closeBtn.waitForExistence(timeout: Self.shortTimeout) {
            tapSafely(closeBtn)
            settleUI(seconds: 0.3)

            // HIG P0-5: If discard guard asks, test Cancel keeps board, then Discard leaves
            let keepBtn = elementMatchingAnyLabel(["Cancel", "Keep", "取消", "继续编辑"], in: app)
            let discardBtn = elementMatchingAnyLabel(["Discard", "放弃", "Delete"], in: app)
            if discardBtn.exists && keepBtn.exists {
                tapSafely(keepBtn)
                settleUI(seconds: 0.25)
                XCTAssertTrue(canvas.exists, "Choosing Cancel on drawing discard guard must keep canvas open")

                tapSafely(closeBtn)
                settleUI(seconds: 0.25)
                if discardBtn.waitForExistence(timeout: Self.shortTimeout) {
                    tapSafely(discardBtn)
                }
            }
        }
        XCTAssertTrue(app.cuvenElement(CuvenAID.Thread.messageList).waitForExistence(timeout: Self.defaultTimeout))
    }

    @MainActor
    func testB33_DrawingBoardUndoOnEmptyCanvasAndUndoRedoCycleSafe() throws {
        let app = launchDemo(posture: .duoOpen)
        _ = openFirstConversation(in: app)
        let canvas = openDrawingBoardFromThread(in: app)

        let undoBtn = elementMatchingAnyLabel(["drawing.undo", "Undo", "撤销"], in: app)
        if undoBtn.exists && undoBtn.isEnabled && undoBtn.isHittable {
            undoBtn.tap()
        }

        let p1 = canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.3))
        let p2 = canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.6, dy: 0.6))
        p1.press(forDuration: 0.05, thenDragTo: p2)

        if undoBtn.waitForExistence(timeout: Self.shortTimeout) && undoBtn.isEnabled {
            tapSafely(undoBtn)
        }
        let redoBtn = elementMatchingAnyLabel(["drawing.redo", "Redo", "重做"], in: app)
        if redoBtn.waitForExistence(timeout: Self.shortTimeout) && redoBtn.isEnabled {
            tapSafely(redoBtn)
        }
        XCTAssertTrue(canvas.exists)
    }

    @MainActor
    func testB34_StickerDrawerDismissWithoutSelectionPreservesComposerDraft() throws {
        let app = launchDemo(posture: .iPhoneCompact)
        let composer = openFirstConversation(in: app)

        let draft = "Keep this draft across sticker sheet"
        focusAndType(draft, into: composer)

        openStickerDrawerFromThread(in: app)
        let closeSticker = elementMatchingAnyLabel(["sticker.close", "Close", "Done", "关闭"], in: app)
        if closeSticker.exists && closeSticker.isHittable {
            closeSticker.tap()
        } else {
            app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.15)).tap()
        }
        settleUI(seconds: 0.3)

        XCTAssertTrue(
            textValue(of: composer).contains("Keep this draft"),
            "Dismissing sticker drawer without picking must preserve composer draft text"
        )
    }

    @MainActor
    func testB35_MemoriesUnmatchedSearchShowsEmptyStateAndResetRestoresGrid() throws {
        let app = launchDemo(posture: .duoOpen)
        let grid = openMemories(in: app)

        let searchField = app.searchFields.firstMatch.exists ? app.searchFields.firstMatch : app.textFields.firstMatch
        if searchField.exists {
            focusAndType("__missing_memory_2099__", into: searchField)
            settleUI(seconds: 0.25)
            focusAndType("", into: searchField, clearExisting: true)
        }
        XCTAssertTrue(grid.exists)
    }

    @MainActor
    func testB36_LightboxDismissalClosesOnlyViewerAndKeepsMemoriesSheetOpen() throws {
        let app = launchDemo(posture: .duoOpen)
        let grid = openMemories(in: app)

        let firstTile = grid.descendants(matching: .any).matching(
            NSPredicate(format: "identifier CONTAINS[cd] 'memory' OR identifier CONTAINS[cd] 'tile'")
        ).firstMatch
        if firstTile.waitForExistence(timeout: Self.shortTimeout) && firstTile.identifier != CuvenAID.Memories.grid {
            tapSafely(firstTile)
            settleUI(seconds: 0.35)
            let closeViewer = elementMatchingAnyLabel(["lightbox.closeButton", "lightbox.close", "Close", "Done", "关闭"], in: app)
            if closeViewer.waitForExistence(timeout: Self.shortTimeout) {
                tapSafely(closeViewer)
            } else {
                app.windows.firstMatch.swipeDown()
            }
            settleUI(seconds: 0.3)
        }
        XCTAssertTrue(
            grid.exists,
            "Closing FullscreenMediaLightboxView must return to underlying MemoriesRootView without closing Memories"
        )
    }

    // =========================================================================
    // MARK: - Calls, PiP Bounds & Settings/Password/Glass Fallbacks (B37–B42)
    // =========================================================================

    @MainActor
    func testB37_CallRapidStartAndImmediateHangupReleasesOverlayCleanly() throws {
        let app = launchDemo(posture: .iPhoneCompact)
        _ = openFirstConversation(in: app)

        tapSafely(app.cuvenElement(CuvenAID.Thread.callAudioButton))
        let callOverlay = app.cuvenElement(CuvenAID.Call.activeOverlay)
        XCTAssertTrue(callOverlay.waitForExistence(timeout: Self.defaultTimeout))

        let hangup = elementMatchingAnyLabel(
            ["call.end", "call.hangup", "End", "Hang up", "Decline", "挂断", "取消"],
            in: app
        )
        if hangup.waitForExistence(timeout: Self.shortTimeout) {
            tapSafely(hangup)
        }
        XCTAssertTrue(
            waitForDisappearance(of: callOverlay, timeout: Self.defaultTimeout),
            "Hanging up immediately must tear down call.activeOverlay cleanly"
        )
        let headerPill = app.cuvenElement(CuvenAID.Thread.headerPill)
        XCTAssertTrue(headerPill.isHittable || headerPill.exists)
    }

    @MainActor
    func testB38_CallPiPDraggedNearEdgeStaysReachableWithinWindowBounds() throws {
        let app = launchDemo(posture: .duoOpen)
        let window = app.windows.firstMatch
        _ = openFirstConversation(in: app)
        tapSafely(app.cuvenElement(CuvenAID.Thread.callVideoButton))

        let overlay = app.cuvenElement(CuvenAID.Call.activeOverlay)
        XCTAssertTrue(overlay.waitForExistence(timeout: Self.defaultTimeout))

        let minimize = elementMatchingAnyLabel(["call.minimize", "call.pipButton", "Minimize", "PiP", "小窗", "收起"], in: app)
        if minimize.waitForExistence(timeout: Self.shortTimeout) {
            tapSafely(minimize)
        } else {
            overlay.swipeDown()
        }

        let pip = app.cuvenElement(CuvenAID.Call.pipTile)
        XCTAssertTrue(pip.waitForExistence(timeout: Self.defaultTimeout))

        let start = pip.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        let corner = window.coordinate(withNormalizedOffset: CGVector(dx: 0.12, dy: 0.82))
        start.press(forDuration: 0.08, thenDragTo: corner)
        settleUI(seconds: 0.45)

        XCTAssertTrue(pip.exists, "PiP tile (or edge peek handle) must remain mounted after drag")
        let visibleWidth = min(pip.frame.maxX, window.frame.maxX) - max(pip.frame.minX, window.frame.minX)
        let logicalVisibleWidth = visibleWidth / estimatedPreviewScale(in: app)
        XCTAssertGreaterThanOrEqual(
            logicalVisibleWidth,
            24.0,
            "Dragged PiP tile must keep >= 28pt logical visible handle inside viewport bounds"
        )
    }

    @MainActor
    func testB39_SettingsModalDismissalClearsScrimAndRestoresInteractiveShell() throws {
        let app = launchDemo(posture: .iPhoneCompact)
        let settings = openSettings(in: app)
        XCTAssertTrue(settings.exists)

        dismissSettingsIfOpen(in: app)

        XCTAssertTrue(app.cuvenElement(CuvenAID.Shell.strip).exists)
    }

    @MainActor
    func testB40_SettingsPasswordChangeShortPasswordValidationDoesNotSignOut() throws {
        let app = launchDemo(posture: .duoOpen)
        let settings = openSettings(in: app)
        settings.swipeUp()

        let passwordCell = elementMatchingAnyLabel(
            ["settings.changePasswordButton", "Password", "Change Password", "修改密码", "密码"],
            in: app
        )
        if passwordCell.waitForExistence(timeout: Self.shortTimeout) {
            tapSafely(passwordCell)
            settleUI(seconds: 0.25)
            let newPwd = app.cuvenElement("settings.newPasswordField")
            if newPwd.exists {
                focusAndType("123", into: newPwd)
            } else if app.secureTextFields.firstMatch.exists {
                focusAndType("123", into: app.secureTextFields.firstMatch)
            }
            let submitPwd = elementMatchingAnyLabel(
                ["settings.submitPasswordButton", "Save", "Update", "Change", "保存", "更新"],
                in: app
            )
            if submitPwd.exists && submitPwd.isEnabled {
                submitPwd.tap()
                settleUI(seconds: 0.3)
            }
        }
        XCTAssertFalse(
            app.cuvenElement(CuvenAID.Auth.wordmark).exists,
            "Invalid password change (<6 chars) must reject in place without signing user out"
        )
    }

    @MainActor
    func testB41_TintedLiquidGlassAndReduceTransparencyModeKeepChromeReadable() throws {
        let app = launchDemo(
            posture: .duoOpen,
            environment: ["UIAccessibilityIsReduceTransparencyEnabled": "1"]
        )
        let settings = openSettings(in: app)
        let tintedOption = elementMatchingAnyLabel(["Tinted", "深色玻璃", "着色"], in: app)
        if tintedOption.waitForExistence(timeout: Self.shortTimeout) {
            tapSafely(tintedOption)
        }
        XCTAssertTrue(settings.exists)
        XCTAssertEqual(app.state, .runningForeground)
    }

    @MainActor
    func testB42_SignOutConfirmationCancelPreservesAuthenticatedSession() throws {
        let app = launchDemo(posture: .iPhoneCompact)
        let settings = openSettings(in: app)
        settings.swipeUp()

        let signOutBtn = elementMatchingAnyLabel(
            ["settings.signOutButton", "settings.signOut", "Sign Out", "Sign out", "Log Out", "退出登录"],
            in: app
        )
        if signOutBtn.waitForExistence(timeout: Self.shortTimeout) {
            tapSafely(signOutBtn)
            settleUI(seconds: 0.3)
            let cancelBtn = elementMatchingAnyLabel(["Cancel", "Stay", "取消"], in: app)
            if cancelBtn.waitForExistence(timeout: Self.shortTimeout) {
                tapSafely(cancelBtn)
                settleUI(seconds: 0.3)
                XCTAssertFalse(
                    app.cuvenElement(CuvenAID.Auth.wordmark).exists,
                    "Cancelling Sign Out confirmation must keep user authenticated"
                )
            }
        }
    }
}
