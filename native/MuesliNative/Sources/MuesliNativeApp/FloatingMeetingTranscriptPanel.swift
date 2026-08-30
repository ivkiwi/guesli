import AppKit
import Observation
import SwiftUI

enum FloatingMeetingTranscriptPlacement {
    static let panelSize = NSSize(width: 360, height: 300)
    static let gap: CGFloat = 8
    static let screenInset: CGFloat = 8

    static func frame(beside indicatorFrame: NSRect, visibleFrame: NSRect) -> NSRect {
        let fitsLeft = indicatorFrame.minX - visibleFrame.minX >= panelSize.width + gap
        let proposedX = fitsLeft
            ? indicatorFrame.minX - panelSize.width - gap
            : indicatorFrame.maxX + gap
        let minX = visibleFrame.minX + screenInset
        let maxX = visibleFrame.maxX - panelSize.width - screenInset
        let minY = visibleFrame.minY + screenInset
        let maxY = visibleFrame.maxY - panelSize.height - screenInset
        return NSRect(
            x: min(max(proposedX, minX), maxX),
            y: min(max(indicatorFrame.midY - panelSize.height / 2, minY), maxY),
            width: panelSize.width,
            height: panelSize.height
        )
    }
}

@MainActor
@Observable
final class FloatingMeetingTranscriptModel {
    var transcript = ""
    var partialYou = ""
    var partialOthers = ""
    var isPaused = false
    var didCopy = false

    var hasContent: Bool {
        !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !partialYou.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !partialOthers.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func copyToPasteboard() {
        var parts = [transcript.trimmingCharacters(in: .whitespacesAndNewlines)]
        if !partialOthers.isEmpty { parts.append("Others: \(partialOthers)") }
        if !partialYou.isEmpty { parts.append("You: \(partialYou)") }
        let text = parts.filter { !$0.isEmpty }.joined(separator: "\n")
        guard !text.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        didCopy = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            self?.didCopy = false
        }
    }

    func reset() {
        transcript = ""
        partialYou = ""
        partialOthers = ""
        isPaused = false
        didCopy = false
    }
}

@MainActor
final class FloatingMeetingTranscriptPanelController {
    private let model = FloatingMeetingTranscriptModel()
    private let onHoverChanged: (Bool) -> Void
    private let onOpenNotes: () -> Void
    private let onDismiss: () -> Void
    private var panel: NSPanel?

    init(
        onHoverChanged: @escaping (Bool) -> Void,
        onOpenNotes: @escaping () -> Void,
        onDismiss: @escaping () -> Void
    ) {
        self.onHoverChanged = onHoverChanged
        self.onOpenNotes = onOpenNotes
        self.onDismiss = onDismiss
    }

    var isVisible: Bool { panel?.isVisible == true }
    var containsMouseLocation: Bool { panel?.frame.contains(NSEvent.mouseLocation) == true }

    func update(transcript: String, partialYou: String, partialOthers: String) {
        model.transcript = transcript
        model.partialYou = partialYou
        model.partialOthers = partialOthers
    }

    func setPaused(_ paused: Bool) {
        model.isPaused = paused
    }

    func show(beside indicatorFrame: NSRect) {
        let panel = panel ?? makePanel()
        self.panel = panel
        let screen = NSScreen.screens.first { $0.frame.intersects(indicatorFrame) } ?? NSScreen.main
        guard let visibleFrame = screen?.visibleFrame else { return }
        panel.setFrame(
            FloatingMeetingTranscriptPlacement.frame(beside: indicatorFrame, visibleFrame: visibleFrame),
            display: true
        )
        panel.orderFrontRegardless()
    }

    func hide(reset: Bool = false) {
        panel?.orderOut(nil)
        if reset { model.reset() }
    }

    func close() {
        panel?.close()
        panel = nil
        model.reset()
    }

    private func makePanel() -> NSPanel {
        let root = FloatingMeetingTranscriptPanelView(
            model: model,
            onHoverChanged: onHoverChanged,
            onOpenNotes: onOpenNotes,
            onDismiss: onDismiss
        )
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: FloatingMeetingTranscriptPlacement.panelSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.contentView = NSHostingView(rootView: root)
        return panel
    }
}

private struct FloatingMeetingTranscriptPanelView: View {
    let model: FloatingMeetingTranscriptModel
    let onHoverChanged: (Bool) -> Void
    let onOpenNotes: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: MuesliTheme.spacing8) {
                Button("Live transcript", action: onOpenNotes)
                    .buttonStyle(.plain)
                    .font(MuesliTheme.callout().weight(.semibold))
                Spacer()
                Circle()
                    .fill(model.isPaused ? MuesliTheme.textTertiary : MuesliTheme.success)
                    .frame(width: 6, height: 6)
                Text(model.isPaused ? "Paused" : "Live")
                    .font(MuesliTheme.caption())
                    .foregroundStyle(MuesliTheme.textSecondary)
                Button(action: model.copyToPasteboard) {
                    Image(systemName: model.didCopy ? "checkmark" : "doc.on.doc")
                }
                .buttonStyle(.plain)
                .disabled(!model.hasContent)
                .help("Copy transcript")
                Button(action: onDismiss) {
                    Image(systemName: "chevron.down")
                }
                .buttonStyle(.plain)
                .help("Hide live transcript")
            }
            .padding(.horizontal, MuesliTheme.spacing16)
            .frame(height: 42)

            Divider().background(MuesliTheme.surfaceBorder)

            LiveTranscriptView(
                transcript: model.transcript,
                partialYou: model.partialYou,
                partialOthers: model.partialOthers
            )
        }
        .frame(width: FloatingMeetingTranscriptPlacement.panelSize.width, height: FloatingMeetingTranscriptPlacement.panelSize.height)
        .background(.ultraThinMaterial)
        .background(MuesliTheme.backgroundRaised.opacity(0.94))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(MuesliTheme.surfaceBorder, lineWidth: 1)
        }
        .onHover(perform: onHoverChanged)
    }
}
