// Purpose: Multi-turn chat UI for querying meeting transcripts via configured LLM backend
// Created: 2026-05-22

import SwiftUI

struct MeetingChatView: View {
    let transcript: String
    let config: AppConfig

    @Binding var history: [ChatTurn]
    @Binding var inputText: String
    @Binding var isThinking: Bool
    @Binding var errorMessage: String?
    @FocusState private var inputFocused: Bool

    struct ChatTurn: Identifiable {
        let id = UUID()
        let role: MeetingChatMessage.Role
        let text: String
    }

    private var systemPrompt: String {
        let transcriptSection = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        if transcriptSection.isEmpty {
            return "You are an assistant helping a user during a meeting. No transcript is available yet."
        }
        return """
        You are an assistant helping a user during a meeting. Below is the transcript so far. \
        Mic audio is labeled "You"; system audio from other participants is labeled "Others" during \
        live meetings, or with speaker labels after the meeting ends. \
        Answer questions about what has been said. Be concise and direct.

        ---
        \(transcriptSection)
        ---
        """
    }

    var body: some View {
        VStack(spacing: 0) {
            Divider()

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: MuesliTheme.spacing8) {
                        if history.isEmpty && !isThinking {
                            Text("Ask a question about the meeting…")
                                .font(MuesliTheme.body())
                                .foregroundStyle(MuesliTheme.textTertiary)
                                .padding(MuesliTheme.spacing24)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }

                        ForEach(history) { turn in
                            chatBubble(for: turn)
                        }

                        if isThinking {
                            thinkingBubble
                        }

                        Color.clear
                            .frame(height: 1)
                            .id("chatBottom")
                    }
                    .padding(.horizontal, MuesliTheme.spacing16)
                    .padding(.vertical, MuesliTheme.spacing12)
                }
                .onChange(of: history.count) { _, _ in
                    DispatchQueue.main.async {
                        withAnimation(.easeOut(duration: 0.2)) {
                            proxy.scrollTo("chatBottom", anchor: .bottom)
                        }
                    }
                }
                .onChange(of: isThinking) { _, _ in
                    DispatchQueue.main.async {
                        withAnimation(.easeOut(duration: 0.2)) {
                            proxy.scrollTo("chatBottom", anchor: .bottom)
                        }
                    }
                }
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(.system(size: 12))
                    .foregroundStyle(.red)
                    .padding(.horizontal, MuesliTheme.spacing16)
                    .padding(.bottom, MuesliTheme.spacing8)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            inputBar
        }
    }

    @ViewBuilder
    private func chatBubble(for turn: ChatTurn) -> some View {
        let isUser = turn.role == .user
        HStack(alignment: .bottom, spacing: MuesliTheme.spacing8) {
            if isUser { Spacer(minLength: 40) }
            Text(turn.text)
                .font(.system(size: 13))
                .foregroundStyle(MuesliTheme.textPrimary)
                .lineSpacing(2)
                .textSelection(.enabled)
                .padding(.horizontal, MuesliTheme.spacing12)
                .padding(.vertical, 8)
                .background(isUser ? MuesliTheme.accent.opacity(0.18) : MuesliTheme.surfacePrimary)
                .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall))
                .overlay(
                    RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall)
                        .strokeBorder(
                            isUser ? MuesliTheme.accent.opacity(0.25) : MuesliTheme.surfaceBorder,
                            lineWidth: 1
                        )
                )
                .frame(maxWidth: 320, alignment: isUser ? .trailing : .leading)
            if !isUser { Spacer(minLength: 40) }
        }
        .frame(maxWidth: .infinity, alignment: isUser ? .trailing : .leading)
    }

    private var thinkingBubble: some View {
        HStack(spacing: 4) {
            ForEach(0..<3, id: \.self) { i in
                Circle()
                    .fill(MuesliTheme.textTertiary)
                    .frame(width: 6, height: 6)
                    .opacity(0.6)
            }
        }
        .padding(.horizontal, MuesliTheme.spacing12)
        .padding(.vertical, 10)
        .background(MuesliTheme.surfacePrimary)
        .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall))
        .overlay(
            RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall)
                .strokeBorder(MuesliTheme.surfaceBorder, lineWidth: 1)
        )
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var inputBar: some View {
        HStack(spacing: MuesliTheme.spacing8) {
            TextField("Ask about the meeting…", text: $inputText, axis: .vertical)
                .font(.system(size: 13))
                .lineLimit(1...4)
                .textFieldStyle(.plain)
                .focused($inputFocused)
                .onSubmit { sendIfPossible() }
                .padding(.horizontal, MuesliTheme.spacing12)
                .padding(.vertical, 8)
                .background(MuesliTheme.surfacePrimary)
                .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall))
                .overlay(
                    RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall)
                        .strokeBorder(MuesliTheme.surfaceBorder, lineWidth: 1)
                )

            Button(action: sendIfPossible) {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 24))
                    .foregroundStyle(canSend ? MuesliTheme.accent : MuesliTheme.textTertiary)
            }
            .buttonStyle(.plain)
            .disabled(!canSend)
        }
        .padding(.horizontal, MuesliTheme.spacing16)
        .padding(.vertical, MuesliTheme.spacing12)
        .background(MuesliTheme.surfacePrimary)
        .overlay(alignment: .top) {
            Divider()
        }
    }

    private var canSend: Bool {
        !isThinking && !inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func sendIfPossible() {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isThinking else { return }
        inputText = ""
        errorMessage = nil

        history.append(ChatTurn(role: .user, text: text))
        isThinking = true

        let messages = buildMessages(userText: text)
        Task {
            do {
                let reply = try await MeetingChatClient.send(messages: messages, config: config)
                await MainActor.run {
                    history.append(ChatTurn(role: .assistant, text: reply))
                    isThinking = false
                }
            } catch {
                await MainActor.run {
                    errorMessage = error.localizedDescription
                    isThinking = false
                }
            }
        }
    }

    private func buildMessages(userText: String) -> [MeetingChatMessage] {
        var messages: [MeetingChatMessage] = [
            MeetingChatMessage(role: .system, content: systemPrompt)
        ]
        for turn in history {
            messages.append(MeetingChatMessage(role: turn.role, content: turn.text))
        }
        return MeetingChatClient.trimmedMessages(messages)
    }
}
