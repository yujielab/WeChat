import XCTest
@testable import CuvenCore

final class EditPolicyAndModelsTests: XCTestCase {

    func testEditPolicyWindowMaxCountAuthorAndEmptyTextRules() {
        let baseTime: Int64 = 1_760_000_000_000
        let ownMessage = Message(
            id: "m1",
            roomID: "r1",
            senderID: "u_tokio",
            senderDisplay: "Tokio",
            kind: .text,
            text: "Meet at 3pm",
            editCount: 0,
            deliveryState: .sent,
            createdAt: baseTime
        )

        // Valid edit inside 15-minute window
        XCTAssertNil(
            EditPolicyValidator.validateEdit(
                message: ownMessage,
                editorUserID: "u_tokio",
                newText: "Meet at 3:30pm",
                nowMilliseconds: baseTime + 15 * 60 * 1000
            )
        )
        XCTAssertEqual(
            EditPolicyValidator.editProblem(
                message: ownMessage,
                editorUserID: "u_tokio",
                newText: "Meet at 3:30pm",
                nowMilliseconds: baseTime + 60_000
            ),
            ""
        )

        // 1ms past 15-minute window -> expired
        let expiredErr = EditPolicyValidator.validateEdit(
            message: ownMessage,
            editorUserID: "u_tokio",
            newText: "Late edit",
            nowMilliseconds: baseTime + 15 * 60 * 1000 + 1
        )
        XCTAssertEqual(expiredErr, .editWindowExpired)
        XCTAssertEqual(expiredErr?.messageText, "Messages sent over 15 minutes ago can't be edited")

        // Empty / whitespace-only replacement rejected
        let emptyErr = EditPolicyValidator.validateEdit(
            message: ownMessage,
            editorUserID: "u_tokio",
            newText: "   \n\t ",
            nowMilliseconds: baseTime + 5_000
        )
        XCTAssertEqual(emptyErr, .emptyMessage)
        XCTAssertEqual(emptyErr?.messageText, "Can't change it to an empty message")

        // 5-edit cap: 4 edits allowed, 5 edits blocked
        var editedFourTimes = ownMessage
        editedFourTimes.editCount = 4
        XCTAssertTrue(EditPolicyValidator.canEdit(message: editedFourTimes, editorUserID: "u_tokio", nowMilliseconds: baseTime + 10_000))

        var editedFiveTimes = ownMessage
        editedFiveTimes.editCount = 5
        XCTAssertFalse(EditPolicyValidator.canEdit(message: editedFiveTimes, editorUserID: "u_tokio", nowMilliseconds: baseTime + 10_000))
        let maxErr = EditPolicyValidator.validateEdit(
            message: editedFiveTimes,
            editorUserID: "u_tokio",
            newText: "6th edit",
            nowMilliseconds: baseTime + 10_000
        )
        XCTAssertEqual(maxErr, .maxEditsReached(5))
        XCTAssertEqual(maxErr?.messageText, "Each message can be edited at most 5 times")

        // Non-author, non-text, or revoked rejected
        XCTAssertEqual(
            EditPolicyValidator.validateEdit(
                message: ownMessage,
                editorUserID: "u_other",
                newText: "Hijack",
                nowMilliseconds: baseTime + 1_000
            ),
            .cannotEditMessage
        )

        var photoMsg = ownMessage
        photoMsg.kind = .image
        XCTAssertEqual(
            EditPolicyValidator.validateEdit(
                message: photoMsg,
                editorUserID: "u_tokio",
                newText: "Caption",
                nowMilliseconds: baseTime + 1_000
            ),
            .cannotEditMessage
        )

        var revokedMsg = ownMessage
        revokedMsg.deliveryState = .revoked
        XCTAssertEqual(
            EditPolicyValidator.validateEdit(
                message: revokedMsg,
                editorUserID: "u_tokio",
                newText: "Restore",
                nowMilliseconds: baseTime + 1_000
            ),
            .cannotEditMessage
        )
    }

    func testReactionAnd24HourNotePolicies() {
        for emoji in ["❤️", "😂", "👍", "😮", "😢", "🙏", ""] {
            XCTAssertTrue(EditPolicyValidator.isValidReaction(emoji), "Expected \(emoji) to be valid")
        }
        XCTAssertFalse(EditPolicyValidator.isValidReaction("🤡"))

        let messy = "  Coffee   at\n\tWest Lake   courtyard  "
        XCTAssertEqual(EditPolicyValidator.normalizeNoteText(messy), "Coffee at West Lake courtyard")

        let overlong = String(repeating: "a", count: 85)
        XCTAssertEqual(EditPolicyValidator.normalizeNoteText(overlong).count, 60)

        let note = UserNote(userID: "u1", userDisplay: "Tokio", text: "Hi", createdAt: 1_000_000)
        XCTAssertTrue(EditPolicyValidator.isNoteActive(note, nowMilliseconds: 1_000_000 + 24 * 3_600_000 - 1))
        XCTAssertFalse(EditPolicyValidator.isNoteActive(note, nowMilliseconds: 1_000_000 + 24 * 3_600_000))
    }

    func testCanonicalDomainModelsCodableRoundTrip() throws {
        let seed = DemoSeedFactory.makeDataset(anchorTimestampMs: 1_763_400_000_000)
        let data = try JSONEncoder().encode(seed)
        let decoded = try JSONDecoder().decode(DemoSeedDataset.self, from: data)
        XCTAssertEqual(decoded, seed)

        let call = CallSession(
            id: "c1",
            roomID: "room_coisini",
            peerDisplay: "Coisini",
            peerAvatarURL: "cuven-demo://avatar/coisini",
            mediaKind: .video,
            phase: .connected,
            isMuted: false,
            isCameraEnabled: true,
            isSpeakerEnabled: true,
            isMinimizedPiP: true,
            startedAt: 1_763_400_000_000
        )
        let callData = try JSONEncoder().encode(call)
        let decodedCall = try JSONDecoder().decode(CallSession.self, from: callData)
        XCTAssertEqual(decodedCall, call)
    }
}
