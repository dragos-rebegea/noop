#if os(iOS)
import SwiftUI
import StrandDesign

/// Type or say what you ate. Speech is transcribed on-device (`CoachVoiceInput`); only the text
/// is sent, and only after "Estimate".
struct FoodDescribeView: View {
    let onEstimate: (String) -> Void

    @StateObject private var voice = CoachVoiceInput()
    @State private var text = ""
    /// The text that was in the field when recording started; the live transcript appends to it.
    @State private var textBeforeVoice = ""
    @FocusState private var focused: Bool
    @Environment(\.dismiss) private var dismiss

    private var trimmed: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: NoopMetrics.sectionGap) {
                ZStack(alignment: .topLeading) {
                    if text.isEmpty {
                        Text("2 eggs, toast with butter, flat white")
                            .font(StrandFont.title2)
                            .foregroundStyle(StrandPalette.textTertiary)
                            .padding(.top, NoopMetrics.space2)
                            .padding(.leading, NoopMetrics.space1)
                            .allowsHitTesting(false)
                    }
                    TextEditor(text: $text)
                        .font(StrandFont.title2)
                        .foregroundStyle(StrandPalette.textPrimary)
                        .scrollContentBackground(.hidden)
                        .focused($focused)
                }
                .frame(maxHeight: .infinity)
                .padding(NoopMetrics.space3)
                .background(StrandPalette.surfaceInset,
                            in: RoundedRectangle(cornerRadius: NoopMetrics.cardRadius, style: .continuous))

                if CoachVoiceInput.isSupported {
                    micButton
                }

                NoopButton("Estimate", systemImage: "sparkles", kind: .primary, fullWidth: true) {
                    if voice.isRecording { voice.stopTranscribing { _ in } }
                    onEstimate(trimmed)
                }
                .disabled(trimmed.isEmpty)
            }
            .padding(NoopMetrics.screenPadding)
            .background(StrandPalette.surfaceBase)
            .navigationTitle(String(localized: "Describe a meal"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "Cancel")) {
                        if voice.isRecording { voice.stopTranscribing { _ in } }
                        dismiss()
                    }
                }
            }
            .onAppear { focused = true }
            .onDisappear { if voice.isRecording { voice.stopTranscribing { _ in } } }
        }
    }

    private var micButton: some View {
        VStack(spacing: NoopMetrics.space2) {
            Button(action: toggleVoice) {
                Image(systemName: voice.isRecording ? "stop.fill" : "mic.fill")
                    .font(StrandFont.title2)
                    .foregroundStyle(voice.isRecording ? StrandPalette.surfaceBase : StrandPalette.textPrimary)
                    .frame(width: NoopMetrics.tileHeight * 0.66, height: NoopMetrics.tileHeight * 0.66)
                    .background(voice.isRecording ? StrandPalette.statusCritical : StrandPalette.surfaceInset,
                                in: Circle())
                    .symbolEffect(.pulse, isActive: voice.isRecording)
            }
            .buttonStyle(.plain)
            .disabled(!(voice.canUseVoice || voice.authorization == .notDetermined))
            .sensoryFeedback(.selection, trigger: voice.isRecording)
            .accessibilityLabel(voice.isRecording ? String(localized: "Stop dictation") : String(localized: "Dictate"))
            Text(voice.isRecording ? String(localized: "Listening. Tap to stop.")
                                   : (voice.statusMessage ?? String(localized: "Tap to say what you ate. Transcribed on this iPhone.")))
                .font(StrandFont.footnote)
                .foregroundStyle(StrandPalette.textTertiary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
    }

    private func toggleVoice() {
        if voice.isRecording {
            voice.stopTranscribing { final in apply(final) }
            return
        }
        focused = false
        textBeforeVoice = trimmed
        let start = { voice.startTranscribing { partial in apply(partial) } }
        if voice.authorization == .notDetermined {
            voice.requestAuthorization { state in if state == .authorized { start() } }
        } else {
            start()
        }
    }

    private func apply(_ transcript: String) {
        let spoken = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !spoken.isEmpty else { return }
        text = textBeforeVoice.isEmpty ? spoken : "\(textBeforeVoice) \(spoken)"
    }
}
#endif
