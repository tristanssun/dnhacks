import SwiftUI

enum Theme {
    // --sf2f-ground
    static let ground = Color(red: 0x05/255, green: 0x07/255, blue: 0x0A/255)
    // --sf2f-ink
    static let ink = Color(red: 0xF3/255, green: 0xF5/255, blue: 0xF4/255)
    static let inkDim = ink.opacity(0.66)      // --sf2f-ink-dim
    static let inkFaint = ink.opacity(0.40)    // --sf2f-ink-faint
    static let line = ink.opacity(0.18)        // --sf2f-line
    static let grid = ink.opacity(0.07)        // hairline grid (derived)
    static let panel = ink.opacity(0.04)       // roster row ground (derived)
    // --sf2f-ember (neon green) — the signature accent. Self marker, "live", action hints.
    static let ember = Color(red: 0x47/255, green: 0xFF/255, blue: 0x51/255)
    static let emberSoft = Color(red: 0x6B/255, green: 0xFF/255, blue: 0x73/255) // --sf2f-ember-soft
    // --sf2f-frost (pale blue) — secondary accent. Used ONLY for relayed (second-hand) data.
    static let frost = Color(red: 0x9F/255, green: 0xC4/255, blue: 0xD2/255)
    // Alarm red — the deliberate exception to the four-hue palette. Reserved for
    // exactly one condition: our own UWB ranging to a peer has dropped out. Every
    // other degraded state is still expressed with opacity and dashes, because if
    // red ever means "somewhat less confident" it stops meaning "this is broken".
    static let alarm = Color(red: 0xFF/255, green: 0x45/255, blue: 0x3A/255)

    // Typography. Second Front: display 'Space Grotesk' → SF Pro here;
    // mono 'Space Mono','SF Mono' → SF Mono (system monospaced design).
    static func mono(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }
    static func display(_ size: CGFloat, _ weight: Font.Weight = .medium) -> Font {
        .system(size: size, weight: weight, design: .default)
    }
    /// Letter-spacing for uppercase mono labels (site uses .16em–.34em).
    static func tracking(_ size: CGFloat, em: CGFloat = 0.18) -> CGFloat { size * em }

    // --sf2f-ease: cubic-bezier(.22,.61,.36,1)
    static let ease = Animation.timingCurve(0.22, 0.61, 0.36, 1, duration: 0.45)
}
