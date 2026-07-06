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
    enum TranscriptMergeDecision: Equatable {
        case unchanged
        case append(String)
        case resetAndAppend(String)
    }

    let transcript: String
    @State private var groups: [LiveTranscriptGroup] = []
    // Tracks how many characters of transcript have been parsed into groups.
    // On each onChange we only parse the new suffix, keeping updates O(k)
    // where k = lines in the new chunk rather than O(n) for the full history.
    @State private var parsedLength: Int = 0
    @State private var parsedTranscript: String = ""

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 6) {
                    if groups.isEmpty {
                        Text("Waiting for speech…")
                            .font(MuesliTheme.body())
                            .foregroundStyle(MuesliTheme.textTertiary)
                            .padding(MuesliTheme.spacing16)
                    } else {
                        ForEach(groups) { group in
                            liveBubble(for: group)
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
                DispatchQueue.main.async {
                    withAnimation(.easeOut(duration: 0.15)) {
                        proxy.scrollTo("liveTranscriptBottom", anchor: .bottom)
                    }
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

    private func mergeNewContent(from newTranscript: String) {
        let decision = Self.transcriptMergeDecision(
            newTranscript: newTranscript,
            parsedTranscript: parsedTranscript,
            parsedLength: parsedLength
        )

        let newContent: String
        switch decision {
        case .unchanged:
            return
        case .append(let suffix):
            newContent = suffix
        case .resetAndAppend(let transcript):
            groups = []
            parsedLength = 0
            parsedTranscript = ""
            newContent = transcript
        }

        parsedLength = newTranscript.count
        parsedTranscript = newTranscript

        let newMessages = TranscriptChatMessage.messages(from: newContent)
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

    static func transcriptMergeDecision(
        newTranscript: String,
        parsedTranscript: String,
        parsedLength: Int
    ) -> TranscriptMergeDecision {
        if newTranscript.count < parsedLength || !newTranscript.hasPrefix(parsedTranscript) {
            return .resetAndAppend(newTranscript)
        }
        guard newTranscript.count > parsedLength else {
            return .unchanged
        }
        let startIndex = newTranscript.index(newTranscript.startIndex, offsetBy: parsedLength)
        return .append(String(newTranscript[startIndex...]))
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
}
