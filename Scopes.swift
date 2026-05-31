import SwiftUI
import CoreImage
import CoreGraphics

// MARK: - Scope model

enum ScopeMode: Int, CaseIterable, Identifiable {
    case histogram = 0, waveform = 1, vectorscope = 2
    var id: Int { rawValue }
    var label: String {
        switch self {
        case .histogram:   return "Histogram"
        case .waveform:    return "Waveform"
        case .vectorscope: return "Vectorscope"
        }
    }
}

/// Computed scope data for one side. Histograms are kept as normalized arrays
/// (drawn live with Canvas); waveform and vectorscope are pre-rasterized to
/// CGImages off the main thread since they're dense 2-D accumulations.
struct ScopeData {
    var histR: [Float]   // 256 bins, normalized 0…1
    var histG: [Float]
    var histB: [Float]
    var histL: [Float]
    var waveform: CGImage?
    var vectorscope: CGImage?
}

// MARK: - Sampler

enum ScopeSampler {
    /// GPU-backed context, working in linear sRGB; render target is 8-bit sRGB
    /// so histogram bins map straight to display code values.
    static let context = CIContext(options: [
        .workingColorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!,
        .cacheIntermediates: false,
    ])
    static let targetW = 256
    static let valueBins = 256
    static let vecN = 256

    static func compute(_ image: CIImage) -> ScopeData? {
        let ext = image.extent
        guard ext.width > 0, ext.height > 0, ext.width.isFinite, ext.height.isFinite else { return nil }

        let w = targetW
        let h = max(1, min(256, Int((Double(targetW) * ext.height / ext.width).rounded())))

        var img = image
        if ext.origin != .zero {
            img = img.transformed(by: CGAffineTransform(translationX: -ext.origin.x, y: -ext.origin.y))
        }
        img = img.transformed(by: CGAffineTransform(scaleX: CGFloat(w) / max(ext.width, 1),
                                                    y: CGFloat(h) / max(ext.height, 1)))

        let rowBytes = w * 4
        var buf = [UInt8](repeating: 0, count: rowBytes * h)
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        buf.withUnsafeMutableBytes { ptr in
            guard let base = ptr.baseAddress else { return }
            context.render(img, toBitmap: base, rowBytes: rowBytes,
                           bounds: CGRect(x: 0, y: 0, width: w, height: h),
                           format: .RGBA8, colorSpace: cs)
        }

        var hR = [Int](repeating: 0, count: 256)
        var hG = [Int](repeating: 0, count: 256)
        var hB = [Int](repeating: 0, count: 256)
        var hL = [Int](repeating: 0, count: 256)
        var wave = [Float](repeating: 0, count: w * valueBins)
        var vec  = [Float](repeating: 0, count: vecN * vecN)

        for y in 0..<h {
            let row = y * rowBytes
            for x in 0..<w {
                let i = row + x * 4
                let r = Int(buf[i]), g = Int(buf[i + 1]), b = Int(buf[i + 2])
                hR[r] += 1; hG[g] += 1; hB[b] += 1
                let l = min(255, Int(0.2126 * Double(r) + 0.7152 * Double(g) + 0.0722 * Double(b)))
                hL[l] += 1
                // Waveform: column x, luma → row (high values at top).
                wave[(valueBins - 1 - l) * w + x] += 1
                // Vectorscope: Cb/Cr chroma plane.
                let rf = Double(r) / 255, gf = Double(g) / 255, bf = Double(b) / 255
                let cb = -0.168736 * rf - 0.331264 * gf + 0.5 * bf      // [-0.5, 0.5]
                let cr =  0.5 * rf - 0.418688 * gf - 0.081312 * bf      // [-0.5, 0.5]
                let vx = Int((cb + 0.5) * Double(vecN - 1))
                let vy = Int((0.5 - cr) * Double(vecN - 1))             // Cr points up
                if vx >= 0, vx < vecN, vy >= 0, vy < vecN { vec[vy * vecN + vx] += 1 }
            }
        }

        let maxH = Float(max(1, [hR.max() ?? 1, hG.max() ?? 1, hB.max() ?? 1, hL.max() ?? 1].max() ?? 1))
        func norm(_ a: [Int]) -> [Float] { a.map { Float($0) / maxH } }

        // Normalize the 2-D accumulations with a sqrt so sparse points stay
        // visible against dense clusters, then rasterize.
        let waveMax = max(1, wave.max() ?? 1)
        let vecMax  = max(1, vec.max() ?? 1)
        let waveImg = makeImage(width: w, height: valueBins,
                                intensity: wave.map { sqrt($0 / waveMax) },
                                r: 0.4, g: 1.0, b: 0.55)
        let vecImg  = makeImage(width: vecN, height: vecN,
                                intensity: vec.map { sqrt($0 / vecMax) },
                                r: 0.55, g: 1.0, b: 0.7)

        return ScopeData(histR: norm(hR), histG: norm(hG), histB: norm(hB), histL: norm(hL),
                         waveform: waveImg, vectorscope: vecImg)
    }

    private static func makeImage(width: Int, height: Int, intensity: [Float],
                                  r: Double, g: Double, b: Double) -> CGImage? {
        guard width > 0, height > 0, intensity.count == width * height else { return nil }
        var px = [UInt8](repeating: 0, count: width * height * 4)
        for i in 0..<(width * height) {
            let v = min(1.0, Double(intensity[i]))
            px[i * 4 + 0] = UInt8(v * r * 255)
            px[i * 4 + 1] = UInt8(v * g * 255)
            px[i * 4 + 2] = UInt8(v * b * 255)
            px[i * 4 + 3] = 255
        }
        let cs = CGColorSpaceCreateDeviceRGB()
        let info = CGImageAlphaInfo.premultipliedLast.rawValue
        return px.withUnsafeMutableBytes { ptr -> CGImage? in
            guard let base = ptr.baseAddress,
                  let ctx = CGContext(data: base, width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: cs, bitmapInfo: info) else { return nil }
            return ctx.makeImage()
        }
    }
}

// MARK: - Panel

struct ScopesPanel: View {
    @ObservedObject var engine: MediaEngine

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.2)
            HStack(spacing: 10) {
                scopeColumn("A", color: Theme.sideA, data: engine.scopeDataA,
                            present: engine.hasMediaA)
                scopeColumn("B", color: Theme.sideB, data: engine.scopeDataB,
                            present: engine.hasMediaB)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .frame(height: 196)
        .background(Theme.panel)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "waveform")
                .foregroundStyle(Theme.accentA)
                .font(.system(size: 13))
            Text("Scopes")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.text)

            Picker("", selection: $engine.scopeMode) {
                ForEach(ScopeMode.allCases) { m in Text(m.label).tag(m) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 280)
            .padding(.leading, 6)

            Spacer()

            Button { engine.scopesOpen = false } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.white.opacity(0.6))
                    .frame(width: 18, height: 18)
                    .background(Theme.panel2, in: Circle())
                    .overlay(Circle().stroke(Theme.border, lineWidth: 1))
            }
            .buttonStyle(.plain)
            .help("Close scopes (S)")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    @ViewBuilder
    private func scopeColumn(_ label: String, color: Color, data: ScopeData?, present: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 5) {
                Circle().fill(color).frame(width: 7, height: 7)
                Text(label)
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Theme.text.opacity(0.85))
            }
            ZStack {
                RoundedRectangle(cornerRadius: 6).fill(Color.black)
                RoundedRectangle(cornerRadius: 6).stroke(Theme.border, lineWidth: 1)
                if !present {
                    Text("—").foregroundStyle(Theme.muted)
                } else if let data {
                    scopeContent(data)
                        .padding(6)
                } else {
                    ProgressView().controlSize(.small)
                }
            }
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private func scopeContent(_ data: ScopeData) -> some View {
        switch engine.scopeMode {
        case .histogram:
            HistogramView(data: data)
        case .waveform:
            if let img = data.waveform {
                Image(decorative: img, scale: 1)
                    .resizable()
                    .interpolation(.low)
            }
        case .vectorscope:
            if let img = data.vectorscope {
                Image(decorative: img, scale: 1)
                    .resizable()
                    .interpolation(.low)
                    .aspectRatio(1, contentMode: .fit)
            }
        }
    }
}

/// RGB-overlaid histogram drawn with additive (screen) blending, plus a luma
/// outline. Cheap enough to redraw live (256 bins per channel).
private struct HistogramView: View {
    let data: ScopeData

    var body: some View {
        Canvas { ctx, size in
            func area(_ h: [Float]) -> Path {
                var p = Path()
                guard h.count > 1 else { return p }
                p.move(to: CGPoint(x: 0, y: size.height))
                for x in 0..<h.count {
                    let px = CGFloat(x) / CGFloat(h.count - 1) * size.width
                    let py = size.height - CGFloat(min(1, h[x])) * size.height
                    p.addLine(to: CGPoint(x: px, y: py))
                }
                p.addLine(to: CGPoint(x: size.width, y: size.height))
                p.closeSubpath()
                return p
            }
            ctx.blendMode = .screen
            ctx.fill(area(data.histR), with: .color(Color(red: 1, green: 0.2, blue: 0.2).opacity(0.7)))
            ctx.fill(area(data.histG), with: .color(Color(red: 0.2, green: 1, blue: 0.3).opacity(0.7)))
            ctx.fill(area(data.histB), with: .color(Color(red: 0.3, green: 0.5, blue: 1).opacity(0.7)))
            ctx.blendMode = .normal
            ctx.stroke(area(data.histL), with: .color(.white.opacity(0.35)), lineWidth: 1)
        }
    }
}
