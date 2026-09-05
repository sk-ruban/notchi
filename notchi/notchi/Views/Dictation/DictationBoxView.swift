import AppKit
import SwiftUI

struct DictationBoxView: View {
    @Bindable var service: SpeechToTextService
    let targetLabel: String?
    let onSend: (String) -> Void
    let onCTA: (DictationCTA) -> Void
    var onCancel: () -> Void = {}

    @Environment(\.panelScale) private var panelScale
    private var fontScale: CGFloat { PanelTypography.fontScale(panelScale: panelScale) }

    private var isEmpty: Bool {
        service.transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(DictationPresentation.statusText(for: service.phase))
                    .font(.system(size: 11 * fontScale, weight: .medium))
                    .foregroundColor(TerminalColors.secondaryText)
                Spacer()
                if let targetLabel {
                    Text(targetLabel)
                        .font(.system(size: 10 * fontScale))
                        .foregroundColor(TerminalColors.dimmedText)
                }
            }

            if DictationPresentation.showsEditor(service.phase, hasText: !isEmpty) {
                DictationTextField(text: $service.transcript, fontScale: fontScale, onSubmit: submit, onCancel: onCancel)
                    .frame(minHeight: 44 * fontScale, maxHeight: 88 * fontScale)
                    .padding(6)
                    .background(TerminalColors.subtleBackground)
                    .cornerRadius(8)

                // WHY: fixed-height bottom bar so swapping the Send button (review)
                // for the activity indicator (busy) doesn't change the box height
                // and jump the text field up/down during re-dictation.
                Group {
                    if DictationPresentation.isBusy(service.phase) {
                        // Activity indicator below the still-visible text; new speech
                        // appends into the field above on return to review.
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.mini)
                            Text(DictationPresentation.statusText(for: service.phase))
                                .font(.system(size: 10 * fontScale))
                                .foregroundColor(TerminalColors.dimmedText)
                            Spacer()
                        }
                    } else {
                        HStack(spacing: 8) {
                            Text("Return to send · ⌥Return newline · Esc to discard")
                                .font(.system(size: 10 * fontScale))
                                .foregroundColor(TerminalColors.dimmedText)
                            Spacer()
                            Button(action: submit) {
                                Text("Send")
                                    .font(.system(size: 12 * fontScale, weight: .semibold))
                                    .foregroundColor(.white)
                                    .padding(.horizontal, 12).padding(.vertical, 5)
                                    .background(TerminalColors.iMessageBlue)
                                    .cornerRadius(6)
                            }
                            .buttonStyle(.plain)
                            .disabled(isEmpty)
                        }
                    }
                }
                .frame(height: 26 * fontScale)
            }

            let cta = DictationPresentation.cta(for: service.phase)
            if cta != .none, !ctaLabel(cta).isEmpty {
                Button(action: { onCTA(cta) }) {
                    Text(ctaLabel(cta))
                        .font(.system(size: 11 * fontScale, weight: .medium))
                        .foregroundColor(TerminalColors.amber)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(10)
        .background(TerminalColors.subtleBackground)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func submit() {
        guard !isEmpty else { return }
        onSend(service.transcript)
    }

    private func ctaLabel(_ cta: DictationCTA) -> String {
        switch cta {
        case .grantMicrophone: return String(localized: "Grant Microphone")
        case .grantAccessibility: return String(localized: "Grant Accessibility")
        case .downloadModel: return String(localized: "Download Model")
        case .retry: return String(localized: "Try Again")
        case .noSession, .sessionNotInjectable, .none: return ""
        }
    }
}

/// Multiline editor where Return submits and ⌥Return / ⇧Return inserts a newline.
private struct DictationTextField: NSViewRepresentable {
    @Binding var text: String
    var fontScale: CGFloat = 1.0
    let onSubmit: () -> Void
    var onCancel: () -> Void = {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let textView = SubmittingTextView()
        textView.delegate = context.coordinator
        textView.onSubmit = { context.coordinator.parent.onSubmit() }
        textView.onCancel = { context.coordinator.parent.onCancel() }
        textView.font = .systemFont(ofSize: 13 * fontScale)
        textView.textColor = .white
        textView.insertionPointColor = .white
        textView.drawsBackground = false
        textView.isRichText = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.allowsUndo = true
        textView.textContainerInset = NSSize(width: 2, height: 4)
        textView.string = text

        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true

        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.borderType = .noBorder
        scroll.documentView = textView
        return scroll
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let textView = nsView.documentView as? SubmittingTextView else { return }
        textView.onSubmit = { context.coordinator.parent.onSubmit() }
        textView.onCancel = { context.coordinator.parent.onCancel() }
        textView.font = .systemFont(ofSize: 13 * fontScale)
        if textView.string != text {
            textView.string = text
            // Setting .string resets the caret to 0; for an external update
            // (re-dictation appending new text) place it at the end so the user
            // can keep going / edit the tail instead of jumping to the start.
            textView.setSelectedRange(NSRange(location: (text as NSString).length, length: 0))
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: DictationTextField
        init(_ parent: DictationTextField) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            parent.text = textView.string
        }
    }

    final class SubmittingTextView: NSTextView {
        var onSubmit: (() -> Void)?
        var onCancel: (() -> Void)?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window {
                window.makeFirstResponder(self)
                setSelectedRange(NSRange(location: (string as NSString).length, length: 0))
            }
        }

        // Esc discards the dictation box.
        override func cancelOperation(_ sender: Any?) {
            onCancel?()
        }

        override func keyDown(with event: NSEvent) {
            // If the user is composing text in an IME (e.g. CJK/Vietnamese), Return
            // confirms the marked composition candidate — don't submit early.
            if hasMarkedText() {
                super.keyDown(with: event)
                return
            }

            // 36 = Return, 76 = keypad Enter
            guard event.keyCode == 36 || event.keyCode == 76 else {
                super.keyDown(with: event)
                return
            }
            let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            if modifiers.contains(.option) || modifiers.contains(.shift) {
                super.keyDown(with: event) // insert a newline
            } else {
                onSubmit?()
            }
        }
    }
}
