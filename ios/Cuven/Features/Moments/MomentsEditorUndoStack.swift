// MomentsEditorUndoStack.swift
// Cuven — Native iOS & iPhone Duo App (iOS 27.1 SDK)
//
// Genuine 200-step immutable Undo / Redo history engine across all Moments Editor state mutations:
// text typing bursts (700ms pause coalescing), media additions/removals, CoreImage photo edits
// (90° rotation, aspect crop, 6-tone filter), +ALT descriptions, @Tag friend selections,
// Audience / Comment permissions, and Scheduled publish timestamps.
// Apple HIG Reference: Undo and Redo (`developer.apple.com/design/human-interface-guidelines/undo-and-redo`).

import Foundation
import UIKit

// MARK: - Editable Photo / Media Attachment State

public struct MomentEditableMediaItem: Identifiable, Equatable, Sendable {
    public let id: String
    public let isVideo: Bool
    /// Original unedited JPEG/PNG image bytes so repeated edits are 100% non-destructive (`moments-editor.js:450`).
    public let originalImageData: Data?
    /// Latest rendered JPEG bytes reflecting `editParameters`.
    public var renderedImageData: Data?
    /// Video or pre-existing remote URL if applicable.
    public var mediaURLString: String?
    public var originalWidth: Int
    public var originalHeight: Int
    public var renderedWidth: Int
    public var renderedHeight: Int
    public var altText: String
    public var editParameters: PhotoEditParameters

    public init(
        id: String = UUID().uuidString,
        isVideo: Bool = false,
        originalImageData: Data?,
        renderedImageData: Data? = nil,
        mediaURLString: String? = nil,
        originalWidth: Int,
        originalHeight: Int,
        renderedWidth: Int? = nil,
        renderedHeight: Int? = nil,
        altText: String = "",
        editParameters: PhotoEditParameters = PhotoEditParameters()
    ) {
        self.id = id
        self.isVideo = isVideo
        self.originalImageData = originalImageData
        self.renderedImageData = renderedImageData ?? originalImageData
        self.mediaURLString = mediaURLString
        self.originalWidth = max(1, originalWidth)
        self.originalHeight = max(1, originalHeight)
        self.renderedWidth = max(1, renderedWidth ?? originalWidth)
        self.renderedHeight = max(1, renderedHeight ?? originalHeight)
        self.altText = altText
        self.editParameters = editParameters
    }

    public var clampedCardAspectRatio: CGFloat {
        let raw = CGFloat(renderedWidth) / CGFloat(max(1, renderedHeight))
        return min(1.60, max(0.62, raw))
    }

    public var hasAltDescription: Bool {
        !altText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

// MARK: - Complete Immutable Editor Draft Snapshot

public struct MomentEditorDraftState: Equatable, Sendable {
    public static let maxTextCharacters: Int = 2000
    public static let maxPhotosCount: Int = 9
    public static let maxAltCharacters: Int = 1000
    public static let maxTaggedFriends: Int = 10

    public var text: String
    public var mediaItems: [MomentEditableMediaItem]
    public var selectedMediaID: String?
    public var taggedUserIDs: [String]
    /// `"everyone"` or `"friends"`
    public var audience: String
    /// `"everyone"`, `"friends"`, or `"off"`
    public var commentPolicy: String
    /// Optional future epoch timestamp in milliseconds (`nil` = publish immediately).
    public var scheduledAtMillis: Int64?

    public init(
        text: String = "",
        mediaItems: [MomentEditableMediaItem] = [],
        selectedMediaID: String? = nil,
        taggedUserIDs: [String] = [],
        audience: String = "everyone",
        commentPolicy: String = "everyone",
        scheduledAtMillis: Int64? = nil
    ) {
        self.text = text
        self.mediaItems = mediaItems
        self.selectedMediaID = selectedMediaID ?? mediaItems.first?.id
        self.taggedUserIDs = taggedUserIDs
        self.audience = audience
        self.commentPolicy = commentPolicy
        self.scheduledAtMillis = scheduledAtMillis
    }

    public var hasPublishableContent: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !mediaItems.isEmpty
    }

    /// Used by the dirty-state dismissal guard (`moments-editor.js:134`).
    public var hasUnsavedChanges: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !mediaItems.isEmpty
            || !taggedUserIDs.isEmpty
            || scheduledAtMillis != nil
            || audience != "everyone"
            || commentPolicy != "everyone"
    }

    public var remainingCharacters: Int {
        Self.maxTextCharacters - text.count
    }

    public var characterProgress: Double {
        min(1.0, max(0.0, Double(text.count) / Double(Self.maxTextCharacters)))
    }

    public var isMediaFull: Bool {
        mediaItems.contains(where: \.isVideo) || mediaItems.count >= Self.maxPhotosCount
    }
}

// MARK: - Generic 200-Step Undo / Redo History Engine

public struct MomentsEditorHistory<State: Equatable & Sendable>: Sendable {
    public let maxDepth: Int
    public private(set) var past: [State]
    public private(set) var present: State
    public private(set) var future: [State]
    private var lastTypingMutationTimestamp: TimeInterval?

    public init(initial: State, maxDepth: Int = 200) {
        self.maxDepth = max(1, maxDepth)
        self.past = []
        self.present = initial
        self.future = []
        self.lastTypingMutationTimestamp = nil
    }

    public var canUndo: Bool { !past.isEmpty }
    public var canRedo: Bool { !future.isEmpty }

    /// Records a discrete user action (adding/removing media, applying CoreImage tone/crop/rotate,
    /// editing +ALT, tagging friends, changing permissions, or scheduling).
    public mutating func record(_ next: State) {
        guard next != present else { return }
        lastTypingMutationTimestamp = nil
        past.append(present)
        if past.count > maxDepth {
            past.removeFirst(past.count - maxDepth)
        }
        future.removeAll()
        present = next
    }

    /// Coalesces rapid consecutive keystrokes within `coalesceWindow` (`0.7s`, matching `moments-editor.js:211-215`)
    /// into a single undo step per typing phrase while keeping `present` live on every keystroke.
    public mutating func recordTyping(
        _ next: State,
        now: TimeInterval = ProcessInfo.processInfo.systemUptime,
        coalesceWindow: TimeInterval = 0.70
    ) {
        guard next != present else { return }
        let shouldPushSnapshot: Bool
        if let last = lastTypingMutationTimestamp, (now - last) < coalesceWindow {
            shouldPushSnapshot = false
        } else {
            shouldPushSnapshot = true
        }

        if shouldPushSnapshot {
            past.append(present)
            if past.count > maxDepth {
                past.removeFirst(past.count - maxDepth)
            }
        }
        future.removeAll()
        present = next
        lastTypingMutationTimestamp = now
    }

    /// Steps backward to the previous state and pushes the current state onto `future`.
    @discardableResult
    public mutating func undo() -> State? {
        guard let previous = past.popLast() else { return nil }
        lastTypingMutationTimestamp = nil
        future.append(present)
        present = previous
        return present
    }

    /// Steps forward to the next undone state and pushes the current state back onto `past`.
    @discardableResult
    public mutating func redo() -> State? {
        guard let restored = future.popLast() else { return nil }
        lastTypingMutationTimestamp = nil
        past.append(present)
        present = restored
        return present
    }
}
