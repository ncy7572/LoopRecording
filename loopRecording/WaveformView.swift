import SwiftUI

// MARK: - WaveformView

struct WaveformView: View {
    let amplitudes: [Float]         // waveformPoints values, oldest → newest
    let filledFraction: Double      // 0–1 of totalSeconds that has been recorded
    let playheadFraction: Double    // 0–1 of totalSeconds
    let totalSeconds: Double
    let isLive: Bool
    var selection: WaveformSelection?

    var onScrub: (Double) -> Void
    var onScrubEnd: (Double) -> Void
    /// Called when the user taps (not drags) the waveform — should jump to that position and play.
    var onSeekTap: ((Double) -> Void)?
    var onSelectionStarted: (() -> Void)?
    var onSelectionChanged: ((Double, Double) -> Void)?  // (startFraction, endFraction)
    var onSelectionCleared: (() -> Void)?

    var body: some View {
        VStack(spacing: 0) {
            DetailWaveView(
                amplitudes: amplitudes,
                filledFraction: filledFraction,
                playheadFraction: playheadFraction,
                totalSeconds: totalSeconds,
                isLive: isLive,
                selection: selection,
                onScrub: onScrub,
                onScrubEnd: onScrubEnd,
                onSeekTap: onSeekTap,
                onSelectionStarted: onSelectionStarted,
                onSelectionChanged: onSelectionChanged,
                onSelectionCleared: onSelectionCleared
            )

            Rectangle()
                .fill(Color(white: 0.18))
                .frame(height: 1)

            OverviewWaveView(
                amplitudes: amplitudes,
                filledFraction: filledFraction,
                playheadFraction: playheadFraction,
                selection: selection,
                onSeek: { f in onScrub(f); onScrubEnd(f) }
            )
            .frame(height: 36)
        }
    }
}

// MARK: - Detail (zoomed, tape-scroll)

private struct DetailWaveView: View {
    let amplitudes: [Float]
    let filledFraction: Double
    let playheadFraction: Double
    let totalSeconds: Double
    let isLive: Bool
    var selection: WaveformSelection?
    var onScrub: (Double) -> Void
    var onScrubEnd: (Double) -> Void
    var onSeekTap: ((Double) -> Void)?
    var onSelectionStarted: (() -> Void)?
    var onSelectionChanged: ((Double, Double) -> Void)?
    var onSelectionCleared: (() -> Void)?

    private let visiblePoints = 200

    @State private var dragBaseFraction: Double? = nil
    // Selection gesture state
    @State private var selectionModeActive: Bool = false            // true after long-press
    @State private var selectionAnchorFraction: Double? = nil       // set from drag startLocation
    @State private var draggingHandle: HandleSide? = nil            // which handle is being moved
    @State private var dragIsScrubbingInSelectionMode: Bool = false // drag started away from handles

    private let green    = Color(red: 0.20, green: 0.85, blue: 0.55)
    private let greenDim = Color(red: 0.12, green: 0.40, blue: 0.28)
    private let red      = Color(red: 1.00, green: 0.35, blue: 0.35)
    private let selectionFill = Color(red: 0.30, green: 0.65, blue: 1.00).opacity(0.18)
    private let selectionEdge = Color(red: 0.45, green: 0.75, blue: 1.00)

    private enum HandleSide { case start, end }

    // How close (points) the finger must be to a handle to grab it
    @ScaledMetric(relativeTo: .body) private var handleGrabRadius: CGFloat = 28

    var body: some View {
        GeometryReader { geo in
            let w  = geo.size.width
            let h  = geo.size.height
            let pw = w / CGFloat(visiblePoints)

            let playheadPt    = CGFloat(playheadFraction) * CGFloat(amplitudes.count)
            let contentOffset = playheadPt * pw - w / 2
            let filledPt      = CGFloat(filledFraction) * CGFloat(amplitudes.count)
            let phColor       = isLive ? red : Color.white

            ZStack {
                Canvas { ctx, size in
                    drawBars(ctx: ctx, size: size, offset: contentOffset, pw: pw,
                             playheadPt: playheadPt, filledPt: filledPt)
                    drawSelection(ctx: ctx, size: size, offset: contentOffset, pw: pw)
                    drawTimeLabels(ctx: ctx, size: size, offset: contentOffset, pw: pw)
                }

                // Playhead line fixed at center
                Rectangle()
                    .fill(phColor)
                    .frame(width: 2)
                    .frame(maxHeight: .infinity)
                    .position(x: w / 2, y: h / 2)
            }
            .contentShape(Rectangle())
            // Long press: enter selection mode if not active, or cancel selection if active.
            .onLongPressGesture(minimumDuration: 0.4, maximumDistance: 25) {
                if selectionModeActive {
                    // Cancel — clear selection and exit selection mode
                    onSelectionCleared?()
                    selectionModeActive = false
                    selectionAnchorFraction = nil
                    dragIsScrubbingInSelectionMode = false
                } else {
                    onSelectionStarted?()
                    selectionModeActive = true
                    selectionAnchorFraction = nil
                }
            }
            .onChange(of: selection == nil) {
                // Selection was cleared externally (e.g. X button or start recording)
                if selection == nil {
                    selectionModeActive = false
                    selectionAnchorFraction = nil
                    dragIsScrubbingInSelectionMode = false
                }
            }
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { v in
                        let touchX = v.location.x
                        let n      = Double(amplitudes.count)
                        let toFrac = { (x: CGFloat) -> Double in
                            max(0, min(filledFraction,
                                (Double(x) + Double(contentOffset)) / Double(pw) / n))
                        }

                        // ── 1. Continue handle drag ──────────────────────────────────────
                        if let side = draggingHandle, let sel = selection {
                            let clamped = toFrac(touchX)
                            switch side {
                            case .start: onSelectionChanged?(clamped, sel.endFraction)
                            case .end:   onSelectionChanged?(sel.startFraction, clamped)
                            }
                            return
                        }

                        // ── 2. Continue waveform scrub started inside selection mode ─────
                        if dragIsScrubbingInSelectionMode {
                            if dragBaseFraction == nil { dragBaseFraction = playheadFraction }
                            let base  = dragBaseFraction!
                            let delta = -Double(v.translation.width / pw) / n
                            onScrub(max(0, min(filledFraction, base + delta)))
                            return
                        }

                        // ── 3. Continue selection-creation drag ──────────────────────────
                        if let anchor = selectionAnchorFraction {
                            let current = toFrac(touchX)
                            onSelectionChanged?(anchor, current)
                            // Edge scroll: nudge the visible window when finger nears edge
                            let edgeZone: CGFloat = 50
                            if touchX < edgeZone {
                                let speed = Double(1 - touchX / edgeZone) * 0.004
                                onScrub(max(0, playheadFraction - speed))
                            } else if touchX > w - edgeZone {
                                let speed = Double((touchX - (w - edgeZone)) / edgeZone) * 0.004
                                onScrub(min(filledFraction, playheadFraction + speed))
                            }
                            return
                        }

                        // ── 4. First event: classify this drag ───────────────────────────
                        // Use startLocation for handle proximity (stable across all events)
                        if let sel = selection {
                            let startX = CGFloat(sel.normalizedStart) * CGFloat(n) * pw - contentOffset
                            let endX   = CGFloat(sel.normalizedEnd)   * CGFloat(n) * pw - contentOffset
                            if abs(v.startLocation.x - startX) < handleGrabRadius {
                                draggingHandle = .start
                                onSelectionChanged?(toFrac(touchX), sel.endFraction)
                                return
                            } else if abs(v.startLocation.x - endX) < handleGrabRadius {
                                draggingHandle = .end
                                onSelectionChanged?(sel.startFraction, toFrac(touchX))
                                return
                            }
                        }

                        if selectionModeActive {
                            if selection != nil {
                                // Selection exists, not near a handle → scroll the waveform
                                dragIsScrubbingInSelectionMode = true
                                dragBaseFraction = playheadFraction
                                let delta = -Double(v.translation.width / pw) / n
                                onScrub(max(0, min(filledFraction, playheadFraction + delta)))
                            } else {
                                // No selection yet → start creating one
                                selectionAnchorFraction = toFrac(v.startLocation.x)
                                onSelectionChanged?(selectionAnchorFraction!, toFrac(touchX))
                            }
                            return
                        }

                        // ── 5. Normal scrub ──────────────────────────────────────────────
                        guard v.translation.width.magnitude > 4 || dragBaseFraction != nil else { return }
                        if dragBaseFraction == nil { dragBaseFraction = playheadFraction }
                        let base  = dragBaseFraction!
                        let delta = -Double(v.translation.width / pw) / n
                        onScrub(max(0, min(filledFraction, base + delta)))
                    }
                    .onEnded { v in
                        let touchX = v.location.x
                        let n      = Double(amplitudes.count)
                        let toFrac = { (x: CGFloat) -> Double in
                            max(0, min(filledFraction,
                                (Double(x) + Double(contentOffset)) / Double(pw) / n))
                        }
                        let isTap = v.translation.width.magnitude < 6 && v.translation.height.magnitude < 6

                        // Finish handle drag
                        if let side = draggingHandle, let sel = selection {
                            let clamped = toFrac(touchX)
                            switch side {
                            case .start: onSelectionChanged?(clamped, sel.endFraction)
                            case .end:   onSelectionChanged?(sel.startFraction, clamped)
                            }
                            draggingHandle = nil
                            return
                        }

                        // Finish waveform scrub in selection mode
                        if dragIsScrubbingInSelectionMode {
                            let base  = dragBaseFraction ?? playheadFraction
                            let delta = -Double(v.translation.width / pw) / n
                            onScrubEnd(max(0, min(filledFraction, base + delta)))
                            dragBaseFraction = nil
                            dragIsScrubbingInSelectionMode = false
                            return
                        }

                        // Finish selection-creation drag
                        if let anchor = selectionAnchorFraction {
                            if isTap {
                                // Barely moved after long-press — do nothing, wait for next drag
                            } else {
                                onSelectionChanged?(anchor, toFrac(touchX))
                            }
                            selectionAnchorFraction = nil
                            return
                        }

                        // Tap in selection mode → do nothing (clear is in the control bar)
                        if selectionModeActive && isTap {
                            return
                        }

                        draggingHandle = nil

                        // Finish normal scrub / tap — taps jump to position and play;
                        // drags only reposition (recording resumes via onScrubEnd).
                        if isTap {
                            onSeekTap?(toFrac(v.location.x))
                        } else {
                            let base  = dragBaseFraction ?? playheadFraction
                            let delta = -Double(v.translation.width / pw) / n
                            onScrubEnd(max(0, min(filledFraction, base + delta)))
                        }
                        dragBaseFraction = nil
                    }
            )
        }
    }

    private func drawBars(ctx: GraphicsContext, size: CGSize,
                          offset: CGFloat, pw: CGFloat,
                          playheadPt: CGFloat, filledPt: CGFloat) {
        let labelAreaH: CGFloat = 20
        let h   = size.height - labelAreaH
        let mid = h / 2
        let w   = size.width

        let maxAmp = Double(amplitudes.max() ?? 0.001)
        let norm   = maxAmp > 0 ? 1.0 / maxAmp : 1.0
        let barW   = pw * 0.6

        let startIdx = max(0, Int(offset / pw) - 1)
        let endIdx   = min(amplitudes.count - 1, Int((offset + w) / pw) + 1)
        guard startIdx <= endIdx else { return }

        for i in startIdx...endIdx {
            guard CGFloat(i) < filledPt else { continue }
            let x     = CGFloat(i) * pw - offset
            let amp   = Double(amplitudes[i]) * norm
            let halfH = CGFloat(max(2, amp * Double(mid) * 0.88))
            let color = CGFloat(i) < playheadPt ? green : greenDim
            ctx.fill(
                Path(CGRect(x: x, y: mid - halfH, width: barW, height: halfH * 2)),
                with: .color(color)
            )
        }
    }

    private func drawSelection(ctx: GraphicsContext, size: CGSize,
                               offset: CGFloat, pw: CGFloat) {
        guard let sel = selection, sel.durationFraction > 0 else { return }
        let n  = CGFloat(amplitudes.count)
        let startX = CGFloat(sel.normalizedStart) * n * pw - offset
        let endX   = CGFloat(sel.normalizedEnd)   * n * pw - offset
        let labelAreaH: CGFloat = 20
        let h = size.height - labelAreaH

        // Fill
        ctx.fill(
            Path(CGRect(x: startX, y: 0, width: endX - startX, height: h)),
            with: .color(selectionFill)
        )
        // Start edge
        ctx.fill(
            Path(CGRect(x: startX - 1, y: 0, width: 2, height: h)),
            with: .color(selectionEdge)
        )
        // End edge
        ctx.fill(
            Path(CGRect(x: endX - 1, y: 0, width: 2, height: h)),
            with: .color(selectionEdge)
        )
        // Handle nubs
        let nubH: CGFloat = 20
        let nubW: CGFloat = 4
        ctx.fill(
            Path(CGRect(x: startX - nubW / 2, y: h / 2 - nubH / 2, width: nubW, height: nubH)),
            with: .color(selectionEdge)
        )
        ctx.fill(
            Path(CGRect(x: endX - nubW / 2, y: h / 2 - nubH / 2, width: nubW, height: nubH)),
            with: .color(selectionEdge)
        )
    }

    private func drawTimeLabels(ctx: GraphicsContext, size: CGSize,
                                offset: CGFloat, pw: CGFloat) {
        let h = size.height
        let w = size.width
        let n = Double(amplitudes.count)

        let secondsPerPoint = totalSeconds / n
        let filledSeconds   = filledFraction * totalSeconds
        let bufferStart     = Date().addingTimeInterval(-filledSeconds)

        let markerEvery: Double = 5
        let pointsPerMarker = markerEvery / secondsPerPoint

        let leftPt  = Double(offset / pw)
        let rightPt = Double((offset + w) / pw)
        let firstK  = Int(ceil(leftPt  / pointsPerMarker))
        let lastK   = Int(floor(rightPt / pointsPerMarker))
        guard firstK <= lastK else { return }

        for k in firstK...lastK {
            guard k >= 0 else { continue }
            let pt = Double(k) * pointsPerMarker
            guard pt / n <= filledFraction else { continue }

            let x        = CGFloat(pt) * pw - offset
            let wallTime = bufferStart.addingTimeInterval(pt * secondsPerPoint)

            ctx.fill(
                Path(CGRect(x: x - 0.5, y: h - 18, width: 1, height: 5)),
                with: .color(.gray.opacity(0.5))
            )
            ctx.draw(
                Text(formatWallTime(wallTime))
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundColor(.gray),
                at: CGPoint(x: x, y: h - 8),
                anchor: .center
            )
        }
    }

    private static let wallTimeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    private func formatWallTime(_ date: Date) -> String {
        Self.wallTimeFormatter.string(from: date)
    }
}

// MARK: - Overview (full buffer, tap/drag to seek)

private struct OverviewWaveView: View {
    let amplitudes: [Float]
    let filledFraction: Double
    let playheadFraction: Double
    var selection: WaveformSelection?
    var onSeek: (Double) -> Void

    private let green    = Color(red: 0.20, green: 0.85, blue: 0.55)
    private let greenDim = Color(red: 0.12, green: 0.40, blue: 0.28)

    var body: some View {
        GeometryReader { geo in
            Canvas { ctx, size in
                drawOverview(ctx: ctx, size: size)
            }
            .contentShape(Rectangle())
            .gesture(
                // onChanged fires continuously during drag and once on tap (minimumDistance: 0),
                // so onEnded is not needed and would only cause a duplicate seek call.
                DragGesture(minimumDistance: 0)
                    .onChanged { v in
                        let f = Double(v.location.x / geo.size.width)
                        onSeek(max(0, min(filledFraction, f)))
                    }
            )
        }
    }

    private func drawOverview(ctx: GraphicsContext, size: CGSize) {
        let w   = size.width
        let h   = size.height
        let mid = h / 2
        let n   = amplitudes.count
        guard n > 0 else { return }

        let bw      = w / CGFloat(n)
        let maxAmp  = Double(amplitudes.max() ?? 0.001)
        let norm    = maxAmp > 0 ? 1.0 / maxAmp : 1.0
        let filledX = CGFloat(filledFraction) * w
        let phX     = CGFloat(playheadFraction) * w

        for i in 0..<n {
            let x = CGFloat(i) * bw
            guard x <= filledX else { break }
            let amp   = Double(amplitudes[i]) * norm
            let halfH = CGFloat(max(0.5, amp * Double(mid) * 0.85))
            ctx.fill(
                Path(CGRect(x: x, y: mid - halfH,
                            width: max(0.5, bw * 0.7), height: halfH * 2)),
                with: .color(x < phX ? green : greenDim)
            )
        }

        // Selection highlight in overview
        if let sel = selection, sel.durationFraction > 0 {
            let sx = CGFloat(sel.normalizedStart) * w
            let ex = CGFloat(sel.normalizedEnd)   * w
            ctx.fill(
                Path(CGRect(x: sx, y: 0, width: ex - sx, height: h)),
                with: .color(Color(red: 0.30, green: 0.65, blue: 1.00).opacity(0.25))
            )
        }

        // Playhead marker
        ctx.fill(
            Path(CGRect(x: phX - 1, y: 0, width: 2, height: h)),
            with: .color(.white)
        )
    }
}
