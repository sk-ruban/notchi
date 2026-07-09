import AppKit
import Carbon.HIToolbox
import SwiftUI

struct ShortcutRecorderView: View {
    private static let recordingPrompt = String(localized: "Press keys")

    let shortcut: GlobalShortcut
    var onBeginRecording: () -> Void = {}
    var onCancelRecording: () -> Void = {}
    var onReset: () -> Void
    var onShortcutChange: (GlobalShortcut) -> Void

    @State private var isRecording = false
    @State private var didRejectLastKey = false
    @State private var recordingPreview = Self.recordingPrompt

    var body: some View {
        HStack(spacing: 4) {
            if shortcut != .defaultTogglePanel {
                Button(action: resetShortcut) {
                    Image(systemName: "arrow.counterclockwise")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(TerminalColors.dimmedText)
                        .frame(width: 18, height: 18)
                }
                .buttonStyle(.plain)
                .help("Reset shortcut")
            }

            Button(action: beginRecording) {
                Text(buttonText)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(buttonForeground)
                    .lineLimit(1)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(buttonBackground)
                    .cornerRadius(5)
            }
            .buttonStyle(.plain)
            .modifier(HorizontalShake(animatableData: didRejectLastKey ? 1 : 0))
        }
        .background {
            if isRecording {
                ShortcutCaptureView(
                    onCapture: captureShortcut,
                    onCancel: cancelRecording,
                    onPreview: updateRecordingPreview,
                    onReject: rejectShortcut
                )
                .frame(width: 1, height: 1)
                .opacity(0.01)
            }
        }
        .onDisappear {
            guard isRecording else { return }
            isRecording = false
            onCancelRecording()
        }
    }

    private var buttonText: String {
        if isRecording {
            return recordingPreview
        }
        return shortcut.displayName
    }

    private var buttonForeground: Color {
        isRecording ? TerminalColors.amber : TerminalColors.primaryText
    }

    private var buttonBackground: Color {
        isRecording ? TerminalColors.amber.opacity(0.15) : Color.white.opacity(0.09)
    }

    private func beginRecording() {
        guard !isRecording else { return }
        didRejectLastKey = false
        recordingPreview = Self.recordingPrompt
        isRecording = true
        onBeginRecording()
    }

    private func captureShortcut(_ newShortcut: GlobalShortcut) {
        isRecording = false
        didRejectLastKey = false
        recordingPreview = Self.recordingPrompt
        onShortcutChange(newShortcut)
    }

    private func cancelRecording() {
        isRecording = false
        didRejectLastKey = false
        recordingPreview = Self.recordingPrompt
        onCancelRecording()
    }

    private func resetShortcut() {
        onReset()
    }

    private func rejectShortcut() {
        NSSound.beep()
        withAnimation(.linear(duration: 0.12)) {
            didRejectLastKey = true
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
            didRejectLastKey = false
        }
    }

    private func updateRecordingPreview(_ preview: String?) {
        recordingPreview = preview ?? Self.recordingPrompt
    }
}

private struct ShortcutCaptureView: NSViewRepresentable {
    var onCapture: (GlobalShortcut) -> Void
    var onCancel: () -> Void
    var onPreview: (String?) -> Void
    var onReject: () -> Void

    func makeNSView(context: Context) -> CaptureView {
        let view = CaptureView()
        view.onCapture = onCapture
        view.onCancel = onCancel
        view.onPreview = onPreview
        view.onReject = onReject
        return view
    }

    func updateNSView(_ nsView: CaptureView, context: Context) {
        nsView.onCapture = onCapture
        nsView.onCancel = onCancel
        nsView.onPreview = onPreview
        nsView.onReject = onReject

        DispatchQueue.main.async {
            guard nsView.superview != nil else { return }
            nsView.window?.makeFirstResponder(nsView)
        }
    }

    final class CaptureView: NSView {
        var onCapture: (GlobalShortcut) -> Void = { _ in }
        var onCancel: () -> Void = {}
        var onPreview: (String?) -> Void = { _ in }
        var onReject: () -> Void = {}

        override var acceptsFirstResponder: Bool { true }

        override func keyDown(with event: NSEvent) {
            if event.keyCode == UInt16(kVK_Escape) {
                onCancel()
                return
            }

            guard let shortcut = GlobalShortcut(event: event) else {
                onPreview(GlobalShortcut.recordingDisplayName(for: event))
                onReject()
                return
            }

            onCapture(shortcut)
        }

        override func flagsChanged(with event: NSEvent) {
            onPreview(GlobalShortcut.recordingDisplayName(for: event))
        }
    }
}

private struct HorizontalShake: GeometryEffect {
    var travelDistance: CGFloat = 3
    var cyclesPerUnit: CGFloat = 1
    var animatableData: CGFloat

    func effectValue(size: CGSize) -> ProjectionTransform {
        ProjectionTransform(
            CGAffineTransform(
                translationX: travelDistance * sin(animatableData * .pi * 2 * cyclesPerUnit),
                y: 0
            )
        )
    }
}
