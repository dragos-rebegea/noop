#if os(iOS)
import AVFoundation
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
    /// Bumped after a permission prompt or a return from Settings, so `voiceState` is re-read.
    @State private var permissionTick = 0
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase

    /// Dictation needs both speech recognition and the microphone; each can be refused separately.
    private enum VoiceState { case ready, needsPrompt, speechDenied, micDenied, unavailable }

    private var voiceState: VoiceState {
        _ = permissionTick
        switch voice.authorization {
        case .denied: return .speechDenied
        case .unavailable: return .unavailable
        case .notDetermined: return .needsPrompt
        case .authorized: break
        }
        switch AVAudioApplication.shared.recordPermission {
        case .denied: return .micDenied
        case .undetermined: return .needsPrompt
        default: break
        }
        return voice.canUseVoice ? .ready : .unavailable
    }

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
            .onChange(of: scenePhase) { _, phase in if phase == .active { permissionTick += 1 } }
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
            .disabled(!(voice.isRecording || voiceState == .ready || voiceState == .needsPrompt))
            .sensoryFeedback(.selection, trigger: voice.isRecording)
            .accessibilityLabel(voice.isRecording ? String(localized: "Stop dictation") : String(localized: "Dictate"))
            Text(micHint)
                .font(StrandFont.footnote)
                .foregroundStyle(StrandPalette.textTertiary)
                .multilineTextAlignment(.center)
            if voiceState == .speechDenied || voiceState == .micDenied {
                Button(String(localized: "Allow in Settings")) {
                    if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                }
                .font(StrandFont.footnote)
                .foregroundStyle(StrandPalette.accent)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var micHint: String {
        if voice.isRecording { return String(localized: "Listening. Tap to stop.") }
        switch voiceState {
        case .ready, .needsPrompt:
            return voice.statusMessage ?? String(localized: "Tap to say what you ate. Transcribed on this iPhone.")
        case .speechDenied:
            return String(localized: "Speech recognition is off for NOOP, so dictation can't start. You can still type.")
        case .micDenied:
            return String(localized: "Microphone access is off for NOOP, so dictation can't start. You can still type.")
        case .unavailable:
            return voice.statusMessage ?? String(localized: "Dictation on this iPhone isn't available for your language. You can still type.")
        }
    }

    private func toggleVoice() {
        if voice.isRecording {
            voice.stopTranscribing { final in apply(final) }
            return
        }
        focused = false
        textBeforeVoice = trimmed
        let start = { voice.startTranscribing { partial in apply(partial) } }
        if voiceState == .needsPrompt {
            // Asks for speech recognition and then the microphone, each only if not yet decided.
            voice.requestAuthorization { state in
                permissionTick += 1
                if state == .authorized, voice.canUseVoice { start() }
            }
        } else if voiceState == .ready {
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
