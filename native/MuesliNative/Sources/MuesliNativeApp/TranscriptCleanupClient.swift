import Foundation

typealias TranscriptCleanupRequest = @Sendable (String, String?, TranscriptCleanupSettings) async throws -> String
typealias ChatGPTTranscriptCleanupRequest = @Sendable (String, String, String, TimeInterval) async throws -> String?

struct TranscriptCleanupSettings: Equatable, Sendable {
    var provider: TranscriptCleanupProviderOption
    var systemPrompt: String
    var chatGPTModel: String
    var openAIAPIKey: String
    var openAIModel: String
    var openRouterAPIKey: String
    var openRouterModel: String
    var customLLMURL: String
    var customLLMAPIKey: String
    var customLLMModel: String
    var customLLMFormat: String

    init(
        provider: TranscriptCleanupProviderOption = .local,
        systemPrompt: String = PostProcessorOption.defaultSystemPrompt,
        chatGPTModel: String = "",
        openAIAPIKey: String = "",
        openAIModel: String = "",
        openRouterAPIKey: String = "",
        openRouterModel: String = "",
        customLLMURL: String = "",
        customLLMAPIKey: String = "",
        customLLMModel: String = "",
        customLLMFormat: String = CustomLLMFormat.openAI.rawValue
    ) {
        self.provider = provider
        self.systemPrompt = systemPrompt
        self.chatGPTModel = chatGPTModel
        self.openAIAPIKey = openAIAPIKey
        self.openAIModel = openAIModel
        self.openRouterAPIKey = openRouterAPIKey
        self.openRouterModel = openRouterModel
        self.customLLMURL = customLLMURL
        self.customLLMAPIKey = customLLMAPIKey
        self.customLLMModel = customLLMModel
        self.customLLMFormat = customLLMFormat
    }

    init(config: AppConfig) {
        self.init(
            provider: TranscriptCleanupProviderOption.resolved(config.transcriptCleanupProvider),
            systemPrompt: config.postProcessorSystemPrompt,
            chatGPTModel: config.resolvedChatGPTDictationCleanupModel,
            openAIAPIKey: config.openAIAPIKey,
            openAIModel: config.openAIModel,
            openRouterAPIKey: config.openRouterAPIKey,
            openRouterModel: config.openRouterModel,
            customLLMURL: config.customLLMURL,
            customLLMAPIKey: config.customLLMAPIKey,
            customLLMModel: config.customLLMModel,
            customLLMFormat: config.customLLMFormat
        )
    }
}

struct TranscriptCleanupCredentialStatus: Equatable, Sendable {
    let message: String
    let isWarning: Bool

    static func dictationCleanup(
        provider: TranscriptCleanupProviderOption,
        config: AppConfig,
        isChatGPTAuthenticated: Bool = false,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Self? {
        switch provider {
        case .local:
            return nil
        case .chatGPT:
            return Self(
                message: isChatGPTAuthenticated
                    ? "Signed in with ChatGPT."
                    : "Sign in with ChatGPT to use subscription cleanup.",
                isWarning: !isChatGPTAuthenticated
            )
        case .openAI:
            let hasConfiguredKey = hasValue(config.openAIAPIKey)
            let hasEnvironmentKey = hasValue(environment["OPENAI_API_KEY"] ?? "")
            return Self(
                message: "Uses Meeting Summaries OpenAI credentials: \(keyStatus(hasConfiguredKey: hasConfiguredKey, hasEnvironmentKey: hasEnvironmentKey)).",
                isWarning: !hasConfiguredKey && !hasEnvironmentKey
            )
        case .openRouter:
            let hasConfiguredKey = hasValue(config.openRouterAPIKey)
            let hasEnvironmentKey = hasValue(environment["OPENROUTER_API_KEY"] ?? "")
            return Self(
                message: "Uses Meeting Summaries OpenRouter credentials: \(keyStatus(hasConfiguredKey: hasConfiguredKey, hasEnvironmentKey: hasEnvironmentKey)).",
                isWarning: !hasConfiguredKey && !hasEnvironmentKey
            )
        case .customLLM:
            let format = CustomLLMFormat(rawValue: config.customLLMFormat) ?? .openAI
            guard format == .openAI else {
                return Self(
                    message: "Dictation cleanup only supports Meeting Summaries Custom LLM in OpenAI-compatible mode.",
                    isWarning: true
                )
            }
            let hasEndpoint = hasValue(config.customLLMURL)
            let hasKey = hasValue(config.customLLMAPIKey)
            let settingsStatus = hasEndpoint || hasKey ? "settings present" : "no custom settings; default local endpoint"
            return Self(
                message: "Uses Meeting Summaries Custom LLM credentials: \(settingsStatus), \(hasKey ? "key present" : "key optional").",
                isWarning: !hasEndpoint && !hasKey
            )
        }
    }

    private static func keyStatus(hasConfiguredKey: Bool, hasEnvironmentKey: Bool) -> String {
        if hasConfiguredKey { return "key present" }
        if hasEnvironmentKey { return "environment key present" }
        return "key missing"
    }

    private static func hasValue(_ value: String) -> Bool {
        !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

enum TranscriptCleanupError: LocalizedError {
    case missingAPIKey(String)
    case unsupportedCustomFormat(String)
    case invalidURL(String)
    case backendFailed(String, Int?, String)
    case emptyResponse(String)
    case rejectedOutput(String)

    var errorDescription: String? {
        switch self {
        case let .missingAPIKey(provider):
            return "\(provider) transcript cleanup needs an API key."
        case let .unsupportedCustomFormat(format):
            return "Transcript cleanup supports OpenAI-compatible Custom LLM endpoints, not \(format)."
        case let .invalidURL(url):
            return "Invalid transcript cleanup URL: \(url)"
        case let .backendFailed(provider, statusCode, message):
            let status = statusCode.map { " Status \($0)." } ?? ""
            return "\(provider) transcript cleanup failed.\(status) \(message)"
        case let .emptyResponse(provider):
            return "\(provider) transcript cleanup returned an empty response."
        case let .rejectedOutput(provider):
            return "\(provider) transcript cleanup output was rejected as unsafe."
        }
    }
}

enum TranscriptCleanupFailureSurface {
    static func warning(provider: TranscriptCleanupProviderOption, error: Error) -> String {
        let reason = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        return "\(provider.label) transcript cleanup failed; using raw transcript. \(reason)"
    }
}

enum ExternalTranscriptCleanupClient {
    private static let openAIURL = URL(string: "https://api.openai.com/v1/chat/completions")!
    private static let openRouterURL = URL(string: "https://openrouter.ai/api/v1/chat/completions")!
    private static let defaultOpenAIModel = "gpt-5.4-mini"
    private static let defaultOpenRouterModel = "stepfun/step-3.5-flash:free"
    private static let defaultCustomModel = "local-model"
    private static let chatGPTTimeout: TimeInterval = 10
    private static let timeout: TimeInterval = 120
    private static let defaultChatGPTRequest: ChatGPTTranscriptCleanupRequest = { systemPrompt, userPrompt, model, timeout in
        try await MeetingSummaryClient.callWHAM(
            systemPrompt: systemPrompt,
            userPrompt: userPrompt,
            model: model,
            timeout: timeout
        )
    }

    static func cleanup(
        _ text: String,
        appContext: String?,
        settings: TranscriptCleanupSettings,
        chatGPTRequest: ChatGPTTranscriptCleanupRequest = defaultChatGPTRequest
    ) async throws -> String {
        switch settings.provider {
        case .local:
            throw TranscriptCleanupError.rejectedOutput(settings.provider.label)
        case .chatGPT:
            guard let raw = try await chatGPTRequest(
                settings.systemPrompt,
                userPrompt(text: text, appContext: appContext),
                AppConfig.resolvedChatGPTModel(
                    settings.chatGPTModel,
                    defaultModel: AppConfig.defaultChatGPTDictationCleanupModel
                ),
                chatGPTTimeout
            ) else {
                throw TranscriptCleanupError.emptyResponse(settings.provider.label)
            }
            return try validateOutput(raw, input: text, provider: settings.provider.label)
        case .openAI:
            let apiKey = resolvedAPIKey(environmentName: "OPENAI_API_KEY", configured: settings.openAIAPIKey)
            guard !apiKey.isEmpty else { throw TranscriptCleanupError.missingAPIKey(settings.provider.label) }
            let model = nonEmpty(settings.openAIModel) ?? defaultOpenAIModel
            return try await callChatCompletions(
                provider: settings.provider.label,
                url: openAIURL,
                apiKey: apiKey,
                model: model,
                text: text,
                appContext: appContext,
                systemPrompt: settings.systemPrompt,
                extraHeaders: [:]
            )
        case .openRouter:
            let apiKey = resolvedAPIKey(environmentName: "OPENROUTER_API_KEY", configured: settings.openRouterAPIKey)
            guard !apiKey.isEmpty else { throw TranscriptCleanupError.missingAPIKey(settings.provider.label) }
            let model = nonEmpty(settings.openRouterModel) ?? defaultOpenRouterModel
            return try await callChatCompletions(
                provider: settings.provider.label,
                url: openRouterURL,
                apiKey: apiKey,
                model: model,
                text: text,
                appContext: appContext,
                systemPrompt: settings.systemPrompt,
                extraHeaders: ["X-OpenRouter-Title": AppIdentity.displayName]
            )
        case .customLLM:
            let format = CustomLLMFormat(rawValue: settings.customLLMFormat) ?? .openAI
            guard format == .openAI else { throw TranscriptCleanupError.unsupportedCustomFormat(format.label) }
            guard let url = resolveOpenAICompatibleURL(settings.customLLMURL) else {
                throw TranscriptCleanupError.invalidURL(settings.customLLMURL)
            }
            return try await callChatCompletions(
                provider: settings.provider.label,
                url: url,
                apiKey: settings.customLLMAPIKey,
                model: nonEmpty(settings.customLLMModel) ?? defaultCustomModel,
                text: text,
                appContext: appContext,
                systemPrompt: settings.systemPrompt,
                extraHeaders: [:]
            )
        }
    }

    static func validateOutput(_ raw: String, input: String, provider: String) throws -> String {
        let cleaned = Qwen3PostProcessorOutputCleaner.clean(raw)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.isEmpty, Qwen3DeletionCueDetector.containsDeletionCue(input) {
            return ""
        }
        guard !cleaned.isEmpty else { throw TranscriptCleanupError.emptyResponse(provider) }
        guard !Qwen3PostProcessorOutputCleaner.shouldFallbackToInput(cleaned: cleaned, input: input) else {
            throw TranscriptCleanupError.rejectedOutput(provider)
        }
        return cleaned
    }

    static func resolveOpenAICompatibleURL(_ rawURL: String) -> URL? {
        let resolved = nonEmpty(rawURL) ?? "http://localhost:8080/v1/chat/completions"
        return resolveEndpointURL(resolved, endpointSuffix: "v1/chat/completions")
    }

    static func extractChatCompletionsText(from payload: [String: Any]) -> String? {
        guard let choices = payload["choices"] as? [[String: Any]] else { return nil }
        let text = choices.compactMap { choice -> String? in
            if let message = choice["message"] as? [String: Any],
               let content = message["content"] as? String,
               !content.isEmpty {
                return content
            }
            if let content = choice["text"] as? String, !content.isEmpty {
                return content
            }
            return nil
        }
        guard !text.isEmpty else { return nil }
        return text.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func callChatCompletions(
        provider: String,
        url: URL,
        apiKey: String,
        model: String,
        text: String,
        appContext: String?,
        systemPrompt: String,
        extraHeaders: [String: String]
    ) async throws -> String {
        let body: [String: Any] = [
            "model": model,
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user", "content": userPrompt(text: text, appContext: appContext)],
            ],
            "temperature": 0,
        ]

        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        extraHeaders.forEach { key, value in request.setValue(value, forHTTPHeaderField: key) }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        try validateHTTPResponse(response, data: data, provider: provider)
        guard
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let raw = extractChatCompletionsText(from: json)
        else {
            throw TranscriptCleanupError.emptyResponse(provider)
        }
        return try validateOutput(raw, input: text, provider: provider)
    }

    private static func userPrompt(text: String, appContext: String?) -> String {
        let context = appContext?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let context, !context.isEmpty {
            return """
            App context:
            \(context)

            Raw transcript:
            \(text)
            """
        }
        return """
        Raw transcript:
        \(text)
        """
    }

    private static func validateHTTPResponse(_ response: URLResponse, data: Data, provider: String) throws {
        guard let http = response as? HTTPURLResponse else { return }
        guard (200..<300).contains(http.statusCode) else {
            let message = extractErrorMessage(from: data) ?? HTTPURLResponse.localizedString(forStatusCode: http.statusCode)
            throw TranscriptCleanupError.backendFailed(provider, http.statusCode, message)
        }
    }

    private static func extractErrorMessage(from data: Data) -> String? {
        guard
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let error = json["error"]
        else {
            return nil
        }
        if let error = error as? [String: Any] {
            return error["message"] as? String
        }
        return error as? String
    }

    private static func resolvedAPIKey(environmentName: String, configured: String) -> String {
        let env = ProcessInfo.processInfo.environment[environmentName] ?? ""
        return nonEmpty(env) ?? (nonEmpty(configured) ?? "")
    }

    private static func nonEmpty(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func resolveEndpointURL(_ rawURL: String, endpointSuffix: String) -> URL? {
        guard var components = URLComponents(string: rawURL.trimmingCharacters(in: .whitespacesAndNewlines)),
              components.scheme != nil,
              components.host != nil else {
            return nil
        }

        let suffixParts = endpointSuffix.split(separator: "/").map(String.init)
        var pathParts = components.path.split(separator: "/").map(String.init)

        if pathParts.isEmpty {
            pathParts = suffixParts
        } else if pathParts.last == suffixParts.first {
            pathParts = Array(pathParts.dropLast()) + suffixParts
        } else if !isCompleteEndpointPath(pathParts, endpointSuffixParts: suffixParts) {
            pathParts.append(contentsOf: suffixParts)
        }

        components.path = "/" + pathParts.joined(separator: "/")
        return components.url
    }

    private static func isCompleteEndpointPath(_ pathParts: [String], endpointSuffixParts suffixParts: [String]) -> Bool {
        if pathParts.suffix(suffixParts.count).elementsEqual(suffixParts) {
            return true
        }
        if suffixParts == ["v1", "chat", "completions"] {
            return pathParts.suffix(2).elementsEqual(["chat", "completions"])
        }
        return false
    }
}
