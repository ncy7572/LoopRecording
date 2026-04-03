# loopRecording

An iOS app that continuously records audio into a circular buffer — think of it as a dashcam for your microphone. Audio is always being captured; you can scrub back in time to hear anything from the last N minutes, then export what you need.

## Features

- **Loop buffer recording** — continuously ingests audio into a fixed-size ring buffer (1 min – 1 hr, configurable). Old audio is silently overwritten as new audio arrives.
- **Live waveform** — two-panel waveform display: a zoomed detail view that scrolls like tape, and a minimap overview of the full buffer.
- **Non-destructive scrubbing** — drag the waveform to rewind while recording continues in the background. Release and recording seamlessly picks back up.
- **Region selection** — long-press the waveform to enter selection mode. Drag to mark a region; grab the handles to adjust it. Play or export just that clip.
- **WAV export** — exports the full buffer or any selected region as a 32-bit float mono WAV via the iOS share sheet.
- **Triggered recording** — automatically pauses ingestion after a configurable period of silence and resumes on the next sound. Includes a pre-roll window (up to 3 s) so the first note is never clipped.
- **Input device selection** — switch between built-in mic, wired headset, Bluetooth HFP, USB audio, and car audio without leaving the app.
- **Interruption handling** — gracefully pauses on phone calls / Siri and optionally resumes when the system allows.
- **Idle timer management** — prevents the screen from sleeping while recording or waiting for a trigger.
- **Dark-only UI** — pure-black background, optimized for OLED displays.

## Usage

### Basic recording

1. Launch the app. It immediately requests microphone permission and starts recording.
2. The waveform scrolls left in real time. The status badge reads **LIVE** and the REC button is highlighted.
3. Tap **REC** again to pause ingestion (the buffer remains intact).

### Playback

| Control | Action |
|---|---|
| Play / Pause | Resume or pause playback from the current position |
| ⏮ 15 s | Skip back 15 seconds |
| ⏭ 15 s | Skip forward 15 seconds |
| Drag waveform | Scrub to any point in the buffer |
| Tap overview | Jump to any position in the full buffer |

When playback ends, recording automatically resumes from where it left off.

### Selecting a region

1. Long-press the waveform (≥ 0.4 s) to enter selection mode.
2. Drag to draw a region. The selected area is highlighted in blue.
3. Drag either edge handle (±28 pt hit area) to trim.
4. Tap **Play Clip** to preview, or **Export Clip** to share just that region.
5. Long-press again to cancel and clear the selection.

### Exporting

- Tap the **share** icon (top-left) to export the entire buffer as a `.wav` file.
- While a region is selected, tap **Export Clip** to export only that region.

Files are written to the system temp directory and presented via `UIActivityViewController`.

### Settings

| Setting | Range | Default | Notes |
|---|---|---|---|
| Triggered Recording | on/off | off | Auto-pauses on silence, resumes on sound |
| Silence Threshold | −60 to −10 dB | −40 dB | RMS level below which silence is counted |
| Stop After | 1–60 s | 10 s | Sustained silence duration before pausing |
| Pre-roll | 0–3 s | 1 s | Seconds prepended from before the trigger fired |
| Buffer Duration | 1–60 min | 5 min | Changing this restarts the engine and clears the buffer |
| Input Device | system list | built-in mic | Changing this also restarts the engine |

## Design & Architecture

### Audio pipeline

```
AVAudioEngine.inputNode
       │ tap (4096 frame buffer, real-time thread)
       ▼
 PreRollBuffer ──► always running, last N seconds of raw audio
       │
       ▼
 TriggerState ──► silence detection / re-trigger logic
       │
       ▼
 RingBuffer ──► circular sample store + incremental waveform buckets
       │
       ├──► main thread: waveformData, filledSeconds, inputLevelDB (via DispatchQueue.main.async)
       │
       └──► playback: copySlice() → AVAudioPCMBuffer → AVAudioPlayerNode
```

### `RingBuffer`

A fixed-capacity circular buffer of `Float` samples written on the audio thread and snapshotted on the main thread. Simultaneously maintains 2 000 RMS-bucketed waveform points so the UI never has to iterate raw samples.

Key methods:
- `write(buffer:)` — mixes multi-channel PCM down to mono and appends to both the sample ring and the current waveform bucket.
- `waveformSnapshot()` — returns a `[Float]` ordered oldest→newest, safe to call from the main thread (lock-free snapshot; the audio thread never reallocates).
- `copySlice(startSec:sampleRate:endSec:)` — extracts a flat contiguous slice from the circular buffer for playback or export.
- `writeRaw(_:)` — bulk-injects the pre-roll samples when a trigger fires.

### `PreRollBuffer`

A separate, always-active circular buffer that the audio thread writes to continuously (even when the main ring is paused). When a trigger fires, `extractLast(count:)` pulls the preceding N samples and injects them into the ring buffer via `writeRaw`.

### `TriggerState`

Plain class (`@unchecked Sendable`) holding trigger configuration (set from main thread) and running counters (maintained on the audio thread). The state machine has two modes:

- **Recording** — counts consecutive silence frames; exceeds `maxSilenceSamples` → pause ring, signal main thread (`isWaitingForSound = true`).
- **Waiting** — watches for RMS ≥ threshold → inject pre-roll, re-activate ring, signal main thread (`isRecording = true`).

### `AudioBufferEngine` (`@MainActor`)

The central `ObservableObject` wiring the UI to the audio pipeline. Responsibilities:

- AVAudioSession lifecycle (category, activation, interruption / route-change handling)
- Engine start / teardown / restart
- Playback state machine with generation counters (prevents stale completion callbacks)
- Recording state capture/restore when the user enters playback mid-recording
- Settings persistence via `UserDefaults`
- Idle timer management

### `WaveformView`

Two-layer SwiftUI `Canvas`-based renderer:

- **`DetailWaveView`** — zoomed view centered on the playhead. Draws only the bars currently in the viewport (clip culled). Handles five distinct gesture modes: normal scrub, selection creation, handle drag, scroll-while-selection-active, and tap-seek.
- **`OverviewWaveView`** — compressed view of the full buffer. Tap or drag anywhere to jump.

Time labels in the detail view are rendered as wall-clock timestamps anchored to the actual capture time of each sample.

## Code Review

### Issues

**1. Data race on `TriggerState` configuration** (`AudioBufferEngine.swift:163`)

`TriggerState` is marked `@unchecked Sendable`. Its config fields (`threshold`, `maxSilenceSamples`, `preRollSamples`) are written on the main thread via `updateTriggerState()` and read on the real-time audio thread without any synchronization primitive. A torn write during a settings change could cause an incorrect threshold to be used for one or more audio callbacks. A simple fix is to make the config fields `@Atomic` (or equivalent) or to capture a snapshot value in the tap closure.

**2. Dead code in `exportWAV()`** (`AudioBufferEngine.swift:409`)

```swift
let _ = sampleRate   // ← does nothing; sampleRate is already captured by the closure
```

This line captures `sampleRate` into a local binding that is immediately discarded. It has no effect and should be removed.

**3. Lock-free ring buffer is technically unsound** (`RingBuffer` — all access)

`RingBuffer` relies on Swift's lack of memory reordering guarantees at the language level. The audio thread writes `samples`, `writeHead`, `totalWritten`, and the bucket state, while the main thread reads them (in `waveformSnapshot` and `copySlice`) with no memory barriers. This works in practice on ARM because of its strong memory model, but it is undefined behavior under Swift's concurrency model. Using `OSAllocatedUnfairLock` or similar for the snapshot path would make it formally correct.

**4. Display timer runs unconditionally** (`AudioBufferEngine.swift:760`)

The 30 Hz `displayTimer` (`tick()`) fires even when the app is paused and nothing is playing. The `tick()` function exits immediately in that case, so there is no functional bug, but it wastes a small amount of CPU. The timer could be started and stopped alongside playback.

**5. `waveformScrubEnded` can start playback unexpectedly** (`AudioBufferEngine.swift:336`)

If the user is in recording mode, scrubs, and lifts their finger, `prePlaybackSnapshot` is set (by `captureRecordingStateIfNeeded`) and `shouldPlay` becomes `true`, which starts playback. This is by design (the code comment explains the intent), but it can surprise users who intended only to peek at the waveform without triggering playback. Consider requiring an explicit play action.

**6. `OverviewWaveView` fires `onSeek` on both `onChanged` and `onEnded`** (`WaveformView.swift:418–425`)

Both handlers call `onSeek` with the same computation, so every drag gesture fires a seek twice on finger-lift. Since `onScrubEnd` stops and restarts the player, the extra call is harmless but redundant. The `onEnded` handler could be removed, or `onChanged` could be skipped for zero-distance taps.

**7. Wall-clock time label uses `Calendar.component` instead of `DateFormatter`** (`WaveformView.swift:389`)

Calling `Calendar.current.component(_:from:)` three times per label per frame is more expensive than a cached `DateFormatter`. At 2 000 waveform points this only draws the subset in the viewport (~200 points max), so it is not a bottleneck — but a formatter is more idiomatic.

**8. `handleGrabRadius` is hardcoded** (`WaveformView.swift:84`)

```swift
private let handleGrabRadius: CGFloat = 28
```

This does not scale with Dynamic Type or pointer devices (iPad with keyboard/trackpad). Users with accessibility settings that increase touch target sizes may find the handles difficult to grab.

### Minor observations

- `isPlayerAttached` is a one-way flag; if `tearDown()` is ever called before the engine is fully started, the player node could be attached to a stopped engine on restart. Resetting this flag in `tearDown()` and re-attaching unconditionally would be safer.
- `formatWallTime` always uses `Calendar.current` (Gregorian). If the device locale uses a non-Gregorian calendar, the hour/minute/second extraction is still correct (it requests specific components), so this is not a bug.
- The `ShareSheet` wrapper (`ContentView.swift:5`) could be replaced with SwiftUI's native `ShareLink` (available since iOS 16), removing the `UIViewControllerRepresentable` boilerplate entirely.

## Requirements

- iOS 16+ (uses `ShareLink`-adjacent APIs and modern SwiftUI)
- Xcode 15+
- Swift 5.9+
- Microphone entitlement (`NSMicrophoneUsageDescription` in `Info.plist`)
