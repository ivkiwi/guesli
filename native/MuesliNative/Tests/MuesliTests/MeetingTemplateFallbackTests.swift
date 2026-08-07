import Testing
import MuesliCore
@testable import MuesliNativeApp

@Test("missing meeting template uses configured default")
func missingMeetingTemplateUsesConfiguredDefault() {
    let custom = CustomMeetingTemplate(
        id: "daily",
        name: "Daily",
        prompt: "Summarize the daily.",
        icon: "calendar"
    )

    #expect(MeetingTemplates.resolveSnapshot(
        id: nil,
        customTemplates: [custom],
        defaultTemplateID: custom.id
    ).id == custom.id)
    #expect(MeetingTemplates.resolveSnapshot(
        id: nil,
        customTemplates: [],
        defaultTemplateID: "deleted"
    ).id == MeetingTemplates.autoID)
}
