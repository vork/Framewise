import SwiftUI
import AVFoundation
import CoreImage
import CoreGraphics

// MARK: - Model

enum TemporalMetric: Int, CaseIterable, Identifiable {
    case mae = 0, psnr = 1, vmaf = 2
    case vif = 3, adm = 4, motion = 5, cambi = 6
    var id: Int { rawValue }
    var label: String {
        switch self {
        case .mae:    return "MAE"
        case .psnr:   return "PSNR"
        case .vmaf:   return "VMAF"
        case .vif:    return "VIF"
        case .adm:    return "ADM"
        case .motion: return "Motion"
        case .cambi:  return "CAMBI"
        }
    }
    /// True when a higher value is better (so "events" are the low points).
    var higherIsBetter: Bool {
        switch self {
        case .mae, .cambi: return false
        case .psnr, .vmaf, .vif, .adm, .motion: return true
        }
    }
    /// Whether this metric requires the VMAF/libvmaf pipeline.
    var requiresVMAF: Bool { rawValue >= 2 }
}

enum TemporalScanMode: Int, CaseIterable, Identifiable {
    case sampled = 0
    case aroundSpikes = 1
    case everyFrame = 2
    var id: Int { rawValue }
}

extension MediaEngine {
    /// Whether VMAF support was compiled in (libvmaf bundled — see README).
    var vmafAvailable: Bool {
        #if FRAMEWISE_VMAF
        return true
        #else
        return false
        #endif
    }
}

/// What feeds frames for one side of a temporal scan.
enum TemporalSource {
    case video(AVAsset, Double)     // asset, fps
    case sequence([URL], Double)    // frame urls, fps
    case still(CIImage)
    case empty
}

/// Per-frame error curve across the whole timeline.
struct TemporalSeries {
    var times: [Double]
    var values: [Float]
    var events: [Int]      // indices of the worst frames, worst first
    var worst: Int?
    var metric: TemporalMetric
}

// MARK: - Analyzer

enum TemporalAnalyzer {
    /// Best-effort cancellation flag shared between the main actor and the scan.
    final class Cancel { var cancelled = false }

    private static let gridW = 128
    private static let gridH = 72

    static func scan(sourceA: TemporalSource, sourceB: TemporalSource,
                     duration: Double, fps: Double, detailed: Bool,
                     metric: TemporalMetric, cancel: Cancel,
                     progress: @escaping (Double) -> Void) -> TemporalSeries? {
        guard duration > 0, fps > 0 else { return nil }

        // VMAF-based metrics need the libvmaf pipeline (stateful, consecutive frames).
        if metric.requiresVMAF {
            #if FRAMEWISE_VMAF
            return VMAFEngine.scan(sourceA: sourceA, sourceB: sourceB,
                                   duration: duration, fps: fps,
                                   metric: metric,
                                   cancel: cancel, progress: progress)
            #else
            return nil
            #endif
        }

        let total = max(2, Int((duration * fps).rounded()))
        // Scale sample count with duration: ~4 samples/sec for short clips,
        // tapering to ~2/sec for long ones. Floor 60, cap at 600.
        let sampledCount = detailed ? total : min(total, max(60, min(600, Int(duration * 3.0))))
        let count = sampledCount

        let provA = makeProvider(sourceA)
        let provB = makeProvider(sourceB)

        var times = [Double](); times.reserveCapacity(count)
        var values = [Float](); values.reserveCapacity(count)

        for i in 0..<count {
            if cancel.cancelled { return nil }
            let t = duration * Double(i) / Double(count - 1)
            guard let ba = provA(t), let bb = provB(t) else { continue }
            let d = diff(ba, bb)
            let v: Float = (metric == .psnr)
                ? (d.mse > 1e-9 ? Float(10.0 * log10(1.0 / Double(d.mse))) : 99.0)
                : d.mae
            times.append(t)
            values.append(v)
            if i % 8 == 0 { progress(Double(i + 1) / Double(count)) }
        }
        guard values.count >= 2 else { return nil }
        let events = computeEvents(values, metric: metric)
        return TemporalSeries(times: times, values: values,
                              events: events, worst: events.first, metric: metric)
    }

    /// Dense scan around spikes from a previous (sampled) series. Densely
    /// samples +/- 2 seconds around each event, merged with the original
    /// coarse samples to give a high-resolution view near problem areas
    /// without scanning the entire video.
    static func scanAroundSpikes(sourceA: TemporalSource, sourceB: TemporalSource,
                                 duration: Double, fps: Double,
                                 metric: TemporalMetric, baseSeries: TemporalSeries,
                                 cancel: Cancel,
                                 progress: @escaping (Double) -> Void) -> TemporalSeries? {
        guard duration > 0, fps > 0 else { return nil }

        if metric.requiresVMAF {
            #if FRAMEWISE_VMAF
            return VMAFEngine.scan(sourceA: sourceA, sourceB: sourceB,
                                   duration: duration, fps: fps,
                                   metric: metric, cancel: cancel, progress: progress)
            #else
            return nil
            #endif
        }

        let provA = makeProvider(sourceA)
        let provB = makeProvider(sourceB)

        // Collect times to sample: base series + dense around each event.
        var sampleTimes = Set(baseSeries.times)
        let radius = 2.0  // seconds around each spike
        let denseStep = 1.0 / fps  // every frame within the radius
        for e in baseSeries.events where e < baseSeries.times.count {
            let center = baseSeries.times[e]
            let lo = max(0, center - radius)
            let hi = min(duration, center + radius)
            var t = lo
            while t <= hi {
                sampleTimes.insert(t)
                t += denseStep
            }
        }

        let sortedTimes = sampleTimes.sorted()
        var times = [Double](); times.reserveCapacity(sortedTimes.count)
        var values = [Float](); values.reserveCapacity(sortedTimes.count)

        for (i, t) in sortedTimes.enumerated() {
            if cancel.cancelled { return nil }
            guard let ba = provA(t), let bb = provB(t) else { continue }
            let d = diff(ba, bb)
            let v: Float = (metric == .psnr)
                ? (d.mse > 1e-9 ? Float(10.0 * log10(1.0 / Double(d.mse))) : 99.0)
                : d.mae
            times.append(t)
            values.append(v)
            if i % 8 == 0 { progress(Double(i + 1) / Double(sortedTimes.count)) }
        }
        guard values.count >= 2 else { return nil }
        let events = computeEvents(values, metric: metric)
        return TemporalSeries(times: times, values: values,
                              events: events, worst: events.first, metric: metric)
    }

    /// Build a closure that yields the downscaled RGBA8 grid for a side at time t.
    private static func makeProvider(_ source: TemporalSource) -> (Double) -> [UInt8]? {
        switch source {
        case .video(let asset, _):
            let gen = AVAssetImageGenerator(asset: asset)
            gen.appliesPreferredTrackTransform = true
            gen.maximumSize = CGSize(width: gridW * 2, height: gridW * 2)
            gen.requestedTimeToleranceBefore = .zero
            gen.requestedTimeToleranceAfter = CMTime(seconds: 0.05, preferredTimescale: 600)
            return { t in
                guard let cg = try? gen.copyCGImage(
                    at: CMTime(seconds: t, preferredTimescale: 600), actualTime: nil)
                else { return nil }
                return draw(cg)
            }
        case .sequence(let urls, let fps):
            let ctx = ScopeSampler.context
            return { t in
                guard !urls.isEmpty else { return nil }
                let idx = max(0, min(urls.count - 1, Int((t * fps).rounded())))
                guard let ci = CIImage(contentsOf: urls[idx]),
                      let cg = ctx.createCGImage(ci, from: ci.extent) else { return nil }
                return draw(cg)
            }
        case .still(let ci):
            let ctx = ScopeSampler.context
            let buf = ctx.createCGImage(ci, from: ci.extent).flatMap { draw($0) }
            return { _ in buf }   // constant across time
        case .empty:
            return { _ in nil }
        }
    }

    /// Draw a CGImage into the fixed comparison grid and return its bytes.
    private static func draw(_ cg: CGImage) -> [UInt8]? {
        var px = [UInt8](repeating: 0, count: gridW * gridH * 4)
        let cs = CGColorSpaceCreateDeviceRGB()
        let info = CGImageAlphaInfo.premultipliedLast.rawValue
        let ok = px.withUnsafeMutableBytes { ptr -> Bool in
            guard let base = ptr.baseAddress,
                  let ctx = CGContext(data: base, width: gridW, height: gridH,
                                      bitsPerComponent: 8, bytesPerRow: gridW * 4,
                                      space: cs, bitmapInfo: info) else { return false }
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: gridW, height: gridH))
            return true
        }
        return ok ? px : nil
    }

    private static func diff(_ a: [UInt8], _ b: [UInt8]) -> (mae: Float, mse: Float) {
        let n = min(a.count, b.count)
        guard n > 0 else { return (0, 0) }
        var sumAbs = 0.0, sumSq = 0.0, cnt = 0
        var i = 0
        while i + 3 < n {
            for c in 0..<3 {                 // RGB only, skip alpha
                let d = Double(a[i + c]) - Double(b[i + c])
                sumAbs += abs(d); sumSq += d * d; cnt += 1
            }
            i += 4
        }
        guard cnt > 0 else { return (0, 0) }
        return (Float(sumAbs / Double(cnt) / 255.0),
                Float(sumSq / Double(cnt) / (255.0 * 255.0)))
    }

    /// Worst frames with non-maximum suppression so events spread across the
    /// timeline instead of clustering on one spike.
    static func computeEvents(_ values: [Float], metric: TemporalMetric) -> [Int] {
        let badness: [Float] = metric.higherIsBetter ? values.map { -$0 } : values
        let order = badness.indices.sorted { badness[$0] > badness[$1] }
        let spacing = max(1, values.count / 24)
        var picked: [Int] = []
        for idx in order {
            if picked.allSatisfy({ abs($0 - idx) >= spacing }) {
                picked.append(idx)
                if picked.count >= 6 { break }
            }
        }
        return picked
    }
}

// MARK: - Strip UI

struct TemporalStrip: View {
    @ObservedObject var engine: MediaEngine

    var body: some View {
        VStack(spacing: 4) {
            header
            graph
                .frame(height: 90)
        }
        .padding(.horizontal, 12)
        .padding(.top, 6)
        .padding(.bottom, 4)
        .background(Theme.panel)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "chart.xyaxis.line")
                .font(.system(size: 11))
                .foregroundStyle(Theme.accentA)
            Text("Error over time")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.text)

            Picker("Metric", selection: $engine.temporalMetric) {
                ForEach(TemporalMetric.allCases.filter { !$0.requiresVMAF || engine.vmafAvailable }) { m in
                    Text(m.label).tag(m)
                }
            }
            .frame(width: 110)
            .onChange(of: engine.temporalMetric) {
                engine.invalidateTemporalSeries()
                engine.runTemporalScan()
            }

            Picker("", selection: $engine.temporalScanMode) {
                Text("Sampled").tag(TemporalScanMode.sampled)
                Text("Around spikes").tag(TemporalScanMode.aroundSpikes)
                Text("Every frame").tag(TemporalScanMode.everyFrame)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 220)

            Button {
                if engine.isScanningTemporal { engine.cancelTemporalScan() }
                else { engine.runTemporalScan() }
            } label: {
                HStack(spacing: 4) {
                    if engine.isScanningTemporal {
                        ProgressView().controlSize(.mini)
                        Text("\(Int(engine.temporalProgress * 100))%")
                    } else {
                        Image(systemName: "arrow.clockwise")
                        Text(engine.temporalSeries == nil ? "Scan" : "Rescan")
                    }
                }
                .font(.system(size: 11, weight: .medium))
            }
            .buttonStyle(GhostButtonStyle())

            Spacer()

            if let s = engine.temporalSeries, let w = s.worst, w < s.times.count {
                Button {
                    engine.seekToPosition(s.times[w] / max(0.0001, engine.duration))
                } label: {
                    Text("Worst → \(timeStr(s.times[w]))")
                        .font(.system(size: 10, design: .monospaced))
                }
                .buttonStyle(GhostButtonStyle())
            }

            Button { engine.temporalOpen = false } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.white.opacity(0.6))
                    .frame(width: 16, height: 16)
                    .background(Theme.panel2, in: Circle())
            }
            .buttonStyle(.plain)
            .help("Close temporal graph (T)")
        }
    }

    private var graph: some View {
        GeometryReader { proxy in
            let size = proxy.size
            ZStack {
                RoundedRectangle(cornerRadius: 6).fill(Color.black)
                RoundedRectangle(cornerRadius: 6).stroke(Theme.border, lineWidth: 1)

                if engine.temporalMetric.requiresVMAF && !engine.vmafAvailable {
                    Text("VMAF not compiled in — rebuild with libvmaf (see README).")
                        .font(.system(size: 11)).foregroundStyle(Theme.muted)
                } else if let s = engine.temporalSeries, s.values.count >= 2 {
                    plot(s, size: size)
                } else if engine.isScanningTemporal {
                    Text("Scanning…").font(.system(size: 11)).foregroundStyle(Theme.muted)
                } else {
                    Text("Scan to chart \(engine.temporalMetric.label) per frame")
                        .font(.system(size: 11)).foregroundStyle(Theme.muted)
                }
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { g in
                    let inset: CGFloat = 4
                    let frac = max(0, min(1, (g.location.x - inset) / max(1, size.width - inset * 2)))
                    engine.seekToPosition(frac)
                }
                .onEnded { g in
                    let inset: CGFloat = 4
                    let w = size.width - inset * 2
                    // Snap to nearest event dot if within 10pt
                    if let s = engine.temporalSeries, s.values.count >= 2, engine.duration > 0 {
                        for e in s.events where e < s.times.count {
                            let dotX = inset + CGFloat(e) / CGFloat(s.values.count - 1) * w
                            if abs(g.location.x - dotX) < 10 {
                                engine.seekToPosition(s.times[e] / max(0.0001, engine.duration))
                                return
                            }
                        }
                    }
                    let frac = max(0, min(1, (g.location.x - inset) / max(1, w)))
                    engine.seekToPosition(frac)
                }
            )
        }
    }

    private func plot(_ s: TemporalSeries, size: CGSize) -> some View {
        // Plain func (no @ViewBuilder) so the nested `point` helper's `return`
        // doesn't get attributed to the result builder context — that pattern
        // confused the compiler into reporting the body as having no return
        // statements at all.
        let lo = s.values.min() ?? 0
        let hi = s.values.max() ?? 1
        let span = max(1e-5, hi - lo)
        let inset: CGFloat = 4
        let w = size.width - inset * 2
        let h = size.height - inset * 2

        func point(_ i: Int) -> CGPoint {
            let x = inset + CGFloat(i) / CGFloat(s.values.count - 1) * w
            // Normalize; for PSNR higher is better so flip so dips read as bad.
            let norm = CGFloat((s.values[i] - lo) / span)
            let y = inset + (1 - norm) * h
            return CGPoint(x: x, y: y)
        }

        return ZStack {
            Canvas { ctx, _ in
                var line = Path()
                for i in 0..<s.values.count {
                    let p = point(i)
                    if i == 0 { line.move(to: p) } else { line.addLine(to: p) }
                }
                var fill = line
                fill.addLine(to: CGPoint(x: inset + w, y: inset + h))
                fill.addLine(to: CGPoint(x: inset, y: inset + h))
                fill.closeSubpath()
                ctx.fill(fill, with: .linearGradient(
                    Gradient(colors: [Theme.accentA.opacity(0.35), Theme.accentA.opacity(0.02)]),
                    startPoint: CGPoint(x: 0, y: inset),
                    endPoint: CGPoint(x: 0, y: inset + h)))
                ctx.stroke(line, with: .color(Theme.accentA), lineWidth: 1.5)

                // Worst-error event markers.
                for e in s.events where e < s.values.count {
                    let p = point(e)
                    let r = CGRect(x: p.x - 3, y: p.y - 3, width: 6, height: 6)
                    ctx.fill(Path(ellipseIn: r), with: .color(Theme.err))
                }

                // Playhead.
                if engine.duration > 0 {
                    let px = inset + CGFloat(engine.currentTime / engine.duration) * w
                    var ph = Path()
                    ph.move(to: CGPoint(x: px, y: inset))
                    ph.addLine(to: CGPoint(x: px, y: inset + h))
                    ctx.stroke(ph, with: .color(.white.opacity(0.5)), lineWidth: 1)
                }
            }
        }
    }

    private func timeStr(_ s: Double) -> String {
        guard s.isFinite, s >= 0 else { return "0:00" }
        let m = Int(s) / 60, sec = Int(s) % 60
        return String(format: "%d:%02d", m, sec)
    }
}
