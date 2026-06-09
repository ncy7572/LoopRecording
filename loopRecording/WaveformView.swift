import SwiftUI

// MARK: - Amplitude scaling

/// A robust display reference for the waveform. Using the single loudest bar
/// (a lone clap/tap) as the reference flattens all quieter audio to a near-flat
/// line; a high percentile of the non-silent bars ignores such outliers so the
/// bulk of the recording stays visible and the scale is stable frame-to-frame.
func waveformReference(_ amps: [Float]) -> Double {
    var vals = amps.compactMap { $0 > 0.0001 ? Double($0) : nil }
    guard !vals.isEmpty else { return 1 }
    vals.sort()
    let pct = vals[Int(Double(vals.count - 1) * 0.95)]
    return max(pct, 0.02)   // floor avoids over-amplifying near-silence
}

/// Maps a bucket amplitude to a 0...1 bar level. The square root gives quiet
/// sounds a visible height while keeping loud (clipped) sounds bounded.
func waveformLevel(_ amp: Float, reference: Double) -> Double {
    min(1.0, Double(amp) / reference).squareRoot()
}

// MARK: - WaveformView

struct WaveformView: View {
    let amplitudes: [Float]         // waveformPoints values, oldest -> newest
    let filledFraction: Double      // 0-1 of totalSeconds that has been recorded
    let playheadFraction: Double    // 0-1 of totalSeconds
    let totalSeconds: Double
    let isAtLiveEdge: Bool

    var onScrub: (Double) -> Void
    var onScrubEnd: (Double) -> Void
    /// Called when the user taps (not drags) the waveform - should jump to that position and play.
    var onSeekTap: ((Double) -> Void)?

    var body: some View {
        VStack(spacing: 0) {
            DetailWaveView(
                amplitudes: amplitudes,
                filledFraction: filledFraction,
                playheadFraction: playheadFraction,
                totalSeconds: totalSeconds,
                isAtLiveEdge: isAtLiveEdge,
                onScrub: onScrub,
                onScrubEnd: onScrubEnd,
                onSeekTap: onSeekTap
            )

            Rectangle()
                .fill(Color(white: 0.18))
                .frame(height: 1)

            OverviewWaveView(
                amplitudes: amplitudes,
                filledFraction: filledFraction,
                playheadFraction: playheadFraction,
                onScrub: onScrub,
                onScrubEnd: onScrubEnd,
                onSeekTap: onSeekTap
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
    
    let isAtLiveEdge: Bool
    
    var onScrub: (Double) -> Void
    var onScrubEnd: (Double) -> Void
    var onSeekTap: ((Double) -> Void)?

    private let bucketWidth: CGFloat = 7

    @State private var dragBaseFraction: Double? = nil

    private let green = Color(red: 0.20, green: 0.85, blue: 0.55)
    private let greenDim = Color(red: 0.12, green: 0.40, blue: 0.28)
    private let red = Color(red: 1.00, green: 0.35, blue: 0.35)

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            let pw = bucketWidth

            let playheadPt = CGFloat(playheadFraction) * CGFloat(amplitudes.count)
            let contentOffset = playheadPt * pw - w / 2
            let filledPt = CGFloat(filledFraction) * CGFloat(amplitudes.count)
            let phColor = isAtLiveEdge ? red : Color.white

            ZStack {
                Canvas { ctx, size in
                    drawBars(
                        ctx: ctx,
                        size: size,
                        offset: contentOffset,
                        pw: pw,
                        playheadPt: playheadPt,
                        filledPt: filledPt
                    )
                    drawTimeLabels(ctx: ctx, size: size, offset: contentOffset, pw: pw)
                }

                Rectangle()
                    .fill(phColor)
                    .frame(width: 2)
                    .frame(maxHeight: .infinity)
                    .position(x: w / 2, y: h / 2)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { v in
                        let n = Double(amplitudes.count)
                        guard v.translation.width.magnitude > 4 || dragBaseFraction != nil else { return }
                        if dragBaseFraction == nil { dragBaseFraction = playheadFraction }
                        let base = dragBaseFraction!
                        let delta = -Double(v.translation.width / pw) / n
                        onScrub(max(0, min(filledFraction, base + delta)))
                    }
                    .onEnded { v in
                        let n = Double(amplitudes.count)
                        let toFrac = { (x: CGFloat) -> Double in
                            max(0, min(filledFraction,
                                (Double(x) + Double(contentOffset)) / Double(pw) / n))
                        }
                        let isTap = v.translation.width.magnitude < 6 && v.translation.height.magnitude < 6

                        if isTap {
                            onSeekTap?(toFrac(v.location.x))
                        } else {
                            let base = dragBaseFraction ?? playheadFraction
                            let delta = -Double(v.translation.width / pw) / n
                            onScrubEnd(max(0, min(filledFraction, base + delta)))
                        }
                        dragBaseFraction = nil
                    }
            )
        }
    }

    private func drawBars(
        ctx: GraphicsContext,
        size: CGSize,
        offset: CGFloat,
        pw: CGFloat,
        playheadPt: CGFloat,
        filledPt: CGFloat
    ) {
        let labelAreaH: CGFloat = 20
        let h = size.height - labelAreaH
        let mid = h / 2
        let w = size.width

        let reference = waveformReference(amplitudes)
        let barW = pw * 0.6

        let startIdx = max(0, Int(offset / pw) - 1)
        let endIdx = min(amplitudes.count - 1, Int((offset + w) / pw) + 1)
        guard startIdx <= endIdx else { return }

        for i in startIdx...endIdx {
            guard CGFloat(i) < filledPt else { continue }
            let x = CGFloat(i) * pw - offset
            let level = waveformLevel(amplitudes[i], reference: reference)
            let halfH = CGFloat(max(2, level * Double(mid) * 0.88))
            let color = CGFloat(i) < playheadPt ? green : greenDim
            ctx.fill(
                Path(CGRect(x: x, y: mid - halfH, width: barW, height: halfH * 2)),
                with: .color(color)
            )
        }
    }

    private func drawTimeLabels(ctx: GraphicsContext, size: CGSize, offset: CGFloat, pw: CGFloat) {
        let h = size.height
        let w = size.width
        let n = Double(amplitudes.count)
        let barsPerMarker = 10.0

        let secondsPerPoint = totalSeconds / n

        let leftPt = Double(offset / pw)
        let rightPt = Double((offset + w) / pw)
        let firstMarker = Int(ceil(leftPt / barsPerMarker)) * Int(barsPerMarker)
        let lastMarker = Int(floor(rightPt / barsPerMarker)) * Int(barsPerMarker)
        guard firstMarker <= lastMarker else { return }

        for marker in stride(from: firstMarker, through: lastMarker, by: Int(barsPerMarker)) {
            guard marker >= 0 else { continue }
            let pt = Double(marker)
            guard pt / n <= filledFraction else { continue }

            let x = CGFloat(pt) * pw - offset
            let filledPt = filledFraction * n
            let offsetSecs = Int((pt - filledPt) * secondsPerPoint)

            ctx.fill(
                Path(CGRect(x: x - 0.5, y: h - 18, width: 1, height: 5)),
                with: .color(.gray.opacity(0.5))
            )
            ctx.draw(
                Text(formatOffset(offsetSecs))
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundColor(.gray),
                at: CGPoint(x: x, y: h - 8),
                anchor: .center
            )
        }
    }

    private func formatOffset(_ seconds: Int) -> String {
        let abs = Swift.abs(seconds)
        let h = abs / 3600
        let m = (abs % 3600) / 60
        let s = abs % 60
        let sign = seconds < 0 ? "-" : ""
        return String(format: "%@%02d:%02d:%02d", sign, h, m, s)
    }
}

// MARK: - Overview (full buffer, tap/drag to seek)

private struct OverviewWaveView: View {
    let amplitudes: [Float]
    let filledFraction: Double
    let playheadFraction: Double
    var onScrub: (Double) -> Void
    var onScrubEnd: (Double) -> Void
    var onSeekTap: ((Double) -> Void)?

    private let green = Color(red: 0.20, green: 0.85, blue: 0.55)
    private let greenDim = Color(red: 0.12, green: 0.40, blue: 0.28)

    var body: some View {
        GeometryReader { geo in
            Canvas { ctx, size in
                drawOverview(ctx: ctx, size: size)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { v in
                        let isTap = v.translation.width.magnitude < 6 && v.translation.height.magnitude < 6
                        if !isTap {
                            let f = Double(v.location.x / geo.size.width)
                            onScrub(max(0, min(filledFraction, f)))
                        }
                    }
                    .onEnded { v in
                        let isTap = v.translation.width.magnitude < 6 && v.translation.height.magnitude < 6
                        let f = Double(v.location.x / geo.size.width)
                        let clamped = max(0, min(filledFraction, f))
                        if isTap {
                            if let onSeekTap {
                                onSeekTap(clamped)
                            } else {
                                onScrub(clamped)
                                onScrubEnd(clamped)
                            }
                        } else {
                            onScrubEnd(clamped)
                        }
                    }
            )
        }
    }

    private func drawOverview(ctx: GraphicsContext, size: CGSize) {
        let w = size.width
        let h = size.height
        let mid = h / 2
        let n = amplitudes.count
        guard n > 0 else { return }

        let bw = w / CGFloat(n)
        let reference = waveformReference(amplitudes)
        let filledX = CGFloat(filledFraction) * w
        let phX = CGFloat(playheadFraction) * w

        for i in 0..<n {
            let x = CGFloat(i) * bw
            guard x <= filledX else { break }
            let level = waveformLevel(amplitudes[i], reference: reference)
            let halfH = CGFloat(max(0.5, level * Double(mid) * 0.85))
            ctx.fill(
                Path(CGRect(
                    x: x,
                    y: mid - halfH,
                    width: max(0.5, bw * 0.7),
                    height: halfH * 2
                )),
                with: .color(x < phX ? green : greenDim)
            )
        }

        ctx.fill(
            Path(CGRect(x: phX - 1, y: 0, width: 2, height: h)),
            with: .color(.white)
        )
    }
}
