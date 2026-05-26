import SwiftUI

// MARK: - Tonemap settings (popover with curve preview + sliders)
//
// CPU-side mirror of the shader's `applyTonemap` so the curve preview matches
// what the GPU produces. Only the per-channel scalar form is duplicated here —
// exposure is intentionally NOT included because the preview is a static
// "operator response" plot, not a frame preview.

private let kCurvePreviewSamples = 96

/// X-axis upper bound for the curve preview. Adapts to the operator: Hable
/// uses its derived white point (so the full toe→shoulder span is visible),
/// Reinhard uses its whitepoint slider, everything else gets a fixed 4×.
@MainActor
private func curveMaxInput(_ engine: MediaEngine) -> Float {
    switch engine.tonemapMode {
    case .piecewise: return max(2.0, engine.piecewiseKnots.W * 1.05)
    case .reinhard:  return max(2.0, Float(engine.reinhardWhitepoint) * 1.05)
    default:         return 4.0
    }
}

/// One scalar input → one display-encoded output, matching the shader. Keep
/// the branches and constants in sync with `applyTonemap` in ShaderSource.
@MainActor
private func evalTonemapChannel(_ mode: TonemapMode, x: Float, engine: MediaEngine) -> Float {
    switch mode {
    case .linear:
        return srgbEncodeScalar(min(1.0, max(0.0, x)))
    case .gamma:
        let g = Float(max(0.01, engine.gamma))
        let s: Float = x < 0 ? -1 : 1
        return s * powf(Swift.abs(x), 1.0 / g)
    case .reinhard:
        let Lw = Float(max(0.0001, engine.reinhardWhitepoint))
        let xi = max(0, x)
        let r = xi * (1.0 + xi / (Lw * Lw)) / (1.0 + xi)
        return srgbEncodeScalar(r)
    case .aces:
        let xi = max(0, x)
        let a: Float = 2.51, b: Float = 0.03, c: Float = 2.43, d: Float = 0.59, e: Float = 0.14
        let v = max(0, min(1, (xi * (a * xi + b)) / (xi * (c * xi + d) + e)))
        return srgbEncodeScalar(v)
    case .filmic:
        let xi = max(0, x - 0.004)
        return (xi * (6.2 * xi + 0.5)) / (xi * (6.2 * xi + 1.7) + 0.06)
    case .piecewise:
        let raw = evalPiecewise(x: max(0, x), knots: engine.piecewiseKnots)
        return srgbEncodeScalar(raw * engine.piecewiseKnots.invScale)
    case .falseColor:
        // Not a real curve — render the colormap legend instead in the UI.
        return min(1, max(0, x))
    case .positiveNegative:
        // Same — these are visualization aids, not response curves.
        return min(1, max(0, x))
    }
}

private func srgbEncodeScalar(_ v: Float) -> Float {
    let x = max(0, v)
    if x <= 0.0031308 { return 12.92 * x }
    return 1.055 * powf(x, 1.0 / 2.4) - 0.055
}

// MARK: - Settings button

struct TonemapSettingsButton: View {
    @ObservedObject var engine: MediaEngine
    @State private var isOpen = false

    var body: some View {
        Button {
            isOpen.toggle()
        } label: {
            Image(systemName: "slider.horizontal.below.square.filled.and.square")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(0.85))
                .frame(width: 22, height: 22)
                .background(isOpen
                            ? Color.yellow.opacity(0.30)
                            : Color.white.opacity(0.06),
                            in: RoundedRectangle(cornerRadius: 5))
        }
        .buttonStyle(.plain)
        .help("Tonemap settings & curve")
        .popover(isPresented: $isOpen, arrowEdge: .top) {
            TonemapSettingsPopover(engine: engine)
        }
    }
}

// MARK: - Popover content

struct TonemapSettingsPopover: View {
    @ObservedObject var engine: MediaEngine

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(engine.tonemapMode.label)
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                Text(operatorSubtitle)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }

            curvePreview
                .frame(width: 280, height: 150)

            Divider().opacity(0.4)

            paramsSection
        }
        .padding(14)
        .frame(width: 320)
    }

    // MARK: Operator subtitles

    private var operatorSubtitle: String {
        switch engine.tonemapMode {
        case .linear:           return "clamp to [0, 1]"
        case .gamma:            return "sign-preserving power"
        case .reinhard:         return "extended, per-channel"
        case .aces:             return "Narkowicz fit"
        case .filmic:           return "Hejl-Burgess-Dawson"
        case .piecewise:        return "Hable, piecewise power"
        case .falseColor:       return "7-stop log-luminance colormap"
        case .positiveNegative: return "signed difference (green/red)"
        }
    }

    // MARK: Curve preview

    @ViewBuilder
    private var curvePreview: some View {
        switch engine.tonemapMode {
        case .falseColor:
            falseColorLegend
        case .positiveNegative:
            posNegLegend
        default:
            curveCanvas
        }
    }

    private var curveCanvas: some View {
        Canvas { ctx, size in
            let maxX = curveMaxInput(engine)
            // Background.
            ctx.fill(Path(CGRect(origin: .zero, size: size)),
                     with: .color(Color.black.opacity(0.35)))

            // Grid: vertical at integer stops up to maxX, horizontal at 0.25.
            var grid = Path()
            let gridStep = max(1, Int(maxX / 6))
            for i in stride(from: 0, through: Int(maxX), by: gridStep) {
                let x = CGFloat(Float(i) / maxX) * size.width
                grid.move(to: CGPoint(x: x, y: 0))
                grid.addLine(to: CGPoint(x: x, y: size.height))
            }
            for j in 1..<4 {
                let y = size.height - CGFloat(j) * size.height / 4
                grid.move(to: CGPoint(x: 0, y: y))
                grid.addLine(to: CGPoint(x: size.width, y: y))
            }
            ctx.stroke(grid, with: .color(Color.white.opacity(0.06)), lineWidth: 1)

            // Reference diagonal (identity y=x in the 0..1 region).
            var diag = Path()
            let diagEndX = size.width / CGFloat(maxX)
            diag.move(to: CGPoint(x: 0, y: size.height))
            diag.addLine(to: CGPoint(x: diagEndX, y: 0))
            ctx.stroke(diag, with: .color(Color.white.opacity(0.18)),
                       style: StrokeStyle(lineWidth: 1, dash: [3, 3]))

            // Operator response curve.
            var curve = Path()
            for i in 0...kCurvePreviewSamples {
                let t = Float(i) / Float(kCurvePreviewSamples)
                let x = t * maxX
                let y = evalTonemapChannel(engine.tonemapMode, x: x, engine: engine)
                let px = CGFloat(t) * size.width
                let py = size.height - CGFloat(max(0, min(1, y))) * size.height
                if i == 0 {
                    curve.move(to: CGPoint(x: px, y: py))
                } else {
                    curve.addLine(to: CGPoint(x: px, y: py))
                }
            }
            ctx.stroke(curve, with: .color(.yellow),
                       style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))

            // Axis labels.
            let axisFont = Font.system(size: 9, design: .monospaced)
            ctx.draw(Text("0").font(axisFont).foregroundStyle(.secondary),
                     at: CGPoint(x: 8, y: size.height - 8))
            ctx.draw(Text(String(format: "%.1f×", maxX)).font(axisFont).foregroundStyle(.secondary),
                     at: CGPoint(x: size.width - 18, y: size.height - 8))
            ctx.draw(Text("1.0").font(axisFont).foregroundStyle(.secondary),
                     at: CGPoint(x: 12, y: 8))
        }
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    /// Stand-in "preview" for false color — a horizontal gradient through the
    /// same 7 stops the shader uses, so the user can read off what each
    /// luminance band maps to.
    private var falseColorLegend: some View {
        VStack(alignment: .leading, spacing: 4) {
            LinearGradient(stops: [
                .init(color: Color(red: 0,   green: 0,   blue: 0),   location: 0.00),
                .init(color: Color(red: 0,   green: 0,   blue: 0.6), location: 0.17),
                .init(color: Color(red: 0,   green: 0.6, blue: 1.0), location: 0.33),
                .init(color: Color(red: 0,   green: 1.0, blue: 0),   location: 0.50),
                .init(color: Color(red: 1.0, green: 1.0, blue: 0),   location: 0.67),
                .init(color: Color(red: 1.0, green: 0,   blue: 0),   location: 0.83),
                .init(color: Color.white,                            location: 1.00),
            ], startPoint: .leading, endPoint: .trailing)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            HStack {
                Text("dark").font(.system(size: 9, design: .monospaced))
                Spacer()
                Text("mid").font(.system(size: 9, design: .monospaced))
                Spacer()
                Text("bright").font(.system(size: 9, design: .monospaced))
            }
            .foregroundStyle(.secondary)
        }
    }

    private var posNegLegend: some View {
        HStack(spacing: 8) {
            VStack {
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.red.opacity(0.9))
                Text("Δ < 0")
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            VStack {
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.green.opacity(0.9))
                Text("Δ > 0")
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: Operator-specific parameters

    @ViewBuilder
    private var paramsSection: some View {
        switch engine.tonemapMode {
        case .gamma:
            paramRow(label: "γ", value: String(format: "%.2f", engine.gamma)) {
                Slider(value: $engine.gamma, in: 0.1...5.0, step: 0.05)
            }
        case .reinhard:
            paramRow(label: "White", value: String(format: "%.2f", engine.reinhardWhitepoint)) {
                Slider(value: $engine.reinhardWhitepoint, in: 0.1...16.0, step: 0.05)
            }
            Text("Input value mapped to display 1.0. Higher = more highlight headroom before rolloff.")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        case .piecewise:
            piecewiseParams
        case .linear, .aces, .filmic:
            Text("No parameters — operator has fixed coefficients.")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        case .falseColor:
            Text("Maps log₂(luminance) to a 7-stop colormap so HDR error magnitudes are readable at a glance.")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        case .positiveNegative:
            Text("Visualizes signed error: green = A > B, red = A < B. Useful for error mode with the signed difference metric.")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var piecewiseParams: some View {
        VStack(alignment: .leading, spacing: 8) {
            paramRow(label: "Toe str",
                     value: String(format: "%.2f", engine.piecewiseParams.toeStrength)) {
                Slider(value: pwBinding(\.toeStrength), in: 0...1)
            }
            paramRow(label: "Toe len",
                     value: String(format: "%.2f", engine.piecewiseParams.toeLength)) {
                Slider(value: pwBinding(\.toeLength), in: 0...1)
            }
            paramRow(label: "Sh str",
                     value: String(format: "%.2f", engine.piecewiseParams.shoulderStrength)) {
                Slider(value: pwBinding(\.shoulderStrength), in: 0...4)
            }
            paramRow(label: "Sh len",
                     value: String(format: "%.2f", engine.piecewiseParams.shoulderLength)) {
                Slider(value: pwBinding(\.shoulderLength), in: 0...1)
            }
            paramRow(label: "Sh ang",
                     value: String(format: "%.2f", engine.piecewiseParams.shoulderAngle)) {
                Slider(value: pwBinding(\.shoulderAngle), in: 0...1)
            }
            paramRow(label: "Curve γ",
                     value: String(format: "%.2f", engine.piecewiseParams.gamma)) {
                Slider(value: pwBinding(\.gamma), in: 0.5...3.0)
            }

            Text("White point W ≈ \(String(format: "%.2f", engine.piecewiseKnots.W)) — derived from shoulder strength (\(String(format: "%.1f", engine.piecewiseParams.shoulderStrength)) stops over mid).")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Button("Reset to defaults") {
                    engine.piecewiseParams = PiecewiseTonemapParams()
                }
                .buttonStyle(.borderless)
                .font(.system(size: 10))
                Spacer()
            }
        }
    }

    /// SwiftUI Slider binding wrapper for a single piecewise param, accepting
    /// a keypath into the params struct. Reads as Double for Slider compat
    /// and writes back as Float, recomputing knots via the engine's didSet.
    private func pwBinding(_ kp: WritableKeyPath<PiecewiseTonemapParams, Float>) -> Binding<Double> {
        Binding(
            get: { Double(engine.piecewiseParams[keyPath: kp]) },
            set: { newValue in
                var copy = engine.piecewiseParams
                copy[keyPath: kp] = Float(newValue)
                engine.piecewiseParams = copy
            }
        )
    }

    @ViewBuilder
    private func paramRow<Control: View>(label: String, value: String,
                                         @ViewBuilder control: () -> Control) -> some View {
        HStack(spacing: 6) {
            Text(label)
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(.tertiary)
                .frame(width: 50, alignment: .leading)
            control()
                .controlSize(.mini)
            Text(value)
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 42, alignment: .trailing)
        }
    }
}

// Binding helpers for direct slider bindings on engine doubles.
private extension Binding where Value == Double {
    init(_ source: Binding<Float>) {
        self.init(
            get: { Double(source.wrappedValue) },
            set: { source.wrappedValue = Float($0) }
        )
    }
}
