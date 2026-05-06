import SwiftUI
import AVFoundation

struct SettingsView: View {
    @ObservedObject var engine: AudioBufferEngine
    @Environment(\.dismiss) private var dismiss

    // Local slider value — committed after the user finishes dragging and confirms
    @State private var localDuration: Double = 300

    // Input device change confirmation
    @State private var pendingInput: AVAudioSessionPortDescription? = nil
    @State private var showInputAlert = false

    // Buffer duration change confirmation
    @State private var showDurationAlert = false

    var body: some View {
        NavigationStack {
            List {
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
        // Buffer duration truncation alert
        .alert("Shorten Buffer and Drop Old Audio?", isPresented: $showDurationAlert) {
            Button("Truncate", role: .destructive) {
                engine.applyBufferDuration(localDuration)
            }
            Button("Cancel", role: .cancel) {
                localDuration = engine.maxSeconds  // revert slider
            }
        } message: {
            Text("The new buffer length is shorter than the audio you already have, so the oldest audio will be removed.")
        }
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

                Slider(
                    value: $localDuration,
                    in: AudioBufferEngine.bufferDurationRange,
                    step: 30,
                    onEditingChanged: { isEditing in
                        guard !isEditing else { return }
                        if Int(localDuration) != Int(engine.maxSeconds) {
                            if engine.bufferDurationChangeNeedsConfirmation(localDuration) {
                                showDurationAlert = true
                            } else {
                                engine.applyBufferDuration(localDuration)
                            }
                        }
                    }
                )

                HStack {
                    Text(formatDuration(AudioBufferEngine.minimumBufferSeconds))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    Spacer()
                    Text(formatDuration(AudioBufferEngine.maximumBufferSeconds))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.vertical, 4)

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
