enum MeetingStartPresentation: Equatable {
    case foregroundNotes
    case backgroundPill

    var showsNotes: Bool { self == .foregroundNotes }
}
