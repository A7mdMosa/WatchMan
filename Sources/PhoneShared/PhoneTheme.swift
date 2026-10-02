import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif
import WatchManCore

/// WatchMan's colours, the same as on the Mac: the dark values are the Mac's, the light ones darker so they read
/// on white (4.5:1 or better). The widgets and the Live Activity stay dark, so they get the dark values.
enum PhoneTheme {
    static let needsYou = adaptive(dark: (0.98, 0.66, 0.16), light: (0.64, 0.37, 0.0))
    static let working = adaptive(dark: (0.20, 0.83, 0.45), light: (0.10, 0.47, 0.23))
    static let unseen = adaptive(dark: (0.36, 0.62, 1.0), light: (0.12, 0.37, 0.82))
    static let failed = adaptive(dark: (0.96, 0.33, 0.38), light: (0.77, 0.14, 0.18))
    static let limit = adaptive(dark: (0.98, 0.57, 0.24), light: (0.70, 0.32, 0.04))
    static let accent = adaptive(dark: (0.36, 0.62, 1.0), light: (0.12, 0.37, 0.82))

    private static func adaptive(dark: (CGFloat, CGFloat, CGFloat), light: (CGFloat, CGFloat, CGFloat)) -> Color {
        #if os(macOS)
        Color(nsColor: NSColor(name: nil) { appearance in
            let c = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: c.0, green: c.1, blue: c.2, alpha: 1)
        })
        #else
        Color(uiColor: UIColor { traits in
            let c = traits.userInterfaceStyle == .dark ? dark : light
            return UIColor(red: c.0, green: c.1, blue: c.2, alpha: 1)
        })
        #endif
    }

    static func color(_ state: SessionSnapshot.State) -> Color {
        switch state {
        case .needsYou: needsYou
        case .working: working
        case .done: unseen
        case .idle: .secondary
        case .limited: limit
        case .failed: failed
        }
    }

    static func title(_ state: SessionSnapshot.State) -> String {
        switch state {
        case .needsYou: "Needs you"
        case .working: "Working"
        case .done: "Done"
        case .idle: "Idle"
        case .limited: "Usage limit"
        case .failed: "Stopped"
        }
    }

    /// A stable colour per project, like the Mac's tiles.
    static func project(_ key: String) -> Color {
        let palette: [Color] = [.red, .orange, .green, .teal, .blue, .purple, .pink, .brown]
        let hash = key.unicodeScalars.reduce(UInt64(5381)) { ($0 &* 33) &+ UInt64($1.value) }
        return palette[Int(hash % UInt64(palette.count))]
    }
}

struct ProjectBadge: View {
    let name: String
    let key: String
    var size: CGFloat = 32

    var body: some View {
        let color = PhoneTheme.project(key)
        RoundedRectangle(cornerRadius: size * 0.3, style: .continuous)
            .fill(color.opacity(0.2))
            .overlay(Text(String(name.first ?? "?").uppercased()).font(.system(size: size * 0.45, weight: .bold, design: .rounded))
                .foregroundStyle(color))
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

extension PhoneTheme {
    /// The ball's colours for how things stand, the same as the Mac's orb.
    static func mood(_ state: SessionSnapshot.State?) -> [Color] { FaceMood(state).palette }
}
