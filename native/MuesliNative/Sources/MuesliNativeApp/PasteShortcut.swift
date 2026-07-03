import Foundation

enum PasteShortcut: String, Codable, CaseIterable {
    case commandV = "command_v"
    case commandShiftV = "command_shift_v"

    var label: String {
        switch self {
        case .commandV: return "⌘V (default)"
        case .commandShiftV: return "⌘⇧V"
        }
    }
}
