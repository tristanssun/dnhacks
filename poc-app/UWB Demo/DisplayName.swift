import Foundation
import UIKit

/// The callsign this device advertises to the team.
///
/// It is the seed for `MCPeerID`, which Multipeer Connectivity fixes for the
/// life of a session and which the rest of the app uses as a peer's identity
/// (`PeerSnapshot.id` is the display name). So an edit cannot be applied to a
/// running session; it is persisted here and picked up by `storedPeerID()` on
/// the next launch, and the editor says so.
enum DisplayName {
    static let key = "UWBDemo.displayName"

    /// MCPeerID rejects a display name over 63 UTF-8 bytes. 24 characters is
    /// well inside that for any script and still fits the roster column.
    static let maxLength = 24

    /// The stored callsign, seeding it from the device name on first run so that
    /// the value shown in the UI is always the one the identity was built from.
    static func resolved() -> String {
        if let stored = UserDefaults.standard.string(forKey: key), !stored.isEmpty {
            return stored
        }
        let base = UIDevice.current.name
        let suffix = String(UUID().uuidString.prefix(4))
        let name = (base.isEmpty || base == "iPhone") ? "iPhone \(suffix)" : base
        let seeded = sanitized(name) ?? "iPhone \(suffix)"
        UserDefaults.standard.set(seeded, forKey: key)
        return seeded
    }

    /// Trimmed and length-capped, or nil if there is nothing usable left.
    static func sanitized(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return String(trimmed.prefix(maxLength))
    }

    /// Returns true if the name actually changed, so the caller can decide
    /// whether it is worth telling the user a relaunch is needed.
    @discardableResult
    static func set(_ raw: String) -> Bool {
        guard let name = sanitized(raw), name != resolved() else { return false }
        UserDefaults.standard.set(name, forKey: key)
        return true
    }
}
