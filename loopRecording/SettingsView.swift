import SwiftUI
import AVFoundation

struct SettingsView: View {
    @ObservedObject var engine: AudioBufferEngine
    @Environment(\.dismiss) private var dismiss

    // Local slider value — only committed when the user taps Apply
    @State private var localDuration: Double = 300

    // Input device change confirmation
    @State private var pendingInput: AVAudioSessionPortDescription? = nil
    @State private var showInputAlert = false

    // Buffer duration change confirmation
    @State private var showDurationAlert = false

    var body: some View {
        NavigationStack {
            List {
                triggeredRecordingSection
                bufferDurationSection
                inputDeviceSection
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                        .fontWeight(.semibold)
                }
            }
        }
        .onAppear {
            localDuration = engine.maxSeconds
            engine.refreshInputs()
        }
        // Input device change alert
        .alert("Change Input Device?", isPresented: $showInputAlert) {
            Button("Apply", role: .destructive) {
                if let port = pendingInput {
                    engine.restartEngine(input: port)
                }
            }
            Button("Cancel", role: .cancel) { pendingInput = nil }
        } message: {
            Text("Changing the input device will restart the audio engine and clear the current buffer.")
        }
        // Buffer duration change alert
        .alert("Change Buffer Duration?", isPresented: $showDurationAlert) {
            Button("Apply", role: .destructive) {
                engine.applyBufferDuration(localDuration)
            }
            Button("Cancel", role: .cancel) {
                localDuration = engine.maxSeconds  // revert slider
            }
        } message: {
            Text("Changing the buffer duration will restart the audio engine and clear the current buffer.")
        }
    }

    // MARK: - Triggered Recording

    private var levelFraction: Double {
        max(0, min(1, (engine.inputLevelDB - (-60)) / 60))
    }

    private var levelColor: Color {
        let db = engine.inputLevelDB
        let thr = engine.triggerThresholdDB
        if db < thr - 6  { return .green }
        if db < thr + 3  { return Color(red: 1, green: 0.75, blue: 0) }
        return Color(red: 1, green: 0.35, blue: 0.35)
    }

    private var inputLevelRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Input Level")
                Spacer()
                Text(engine.inputLevelDB <= -159
                     ? "– dB"
                     : String(format: "%.0f dB", engine.inputLevelDB))
                    .monospacedDigit()
                    .foregroundStyle(engine.inputLevelDB <= -159 ? .secondary : levelColor)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.white.opacity(0.1))
                        .frame(height: 6)
                    Capsule()
                        .fill(levelColor)
                        .frame(width: geo.size.width * levelFraction, height: 6)
                }
            }
            .frame(height: 6)
        }
        .padding(.vertical, 4)
    }

    private var triggeredRecordingSection: some View {
        Section {
            Toggle(isOn: Binding(
                get: { engine.triggeredRecording },
                set: { engine.setTriggerEnabled($0) }
            )) {
                Label("Triggered Recording", systemImage: "waveform.badge.mic")
            }

            inputLevelRow

            if engine.triggeredRecording {
                settingRow(
                    label: "Silence Threshold",
                    value: String(format: "%.0f dB", engine.triggerThresholdDB)
                ) {
                    Slider(value: Binding(
                        get: { engine.triggerThresholdDB },
                        set: { engine.setTriggerThresholdDB($0) }
                    ), in: -60 ... -10, step: 1)
                }

                settingRow(
                    label: "Stop After",
                    value: String(format: "%.1f s", engine.triggerSilenceDuration)
                ) {
                    Slider(value: Binding(
                        get: { engine.triggerSilenceDuration },
                        set: { engine.setTriggerSilenceDuration($0) }
                    ), in: 1.0 ... 60.0, step: 0.5)
                }

                settingRow(
                    label: "Pre-roll",
                    value: String(format: "%.1f s", engine.triggerPreRollSeconds)
                ) {
                    Slider(value: Binding(
                        get: { engine.triggerPreRollSeconds },
                        set: { engine.setTriggerPreRoll($0) }
                    ), in: 0.0 ... 3.0, step: 0.5)
                }
            }
        } header: {
            Text("Triggered Recording")
        } footer: {
            Text("Pauses recording after sustained silence and resumes on the next sound. Pre-roll rewinds the buffer slightly so the first note is never clipped.")
        }
    }

    private func settingRow<S: View>(label: String, value: String, @ViewBuilder slider: () -> S) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(label)
                Spacer()
                Text(value)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            slider()
        }
        .padding(.vertical, 4)
    }

    // MARK: - Buffer Duration

    private var bufferDurationSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Buffer Duration")
                    Spacer()
                    Text(formatDuration(localDuration))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }

                Slider(value: $localDuration, in: 60...3600, step: 30)

                HStack {
                    Text(formatDuration(60))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    Spacer()
                    Text(formatDuration(3600))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.vertical, 4)

            if Int(localDuration) != Int(engine.maxSeconds) {
                Button("Apply") { showDurationAlert = true }
                    .foregroundStyle(.red)
            }
        } header: {
            Text("Buffer")
        } footer: {
            Text("How much audio is kept in memory. Longer buffers use more RAM.")
        }
    }

    // MARK: - Input Device

    private var inputDeviceSection: some View {
        Section("Input Device") {
            if engine.availableInputs.isEmpty {
                Text("No inputs available")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(engine.availableInputs, id: \.uid) { port in
                    Button {
                        pendingInput = port
                        showInputAlert = true
                    } label: {
                        HStack(spacing: 14) {
                            Image(systemName: icon(for: port))
                                .frame(width: 22)
                                .foregroundStyle(.primary)
                            Text(port.portName)
                                .foregroundStyle(.primary)
                            Spacer()
                            if engine.currentInput?.uid == port.uid {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(.tint)
                                    .fontWeight(.semibold)
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: - Helpers

    private func formatDuration(_ seconds: Double) -> String {
        let mins = Int(seconds) / 60
        let secs = Int(seconds) % 60
        return secs == 0 ? "\(mins) min" : "\(mins)m \(secs)s"
    }

    private func icon(for port: AVAudioSessionPortDescription) -> String {
        switch port.portType {
        case .builtInMic:                        return "mic"
        case .headsetMic:                        return "headphones"
        case .bluetoothHFP, .bluetoothA2DP,
             .bluetoothLE:                       return "airpods"
        case .usbAudio:                          return "cable.connector"
        case .carAudio:                          return "car"
        default:                                 return "mic.circle"
        }
    }
}
