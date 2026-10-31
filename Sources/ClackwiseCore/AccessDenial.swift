import Foundation

/// Tells "the user chose Deny" from "the user is on the way to System Settings". macOS's "Keystroke
/// Receiving" alert has Deny as its default button; after "Open System Settings" the pane is on screen
/// within about a second, after Deny nothing follows and macOS never asks again.
public struct DenialTracker {
    /// Alert seen, gone for longer than `grace`, and neither access nor any macOS UI followed.
    public private(set) var denied = false
    private var alertSeen = false
    private var goneSince: Date?
    public static let grace: TimeInterval = 2.5

    public init() {}

    /// `systemUI`: the alert, a Touch ID sheet or System Settings is on screen (the alert included).
    @discardableResult
    public mutating func update(alertVisible: Bool, systemUI: Bool, hasAccess: Bool, now: Date = Date()) -> Bool {
        if hasAccess || (!alertVisible && systemUI) {
            alertSeen = false; goneSince = nil; denied = false
        } else if alertVisible {
            alertSeen = true; goneSince = nil; denied = false
        } else if alertSeen {
            let since = goneSince ?? now
            goneSince = since
            if now.timeIntervalSince(since) > Self.grace { alertSeen = false; denied = true }
        }
        return denied
    }
}
