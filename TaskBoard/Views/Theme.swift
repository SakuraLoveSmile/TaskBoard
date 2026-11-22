import SwiftUI

enum Theme {
    static let accent = Color(red: 0.36, green: 0.49, blue: 0.98)
    static let accentSoft = accent.opacity(0.13)
    static let success = Color(red: 0.24, green: 0.72, blue: 0.44)

    static let panelWidth: CGFloat = 384
    static let panelHeight: CGFloat = 620
    static let pebbleSide: CGFloat = 44
    static let panelCorner: CGFloat = 24
    static let cardCorner: CGFloat = 14
    static let warning = Color(red: 0.95, green: 0.45, blue: 0.32)
    static let waiting = Color(red: 0.55, green: 0.48, blue: 0.88)
}

extension TaskStatus {
    var tint: Color {
        switch self {
        case .todo: Color.secondary
        case .inProgress: Theme.accent
        case .blocked: Theme.warning
        case .waiting: Theme.waiting
        }
    }

    var symbol: String {
        switch self {
        case .todo: "circle"
        case .inProgress: "play.circle.fill"
        case .blocked: "exclamationmark.octagon.fill"
        case .waiting: "hourglass"
        }
    }
}
