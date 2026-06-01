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
    var waveformWhite: CGImage?
    var vectorscopeWhite: CGImage?
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
        let waveNorm = wave.map { sqrt($0 / waveMax) }
        let vecNorm  = vec.map { sqrt($0 / vecMax) }
        let waveImg = makeImage(width: w, height: valueBins, intensity: waveNorm,
                                r: 0.4, g: 1.0, b: 0.55)
        let vecImg  = makeImage(width: vecN, height: vecN, intensity: vecNorm,
                                r: 0.55, g: 1.0, b: 0.7)
        let waveWhite = makeImage(width: w, height: valueBins, intensity: waveNorm,
                                  r: 1.0, g: 1.0, b: 1.0)
        let vecWhite  = makeImage(width: vecN, height: vecN, intensity: vecNorm,
                                  r: 1.0, g: 1.0, b: 1.0)

        return ScopeData(histR: norm(hR), histG: norm(hG), histB: norm(hB), histL: norm(hL),
                         waveform: waveImg, vectorscope: vecImg,
                         waveformWhite: waveWhite, vectorscopeWhite: vecWhite)
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

    private var isComparisonMode: Bool {
        engine.displayMode == .error && engine.hasMediaA && engine.hasMediaB
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.2)
            if isComparisonMode {
                comparisonScope
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
            } else {
                HStack(spacing: 10) {
                    scopeColumn("A", color: Theme.sideA, data: engine.scopeDataA,
                                present: engine.hasMediaA)
                    scopeColumn("B", color: Theme.sideB, data: engine.scopeDataB,
                                present: engine.hasMediaB)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var comparisonScope: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6).fill(Color.black)
            RoundedRectangle(cornerRadius: 6).stroke(Theme.border, lineWidth: 1)
            if let dataA = engine.scopeDataA, let dataB = engine.scopeDataB {
                switch engine.scopeMode {
                case .histogram:
                    ComparisonHistogramView(dataA: dataA, dataB: dataB)
                        .padding(6)
                case .waveform:
                    ComparisonWaveformView(imageA: dataA.waveformWhite, imageB: dataB.waveformWhite)
                        .padding(6)
                case .vectorscope:
                    ComparisonVectorscopeView(imageA: dataA.vectorscopeWhite, imageB: dataB.vectorscopeWhite)
                        .padding(6)
                }
            } else {
                ProgressView().controlSize(.small)
            }
        }
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
                WaveformView(image: img)
            }
        case .vectorscope:
            if let img = data.vectorscope {
                VectorscopeView(image: img)
            }
        }
    }
}

/// Single-side scope panel used in split mode — one per video side.
struct SingleScopePanel: View {
    @ObservedObject var engine: MediaEngine
    let side: MediaSide
    let panelSize: CGSize

    private var sideLabel: String { side == .a ? "A" : "B" }
    private var sideColor: Color { side == .a ? Theme.sideA : Theme.sideB }
    private var data: ScopeData? { side == .a ? engine.scopeDataA : engine.scopeDataB }
    private var present: Bool { side == .a ? engine.hasMediaA : engine.hasMediaB }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.2)
            ZStack {
                RoundedRectangle(cornerRadius: 6).fill(Color.black)
                RoundedRectangle(cornerRadius: 6).stroke(Theme.border, lineWidth: 1)
                if !present {
                    Text("—").foregroundStyle(Theme.muted)
                } else if let data {
                    scopeContent(data).padding(6)
                } else {
                    ProgressView().controlSize(.small)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
        }
        .frame(width: panelSize.width, height: panelSize.height)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Circle().fill(sideColor).frame(width: 8, height: 8)
            Text(sideLabel)
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundStyle(Theme.text)

            Picker("", selection: $engine.scopeMode) {
                ForEach(ScopeMode.allCases) { m in Text(m.label).tag(m) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 200)

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
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
    }

    @ViewBuilder
    private func scopeContent(_ data: ScopeData) -> some View {
        switch engine.scopeMode {
        case .histogram:
            HistogramView(data: data)
        case .waveform:
            if let img = data.waveform { WaveformView(image: img) }
        case .vectorscope:
            if let img = data.vectorscope { VectorscopeView(image: img) }
        }
    }
}

/// RGB-overlaid histogram drawn with additive (screen) blending, plus a luma
/// outline. Cheap enough to redraw live (256 bins per channel).
private struct HistogramView: View {
    let data: ScopeData

    var body: some View {
        VStack(spacing: 3) {
            ZStack {
                HistogramGrid()
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
            histogramLegend
        }
    }

    private var histogramLegend: some View {
        HStack(spacing: 8) {
            legendDot(color: Color(red: 1, green: 0.2, blue: 0.2), label: "R")
            legendDot(color: Color(red: 0.2, green: 1, blue: 0.3), label: "G")
            legendDot(color: Color(red: 0.3, green: 0.5, blue: 1), label: "B")
            legendDot(color: .white.opacity(0.5), label: "L", outline: true)
        }
        .font(.system(size: 9, weight: .medium, design: .monospaced))
    }

    private func legendDot(color: Color, label: String, outline: Bool = false) -> some View {
        HStack(spacing: 2) {
            if outline {
                Circle().stroke(color, lineWidth: 1).frame(width: 6, height: 6)
            } else {
                Circle().fill(color).frame(width: 6, height: 6)
            }
            Text(label).foregroundStyle(Theme.muted)
        }
    }
}

private struct HistogramGrid: View {
    var body: some View {
        Canvas { ctx, size in
            let gc = Color.white.opacity(0.25)
            let labelColor = Color.white.opacity(0.5)
            let labelFont = Font.system(size: 7, weight: .medium, design: .monospaced)
            let vLines: [(CGFloat, String)] = [
                (0.0, "0"), (0.25, "64"), (0.5, "128"), (0.75, "192"), (1.0, "255")
            ]
            for (frac, label) in vLines {
                let x = frac * size.width
                var path = Path()
                path.move(to: CGPoint(x: x, y: 0))
                path.addLine(to: CGPoint(x: x, y: size.height))
                ctx.stroke(path, with: .color(gc), lineWidth: 0.5)
                ctx.draw(Text(label).font(labelFont).foregroundColor(labelColor),
                         at: CGPoint(x: x, y: size.height - 4), anchor: .bottom)
            }
            for frac in [0.25, 0.5, 0.75] as [CGFloat] {
                let y = (1 - frac) * size.height
                var path = Path()
                path.move(to: CGPoint(x: 0, y: y))
                path.addLine(to: CGPoint(x: size.width, y: y))
                ctx.stroke(path, with: .color(gc), lineWidth: 0.5)
            }
        }
        .allowsHitTesting(false)
    }
}

/// Waveform display with horizontal IRE/code-value reference lines.
private struct WaveformView: View {
    let image: CGImage

    var body: some View {
        ZStack {
            Image(decorative: image, scale: 1)
                .resizable()
                .interpolation(.low)
            Canvas { ctx, size in
                let lines: [(CGFloat, String)] = [
                    (0.0, "255"), (0.25, "192"), (0.5, "128"), (0.75, "64"), (1.0, "0")
                ]
                for (frac, label) in lines {
                    let y = frac * size.height
                    var path = Path()
                    path.move(to: CGPoint(x: 0, y: y))
                    path.addLine(to: CGPoint(x: size.width, y: y))
                    ctx.stroke(path, with: .color(.white.opacity(0.3)), lineWidth: 0.5)
                    ctx.draw(Text(label)
                        .font(.system(size: 8, weight: .medium, design: .monospaced))
                        .foregroundColor(.white.opacity(0.55)),
                             at: CGPoint(x: 14, y: y), anchor: .leading)
                }
            }
            .allowsHitTesting(false)
        }
    }
}

/// Vectorscope with graticule overlay: concentric circles at 25/50/75/100%
/// saturation, color target boxes at standard R/G/B/C/M/Y positions,
/// and a skin-tone line.
private struct VectorscopeView: View {
    let image: CGImage

    var body: some View {
        ZStack {
            Image(decorative: image, scale: 1)
                .resizable()
                .interpolation(.low)
                .aspectRatio(1, contentMode: .fit)
            GeometryReader { proxy in
                let size = min(proxy.size.width, proxy.size.height)
                let center = CGPoint(x: proxy.size.width / 2, y: proxy.size.height / 2)
                Canvas { ctx, _ in
                    let graticuleColor = Color.white.opacity(0.35)

                    for pct in [0.25, 0.5, 0.75, 1.0] as [CGFloat] {
                        let r = size / 2 * pct
                        let rect = CGRect(x: center.x - r, y: center.y - r, width: r * 2, height: r * 2)
                        ctx.stroke(Path(ellipseIn: rect), with: .color(graticuleColor), lineWidth: 0.5)
                    }

                    var hLine = Path()
                    hLine.move(to: CGPoint(x: center.x - size / 2, y: center.y))
                    hLine.addLine(to: CGPoint(x: center.x + size / 2, y: center.y))
                    ctx.stroke(hLine, with: .color(graticuleColor), lineWidth: 0.5)
                    var vLine = Path()
                    vLine.move(to: CGPoint(x: center.x, y: center.y - size / 2))
                    vLine.addLine(to: CGPoint(x: center.x, y: center.y + size / 2))
                    ctx.stroke(vLine, with: .color(graticuleColor), lineWidth: 0.5)

                    let skinAngle: CGFloat = 123 * .pi / 180
                    let skinEnd = CGPoint(
                        x: center.x + cos(skinAngle) * size / 2,
                        y: center.y - sin(skinAngle) * size / 2)
                    var skinLine = Path()
                    skinLine.move(to: center)
                    skinLine.addLine(to: skinEnd)
                    ctx.stroke(skinLine, with: .color(Color(red: 1, green: 0.8, blue: 0.6).opacity(0.5)), lineWidth: 1)

                    // Color target boxes at 75% saturation (BT.709 Cb/Cr)
                    // Pure color Cb/Cr from the BT.709 formula:
                    //   R(1,0,0): cb=-0.169, cr= 0.500
                    //   G(0,1,0): cb=-0.331, cr=-0.419
                    //   B(0,0,1): cb= 0.500, cr=-0.081
                    //   C(0,1,1): cb= 0.169, cr=-0.500
                    //   M(1,0,1): cb= 0.331, cr= 0.419
                    //   Y(1,1,0): cb=-0.500, cr= 0.081
                    let targets: [(String, CGFloat, CGFloat, Color)] = [
                        ("R", -0.169,  0.500, Color.red),
                        ("G", -0.331, -0.419, Color.green),
                        ("B",  0.500, -0.081, Color.blue),
                        ("C",  0.169, -0.500, Color.cyan),
                        ("M",  0.331,  0.419, Color(red: 1, green: 0, blue: 1)),
                        ("Y", -0.500,  0.081, Color.yellow),
                    ]
                    let targetScale: CGFloat = 0.75
                    for (label, cb, cr, color) in targets {
                        let x = center.x + cb * targetScale * size
                        let y = center.y - cr * targetScale * size
                        let boxSize: CGFloat = 8
                        let rect = CGRect(x: x - boxSize / 2, y: y - boxSize / 2,
                                          width: boxSize, height: boxSize)
                        ctx.stroke(Path(rect), with: .color(color.opacity(0.6)), lineWidth: 1)
                        ctx.draw(Text(label)
                            .font(.system(size: 7, weight: .bold))
                            .foregroundColor(color.opacity(0.5)),
                                 at: CGPoint(x: x, y: y - boxSize / 2 - 5), anchor: .center)
                    }
                }
                .allowsHitTesting(false)
            }
            .aspectRatio(1, contentMode: .fit)
        }
        .aspectRatio(1, contentMode: .fit)
    }
}

/// Overlaid A/B waveform — both sides tinted and composited with screen blend
/// so differences in luma distribution are immediately visible.
private struct ComparisonWaveformView: View {
    let imageA: CGImage?
    let imageB: CGImage?

    var body: some View {
        ZStack {
            if let imgA = imageA {
                Image(decorative: imgA, scale: 1)
                    .resizable().interpolation(.low)
                    .colorMultiply(Color(red: 0.2, green: 0.6, blue: 1.0))
                    .blendMode(.plusLighter)
            }
            if let imgB = imageB {
                Image(decorative: imgB, scale: 1)
                    .resizable().interpolation(.low)
                    .colorMultiply(Color(red: 1.0, green: 0.4, blue: 0.15))
                    .blendMode(.plusLighter)
            }
            // Waveform graticule lines
            Canvas { ctx, size in
                let lines: [(CGFloat, String)] = [
                    (0.0, "255"), (0.25, "192"), (0.5, "128"), (0.75, "64"), (1.0, "0")
                ]
                for (frac, label) in lines {
                    let y = frac * size.height
                    var path = Path()
                    path.move(to: CGPoint(x: 0, y: y))
                    path.addLine(to: CGPoint(x: size.width, y: y))
                    ctx.stroke(path, with: .color(.white.opacity(0.3)), lineWidth: 0.5)
                    ctx.draw(Text(label)
                        .font(.system(size: 8, weight: .medium, design: .monospaced))
                        .foregroundColor(.white.opacity(0.55)),
                             at: CGPoint(x: 14, y: y), anchor: .leading)
                }
            }
            .allowsHitTesting(false)
            ComparisonLegend()
        }
    }
}

private let comparisonColorA = Color(red: 0.2, green: 0.6, blue: 1.0)
private let comparisonColorB = Color(red: 1.0, green: 0.4, blue: 0.15)

private struct ComparisonLegend: View {
    var body: some View {
        VStack {
            Spacer()
            HStack(spacing: 12) {
                HStack(spacing: 3) {
                    RoundedRectangle(cornerRadius: 2).fill(comparisonColorA)
                        .frame(width: 10, height: 6)
                    Text("A").font(.system(size: 9, weight: .medium, design: .monospaced))
                        .foregroundStyle(Theme.muted)
                }
                HStack(spacing: 3) {
                    RoundedRectangle(cornerRadius: 2).fill(comparisonColorB)
                        .frame(width: 10, height: 6)
                    Text("B").font(.system(size: 9, weight: .medium, design: .monospaced))
                        .foregroundStyle(Theme.muted)
                }
                Spacer()
            }
            .padding(.leading, 4).padding(.bottom, 2)
        }
    }
}

/// Overlaid A/B vectorscope — both sides tinted and composited with screen blend,
/// plus graticule overlay for spatial reference.
private struct ComparisonVectorscopeView: View {
    let imageA: CGImage?
    let imageB: CGImage?

    var body: some View {
        ZStack {
            ZStack {
                if let imgA = imageA {
                    Image(decorative: imgA, scale: 1)
                        .resizable().interpolation(.low)
                        .colorMultiply(Color(red: 0.2, green: 0.6, blue: 1.0))
                        .blendMode(.plusLighter)
                }
                if let imgB = imageB {
                    Image(decorative: imgB, scale: 1)
                        .resizable().interpolation(.low)
                        .colorMultiply(Color(red: 1.0, green: 0.4, blue: 0.15))
                        .blendMode(.plusLighter)
                }
            }
            .aspectRatio(1, contentMode: .fit)
            // Reuse the same graticule overlay
            GeometryReader { proxy in
                let size = min(proxy.size.width, proxy.size.height)
                let center = CGPoint(x: proxy.size.width / 2, y: proxy.size.height / 2)
                Canvas { ctx, _ in
                    let gc = Color.white.opacity(0.35)
                    for pct in [0.25, 0.5, 0.75, 1.0] as [CGFloat] {
                        let r = size / 2 * pct
                        let rect = CGRect(x: center.x - r, y: center.y - r, width: r * 2, height: r * 2)
                        ctx.stroke(Path(ellipseIn: rect), with: .color(gc), lineWidth: 0.5)
                    }
                    var hLine = Path()
                    hLine.move(to: CGPoint(x: center.x - size / 2, y: center.y))
                    hLine.addLine(to: CGPoint(x: center.x + size / 2, y: center.y))
                    ctx.stroke(hLine, with: .color(gc), lineWidth: 0.5)
                    var vLine = Path()
                    vLine.move(to: CGPoint(x: center.x, y: center.y - size / 2))
                    vLine.addLine(to: CGPoint(x: center.x, y: center.y + size / 2))
                    ctx.stroke(vLine, with: .color(gc), lineWidth: 0.5)

                    let skinAngle: CGFloat = 123 * .pi / 180
                    let skinEnd = CGPoint(
                        x: center.x + cos(skinAngle) * size / 2,
                        y: center.y - sin(skinAngle) * size / 2)
                    var skinLine = Path()
                    skinLine.move(to: center)
                    skinLine.addLine(to: skinEnd)
                    ctx.stroke(skinLine, with: .color(Color(red: 1, green: 0.8, blue: 0.6).opacity(0.5)), lineWidth: 1)
                }
                .allowsHitTesting(false)
            }
            .aspectRatio(1, contentMode: .fit)
            ComparisonLegend()
        }
        .aspectRatio(1, contentMode: .fit)
    }
}

/// Overlaid A/B histogram for comparison mode — both sides' luma histograms
/// in distinct colors so distribution differences are immediately visible.
private struct ComparisonHistogramView: View {
    let dataA: ScopeData
    let dataB: ScopeData

    var body: some View {
        VStack(spacing: 3) {
            ZStack {
                HistogramGrid()
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
                    ctx.fill(area(dataA.histL), with: .color(Theme.sideA.opacity(0.4)))
                    ctx.stroke(area(dataA.histL), with: .color(Theme.sideA.opacity(0.8)), lineWidth: 1.5)
                    ctx.fill(area(dataB.histL), with: .color(Theme.sideB.opacity(0.3)))
                    ctx.stroke(area(dataB.histL), with: .color(Theme.sideB.opacity(0.8)), lineWidth: 1.5)
                }
            }
            HStack(spacing: 12) {
                HStack(spacing: 3) {
                    RoundedRectangle(cornerRadius: 2).fill(Theme.sideA).frame(width: 10, height: 6)
                    Text("A").font(.system(size: 9, weight: .medium, design: .monospaced))
                        .foregroundStyle(Theme.muted)
                }
                HStack(spacing: 3) {
                    RoundedRectangle(cornerRadius: 2).fill(Theme.sideB).frame(width: 10, height: 6)
                    Text("B").font(.system(size: 9, weight: .medium, design: .monospaced))
                        .foregroundStyle(Theme.muted)
                }
                Spacer()
                Text("Luma").font(.system(size: 9, design: .monospaced)).foregroundStyle(Theme.muted)
            }
        }
    }
}
