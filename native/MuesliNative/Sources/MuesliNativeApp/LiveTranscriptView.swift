// Purpose: Scrolling live transcript view with auto-scroll during active meetings
// Created: 2026-05-22

import SwiftUI

private struct LiveTranscriptGroup: Identifiable {
    // Stable ID: sequential index of the group in arrival order.
    // Using a deterministic Int instead of UUID prevents SwiftUI from treating
    // every group as removed+reinserted on each transcript update.
    let id: Int
    let speaker: String?
    let isUser: Bool
    let lines: [String]
    let timestamp: String?
}

struct LiveTranscriptView: View {
    let transcript: String
    let placeholder: String
    let partialYou: String
    let partialOthers: String
    @State private var groups: [LiveTranscriptGroup] = []
    // Tracks how many characters of transcript have been parsed into groups.
    // On each onChange we only parse the new suffix, keeping updates O(k)
    // where k = lines in the new chunk rather than O(n) for the full history.
    @State private var parsedLength: Int = 0

    init(
        transcript: String,
        placeholder: String = "Waiting for speech…",
        partialYou: String = "",
        partialOthers: String = ""
    ) {
        self.transcript = transcript
        self.placeholder = placeholder
        self.partialYou = partialYou
        self.partialOthers = partialOthers
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 6) {
                    if groups.isEmpty && trimmedPartialYou.isEmpty && trimmedPartialOthers.isEmpty {
                        Text(placeholder)
                            .font(MuesliTheme.body())
                            .foregroundStyle(MuesliTheme.textTertiary)
                            .padding(MuesliTheme.spacing16)
                    } else {
                        ForEach(groups) { group in
                            liveBubble(for: group)
                        }
                        if !trimmedPartialOthers.isEmpty {
                            partialBubble(speaker: "Others", text: trimmedPartialOthers, isUser: false)
                        }
                        if !trimmedPartialYou.isEmpty {
                            partialBubble(speaker: "You", text: trimmedPartialYou, isUser: true)
                        }
                        Color.clear
                            .frame(height: 1)
                            .id("liveTranscriptBottom")
                    }
                }
                .padding(.horizontal, MuesliTheme.spacing16)
                .padding(.vertical, MuesliTheme.spacing8)
            }
            .onChange(of: transcript) { _, newTranscript in
                mergeNewContent(from: newTranscript)
                scrollToBottom(proxy)
            }
            .onChange(of: partialYou) { old, new in
                if old.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                   !new.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    scrollToBottom(proxy)
                }
            }
            .onChange(of: partialOthers) { old, new in
                if old.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                   !new.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    scrollToBottom(proxy)
                }
            }
            .onAppear {
                // @State is freshly initialized on each tab switch, so this
                // catches up with any chunks that arrived on another tab.
                mergeNewContent(from: transcript)
                DispatchQueue.main.async {
                    proxy.scrollTo("liveTranscriptBottom", anchor: .bottom)
                }
            }
        }
    }

    private var trimmedPartialYou: String {
        partialYou.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var trimmedPartialOthers: String {
        partialOthers.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func mergeNewContent(from newTranscript: String) {
        guard newTranscript.count > parsedLength else {
            // Transcript was reset (meeting ended).
            groups = []
            parsedLength = 0
            return
        }
        let startIndex = newTranscript.index(newTranscript.startIndex, offsetBy: parsedLength)
        parsedLength = newTranscript.count

        let newMessages = TranscriptChatMessage.messages(from: String(newTranscript[startIndex...]))
        for msg in newMessages {
            if let last = groups.last, last.speaker == msg.speaker {
                groups[groups.count - 1] = LiveTranscriptGroup(
                    id: last.id,
                    speaker: last.speaker,
                    isUser: last.isUser,
                    lines: last.lines + [msg.text],
                    timestamp: last.timestamp
                )
            } else {
                groups.append(LiveTranscriptGroup(
                    id: groups.count,
                    speaker: msg.speaker,
                    isUser: msg.isUser,
                    lines: [msg.text],
                    timestamp: msg.timestamp
                ))
            }
        }
    }

    @ViewBuilder
    private func liveBubble(for group: LiveTranscriptGroup) -> some View {
        let isUser = group.isUser
        HStack(alignment: .bottom, spacing: 6) {
            if isUser { Spacer(minLength: 40) }
            VStack(alignment: .leading, spacing: 2) {
                if let speaker = group.speaker {
                    Text(speaker + (group.timestamp.map { "  \($0)" } ?? ""))
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(MuesliTheme.textTertiary)
                }
                ForEach(Array(group.lines.enumerated()), id: \.offset) { _, line in
                    Text(line)
                        .font(.system(size: 13))
                        .foregroundStyle(MuesliTheme.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(isUser ? MuesliTheme.accent.opacity(0.15) : MuesliTheme.surfacePrimary)
            .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall))
            .overlay(
                RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall)
                    .strokeBorder(
                        isUser ? MuesliTheme.accent.opacity(0.2) : MuesliTheme.surfaceBorder,
                        lineWidth: 1
                    )
            )
            if !isUser { Spacer(minLength: 40) }
        }
        .frame(maxWidth: .infinity, alignment: isUser ? .trailing : .leading)
    }

    private func partialBubble(speaker: String, text: String, isUser: Bool) -> some View {
        HStack(alignment: .bottom, spacing: 6) {
            if isUser { Spacer(minLength: 40) }
            VStack(alignment: .leading, spacing: 2) {
                Text(speaker)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(MuesliTheme.textTertiary)
                Text(text)
                    .font(.system(size: 13))
                    .italic()
                    .foregroundStyle(MuesliTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(isUser ? MuesliTheme.accent.opacity(0.06) : MuesliTheme.surfacePrimary.opacity(0.5))
            .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall))
            .overlay {
                RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall)
                    .strokeBorder(
                        MuesliTheme.surfaceBorder,
                        style: StrokeStyle(lineWidth: 1, dash: [4, 3])
                    )
            }
            if !isUser { Spacer(minLength: 40) }
        }
        .frame(maxWidth: .infinity, alignment: isUser ? .trailing : .leading)
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy) {
        DispatchQueue.main.async {
            withAnimation(.easeOut(duration: 0.15)) {
                proxy.scrollTo("liveTranscriptBottom", anchor: .bottom)
            }
        }
    }
}
