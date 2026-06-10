import AVFoundation
import UIKit
import os.log


enum EngineState {
    case ready
    case recording
    case playing
    case paused
}

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

    // Copy a waveform snapshot for UI — ordered oldest→newest.
    func copyWaveformSnapshot(into result: inout [Float]) {
        if result.count != waveformPoints {
            result = Array(repeating: 0, count: waveformPoints)
        } else {
            for i in result.indices {
                result[i] = 0
            }
        }

        let filledBuckets = min(totalWritten / samplesPerBucket, waveformPoints)
        let oldest = totalWritten >= capacity ? bucketWriteIdx : 0
        for i in 0..<filledBuckets {
            result[i] = buckets[(oldest + i) % waveformPoints]
        }
    }

    func waveformSnapshot() -> [Float] {
        var result = [Float](repeating: 0, count: waveformPoints)
        copyWaveformSnapshot(into: &result)
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

// MARK: - Export Error

enum ExportError: LocalizedError {
    case notReady, empty, bufferError

    var errorDescription: String? {
        switch self {
        case .notReady:      return String(localized: "Engine not ready — start recording first.", bundle: LanguageManager.shared.bundle)
        case .empty:         return String(localized: "Nothing recorded yet.", bundle: LanguageManager.shared.bundle)
        case .bufferError:   return String(localized: "Failed to create audio buffer.", bundle: LanguageManager.shared.bundle)
        }
    }
}

// MARK: - Audio Buffer Engine (implicitly @MainActor via project settings)

import Combine

final class AudioBufferEngine: ObservableObject {

    static let waveformPoints: Int = 2000
    static let minimumBufferSeconds: Double = 60
    static let maximumBufferSeconds: Double = 15 * 60
    static let bufferDurationRange: ClosedRange<Double> = minimumBufferSeconds...maximumBufferSeconds

    private static let defaultBufferSeconds: Double = 300
    private static let waveformPublishInterval: TimeInterval = 1.0 / 15.0
    private static let positionPublishInterval: TimeInterval = 1.0 / 30.0
    private static let durationKey         = "loopRecording.bufferDuration"

    private static func clampedBufferDuration(_ seconds: Double) -> Double {
        min(max(seconds, minimumBufferSeconds), maximumBufferSeconds)
    }

    // MARK: Published state (main thread)
    @Published var state: EngineState = .ready
    
    @Published var waveformData: [Float] = Array(repeating: 0, count: waveformPoints)
    @Published var filledSeconds: Double = 0
    @Published var playheadSeconds: Double = 0
    @Published var isPlaying: Bool = false
    @Published var isAtLiveEdge: Bool = false
    @Published var isRecording: Bool = false { didSet { updateIdleTimer() } }
    @Published var permissionDenied: Bool = false
    @Published var availableInputs: [AVAudioSessionPortDescription] = []
    @Published var currentInput: AVAudioSessionPortDescription? = nil
    @Published var maxSeconds: Double
    @Published var engineError: String? = nil

    // MARK: Private
    private let avEngine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()
    private var sampleRate: Double = 44100
    private var monoFormat: AVAudioFormat?
    private var ring: RingBuffer?
    private var isEngineStarted = false
    private var isPlayerAttached = false
    private var wasInterrupted = false
    private var notificationObservers: [NSObjectProtocol] = []
    private var waveformTimer: Timer?
    private var positionTimer: Timer?
    private var waveformBufferA = [Float](repeating: 0, count: AudioBufferEngine.waveformPoints)
    private var waveformBufferB = [Float](repeating: 0, count: AudioBufferEngine.waveformPoints)
    private var useWaveformBufferA = true
    private var positionAnchorSampleCount = 0
    private var positionAnchorWall = Date()

    init() {
        let ud = UserDefaults.standard
        ud.register(defaults: [
            Self.durationKey: Self.defaultBufferSeconds
        ])
        let saved = ud.double(forKey: Self.durationKey)
        maxSeconds = Self.clampedBufferDuration(saved)
        if saved != maxSeconds {
            ud.set(maxSeconds, forKey: Self.durationKey)
        }
    }

    private var playbackStartWall: Date?
    private var playbackStartSec: Double = 0
    private var displayTimer: Timer?
    private var playbackGeneration = 0
    private var wasPlayingBeforeScrub = false
    // State snapshot taken when playback interrupts an active recording session
    private enum RecordingSnapshot { case recording }
    private var prePlaybackSnapshot: RecordingSnapshot? = nil

    // MARK: - Public API

    private var liveEdgeThresholdSeconds: Double {
        max(0, filledSeconds - 0.5)
    }

    func requestPermissionAndStart() {
        AVAudioApplication.requestRecordPermission { [weak self] granted in
            DispatchQueue.main.async {
                if granted {
                    do { try self?.start() } catch {
                        self?.engineError = String(localized: "Failed to start recording: \(error.localizedDescription)", bundle: LanguageManager.shared.bundle)
                    }
                } else {
                    self?.permissionDenied = true
                    self?.state = .ready
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
        isAtLiveEdge = false
        if wasPlaying || hadRecording {
            if newSec >= filledSeconds {
                // Skipped to the live edge — treat as playback reaching the end.
                finishPlaybackAndRestore()
            } else if !startPlayback(fromSeconds: newSec) {
                // Too close to the live edge to play — treat as reaching the end
                // so playback stops and recording (if any) is restored, rather
                // than leaving the old player running from its previous position.
                finishPlaybackAndRestore()
            }
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
        if clamped >= liveEdgeThresholdSeconds {
            playheadSeconds = filledSeconds
            isAtLiveEdge = true
            if isPlaying || prePlaybackSnapshot != nil {
                finishPlaybackAndRestore()
            }
            return
        }

        captureRecordingStateIfNeeded()
        playheadSeconds = clamped
        isAtLiveEdge = false
        if !startPlayback(fromSeconds: clamped) {
            restoreRecordingState()
        }
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
        isAtLiveEdge = false
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
        isAtLiveEdge = false
        if shouldPlay {
            if clamped >= filledSeconds {
                // Dragged to the live edge while playing — treat as playback reaching the end.
                finishPlaybackAndRestore()
            } else {
                if !startPlayback(fromSeconds: clamped) {
                    restoreRecordingState()
                }
            }
        } else if prePlaybackSnapshot != nil {
            if clamped < filledSeconds {
                // User dragged back while recording — enter playback from the scrubbed position.
                if !startPlayback(fromSeconds: clamped) {
                    restoreRecordingState()
                }
            } else {
                // Scrub ended at the live edge — restore recording.
                restoreRecordingState()
            }
        }
        // Was already paused → stay paused at the scrubbed position.
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
        stopWaveformTimer()
        stopPositionTimer()
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
            if isRecording {
                wasInterrupted = true
                ring?.isActive = false
                isRecording = false
                state = filledSeconds > 0 ? .paused : .ready
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
                isAtLiveEdge = true
                state = .recording
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

    func bufferDurationChangeNeedsConfirmation(_ seconds: Double) -> Bool {
        filledSeconds > Self.clampedBufferDuration(seconds)
    }

    func applyBufferDuration(_ seconds: Double) {
        let targetSeconds = Self.clampedBufferDuration(seconds)
        maxSeconds = targetSeconds
        UserDefaults.standard.set(targetSeconds, forKey: Self.durationKey)
        guard isEngineStarted, let r = ring else { return }

        let wasPlaying = isPlaying
        // Recording should resume if it's active now, or was suspended to enter
        // playback (prePlaybackSnapshot). Using isRecording alone loses the latter.
        let shouldResumeRecording = isRecording || prePlaybackSnapshot == .recording
        let oldFilledSeconds = filledSeconds
        let droppedSeconds = max(0, oldFilledSeconds - targetSeconds)
        // Pause ingestion while copying so the audio thread isn't writing the
        // samples we read (mirrors exportWAV), then restore.
        let wasActive = r.isActive
        r.isActive = false
        let preservedAudio = r.copySlice(startSec: droppedSeconds, sampleRate: sampleRate) ?? []
        r.isActive = wasActive
        let restoredPlayhead = isAtLiveEdge
            ? min(targetSeconds, oldFilledSeconds)
            : max(0, playheadSeconds - droppedSeconds)
        let restoredIsAtLiveEdge = isAtLiveEdge || restoredPlayhead >= min(targetSeconds, oldFilledSeconds) - 0.5

        tearDown()
        prePlaybackSnapshot = nil

        do {
            // While playback resumes we must not ingest; if recording should
            // resume, that intent is carried by prePlaybackSnapshot and restored
            // when playback finishes.
            let willResumePlayback = wasPlaying && restoredPlayhead < min(targetSeconds, oldFilledSeconds)
            try start(
                preservedSamples: preservedAudio,
                startRecording: shouldResumeRecording && !willResumePlayback,
                initialPlayheadSeconds: restoredPlayhead,
                initialIsAtLiveEdge: restoredIsAtLiveEdge
            )
            if willResumePlayback {
                if shouldResumeRecording {
                    prePlaybackSnapshot = .recording
                }
                _ = startPlayback(fromSeconds: restoredPlayhead)
            }
        } catch {
            engineError = String(localized: "Failed to change buffer duration: \(error.localizedDescription)", bundle: LanguageManager.shared.bundle)
        }
    }

    // Applies a new input device and restarts the engine. Clears the buffer.
    func restartEngine(input: AVAudioSessionPortDescription? = nil) {
        tearDown()

        isPlaying = false
        isRecording = false
        isAtLiveEdge = false
        state = .ready
        playheadSeconds = 0
        filledSeconds = 0
        waveformData = Array(repeating: 0, count: Self.waveformPoints)
        prePlaybackSnapshot = nil
        if let input {
            try? AVAudioSession.sharedInstance().setPreferredInput(input)
            currentInput = input
        }

        do { try start() } catch {
            engineError = String(localized: "Failed to restart audio engine: \(error.localizedDescription)", bundle: LanguageManager.shared.bundle)
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
        if isRecording {
            // User explicitly stopped — discard any playback-restore snapshot
            prePlaybackSnapshot = nil
            ring?.isActive = false
            isRecording = false
            state = filledSeconds > 0 ? .paused : .ready
            // isAtLiveEdge stays true — playhead is still at the end of the buffer
        } else {
            // Resume: jump to the live edge and start ingesting again.
            // Recording is live again, so any snapshot captured when playback
            // interrupted a previous session is obsolete — clearing it lets the
            // next waveform tap suspend recording properly.
            stopPlayback()
            prePlaybackSnapshot = nil
            ring?.isActive = true
            isRecording = true
            isAtLiveEdge = true
            playheadSeconds = filledSeconds
            state = .recording
        }
    }

    // MARK: - Helpers

    private func updateIdleTimer() {
        UIApplication.shared.isIdleTimerDisabled = isRecording
    }

    private func startWaveformTimer() {
        stopWaveformTimer()
        publishWaveformSnapshot()
        waveformTimer = Timer.scheduledTimer(withTimeInterval: Self.waveformPublishInterval, repeats: true) { [weak self] _ in
            self?.publishWaveformSnapshot()
        }
    }

    private func stopWaveformTimer() {
        waveformTimer?.invalidate()
        waveformTimer = nil
    }

    private func startPositionTimer() {
        stopPositionTimer()
        positionAnchorSampleCount = ring?.filledSampleCount ?? 0
        positionAnchorWall = Date()
        publishPositionSnapshot()
        positionTimer = Timer.scheduledTimer(withTimeInterval: Self.positionPublishInterval, repeats: true) { [weak self] _ in
            self?.publishPositionSnapshot()
        }
    }

    private func stopPositionTimer() {
        positionTimer?.invalidate()
        positionTimer = nil
    }

    private func publishWaveformSnapshot() {
        guard let r = ring else { return }

        if useWaveformBufferA {
            r.copyWaveformSnapshot(into: &waveformBufferA)
            waveformData = waveformBufferA
        } else {
            r.copyWaveformSnapshot(into: &waveformBufferB)
            waveformData = waveformBufferB
        }
        useWaveformBufferA.toggle()
    }

    private func publishPositionSnapshot() {
        guard let r = ring else { return }
        let now = Date()
        let sampleCount = r.filledSampleCount
        if sampleCount != positionAnchorSampleCount {
            positionAnchorSampleCount = sampleCount
            positionAnchorWall = now
        }

        let actualFilled = Double(sampleCount) / sampleRate
        let liveEstimate = isRecording
            ? min(maxSeconds, actualFilled + now.timeIntervalSince(positionAnchorWall))
            : actualFilled
        let filled = max(actualFilled, liveEstimate)
        filledSeconds = filled
        if isAtLiveEdge {
            playheadSeconds = filled
        }
    }

    // MARK: - Setup

    private func start(
        preservedSamples: [Float] = [],
        startRecording: Bool = true,
        initialPlayheadSeconds: Double = 0,
        initialIsAtLiveEdge: Bool = true
    ) throws {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playAndRecord, mode: .default,
                                    options: [.defaultToSpeaker, .allowBluetoothHFP, .mixWithOthers])
            try session.setActive(true)

            let inputNode = avEngine.inputNode
            let inputFormat = inputNode.outputFormat(forBus: 0)
            sampleRate = inputFormat.sampleRate

            maxSeconds = Self.clampedBufferDuration(maxSeconds)
            let capacity = Int(maxSeconds * sampleRate)
            let r = RingBuffer(capacity: capacity, waveformPoints: Self.waveformPoints)
            ring = r
            r.isActive = startRecording

            let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                    sampleRate: sampleRate, channels: 1,
                                    interleaved: false)!
            monoFormat = fmt

            if !preservedSamples.isEmpty {
                r.writeRaw(preservedSamples)
            }

            let initialFilledSeconds = Double(r.filledSampleCount) / sampleRate
            filledSeconds = initialFilledSeconds
            playheadSeconds = min(initialPlayheadSeconds, initialFilledSeconds)
            isAtLiveEdge = initialFilledSeconds > 0
                ? (initialIsAtLiveEdge || playheadSeconds >= initialFilledSeconds - 0.5)
                : initialIsAtLiveEdge

            if !isPlayerAttached {
                avEngine.attach(playerNode)
                isPlayerAttached = true
            }
            avEngine.connect(playerNode, to: avEngine.mainMixerNode, format: fmt)

            inputNode.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [r] buf, _ in
                r.write(buffer: buf)
            }

            setupNotifications()
            try avEngine.start()
            isEngineStarted = true
            isRecording = startRecording
            if startRecording {
                isAtLiveEdge = true
                playheadSeconds = filledSeconds
                state = .recording
            } else {
                state = filledSeconds > 0 ? .paused : .ready
            }
            startWaveformTimer()
            startPositionTimer()
            refreshInputs()
        } catch {
            tearDown()
            throw error
        }
    }

    // MARK: - Timer tick (main thread)

    private func tick() {
        guard isPlaying, let start = playbackStartWall else { return }
        let pos = playbackStartSec + Date().timeIntervalSince(start)
        if pos >= filledSeconds {
            finishPlaybackAndRestore()
        } else {
            playheadSeconds = pos
        }
    }

    // MARK: - Playback

    private func play() {
        startPlayback(fromSeconds: isAtLiveEdge ? filledSeconds : playheadSeconds)
    }

    private func seekTo(seconds: Double) {
        let clamped = max(0, min(filledSeconds, seconds))
        playheadSeconds = clamped
        isAtLiveEdge = clamped >= filledSeconds - 0.5
        if isPlaying, !startPlayback(fromSeconds: clamped) {
            finishPlaybackAndRestore()
        }
    }

    @discardableResult
    private func startPlayback(fromSeconds seconds: Double) -> Bool {
        guard let fmt = monoFormat, let r = ring else { return false }
        guard seconds < liveEdgeThresholdSeconds else { return false }

        guard let flat = r.copySlice(startSec: seconds, sampleRate: sampleRate) else { return false }

        guard let pcmBuf = AVAudioPCMBuffer(pcmFormat: fmt,
                                             frameCapacity: AVAudioFrameCount(flat.count)),
              let dst = pcmBuf.floatChannelData?[0] else { return false }
        pcmBuf.frameLength = AVAudioFrameCount(flat.count)
        flat.withUnsafeBufferPointer { src in
            dst.initialize(from: src.baseAddress!, count: flat.count)
        }

        stopPlayback()
        playbackGeneration += 1
        let gen = playbackGeneration
        playbackStartSec = seconds
        playbackStartWall = Date()

        playerNode.scheduleBuffer(pcmBuf) { [weak self] in
            DispatchQueue.main.async {
                guard let self, self.playbackGeneration == gen else { return }
                self.finishPlaybackAndRestore(expectedGeneration: gen)
            }
        }
        playerNode.play()
        isPlaying = true
        isAtLiveEdge = false
        
        // Engine state changes
        state = .playing
        
        displayTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            self?.tick()
        }
        return true
    }

    // Save active recording state then stop the ring — called before entering playback.
    // Guards against being called twice (e.g. scrubbing fires many events).
    private func captureRecordingStateIfNeeded() {
        if prePlaybackSnapshot == nil, isRecording {
            prePlaybackSnapshot = .recording
        }
        // Always suspend ingestion, even if a snapshot already exists — a stale
        // snapshot must never leave recording running underneath playback.
        guard isRecording || ring?.isActive == true else { return }
        ring?.isActive = false
        isRecording = false
        state = filledSeconds > 0 ? .paused : .ready
    }

    // Restore recording state saved by captureRecordingStateIfNeeded.
    private func restoreRecordingState() {
        defer { prePlaybackSnapshot = nil }
        switch prePlaybackSnapshot {
        case .recording:
            ring?.isActive = true
            isRecording = true
            isAtLiveEdge = true
            playheadSeconds = filledSeconds
            state = .recording
        case nil:
            // Was paused — go to live edge
            isAtLiveEdge = true
            playheadSeconds = filledSeconds
            state = filledSeconds > 0 ? .paused : .ready
        }
    }

    private func pause() {
        playbackGeneration += 1
        playerNode.pause()
        isPlaying = false
        playbackStartWall = nil
        displayTimer?.invalidate()
        displayTimer = nil
        // User explicitly chose to pause — forget any recording state that was
        // captured before playback started. Further seeks must stay paused.
        prePlaybackSnapshot = nil
        state = filledSeconds > 0 ? .paused : .ready
    }

    private func stopPlayback(invalidateCompletion: Bool = true) {
        if invalidateCompletion {
            playbackGeneration += 1
        }
        playerNode.stop()
        isPlaying = false
        playbackStartWall = nil
        displayTimer?.invalidate()
        displayTimer = nil
    }

    private func finishPlaybackAndRestore(expectedGeneration: Int? = nil) {
        if let expectedGeneration, playbackGeneration != expectedGeneration { return }
        playbackGeneration += 1
        playheadSeconds = filledSeconds
        stopPlayback(invalidateCompletion: false)
        restoreRecordingState()
    }
}
