import Foundation

/// Lifecycle of one queued transfer.
///
/// The raw values are the wire strings the upstream C# app writes into its
/// queue, so a state persisted by either app decodes identically.
public enum QueueState: String, Codable, Hashable, Sendable, CaseIterable {
    case queued
    case sending
    case copying
    case paused
    case done
    case failed
    case cancelled

    /// Finished rows never come back: they are pinned to the bottom and tinted.
    public var isFinished: Bool {
        switch self {
        case .done, .failed, .cancelled: return true
        case .queued, .sending, .copying, .paused: return false
        }
    }

    /// Copying is the console-side step after the bytes have arrived; pausing
    /// there only stops the local side and would leave the console mid-write.
    public var canPause: Bool {
        switch self {
        case .queued, .sending, .copying: return true
        case .paused, .done, .failed, .cancelled: return false
        }
    }

    /// Pause glyph: ⏸ while running, ▶ while paused.
    public var pauseGlyph: String { isPausedState ? "▶" : "⏸" }

    private var isPausedState: Bool { self == .paused }
}

/// One row of the send queue.
///
/// `game` is an embedded snapshot rather than a reference into the library:
/// the library can be rescanned (or the source file deleted) while a transfer
/// is still running, and the row must keep showing what was queued.
public struct QueueEntry: Identifiable, Codable, Hashable, Sendable {
    public var id: String
    public var game: GameItem
    public var state: QueueState
    /// 0...1.
    public var percent: Double
    public var bytesSent: Int64
    public var message: String
    public var speed: String
    public var isPaused: Bool
    /// Set by the sender when the console accepted a resumeable partial push.
    public var canResume: Bool
    /// ▲▼ reorder handles: shown while the row is still queued, on any console.
    public var canReorder: Bool
    public var addedAt: Date

    public init(
        game: GameItem,
        state: QueueState = .queued,
        percent: Double = 0,
        bytesSent: Int64 = 0,
        message: String = "",
        speed: String = "",
        isPaused: Bool = false,
        canResume: Bool = false,
        canReorder: Bool = false,
        addedAt: Date = Date()
    ) {
        self.id = game.id
        self.game = game
        self.state = state
        self.percent = min(max(percent, 0), 1)
        self.bytesSent = max(0, bytesSent)
        self.message = message
        self.speed = speed
        self.isPaused = isPaused
        self.canResume = canResume
        self.canReorder = canReorder
        self.addedAt = addedAt
    }

    /// A full re-push of a failed row (fresh counter), as opposed to
    /// `canResume`, which continues the same URL from the last byte.
    public var canResend: Bool { canResume && state == .failed }

    public var isFinished: Bool { state.isFinished }
    public var canPause: Bool { state.canPause }
    public var pauseGlyph: String { state.pauseGlyph }

    /// Byte count of a partially-sent row, derived when the sender reports
    /// only a percentage.
    public var progressBytes: Int64 {
        guard percent > 0, bytesSent == 0 else { return bytesSent }
        return Int64((Double(game.sizeBytes) * percent).rounded())
    }
}
