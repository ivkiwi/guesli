import Foundation
import MuesliCore

struct CustomMeetingTemplate: Codable, Equatable, Identifiable, Sendable {
    let id: String
    var name: String
    var prompt: String
    var icon: String

    init(
        id: String = UUID().uuidString,
        name: String,
        prompt: String,
        icon: String = MeetingTemplates.customIconFallback
    ) {
        self.id = id
        self.name = name
        self.prompt = prompt
        self.icon = MeetingTemplates.normalizedCustomIcon(named: icon)
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case prompt
        case icon
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
        name = try c.decode(String.self, forKey: .name)
        prompt = try c.decode(String.self, forKey: .prompt)
        icon = MeetingTemplates.normalizedCustomIcon(
            named: try c.decodeIfPresent(String.self, forKey: .icon)
        )
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(prompt, forKey: .prompt)
        try c.encode(MeetingTemplates.normalizedCustomIcon(named: icon), forKey: .icon)
    }
}

struct MeetingTemplateSnapshot: Equatable, Sendable {
    let id: String
    let name: String
    let kind: MeetingTemplateKind
    let prompt: String
}

struct MeetingTemplateDefinition: Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    let category: String?
    let icon: String
    let kind: MeetingTemplateKind
    let promptBody: String

    var snapshot: MeetingTemplateSnapshot {
        MeetingTemplateSnapshot(
            id: id,
            name: title,
            kind: kind,
            prompt: promptBody
        )
    }
}

enum MeetingTemplates {
    static let autoID = "auto"
    static let customIconFallback = "square.and.pencil"

    struct CustomIconOption: Identifiable, Equatable, Sendable {
        let symbolName: String
        let label: String

        var id: String { symbolName }
    }

    static let auto = MeetingTemplateDefinition(
        id: autoID,
        title: "Auto Detailed Notes",
        category: nil,
        icon: "sparkles",
        kind: .auto,
        promptBody: """
        Сначала определи основной язык встречи и тип встречи. Не выводи этот анализ отдельно, используй его только для выбора акцентов.

        Язык:
        - Если встреча в основном на русском — пиши все заметки на русском.
        - Если встреча в основном на английском — пиши все заметки на английском.
        - Если встреча смешанная и основной язык неясен — пиши на русском.
        - Не смешивай языки в заголовках и служебных словах.
        - Не переводи имена, названия продуктов, компаний, файлов, путей, веток, команд, ticket IDs, ссылки, метрики, ошибки и короткие важные цитаты.

        Тип встречи:
        - dev/product/work execution: баги, продукт, код, архитектура, релизы, процессы.
        - status/weekly/stand-up: прогресс, планы, блокеры, статусы.
        - 1:1/sync: договоренности, поддержка, feedback, личный контекст.
        - customer/discovery/sales: боли клиента, workflow, buying signals, next steps.
        - hiring/interview: сигналы кандидата, риски, fit, следующий шаг.
        - generic: если тип неясен.

        Главное правило:
        Извлекай факты, решения и работу, которую надо сделать. Не делай красивое общее саммари вместо полезных заметок. Не выдумывай. Если владелец, срок или статус не названы, всё равно сохрани пункт и пометь как TBD / unclear.

        Используй ровно эти разделы. Назови заголовки на выбранном языке встречи. Если выбран английский — переведи заголовки на английский и не показывай русские варианты.

        ## Коротко
        - 2-4 пункта: главный outcome, что изменилось, что решили, что осталось сделать.
        - Для customer-встреч добавь главный customer signal.
        - Для hiring добавь главный hiring signal.
        - Для status-встреч добавь главный прогресс и главный блокер.

        ## Контекст
        - Какая тема, проблема, цель или ситуация обсуждалась.
        - Сохраняй важные ограничения, evidence, examples, numbers, affected users/customers/systems.
        - Для customer: company, role, use case, current workflow.
        - Для hiring: candidate background, role, relevant experience.
        - Для 1:1: важный feedback, concerns, support context.

        ## Обсуждали
        - Конкретные темы и детали.
        - Не пиши small talk, если он не влияет на работу.
        - Сохраняй edge cases, rejected approaches, objections, blockers, dependencies.

        ## Решения
        - Решение — причина/контекст — владелец: NAME/TBD.
        - Сохраняй confirmed agreements и explicit non-decisions.
        - Если решений не было, напиши "Не зафиксировано." на выбранном языке.

        ## TODO / Исправления / Доделки
        - [ ] Задача — владелец: NAME/TBD — срок: DATE/TBD — статус: agreed/proposed/unclear — контекст: почему важно.
        - Обязательно сохраняй все обсужденные действия: исправить, проверить, доделать, посмотреть позже, протестировать, задеплоить, написать, спросить, создать тикет, обновить документ, разобраться, вернуться к теме.
        - Сохраняй tentative-пункты: "может быть", "надо бы", "давай потом", "посмотрим", "нужно проверить".
        - Не объединяй разные задачи в один пункт.
        - Не удаляй пункты без owner/date.
        - Для customer: follow-up emails, demos, docs, pricing, trials, promised answers.
        - Для hiring: next interview, references, take-home review, process steps, questions to ask.
        - Для status: unblock actions, reviews, deploys, checks, tickets.

        ## Проверка / Риски / Открытые вопросы
        - Tests, metrics, logs, data, users, rollout checks, acceptance checks.
        - Risks, blockers, dependencies, unclear requirements, disagreements.
        - Если нужна проверка, но никто не назначен — всё равно запиши как TODO или риск.

        ## Важные детали
        - Ticket IDs, links, commands, paths, branch names, release names, metrics, dates, names, exact terms.
        - Для customer: pains, buying signals, objections, competitors.
        - Для hiring: strong signals, weak signals, fit concerns.
        - Для 1:1: preferences, recurring themes, important personal/work constraints.

        ## Цитаты
        - Только короткие цитаты, если они сохраняют смысл решения, риска, боли клиента, feedback или несогласия.
        - Если важных цитат нет, напиши "Не зафиксировано." на выбранном языке.
        """
    )

    static let builtIns: [MeetingTemplateDefinition] = [
        MeetingTemplateDefinition(
            id: "one-to-one",
            title: "1 to 1",
            category: "Team",
            icon: "person.2.fill",
            kind: .builtin,
            promptBody: """
            Use this structure exactly:

            ## Check-In
            A brief summary of how the conversation opened and the overall tone.

            ## Topics Discussed
            - Main themes raised by either person

            ## Support Needed
            - Blockers, concerns, or asks for help

            ## Commitments
            - [ ] Follow-ups or commitments made by either person

            ## Manager Notes
            - Coaching, feedback, or context that should be remembered
            """
        ),
        MeetingTemplateDefinition(
            id: "customer-discovery",
            title: "Customer: Discovery",
            category: "Commercial",
            icon: "person.crop.circle.badge.questionmark",
            kind: .builtin,
            promptBody: """
            Use this structure exactly:

            ## Customer Context
            - Company, role, or situation if mentioned

            ## Problems and Pain Points
            - Explicit frustrations, blockers, or unmet needs

            ## Current Workflow
            - How they currently solve the problem today

            ## Buying Signals
            - Indicators of urgency, budget, timing, or decision process

            ## Next Steps
            - [ ] Follow-up actions, owners, and dates if mentioned
            """
        ),
        MeetingTemplateDefinition(
            id: "hiring",
            title: "Hiring",
            category: "Recruiting",
            icon: "briefcase.fill",
            kind: .builtin,
            promptBody: """
            Use this structure exactly:

            ## Candidate Snapshot
            A concise overview of the candidate and relevant background.

            ## Strengths
            - Positive signals from the conversation

            ## Concerns
            - Risks, gaps, or open questions

            ## Role Fit
            - Why they do or do not fit the role as discussed

            ## Decision and Next Steps
            - [ ] Hiring decision, interview progression, or follow-up items
            """
        ),
        MeetingTemplateDefinition(
            id: "stand-up",
            title: "Stand-Up",
            category: "Team",
            icon: "figure.stand",
            kind: .builtin,
            promptBody: """
            Use this structure exactly:

            ## Yesterday
            - Work completed or progress since the last update

            ## Today
            - Planned work or priorities for today

            ## Blockers
            - Risks, delays, or dependencies

            ## Coordination Notes
            - Decisions, asks, or cross-team alignment points
            """
        ),
        MeetingTemplateDefinition(
            id: "weekly-team-meeting",
            title: "Weekly Team Meeting",
            category: "Team",
            icon: "calendar",
            kind: .builtin,
            promptBody: """
            Use this structure exactly:

            ## Weekly Overview
            A concise summary of the most important updates from the meeting.

            ## Progress Updates
            - Key workstreams and status changes

            ## Decisions
            - Decisions made or confirmed

            ## Risks and Open Questions
            - Issues that need attention or follow-up

            ## Action Items
            - [ ] Tasks, owners, and timing if mentioned
            """
        ),
    ]

    static let customIconOptions: [CustomIconOption] = [
        CustomIconOption(symbolName: "square.and.pencil", label: "Notes"),
        CustomIconOption(symbolName: "person.2.fill", label: "1 to 1"),
        CustomIconOption(symbolName: "person.crop.circle.badge.questionmark", label: "Discovery"),
        CustomIconOption(symbolName: "briefcase.fill", label: "Hiring"),
        CustomIconOption(symbolName: "calendar", label: "Weekly"),
        CustomIconOption(symbolName: "figure.stand", label: "Stand-Up"),
        CustomIconOption(symbolName: "person.fill.questionmark", label: "Interview"),
        CustomIconOption(symbolName: "person.fill.checkmark", label: "Review"),
        CustomIconOption(symbolName: "building.2.fill", label: "Business"),
        CustomIconOption(symbolName: "chart.line.uptrend.xyaxis", label: "Strategy"),
        CustomIconOption(symbolName: "dollarsign.circle", label: "Sales"),
        CustomIconOption(symbolName: "megaphone.fill", label: "Marketing"),
        CustomIconOption(symbolName: "hammer.fill", label: "Execution"),
        CustomIconOption(symbolName: "shippingbox.fill", label: "Ops"),
        CustomIconOption(symbolName: "doc.text.fill", label: "Docs"),
        CustomIconOption(symbolName: "checklist", label: "Checklist"),
        CustomIconOption(symbolName: "lightbulb.fill", label: "Ideas"),
        CustomIconOption(symbolName: "waveform.path.ecg", label: "Health"),
        CustomIconOption(symbolName: "graduationcap.fill", label: "Learning"),
        CustomIconOption(symbolName: "globe", label: "Global"),
        CustomIconOption(symbolName: "phone.fill", label: "Calls"),
        CustomIconOption(symbolName: "message.fill", label: "Conversation"),
        CustomIconOption(symbolName: "person.3.fill", label: "Team"),
        CustomIconOption(symbolName: "target", label: "Goals"),
        CustomIconOption(symbolName: "flag.fill", label: "Milestones"),
        CustomIconOption(symbolName: "sparkles", label: "Enhanced"),
        CustomIconOption(symbolName: "wand.and.stars", label: "Creative"),
        CustomIconOption(symbolName: "paperplane.fill", label: "Launch"),
        CustomIconOption(symbolName: "gearshape.fill", label: "Systems"),
        CustomIconOption(symbolName: "folder.fill", label: "Projects"),
        CustomIconOption(symbolName: "clock.fill", label: "Timeline"),
        CustomIconOption(symbolName: "bolt.fill", label: "Sprint"),
    ]

    static func normalizedCustomIcon(named icon: String?) -> String {
        let trimmed = icon?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty else { return customIconFallback }
        // Older configs stored rocket.fill for launch-style templates; remap it for compatibility.
        if trimmed == "rocket.fill" {
            return "paperplane.fill"
        }
        return customIconOptions.contains(where: { $0.symbolName == trimmed }) ? trimmed : customIconFallback
    }

    static func customDefinition(from customTemplate: CustomMeetingTemplate) -> MeetingTemplateDefinition {
        MeetingTemplateDefinition(
            id: customTemplate.id,
            title: customTemplate.name,
            category: "Custom",
            icon: normalizedCustomIcon(named: customTemplate.icon),
            kind: .custom,
            promptBody: customTemplate.prompt
        )
    }

    static func customDefinitions(from customTemplates: [CustomMeetingTemplate]) -> [MeetingTemplateDefinition] {
        customTemplates.map(customDefinition)
    }

    static func allDefinitions(customTemplates: [CustomMeetingTemplate]) -> [MeetingTemplateDefinition] {
        [auto] + builtIns + customDefinitions(from: customTemplates)
    }

    static func resolveDefinition(
        id: String?,
        customTemplates: [CustomMeetingTemplate],
        defaultTemplateID: String? = nil
    ) -> MeetingTemplateDefinition {
        let normalizedID = id?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let normalizedDefault = defaultTemplateID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let effectiveID = normalizedID.isEmpty || normalizedID == autoID
            ? (normalizedDefault.isEmpty ? autoID : normalizedDefault)
            : normalizedID
        if effectiveID == autoID {
            return auto
        }
        if let builtIn = builtIns.first(where: { $0.id == effectiveID }) {
            return builtIn
        }
        if let custom = customTemplates.first(where: { $0.id == effectiveID }) {
            return customDefinition(from: custom)
        }
        return auto
    }

    static func resolveExactDefinition(id: String?, customTemplates: [CustomMeetingTemplate]) -> MeetingTemplateDefinition? {
        let normalizedID = id?.trimmingCharacters(in: .whitespacesAndNewlines) ?? autoID
        if normalizedID.isEmpty || normalizedID == autoID {
            return auto
        }
        if let builtIn = builtIns.first(where: { $0.id == normalizedID }) {
            return builtIn
        }
        if let custom = customTemplates.first(where: { $0.id == normalizedID }) {
            return customDefinition(from: custom)
        }
        return nil
    }

    static func resolveSnapshot(
        id: String?,
        customTemplates: [CustomMeetingTemplate],
        defaultTemplateID: String? = nil
    ) -> MeetingTemplateSnapshot {
        resolveDefinition(
            id: id,
            customTemplates: customTemplates,
            defaultTemplateID: defaultTemplateID
        ).snapshot
    }

    static func resolveExactSnapshot(id: String?, customTemplates: [CustomMeetingTemplate]) -> MeetingTemplateSnapshot? {
        resolveExactDefinition(id: id, customTemplates: customTemplates)?.snapshot
    }

    static func snapshot(
        for meeting: MeetingRecord,
        customTemplates: [CustomMeetingTemplate],
        defaultTemplateID: String? = nil
    ) -> MeetingTemplateSnapshot {
        let storedID = meeting.selectedTemplateID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let storedName = meeting.selectedTemplateName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let storedPrompt = meeting.selectedTemplatePrompt?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !storedID.isEmpty, !storedName.isEmpty, !storedPrompt.isEmpty {
            return MeetingTemplateSnapshot(
                id: storedID,
                name: storedName,
                kind: meeting.selectedTemplateKind ?? .auto,
                prompt: storedPrompt
            )
        }
        return resolveSnapshot(
            id: storedID.isEmpty ? nil : storedID,
            customTemplates: customTemplates,
            defaultTemplateID: defaultTemplateID
        )
    }
}
