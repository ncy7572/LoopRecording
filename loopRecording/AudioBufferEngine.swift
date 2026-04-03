import AVFoundation
import UIKit
import os.log

// MARK: - Ring Buffer (non-actor-isolated, accessed from both audio thread and main thread)

final class RingBuffer: @unchecked Sendable {
    let capacity: Int
    let waveformPoints: Int
    let samplesPerBucket: Int

    // Set false to pause ingestion without stopping the engine
    var isActive: Bool = true

    // Raw audio samples — written by audio thread, read by main thread (snapshot)
    var samples: [Float]
    var writeHead: Int = 0
    var totalWritten: Int = 0

    // Incremental waveform bucket state — audio thread only
    var buckets: [Float]
    var bucketWriteIdx: Int = 0
    var bucketSumSq: Float = 0
    var bucketSampleCount: Int = 0

    init(capacity: Int, waveformPoints: Int) {
        self.capacity = capacity
        self.waveformPoints = waveformPoints
        self.samplesPerBucket = max(1, capacity / waveformPoints)
        self.samples = Array(repeating: 0, count: capacity)
        self.buckets = Array(repeating: 0, count: waveformPoints)
    }

    // Called on the audio real-time thread
    func write(buffer: AVAudioPCMBuffer) {
        guard isActive, let channelData = buffer.floatChannelData else { return }
        let frameCount = Int(buffer.frameLength)
        let numChannels = Int(buffer.format.channelCount)

        for i in 0..<frameCount {
            var mono: Float = 0
            for ch in 0..<numChannels { mono += channelData[ch][i] }
            mono /= Float(numChannels)

            samples[writeHead] = mono
            writeHead = (writeHead + 1) % capacity
            totalWritten += 1

            bucketSumSq += mono * mono
            bucketSampleCount += 1
            if bucketSampleCount >= samplesPerBucket {
                buckets[bucketWriteIdx] = sqrt(bucketSumSq / Float(bucketSampleCount))
                bucketWriteIdx = (bucketWriteIdx + 1) % waveformPoints
                bucketSumSq = 0
                bucketSampleCount = 0
            }
        }
    }

    // Snapshot waveform for UI — ordered oldest→newest
    func waveformSnapshot() -> [Float] {
        let filledBuckets = min(totalWritten / samplesPerBucket, waveformPoints)
        let oldest = totalWritten >= capacity ? bucketWriteIdx : 0
        var result = [Float](repeating: 0, count: waveformPoints)
        for i in 0..<filledBuckets {
            result[i] = buckets[(oldest + i) % waveformPoints]
        }
        return result
    }

    // Copy a slice from the circular buffer into a flat array for playback.
    // startSec/endSec: seconds from the oldest sample. Pass nil endSec for "to end".
    func copySlice(startSec: Double, sampleRate: Double, endSec: Double? = nil) -> [Float]? {
        let filledSamples = min(totalWritten, capacity)
        let filledSec = Double(filledSamples) / sampleRate
        guard filledSec > 0 else { return nil }

        let clampedStart = max(0, min(filledSec, startSec))
        let startOffset  = Int(clampedStart / filledSec * Double(filledSamples))

        let endOffset: Int
        if let e = endSec {
            let clampedEnd = max(clampedStart, min(filledSec, e))
            endOffset = Int(clampedEnd / filledSec * Double(filledSamples))
        } else {
            endOffset = filledSamples
        }

        let count = endOffset - startOffset
        guard count > 100 else { return nil }

        let oldest   = totalWritten >= capacity ? writeHead : 0
        let startIdx = (oldest + startOffset) % capacity
        var flat = [Float](repeating: 0, count: count)
        for i in 0..<count {
            flat[i] = samples[(startIdx + i) % capacity]
        }
        return flat
    }

    // Bulk-inject flat mono samples (e.g. pre-roll) with full waveform bucket tracking
    func writeRaw(_ flat: [Float]) {
        for sample in flat {
            samples[writeHead] = sample
            writeHead = (writeHead + 1) % capacity
            totalWritten += 1
            bucketSumSq += sample * sample
            bucketSampleCount += 1
            if bucketSampleCount >= samplesPerBucket {
                buckets[bucketWriteIdx] = sqrt(bucketSumSq / Float(bucketSampleCount))
                bucketWriteIdx = (bucketWriteIdx + 1) % waveformPoints
                bucketSumSq = 0
                bucketSampleCount = 0
            }
        }
    }

    var filledSampleCount: Int {
        min(totalWritten, capacity)
    }
}

// MARK: - Pre-roll Buffer (audio-thread write, main-thread never touches internals)

final class PreRollBuffer: @unchecked Sendable {
    private var buf: [Float]
    private let capacity: Int
    private var head: Int = 0
    private var total: Int = 0

    init(capacity: Int) {
        self.capacity = max(1, capacity)
        self.buf = [Float](repeating: 0, count: max(1, capacity))
    }

    // Mix down to mono and append — audio thread only
    func write(buffer: AVAudioPCMBuffer) {
        guard let ch = buffer.floatChannelData else { return }
        let frames = Int(buffer.frameLength)
        let numCh  = Int(buffer.format.channelCount)
        for i in 0..<frames {
            var mono: Float = 0
            for c in 0..<numCh { mono += ch[c][i] }
            buf[head] = mono / Float(numCh)
            head = (head + 1) % capacity
            total += 1
        }
    }

    // Return the last `count` samples in chronological order — audio thread only
    func extractLast(count: Int) -> [Float] {
        let n = min(count, min(total, capacity))
        guard n > 0 else { return [] }
        var result = [Float](repeating: 0, count: n)
        let start = (head - n + capacity) % capacity
        for i in 0..<n { result[i] = buf[(start + i) % capacity] }
        return result
    }
}

// MARK: - Trigger State (@unchecked Sendable — main thread sets config, audio thread tracks counters)

final class TriggerState: @unchecked Sendable {
    // Config — protected by a lock; written from main thread, read from audio thread.
    // os_unfair_lock (via OSAllocatedUnfairLock) is safe for brief critical sections on
    // the audio thread because it never sleeps and has no priority-inversion risk when
    // contention (settings changes) is rare.
    private let configLock = OSAllocatedUnfairLock()
    private var _isEnabled: Bool   = false
    private var _threshold: Float  = 0.01
    private var _maxSilenceSamples: Int = 0
    private var _preRollSamples: Int    = 0

    var isEnabled: Bool {
        get { configLock.withLockUnchecked { _isEnabled } }
        set { configLock.withLockUnchecked { _isEnabled = newValue } }
    }

    // Atomically updates all four config fields in one lock acquisition.
    func updateConfig(isEnabled: Bool, threshold: Float,
                      maxSilenceSamples: Int, preRollSamples: Int) {
        configLock.withLockUnchecked {
            _isEnabled        = isEnabled
            _threshold        = threshold
            _maxSilenceSamples = maxSilenceSamples
            _preRollSamples   = preRollSamples
        }
    }

    // Returns a consistent snapshot of all config fields — call once per audio callback.
    struct Config {
        let isEnabled: Bool
        let threshold: Float
        let maxSilenceSamples: Int
        let preRollSamples: Int
    }
    func snapshotConfig() -> Config {
        configLock.withLockUnchecked {
            Config(isEnabled: _isEnabled, threshold: _threshold,
                   maxSilenceSamples: _maxSilenceSamples, preRollSamples: _preRollSamples)
        }
    }

    // Counters — audio thread only; no locking needed.
    var silenceCount: Int = 0
    var isWaiting: Bool   = false
}

// MARK: - Waveform Selection

struct WaveformSelection {
    var startFraction: Double
    var endFraction: Double

    /// Always the smaller of the two
    var normalizedStart: Double { min(startFraction, endFraction) }
    /// Always the larger of the two
    var normalizedEnd: Double   { max(startFraction, endFraction) }

    var durationFraction: Double { abs(endFraction - startFraction) }
}

// MARK: - Export Error

enum ExportError: LocalizedError {
    case notReady, empty, bufferError

    var errorDescription: String? {
        switch self {
        case .notReady:      return "Engine not ready — start recording first."
        case .empty:         return "Nothing recorded yet."
        case .bufferError:   return "Failed to create audio buffer."
        }
    }
}

// MARK: - Audio Buffer Engine (implicitly @MainActor via project settings)

import Combine

final class AudioBufferEngine: ObservableObject {

    static let waveformPoints: Int = 2000
    private static let durationKey         = "loopRecording.bufferDuration"
    private static let trigEnabledKey      = "loopRecording.trigEnabled"
    private static let trigThresholdKey    = "loopRecording.trigThresholdDB"
    private static let trigSilenceKey      = "loopRecording.trigSilenceDuration"
    private static let trigPreRollKey      = "loopRecording.trigPreRoll"

    // MARK: Published state (main thread)
    @Published var waveformData: [Float] = Array(repeating: 0, count: waveformPoints)
    @Published var filledSeconds: Double = 0
    @Published var playheadSeconds: Double = 0
    @Published var isPlaying: Bool = false
    @Published var isLive: Bool = false
    @Published var isRecording: Bool = false { didSet { updateIdleTimer() } }
    @Published var permissionDenied: Bool = false
    @Published var availableInputs: [AVAudioSessionPortDescription] = []
    @Published var currentInput: AVAudioSessionPortDescription? = nil
    @Published var maxSeconds: Double
    // Triggered recording
    @Published var triggeredRecording: Bool
    @Published var triggerThresholdDB: Double
    @Published var triggerSilenceDuration: Double
    @Published var triggerPreRollSeconds: Double
    @Published var isWaitingForSound: Bool = false { didSet { updateIdleTimer() } }
    @Published var inputLevelDB: Double = -160
    @Published var waveformSelection: WaveformSelection? = nil
    @Published var engineError: String? = nil

    // MARK: Private
    private var playbackClipEndSeconds: Double? = nil
    private let avEngine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()
    private var sampleRate: Double = 44100
    private var monoFormat: AVAudioFormat?
    private var ring: RingBuffer?
    private var isEngineStarted = false
    private var isPlayerAttached = false
    private var wasInterrupted = false
    private var notificationObservers: [NSObjectProtocol] = []

    init() {
        let ud = UserDefaults.standard
        let saved = ud.double(forKey: Self.durationKey)
        maxSeconds = saved >= 60 ? saved : 300

        ud.register(defaults: [
            Self.trigEnabledKey:   false,
            Self.trigThresholdKey: -40.0,
            Self.trigSilenceKey:   10.0,
            Self.trigPreRollKey:   1.0
        ])
        triggeredRecording       = ud.bool(forKey: Self.trigEnabledKey)
        triggerThresholdDB       = ud.double(forKey: Self.trigThresholdKey)
        triggerSilenceDuration   = ud.double(forKey: Self.trigSilenceKey)
        triggerPreRollSeconds    = ud.double(forKey: Self.trigPreRollKey)
    }

    private var playbackStartWall: Date?
    private var playbackStartSec: Double = 0
    private var displayTimer: Timer?
    private var playbackGeneration = 0
    private var wasPlayingBeforeScrub = false
    private var preRollBuffer: PreRollBuffer?
    private var triggerState: TriggerState?

    // State snapshot taken when playback interrupts an active recording session
    private enum RecordingSnapshot { case recording, waitingForTrigger }
    private var prePlaybackSnapshot: RecordingSnapshot? = nil

    // True while playing a selection clip — completion stays put instead of restoring state
    private var isPlayingClip: Bool = false

    // MARK: - Public API

    func requestPermissionAndStart() {
        AVAudioApplication.requestRecordPermission { [weak self] granted in
            DispatchQueue.main.async {
                if granted {
                    do { try self?.start() } catch {
                        self?.engineError = "Failed to start recording: \(error.localizedDescription)"
                    }
                } else {
                    self?.permissionDenied = true
                }
            }
        }
    }

    func togglePlayPause() {
        isPlaying ? pause() : play()
    }

    func skip(by delta: Double) {
        let wasPlaying = isPlaying
        captureRecordingStateIfNeeded()
        // hadRecording is true when recording/waiting was interrupted to enter playback
        let hadRecording = prePlaybackSnapshot != nil
        let newSec = max(0, min(filledSeconds, playheadSeconds + delta))
        playheadSeconds = newSec
        isLive = false
        if wasPlaying || hadRecording {
            // Was playing → continue; was recording → play from here, restore on finish
            startPlayback(fromSeconds: newSec)
        }
        // Was paused → stay paused at the new position (prePlaybackSnapshot is nil, nothing to restore)
    }

    func seekTo(fraction: Double) {
        seekTo(seconds: fraction * maxSeconds)
    }

    // Called when the user taps (not drags) the waveform — jumps to that position and plays.
    // Recording is suspended and automatically restored when playback ends.
    func waveformTapped(fraction: Double) {
        let clamped = max(0, min(filledSeconds, fraction * maxSeconds))
        captureRecordingStateIfNeeded()
        playheadSeconds = clamped
        isLive = false
        startPlayback(fromSeconds: clamped)
    }

    // Called by the waveform during a continuous drag — stops recording, updates position only.
    func waveformScrubbing(fraction: Double) {
        captureRecordingStateIfNeeded()
        if isPlaying {
            wasPlayingBeforeScrub = true
            stopPlayback()
        }
        let clamped = max(0, min(filledSeconds, fraction * maxSeconds))
        playheadSeconds = clamped
        isLive = false
    }

    // Called when the user lifts their finger — seeks and optionally resumes playback.
    func waveformScrubEnded(fraction: Double) {
        captureRecordingStateIfNeeded()
        // Play only if the user was already in playback mode before the scrub.
        // Recording being paused by the scrub is not enough to auto-start playback —
        // the user must tap Play explicitly. Recording is restored immediately below.
        let shouldPlay = isPlaying || wasPlayingBeforeScrub
        wasPlayingBeforeScrub = false

        let clamped = max(0, min(filledSeconds, fraction * maxSeconds))
        playheadSeconds = clamped
        isLive = false
        if shouldPlay {
            startPlayback(fromSeconds: clamped)
        } else if prePlaybackSnapshot != nil {
            // Recording was interrupted for this scrub — restore it at the live edge.
            restoreRecordingState()
        }
        // Was already paused → stay paused at the scrubbed position.
    }

    // Called when the user long-presses to open the selection popup.
    // Recording stops permanently (no restore on playback end).
    func enterSelectionMode() {
        stopPlayback()
        prePlaybackSnapshot = nil   // discard any pending restore
        triggerState?.isEnabled = false  // stop the audio thread from re-triggering
        triggerState?.isWaiting = false
        triggerState?.silenceCount = 0
        ring?.isActive = false
        isRecording = false
        isWaitingForSound = false
    }

    // MARK: - Selection API

    func setSelection(startFraction: Double, endFraction: Double) {
        waveformSelection = WaveformSelection(startFraction: startFraction,
                                              endFraction: endFraction)
    }

    func clearSelection() {
        waveformSelection = nil
    }

    func playSelection() {
        guard let sel = waveformSelection else { return }
        let startSec = sel.normalizedStart * maxSeconds
        let endSec   = sel.normalizedEnd   * maxSeconds
        captureRecordingStateIfNeeded()
        startPlayback(fromSeconds: startSec, toSeconds: endSec)
    }

    // Exports only the selected region as a WAV file.
    func exportSelectionWAV() async throws -> URL {
        guard isEngineStarted, let r = ring, let fmt = monoFormat else { throw ExportError.notReady }
        guard let sel = waveformSelection else { throw ExportError.empty }
        let startSec = sel.normalizedStart * maxSeconds
        let endSec   = sel.normalizedEnd   * maxSeconds
        // Pause ingestion while copying to reduce the concurrent-write window.
        let wasActive = r.isActive
        r.isActive = false
        let flat = r.copySlice(startSec: startSec, sampleRate: sampleRate, endSec: endSec)
        r.isActive = wasActive
        guard let flat else { throw ExportError.empty }
        return try await Task.detached(priority: .userInitiated) {
            let stamp = Int(Date().timeIntervalSince1970)
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("loopRecording_clip_\(stamp).wav")
            let file = try AVAudioFile(forWriting: url, settings: fmt.settings)
            guard let buf = AVAudioPCMBuffer(pcmFormat: fmt,
                                              frameCapacity: AVAudioFrameCount(flat.count)),
                  let dst = buf.floatChannelData?[0] else { throw ExportError.bufferError }
            buf.frameLength = AVAudioFrameCount(flat.count)
            flat.withUnsafeBufferPointer { dst.initialize(from: $0.baseAddress!, count: flat.count) }
            try file.write(from: buf)
            return url
        }.value
    }

    // Exports the entire filled buffer as a 32-bit float WAV file.
    // File I/O runs on a background thread; safe to await from the UI.
    func exportWAV() async throws -> URL {
        guard isEngineStarted, let r = ring, let fmt = monoFormat else { throw ExportError.notReady }
        // Pause ingestion while copying to reduce the concurrent-write window.
        let wasActive = r.isActive
        r.isActive = false
        let flat = r.copySlice(startSec: 0, sampleRate: sampleRate)
        r.isActive = wasActive
        guard let flat else { throw ExportError.empty }

        return try await Task.detached(priority: .userInitiated) {
            let stamp = Int(Date().timeIntervalSince1970)
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("loopRecording_\(stamp).wav")

            let file = try AVAudioFile(forWriting: url, settings: fmt.settings)

            guard let buf = AVAudioPCMBuffer(pcmFormat: fmt,
                                              frameCapacity: AVAudioFrameCount(flat.count)),
                  let dst = buf.floatChannelData?[0] else { throw ExportError.bufferError }
            buf.frameLength = AVAudioFrameCount(flat.count)
            flat.withUnsafeBufferPointer { dst.initialize(from: $0.baseAddress!, count: flat.count) }

            try file.write(from: buf)
            return url
        }.value
    }

    // Stops the engine and resets all state. Safe to call before restart.
    private func tearDown() {
        displayTimer?.invalidate()
        displayTimer = nil
        removeNotifications()
        avEngine.inputNode.removeTap(onBus: 0)
        avEngine.disconnectNodeOutput(playerNode)
        avEngine.stop()
        if isPlayerAttached {
            avEngine.detach(playerNode)
            isPlayerAttached = false
        }
        isEngineStarted = false
        ring = nil
        monoFormat = nil
    }

    // MARK: - Audio Session Notifications

    private func setupNotifications() {
        let nc = NotificationCenter.default
        let session = AVAudioSession.sharedInstance()

        notificationObservers.append(nc.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: session,
            queue: .main
        ) { [weak self] note in self?.handleInterruption(note) })

        notificationObservers.append(nc.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: session,
            queue: .main
        ) { [weak self] note in self?.handleRouteChange(note) })

        notificationObservers.append(nc.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: avEngine,
            queue: .main
        ) { [weak self] _ in self?.handleEngineConfigurationChange() })
    }

    private func removeNotifications() {
        notificationObservers.forEach { NotificationCenter.default.removeObserver($0) }
        notificationObservers.removeAll()
    }

    private func handleInterruption(_ notification: Notification) {
        guard let info = notification.userInfo,
              let typeValue = info[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: typeValue) else { return }
        switch type {
        case .began:
            // Phone call, Siri, alarm, etc. — pause recording
            if isRecording || isWaitingForSound {
                wasInterrupted = true
                ring?.isActive = false
                isRecording = false
                isWaitingForSound = false
            }
        case .ended:
            guard wasInterrupted else { return }
            wasInterrupted = false
            let options = (info[AVAudioSessionInterruptionOptionKey] as? UInt)
                .flatMap { AVAudioSession.InterruptionOptions(rawValue: $0) } ?? []
            if options.contains(.shouldResume) {
                try? AVAudioSession.sharedInstance().setActive(true)
                ring?.isActive = true
                isRecording = true
                isLive = true
            }
        @unknown default:
            break
        }
    }

    private func handleRouteChange(_ notification: Notification) {
        guard let info = notification.userInfo,
              let reasonValue = info[AVAudioSessionRouteChangeReasonKey] as? UInt,
              let reason = AVAudioSession.RouteChangeReason(rawValue: reasonValue) else { return }
        switch reason {
        case .oldDeviceUnavailable:
            // Headphones/mic unplugged — stop playback to avoid speaker bleed
            if isPlaying { pause() }
            refreshInputs()
        default:
            refreshInputs()
        }
    }

    private func handleEngineConfigurationChange() {
        // Hardware config changed (e.g. sample rate, channel count) — restart engine
        guard isEngineStarted else { return }
        restartEngine()
    }

    func setTriggerEnabled(_ enabled: Bool) {
        triggeredRecording = enabled
        UserDefaults.standard.set(enabled, forKey: Self.trigEnabledKey)
        if !enabled && isWaitingForSound {
            // Cancel any active wait and resume recording
            triggerState?.isWaiting = false
            triggerState?.silenceCount = 0
            ring?.isActive = true
            isWaitingForSound = false
            isRecording = true
        }
        updateTriggerState()
    }

    func setTriggerThresholdDB(_ db: Double) {
        triggerThresholdDB = db
        UserDefaults.standard.set(db, forKey: Self.trigThresholdKey)
        updateTriggerState()
    }

    func setTriggerSilenceDuration(_ seconds: Double) {
        triggerSilenceDuration = seconds
        UserDefaults.standard.set(seconds, forKey: Self.trigSilenceKey)
        updateTriggerState()
    }

    func setTriggerPreRoll(_ seconds: Double) {
        triggerPreRollSeconds = seconds
        UserDefaults.standard.set(seconds, forKey: Self.trigPreRollKey)
        updateTriggerState()
    }

    func applyBufferDuration(_ seconds: Double) {
        maxSeconds = seconds
        UserDefaults.standard.set(seconds, forKey: Self.durationKey)
        guard isEngineStarted else { return }
        restartEngine()
    }

    // Applies a new input device and restarts the engine. Clears the buffer.
    func restartEngine(input: AVAudioSessionPortDescription? = nil) {
        tearDown()

        isPlaying = false
        isRecording = false
        isLive = false
        isWaitingForSound = false
        playheadSeconds = 0
        filledSeconds = 0
        waveformData = Array(repeating: 0, count: Self.waveformPoints)
        preRollBuffer = nil
        triggerState = nil
        prePlaybackSnapshot = nil
        if let input {
            try? AVAudioSession.sharedInstance().setPreferredInput(input)
            currentInput = input
        }

        do { try start() } catch {
            engineError = "Failed to restart audio engine: \(error.localizedDescription)"
        }
    }

    func refreshInputs() {
        let session = AVAudioSession.sharedInstance()
        availableInputs = session.availableInputs ?? []
        currentInput = session.currentRoute.inputs.first
    }

    func selectInput(_ port: AVAudioSessionPortDescription) {
        do {
            try AVAudioSession.sharedInstance().setPreferredInput(port)
            currentInput = port
        } catch {
            print("selectInput error: \(error)")
        }
    }

    func toggleRecording() {
        guard isEngineStarted else {
            // First press — request permission and start the engine.
            requestPermissionAndStart()
            return
        }
        if isRecording || isWaitingForSound {
            // User explicitly stopped — discard any playback-restore snapshot
            prePlaybackSnapshot = nil
            triggerState?.isWaiting = false
            triggerState?.silenceCount = 0
            ring?.isActive = false
            isRecording = false
            isWaitingForSound = false
            // isLive stays true — playhead is still at the end of the buffer
        } else {
            // Resume: jump to the live edge and start ingesting again.
            // Close any open selection — recording and selection mode are mutually exclusive.
            waveformSelection = nil
            stopPlayback()
            updateTriggerState()   // restore trigger enabled/settings after selection mode
            triggerState?.isWaiting = false
            triggerState?.silenceCount = 0
            ring?.isActive = true
            isRecording = true
            isLive = true
            isWaitingForSound = false
            playheadSeconds = filledSeconds
        }
    }

    // MARK: - Helpers

    private func updateIdleTimer() {
        UIApplication.shared.isIdleTimerDisabled = isRecording || isWaitingForSound
    }

    // Compute mono RMS from a PCM buffer — called on audio thread, must be nonisolated
    private static func monoRMS(_ buf: AVAudioPCMBuffer) -> Float {
        guard let ch = buf.floatChannelData else { return 0 }
        let frames  = Int(buf.frameLength)
        let numCh   = Int(buf.format.channelCount)
        guard frames > 0 else { return 0 }
        var sumSq: Float = 0
        for i in 0..<frames {
            var mono: Float = 0
            for c in 0..<numCh { mono += ch[c][i] }
            let m = mono / Float(numCh)
            sumSq += m * m
        }
        return sqrt(sumSq / Float(frames))
    }

    // Sync TriggerState fields from current published settings + sampleRate
    private func updateTriggerState() {
        guard let trig = triggerState else { return }
        trig.updateConfig(
            isEnabled:         triggeredRecording,
            threshold:         Float(pow(10.0, triggerThresholdDB / 20.0)),
            maxSilenceSamples: Int(triggerSilenceDuration * sampleRate),
            preRollSamples:    Int(triggerPreRollSeconds  * sampleRate)
        )
    }

    // MARK: - Setup

    private func start() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .default,
                                options: [.defaultToSpeaker, .allowBluetoothHFP, .mixWithOthers])
        try session.setActive(true)

        let inputNode = avEngine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)
        sampleRate = inputFormat.sampleRate

        let capacity = Int(maxSeconds * sampleRate)
        let r = RingBuffer(capacity: capacity, waveformPoints: Self.waveformPoints)
        ring = r

        let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                sampleRate: sampleRate, channels: 1,
                                interleaved: false)!
        monoFormat = fmt

        if !isPlayerAttached {
            avEngine.attach(playerNode)
            isPlayerAttached = true
        }
        avEngine.connect(playerNode, to: avEngine.mainMixerNode, format: fmt)

        // Pre-roll buffer: capacity = 3 s (hard max for the pre-roll slider)
        let preRoll = PreRollBuffer(capacity: Int(3.0 * sampleRate))
        preRollBuffer = preRoll

        // Trigger state — settings propagated via updateTriggerState()
        let trig = TriggerState()
        triggerState = trig
        updateTriggerState()

        // Capture ring, pre-roll and trigger state directly — avoids @MainActor crossing on audio thread
        let sr = sampleRate
        inputNode.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self, r, preRoll, trig] buf, _ in
            // Always write to pre-roll (even while the main ring is paused)
            preRoll.write(buffer: buf)

            let rms = AudioBufferEngine.monoRMS(buf)
            let db  = rms > 0 ? Double(20.0 * log10(rms)) : -160.0

            // Snapshot config once — single lock acquisition for the entire callback.
            let cfg = trig.snapshotConfig()
            if cfg.isEnabled {
                if !trig.isWaiting {
                    // Recording — watch for sustained silence
                    if rms < cfg.threshold {
                        trig.silenceCount += Int(buf.frameLength)
                        if trig.silenceCount >= cfg.maxSilenceSamples {
                            r.isActive = false
                            trig.isWaiting = true
                            trig.silenceCount = 0
                            DispatchQueue.main.async { [weak self] in
                                self?.isWaitingForSound = true
                                self?.isRecording = false
                            }
                        }
                    } else {
                        trig.silenceCount = 0
                    }
                } else {
                    // Waiting — watch for sound to resume
                    if rms >= cfg.threshold {
                        let pre = preRoll.extractLast(count: cfg.preRollSamples)
                        r.writeRaw(pre)
                        r.isActive = true
                        trig.isWaiting = false
                        trig.silenceCount = 0
                        DispatchQueue.main.async { [weak self] in
                            self?.isWaitingForSound = false
                            self?.isRecording = true
                        }
                    }
                }
            }

            r.write(buffer: buf)
            let wf = r.waveformSnapshot()
            let filled = Double(r.filledSampleCount) / sr
            DispatchQueue.main.async { [weak self] in
                self?.waveformData = wf
                self?.filledSeconds = filled
                self?.inputLevelDB = db
                if self?.isLive == true {
                    self?.playheadSeconds = filled
                }
            }

        }

        setupNotifications()
        try avEngine.start()
        isEngineStarted = true
        isRecording = true
        isLive = true
        refreshInputs()
    }

    // MARK: - Timer tick (main thread)

    private func tick() {
        guard isPlaying, let start = playbackStartWall else { return }
        let pos = playbackStartSec + Date().timeIntervalSince(start)
        let ceiling = playbackClipEndSeconds ?? filledSeconds
        if pos >= ceiling {
            // Increment generation BEFORE stopPlayback so the buffer completion
            // callback (which checks generation) is invalidated and won't fire
            // onPlaybackComplete a second time.
            playbackGeneration += 1
            playheadSeconds = ceiling   // pin exactly to the clip/buffer end
            stopPlayback()
            onPlaybackComplete()
        } else {
            playheadSeconds = pos
        }
    }

    // MARK: - Playback

    private func play() {
        startPlayback(fromSeconds: isLive ? filledSeconds : playheadSeconds)
    }

    private func seekTo(seconds: Double) {
        let clamped = max(0, min(filledSeconds, seconds))
        playheadSeconds = clamped
        isLive = clamped >= filledSeconds - 0.5
        if isPlaying { startPlayback(fromSeconds: clamped) }
    }

    private func startPlayback(fromSeconds seconds: Double, toSeconds: Double? = nil) {
        guard let fmt = monoFormat, let r = ring else { return }

        stopPlayback()
        playbackGeneration += 1
        let gen = playbackGeneration

        guard let flat = r.copySlice(startSec: seconds, sampleRate: sampleRate,
                                     endSec: toSeconds) else { return }

        guard let pcmBuf = AVAudioPCMBuffer(pcmFormat: fmt,
                                             frameCapacity: AVAudioFrameCount(flat.count)),
              let dst = pcmBuf.floatChannelData?[0] else { return }
        pcmBuf.frameLength = AVAudioFrameCount(flat.count)
        flat.withUnsafeBufferPointer { src in
            dst.initialize(from: src.baseAddress!, count: flat.count)
        }

        playbackStartSec = seconds
        playbackStartWall = Date()
        playbackClipEndSeconds = toSeconds
        isPlayingClip = (toSeconds != nil)

        playerNode.scheduleBuffer(pcmBuf) { [weak self] in
            DispatchQueue.main.async {
                guard let self, self.playbackGeneration == gen else { return }
                self.onPlaybackComplete()
            }
        }
        playerNode.play()
        isPlaying = true
        isLive = false

        displayTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            self?.tick()
        }
    }

    // Save active recording state then stop the ring — called before entering playback.
    // Guards against being called twice (e.g. scrubbing fires many events).
    private func captureRecordingStateIfNeeded() {
        guard prePlaybackSnapshot == nil else { return }
        if isRecording {
            prePlaybackSnapshot = .recording
        } else if isWaitingForSound {
            prePlaybackSnapshot = .waitingForTrigger
        }
        triggerState?.isWaiting = false
        triggerState?.silenceCount = 0
        ring?.isActive = false
        isRecording = false
        isWaitingForSound = false
    }

    // Restore recording state saved by captureRecordingStateIfNeeded.
    private func restoreRecordingState() {
        defer { prePlaybackSnapshot = nil }
        switch prePlaybackSnapshot {
        case .recording:
            ring?.isActive = true
            isRecording = true
            isLive = true
            playheadSeconds = filledSeconds
        case .waitingForTrigger:
            triggerState?.isWaiting = true
            isWaitingForSound = true
            isLive = true
            playheadSeconds = filledSeconds
        case nil:
            // Was paused — go to live edge
            isLive = true
            playheadSeconds = filledSeconds
        }
    }

    private func pause() {
        playerNode.pause()
        isPlaying = false
        playbackStartWall = nil
        displayTimer?.invalidate()
        displayTimer = nil
        // User explicitly chose to pause — forget any recording state that was
        // captured before playback started. Further seeks must stay paused.
        prePlaybackSnapshot = nil
    }

    private func stopPlayback() {
        playerNode.stop()
        isPlaying = false
        playbackStartWall = nil
        playbackClipEndSeconds = nil
        displayTimer?.invalidate()
        displayTimer = nil
        // isPlayingClip intentionally NOT cleared here — onPlaybackComplete reads it
    }

    private func onPlaybackComplete() {
        isPlaying = false
        if isPlayingClip {
            // Clip finished — playhead is already at the clip end (set by the last tick()).
            // Stay paused there. Recording was permanently stopped when selection mode
            // was entered, so there is nothing to restore.
            isPlayingClip = false
        } else {
            restoreRecordingState()
        }
    }
}
