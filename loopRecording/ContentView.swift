import SwiftUI
import UIKit

// Wraps UIActivityViewController for the share sheet.
// TODO: Change this to ShareLink
private struct ShareSheet: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }
    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}

struct ContentView: View {
    @StateObject private var engine = AudioBufferEngine()
    // Observed so the UI re-renders (re-resolving localized strings) on language change.
    @EnvironmentObject private var language: LanguageManager

    // Settings panel
    @State private var showSettings = false
    // Exporting panel
    @State private var isExporting = false
    @State private var exportURL: URL? = nil
    @State private var exportError: String? = nil

    // MARK: - UI State

    private var hasRecording: Bool { engine.filledSeconds > 0 }

    // Button availability
    private var playEnabled: Bool    { hasRecording && !engine.isRecording && !engine.isAtLiveEdge }
    private var rewindEnabled: Bool  { hasRecording && engine.playheadSeconds > 0 }
    private var forwardEnabled: Bool { hasRecording && engine.playheadSeconds < engine.filledSeconds }
    private var exportEnabled: Bool  { hasRecording && !isExporting }

    // Status badge
    private var statusKey: LocalizedStringKey {
        switch engine.state {
        case .ready: return "READY"
        case .recording: return "RECORDING"
        case .playing: return "PLAYING"
        case .paused: return "PAUSED"
        }
    }

    private var statusColor: Color {
        switch engine.state {
        case .recording:
            return Color(red: 1, green: 0.35, blue: 0.35)
        case .playing:
            return .green
        case .ready, .paused:
            return .gray
        }
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if engine.permissionDenied {
                permissionDeniedView
            } else {
                mainView
            }
        }
        .preferredColorScheme(.dark)
        .sheet(isPresented: $showSettings) {
            SettingsView(engine: engine)
                .environmentObject(language)
        }
        .sheet(isPresented: Binding(
            get: { exportURL != nil },
            set: { if !$0 { exportURL = nil } }
        )) {
            if let url = exportURL { ShareSheet(url: url) }
        }
        .alert("Export Failed", isPresented: Binding(
            get: { exportError != nil },
            set: { if !$0 { exportError = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(exportError ?? "")
        }
        .alert("Audio Error", isPresented: Binding(
            get: { engine.engineError != nil },
            set: { if !$0 { engine.engineError = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(engine.engineError ?? "")
        }
    }

    // MARK: - Main Layout

    private var mainView: some View {
        VStack(spacing: 0) {
            // Top bar
            HStack {
                // Share / export
                Button {
                    isExporting = true
                    Task {
                        do {
                            exportURL = try await engine.exportWAV()
                        } catch {
                            exportError = error.localizedDescription
                        }
                        isExporting = false
                    }
                } label: {
                    Group {
                        if isExporting {
                            ProgressView().tint(Color(white: 0.5))
                        } else {
                            Image(systemName: "square.and.arrow.up")
                                .font(.system(size: 20))
                                .foregroundStyle(exportEnabled ? Color(white: 0.5) : Color(white: 0.25))
                        }
                    }
                    .frame(width: 24, height: 24)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                }
                .disabled(!exportEnabled)
                .accessibilityLabel(isExporting ? "Exporting" : "Export recording")

                Spacer()

                // Settings
                Button { showSettings = true } label: {
                    Image(systemName: "gearshape")
                        .font(.system(size: 20))
                        .foregroundStyle(Color(white: 0.5))
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                }
                .accessibilityLabel("Settings")
            }

            Spacer()
            timeDisplay
                .padding(.bottom, 16)
            waveformSection
            Spacer()
            transportControls
                .padding(.bottom, 40)
        }
    }

    // MARK: - Waveform

    private var waveformSection: some View {
        WaveformView(
            amplitudes: engine.waveformData,
            filledFraction: engine.filledSeconds / engine.maxSeconds,
            playheadFraction: engine.playheadSeconds / engine.maxSeconds,
            totalSeconds: engine.maxSeconds,
            isAtLiveEdge: engine.isAtLiveEdge,
            onScrub: { f in engine.waveformScrubbing(fraction: f) },
            onScrubEnd: { f in engine.waveformScrubEnded(fraction: f) },
            onSeekTap: { f in engine.waveformTapped(fraction: f) }
        )
        // detail + 1pt divider + 36pt overview
        .frame(height: 180)
        .background(Color(white: 0.05))
    }

    // MARK: - Time Display

    private var timeDisplay: some View {
        VStack(spacing: 4) {
            // Big display: offset when scrubbed back, empty when at live edge
            Group {
                if !engine.isAtLiveEdge && hasRecording {
                    Text(formatOffset(engine.filledSeconds - engine.playheadSeconds))
                        .font(.system(size: 52, weight: .thin, design: .monospaced))
                        .foregroundColor(.white)
                } else {
                    Color.clear
                }
            }
            .frame(height: 64)

            // Status badge — sole indicator when at the live edge
            HStack(spacing: 6) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 7, height: 7)
                    .accessibilityHidden(true)
                Text(statusKey)
                    .font(.caption.bold())
                    .foregroundColor(statusColor)
                    .kerning(1.5)
            }
            .accessibilityLabel(Text("Status: ") + Text(statusKey))

        }
    }

    // MARK: - Transport Controls

    private var transportControls: some View {
        HStack(spacing: 44) {
            // Rewind 15s
            Button {
                engine.skip(by: -15)
            } label: {
                Image(systemName: "gobackward.15")
                    .font(.system(size: 28))
                    .foregroundColor(rewindEnabled ? .white : Color(white: 0.35))
            }
            .disabled(!rewindEnabled)
            .accessibilityLabel("Skip back 15 seconds")

            // Play / Pause
            Button {
                engine.togglePlayPause()
            } label: {
                ZStack {
                    Circle()
                        .fill(Color(white: playEnabled ? 0.15 : 0.08))
                        .frame(width: 72, height: 72)
                    Image(systemName: engine.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 28))
                        .foregroundColor(playEnabled ? .white : Color(white: 0.35))
                        .offset(x: engine.isPlaying ? 0 : 2)
                }
            }
            .disabled(!playEnabled)
            .accessibilityLabel(engine.isPlaying ? "Pause" : "Play")

            // Forward 15s
            Button {
                engine.skip(by: 15)
            } label: {
                Image(systemName: "goforward.15")
                    .font(.system(size: 28))
                    .foregroundColor(forwardEnabled ? .white : Color(white: 0.35))
            }
            .disabled(!forwardEnabled)
            .accessibilityLabel("Skip forward 15 seconds")

            // Record toggle
            Button {
                engine.toggleRecording()
            } label: {
                VStack(spacing: 3) {
                    Image(systemName: engine.isRecording ? "record.circle.fill" : "record.circle")
                        .font(.system(size: 26))
                        .foregroundColor(engine.isRecording
                                         ? Color(red: 1, green: 0.35, blue: 0.35)
                                         : .white)
                }
            }
            .accessibilityLabel(engine.isRecording ? "Stop recording" : "Start recording")
        }
        .padding(.horizontal, 24)
    }

    // MARK: - Permission Denied

    private var permissionDeniedView: some View {
        VStack(spacing: 16) {
            Image(systemName: "mic.slash")
                .font(.system(size: 48))
                .foregroundColor(.gray)
            Text("Microphone Access Required")
                .font(.headline)
                .foregroundColor(.white)
            Text("Enable microphone access in Settings to use loopRecording.")
                .font(.subheadline)
                .foregroundColor(.gray)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
        }
    }

    // MARK: - Helpers

    /// Formats a "how far behind live" offset as "-M:SS"
    private func formatOffset(_ seconds: Double) -> String {
        let s = Int(max(0, seconds))
        return String(format: "-%d:%02d", s / 60, s % 60)
    }
}

#Preview {
    ContentView()
        .environmentObject(LanguageManager.shared)
}
