import SwiftUI
import UniformTypeIdentifiers

// MARK: - Enum Display Labels

extension DisplayMode {
    var label: String {
        switch self {
        case .split: return "Split"
        case .error: return "Error"
        }
    }
    var icon: String {
        switch self {
        case .split: return "rectangle.split.2x1"
        case .error: return "waveform.path.ecg"
        }
    }
}

extension ErrorMetric {
    var label: String {
        switch self {
        case .error: return "Error"
        case .absoluteError: return "Abs Error"
        case .squaredError: return "Sq Error"
        case .relativeAbsolute: return "Rel Abs"
        case .relativeSquared: return "Rel Sq"
        case .logLuminance: return "Log-Lum"
        }
    }

    /// Compact symbolic label for the hover-readout chip — short enough to sit
    /// inline with the channel values.
    var symbol: String {
        switch self {
        case .error:            return "\u{0394}"          // Δ
        case .absoluteError:    return "|\u{0394}|"        // |Δ|
        case .squaredError:     return "\u{0394}\u{00B2}"  // Δ²
        case .relativeAbsolute: return "|\u{0394}|/B"
        case .relativeSquared:  return "(\u{0394}/B)\u{00B2}"
        case .logLuminance:     return "log\u{2081}\u{2080}A\u{2212}log\u{2081}\u{2080}B"
        }
    }
}

extension TonemapMode {
    var label: String {
        switch self {
        case .linear:           return "Linear"
        case .gamma:            return "Gamma"
        case .reinhard:         return "Reinhard"
        case .aces:             return "ACES"
        case .filmic:           return "Filmic"
        case .piecewise:        return "Piecewise"
        case .falseColor:       return "False Color"
        case .positiveNegative: return "Pos/Neg"
        }
    }

    /// Canonical ordering for menus and the F-key cycle: real tonemap
    /// operators first, then the two error-visualization aids.
    static var orderedCases: [TonemapMode] {
        [.linear, .gamma, .reinhard, .aces, .filmic, .piecewise,
         .falseColor, .positiveNegative]
    }
}

// MARK: - Content View

struct ContentView: View {
    @StateObject private var engine = MediaEngine()
    @State private var frameInput: String = ""
    @State private var showHelp = false
    @State private var hostWindow: NSWindow?

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                MetalComparisonView(engine: engine)

                // Media name overlays
                VStack {
                    HStack(alignment: .top) {
                        if let name = engine.mediaNameA {
                            mediaLabel(name, color: Theme.sideA) {
                                engine.unloadMedia(side: .a)
                            }
                            .padding(.leading, 12)
                            .padding(.top, 10)
                        }
                        Spacer()
                        if let name = engine.mediaNameB {
                            mediaLabel(name, color: Theme.sideB) {
                                engine.unloadMedia(side: .b)
                            }
                            .padding(.trailing, 12)
                            .padding(.top, 10)
                        }
                    }
                    Spacer()
                }

                // Empty state
                if !engine.hasMediaA && !engine.hasMediaB {
                    emptyStateView
                }

                // Blink: center-top badge naming the side currently shown.
                if engine.blinkActive {
                    VStack {
                        blinkBadge.padding(.top, 10)
                        Spacer()
                    }
                    .frame(maxWidth: .infinity)
                    .allowsHitTesting(false)
                    .transition(.opacity)
                }

                // Pixel hover readout (bottom). Suppress when zoomed in far
                // enough that the in-shader per-pixel value overlay is on, so
                // the user never sees both readouts at once.
                GeometryReader { proxy in
                    let overlayActive = engine.inShaderTextOverlayActive(viewSize: proxy.size)
                    if !overlayActive,
                       (engine.hoverSampleA != nil || engine.hoverSampleB != nil) {
                        VStack {
                            Spacer()
                            pixelReadout
                                .padding(.horizontal, 12)
                                .padding(.bottom, 10)
                        }
                        .frame(width: proxy.size.width, height: proxy.size.height)
                        .allowsHitTesting(false)
                        .transition(.opacity)
                    }
                }
                .allowsHitTesting(false)

                // Help overlay
                if showHelp {
                    helpOverlay
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            // Explorer requires both sides loaded — A vs B is the whole point.
            // Stays hidden (without flipping the persisted flag) when only one
            // side is present, so opening the second video reveals it again.
            if engine.explorerOpen && engine.hasMediaA && engine.hasMediaB {
                ExplorerPanel(engine: engine)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            controlsBar
        }
        .animation(.easeInOut(duration: 0.18),
                   value: engine.explorerOpen && engine.hasMediaA && engine.hasMediaB)
        .background(Theme.bg)
        .tint(Theme.accentA)
        .preferredColorScheme(.dark)
        .focusable()
        // Capture our hosting NSWindow so we can detect when WE become key.
        .background(WindowAccessor(window: $hostWindow))
        // Register this engine with the URLRouter so files opened from
        // Finder, the Dock, or `open` reach the front-most window.
        .onAppear { URLRouter.shared.register(engine: engine) }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { note in
            if let win = note.object as? NSWindow, win === hostWindow {
                URLRouter.shared.register(engine: engine)
            }
        }
        // SwiftUI single-URL fallback for environments where
        // `application(_:open:)` isn't invoked. Idempotent with the AppDelegate
        // path; both ultimately call into the router.
        .onOpenURL { url in URLRouter.shared.deliver(urls: [url]) }
        // ── Playback ─────────────────────────────────────────
        .onKeyPress(.space) { engine.togglePlayPause(); return .handled }
        .onKeyPress(.leftArrow) { engine.stepBackward(); return .handled }
        .onKeyPress(.rightArrow) { engine.stepForward(); return .handled }
        .onKeyPress(.home) { engine.seekToStart(); return .handled }
        .onKeyPress(.end) { engine.seekToEnd(); return .handled }
        // ── Zoom ─────────────────────────────────────────────
        .onKeyPress(.upArrow) { engine.zoom = min(MediaEngine.maxZoom, engine.zoom * 1.25); return .handled }
        .onKeyPress(.downArrow) { engine.zoom = max(0.1, engine.zoom / 1.25); return .handled }
        .onKeyPress("r") { engine.resetView(); return .handled }
        .onKeyPress("1") { engine.zoom = 1.0; return .handled }
        .onKeyPress("2") { engine.zoom = 2.0; return .handled }
        .onKeyPress("4") { engine.zoom = 4.0; return .handled }
        .onKeyPress("8") { engine.zoom = 8.0; return .handled }
        // ── Display mode ─────────────────────────────────────
        .onKeyPress("e") {
            if engine.hasMediaA && engine.hasMediaB {
                engine.displayMode = engine.displayMode == .split ? .error : .split
            }
            return .handled
        }
        .onKeyPress("m") {
            let next = (engine.errorMetric.rawValue + 1) % ErrorMetric.allCases.count
            engine.errorMetric = ErrorMetric(rawValue: next)!
            return .handled
        }
        .onKeyPress("f") {
            let ordered = TonemapMode.orderedCases
            let idx = ordered.firstIndex(of: engine.tonemapMode) ?? 0
            engine.tonemapMode = ordered[(idx + 1) % ordered.count]
            return .handled
        }
        // ── Exposure & Gamma ─────────────────────────────────
        .onKeyPress("]") { engine.exposure = min(10, engine.exposure + 0.1); return .handled }
        .onKeyPress("[") { engine.exposure = max(-10, engine.exposure - 0.1); return .handled }
        .onKeyPress("}") { engine.gamma = min(5, engine.gamma + 0.1); return .handled }
        .onKeyPress("{") { engine.gamma = max(0.1, engine.gamma - 0.1); return .handled }
        .onKeyPress("0") { engine.exposure = 0; engine.gamma = 2.2; return .handled }
        // ── Pixel inspection ─────────────────────────────────
        .onKeyPress("p") { engine.pixelInspect.toggle(); return .handled }
        // ── Blink / channels / loop ──────────────────────────
        .onKeyPress("b") { engine.blinkSwap(); return .handled }
        .onKeyPress("c") { engine.cycleChannel(); return .handled }
        .onKeyPress("i") { engine.setLoopIn(); return .handled }
        .onKeyPress("o") { engine.setLoopOut(); return .handled }
        .onKeyPress("l") { engine.toggleLoop(); return .handled }
        // ── Error exploration ────────────────────────────────
        .onKeyPress("x") {
            if engine.hasMediaA && engine.hasMediaB {
                engine.explorerOpen.toggle()
                if engine.explorerOpen && engine.analysisResult == nil {
                    engine.runAnalysis()
                }
            }
            return .handled
        }
        // ── Help ─────────────────────────────────────────────
        .onKeyPress("?") { showHelp.toggle(); return .handled }
        .onKeyPress(.escape) {
            if showHelp { showHelp = false; return .handled }
            if engine.blinkActive { engine.exitBlink(); return .handled }
            return .ignored
        }
    }

    // MARK: - Media Label

    func mediaLabel(_ name: String, color: Color, onClose: @escaping () -> Void) -> some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(name).lineLimit(1).truncationMode(.middle)
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.white.opacity(0.6))
                    .frame(width: 16, height: 16)
                    .background(.white.opacity(0.15), in: Circle())
            }
            .buttonStyle(.plain)
        }
        .font(.system(size: 12, weight: .medium, design: .monospaced))
        .foregroundStyle(.white)
        .padding(.leading, 10)
        .padding(.trailing, 6)
        .padding(.vertical, 5)
        .background(Theme.panel.opacity(0.82), in: RoundedRectangle(cornerRadius: 7))
        .overlay(
            RoundedRectangle(cornerRadius: 7)
                .stroke(Theme.border, lineWidth: 1)
        )
    }

    // MARK: - Blink Badge

    /// Center-top pill naming the side currently shown during blink, colored to
    /// match that side's identity (A purple, B amber).
    var blinkBadge: some View {
        HStack(spacing: 6) {
            Image(systemName: "arrow.left.arrow.right")
                .font(.system(size: 11, weight: .bold))
            Text(engine.blinkShowingA ? "A" : "B")
                .font(.system(size: 13, weight: .bold, design: .monospaced))
            if engine.blinkAuto {
                Image(systemName: "timer")
                    .font(.system(size: 10, weight: .bold))
            }
        }
        .foregroundStyle(Theme.bg)
        .padding(.horizontal, 11)
        .padding(.vertical, 5)
        .background(engine.blinkShowingA ? Theme.sideA : Theme.sideB, in: Capsule())
        .shadow(color: .black.opacity(0.45), radius: 6, y: 1)
    }

    // MARK: - Pixel Readout

    var pixelReadout: some View {
        let a = engine.hoverSampleA
        let b = engine.hoverSampleB
        // Pixel coords come from whichever side is loaded. If both are loaded
        // and have the same dimensions the values match; if dimensions differ,
        // we report A's coords (it's the reference for aspect anyway).
        let coord: CGPoint? = a?.pixel ?? b?.pixel

        return HStack(spacing: 14) {
            if let s = a {
                sampleChip(label: "A", color: Theme.sideA, sample: s)
            }
            if let s = b {
                sampleChip(label: "B", color: Theme.sideB, sample: s)
            }
            if let sa = a, let sb = b {
                deltaChip(a: sa, b: sb)
            }
            Spacer(minLength: 8)
            if let p = coord {
                Text("x: \(Int(p.x))  y: \(Int(p.y))")
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.8))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(Theme.panel.opacity(0.82), in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Theme.border, lineWidth: 1)
        )
    }

    private func sampleChip(label: String, color: Color, sample: MediaEngine.PixelSample) -> some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(label)
                .foregroundStyle(.white.opacity(0.85))
            channelText("R", sample.rgba.x, tint: .red)
            channelText("G", sample.rgba.y, tint: .green)
            channelText("B", sample.rgba.z, tint: Color(red: 0.4, green: 0.6, blue: 1.0))
            if sample.hasAlpha && abs(sample.rgba.w - 1.0) > 0.001 {
                channelText("A", sample.rgba.w, tint: .white)
            }
        }
        .font(.system(size: 11, weight: .medium, design: .monospaced))
    }

    private func channelText(_ name: String, _ v: Float, tint: Color) -> some View {
        HStack(spacing: 2) {
            Text(name).foregroundStyle(tint.opacity(0.85))
            Text(formatChannel(v)).foregroundStyle(.white)
        }
    }

    /// Emit a monospaced fixed-width number suitable for HDR-range floats.
    private func formatChannel(_ v: Float) -> String {
        guard v.isFinite else { return v.isNaN ? " NaN " : (v < 0 ? " -Inf" : " +Inf") }
        let mag = abs(v)
        if mag >= 1000 { return String(format: "%6.0f", v) }
        if mag >= 100  { return String(format: "%6.1f", v) }
        if mag >= 10   { return String(format: "%6.2f", v) }
        return String(format: "%+6.3f", v)
    }

    private func deltaChip(a: MediaEngine.PixelSample, b: MediaEngine.PixelSample) -> some View {
        // Use the same per-channel formula the shader uses for the active error
        // metric so the chip readout matches the rendered error-mode pixels.
        let metric = engine.errorMetric
        let aRGB = SIMD3<Float>(a.rgba.x, a.rgba.y, a.rgba.z)
        let bRGB = SIMD3<Float>(b.rgba.x, b.rgba.y, b.rgba.z)
        let d = metric.apply(a: aRGB, b: bRGB)
        return HStack(spacing: 6) {
            Text(metric.symbol)
                .foregroundStyle(.white.opacity(0.85))
            channelText("R", d.x, tint: .red.opacity(0.8))
            channelText("G", d.y, tint: .green.opacity(0.8))
            channelText("B", d.z, tint: Color(red: 0.4, green: 0.6, blue: 1.0).opacity(0.8))
        }
        .font(.system(size: 11, weight: .medium, design: .monospaced))
        .help("Error metric: \(metric.label)")
    }

    // MARK: - Empty State

    var emptyStateView: some View {
        VStack(spacing: 16) {
            Image(systemName: "film.stack")
                .font(.system(size: 48, weight: .thin))
                .foregroundStyle(.secondary)
            Text("Open or drag-and-drop two videos or images to compare")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(.secondary)
            Text("Drop on the left half for A, the right half for B  ·  drop a folder or many frames for a sequence  ·  HDR EXR / HDR HEIC supported")
                .font(.system(size: 12))
                .foregroundStyle(.tertiary)
            HStack(spacing: 12) {
                Button { openFile(for: .a) } label: {
                    Label("Open A", systemImage: "a.square.fill")
                        .font(.system(size: 13, weight: .semibold))
                }
                Button { openFile(for: .b) } label: {
                    Label("Open B", systemImage: "b.square.fill")
                        .font(.system(size: 13, weight: .semibold))
                }
            }
            .buttonStyle(BrandButtonStyle())
            .padding(.top, 4)
        }
    }

    // MARK: - Help Overlay

    var helpOverlay: some View {
        ZStack {
            Color.black.opacity(0.75)
                .ignoresSafeArea()
                .onTapGesture { showHelp = false }

            VStack(spacing: 0) {
                // Header
                HStack {
                    Text("Keyboard Shortcuts")
                        .font(.system(size: 16, weight: .semibold))
                    Spacer()
                    Button { showHelp = false } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 18))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 24)
                .padding(.top, 20)
                .padding(.bottom, 12)

                Divider().opacity(0.3)

                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        shortcutSection("Playback", shortcuts: [
                            ("Space", "Play / Pause"),
                            ("\u{2190} \u{2192}", "Step back / forward one frame"),
                            ("Home / End", "Go to start / end"),
                        ])

                        shortcutSection("View", shortcuts: [
                            ("\u{2191} \u{2193}", "Zoom in / out"),
                            ("1  2  4  8", "Zoom presets"),
                            ("R", "Reset zoom & pan"),
                            ("Drag", "Pan (when zoomed in)"),
                            ("Scroll / Pinch", "Zoom at cursor"),
                        ])

                        shortcutSection("Comparison", shortcuts: [
                            ("E", "Toggle Split / Error mode"),
                            ("B", "Blink \u{2014} swap A\u{2194}B in place (works during playback)"),
                            ("M", "Cycle error metric"),
                            ("F", "Cycle visualization mode"),
                            ("Drag handle", "Move split slider"),
                        ])

                        shortcutSection("Channels & Playback", shortcuts: [
                            ("C", "Cycle channel isolation (RGB / R / G / B / A / Luma)"),
                            ("I  /  O", "Set loop in / out point"),
                            ("L", "Toggle segment loop"),
                            ("\u{2318} options", "Clipping & gamut warnings, speed, A/B offset"),
                        ])

                        shortcutSection("Exposure & Gamma", shortcuts: [
                            ("]  /  [", "Increase / decrease exposure (\u{00B1}0.1 EV)"),
                            ("}  /  {", "Increase / decrease gamma (\u{00B1}0.1)"),
                            ("0", "Reset exposure & gamma"),
                        ])

                        shortcutSection("Pixel Inspection", shortcuts: [
                            ("P", "Toggle pixel grid + RGB values overlay"),
                            ("Zoom in", "Auto-shows when pixels are large enough"),
                            ("Hover", "RGB readout (linear sRGB) appears at the bottom"),
                        ])

                        shortcutSection("Error Exploration", shortcuts: [
                            ("X", "Toggle HDR error exploration panel"),
                            ("Click tile", "Zoom into a top-error region"),
                            ("Categories", "Highlights · Shadows · Color · Fireflies · Blur · Texture · Ringing"),
                        ])

                        shortcutSection("Loading Media", shortcuts: [
                            ("Drop / Open", "Videos: mov, mp4, mkv, webm, avi, …"),
                            ("Drop / Open", "Images: png, jpg, webp, heic, exr, hdr, raw, …"),
                            ("Mix", "Compare a video against a still image"),
                        ])

                        shortcutSection("General", shortcuts: [
                            ("?", "Show / hide this help"),
                            ("Esc", "Close help"),
                        ])
                    }
                    .padding(.horizontal, 24)
                    .padding(.vertical, 16)
                }
            }
            .frame(width: 420, height: 480)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .stroke(Theme.border, lineWidth: 1)
            )
            .overlay(alignment: .top) {
                // Brand hairline along the top edge.
                Theme.brand
                    .frame(height: 3)
                    .clipShape(
                        .rect(topLeadingRadius: 14, topTrailingRadius: 14)
                    )
            }
            .shadow(color: .black.opacity(0.55), radius: 30)
        }
    }

    func shortcutSection(_ title: String, shortcuts: [(String, String)]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.primary)

            ForEach(Array(shortcuts.enumerated()), id: \.offset) { _, shortcut in
                HStack(alignment: .top, spacing: 0) {
                    Text(shortcut.0)
                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                        .foregroundStyle(Theme.accentA)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Theme.accentA.opacity(0.14), in: RoundedRectangle(cornerRadius: 4))
                        .overlay(
                            RoundedRectangle(cornerRadius: 4)
                                .stroke(Theme.accentA.opacity(0.25), lineWidth: 1)
                        )
                        .frame(width: 120, alignment: .trailing)

                    Text(shortcut.1)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .padding(.leading, 12)

                    Spacer()
                }
            }
        }
    }

    // MARK: - Controls Bar

    var controlsBar: some View {
        VStack(spacing: 0) {
            // Timeline (shown for videos and image sequences)
            if engine.hasTimeline {
                HStack(spacing: 10) {
                    Text(engine.currentTimeString)
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .frame(width: 80, alignment: .trailing)

                    Slider(
                        value: Binding(
                            get: { engine.seekPosition },
                            set: { engine.seekToPosition($0) }
                        ),
                        in: 0...1
                    )
                    .controlSize(.small)

                    Text(engine.durationString)
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .frame(width: 80, alignment: .leading)
                }
                .padding(.horizontal, 12)
                .padding(.top, 6)
                .padding(.bottom, 2)
            }

            // Transport + controls
            HStack(spacing: 6) {
                compactButton("Open A", icon: "a.square.fill", color: Theme.sideA) { openFile(for: .a) }
                compactButton("Open B", icon: "b.square.fill", color: Theme.sideB) { openFile(for: .b) }

                Spacer().frame(width: 4)

                if engine.hasTimeline {
                    Group {
                        iconButton("backward.end.fill") { engine.seekToStart() }
                        iconButton("backward.frame.fill") { engine.stepBackward() }
                        iconButton(engine.isPlaying ? "pause.fill" : "play.fill", size: 16) {
                            engine.togglePlayPause()
                        }
                        iconButton("forward.frame.fill") { engine.stepForward() }
                        iconButton("forward.end.fill") { engine.seekToEnd() }
                    }

                    Spacer().frame(width: 4)
                }

                errorControls

                Spacer()

                if engine.hasTimeline {
                    HStack(spacing: 4) {
                        Text("Frame")
                            .foregroundStyle(.tertiary)
                        Text("\(engine.currentFrame)")
                            .foregroundStyle(.secondary)
                    }
                    .font(.system(size: 11, weight: .medium, design: .monospaced))

                    TextField("Go to", text: $frameInput)
                        .textFieldStyle(.plain)
                        .font(.system(size: 11, design: .monospaced))
                        .frame(width: 55)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(Theme.panel2, in: RoundedRectangle(cornerRadius: 4))
                        .overlay(
                            RoundedRectangle(cornerRadius: 4)
                                .stroke(Theme.border, lineWidth: 1)
                        )
                        .onSubmit {
                            if let frame = Int(frameInput) {
                                engine.seekToFrame(frame)
                                frameInput = ""
                            }
                        }

                    Spacer().frame(width: 4)
                }

                // Zoom
                HStack(spacing: 4) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.tertiary)
                        .font(.system(size: 10))
                    Text("\(engine.zoom, specifier: engine.zoom >= 10 ? "%.0f" : "%.1f")x")
                        .foregroundStyle(.secondary)
                }
                .font(.system(size: 11, weight: .medium, design: .monospaced))

                if engine.hasMediaA || engine.hasMediaB {
                    ViewOptionsButton(engine: engine)
                }

                iconButton("arrow.up.left.and.arrow.down.right") {
                    engine.resetView()
                }
                .help("Reset view (R)")

                iconButton("questionmark.circle") {
                    showHelp.toggle()
                }
                .help("Keyboard shortcuts (?)")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        }
        .background(
            Theme.panelSheen
                .overlay(alignment: .top) {
                    Rectangle().fill(Theme.border).frame(height: 1)
                }
        )
    }

    // MARK: - Error Controls

    @ViewBuilder
    var errorControls: some View {
        // Mode toggle: require both videos
        if engine.hasMediaA && engine.hasMediaB {
            Picker("", selection: $engine.displayMode) {
                ForEach(DisplayMode.allCases, id: \.self) { mode in
                    Label(mode.label, systemImage: mode.icon).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 120)
            .help("Toggle Split/Error mode (E)")

            // Error metric picker: always visible when both sides are loaded.
            // In split mode the picker still matters because the hover readout
            // and per-pixel value overlay display the chosen metric.
            Divider().frame(height: 16)

            Picker("Metric", selection: $engine.errorMetric) {
                ForEach(ErrorMetric.allCases, id: \.self) { m in
                    Text(m.label).tag(m)
                }
            }
            .frame(width: 140)
            .help("Error metric (M to cycle) — drives both error-mode rendering and the hover/value readouts")

            // Explorer toggle — surfaces top-error regions by category.
            // Only meaningful with both sides loaded; disabled otherwise so
            // the persisted explorerOpen flag isn't silently toggled.
            Divider().frame(height: 16)
            let canExplore = engine.hasMediaA && engine.hasMediaB
            Button {
                engine.explorerOpen.toggle()
                if engine.explorerOpen && engine.analysisResult == nil {
                    engine.runAnalysis()
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "scope")
                    Text("Explore")
                }
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(canExplore ? Theme.text.opacity(0.9) : Theme.muted.opacity(0.6))
            }
            .buttonStyle(GhostButtonStyle(active: engine.explorerOpen && canExplore))
            .disabled(!canExplore)
            .help(canExplore
                  ? "Toggle HDR error exploration (X)"
                  : "Load both A and B to enable error exploration")
        }

        // Visualization mode + per-operator inline params.
        // Modes with a single knob (gamma, reinhard) get an inline slider so
        // the popover gear only appears for the multi-knob piecewise mode.
        if engine.hasMediaA || engine.hasMediaB {
            Picker("Vis", selection: $engine.tonemapMode) {
                ForEach(TonemapMode.orderedCases, id: \.self) { m in
                    Text(m.label).tag(m)
                }
            }
            .frame(width: 120)
            .help("Visualization mode (F to cycle)")

            switch engine.tonemapMode {
            case .gamma:
                inlineSlider(label: "γ",
                             value: $engine.gamma,
                             range: 0.1...5.0,
                             step: 0.1,
                             format: "%.1f",
                             width: 60)
            case .reinhard:
                inlineSlider(label: "Wp",
                             value: $engine.reinhardWhitepoint,
                             range: 0.1...16.0,
                             step: 0.1,
                             format: "%.1f",
                             width: 60)
            case .piecewise:
                TonemapSettingsButton(engine: engine)
            case .linear, .aces, .filmic, .falseColor, .positiveNegative:
                EmptyView()
            }
        }

        // Exposure (applies pre-tonemap to every operator).
        if engine.hasMediaA || engine.hasMediaB {
            Divider().frame(height: 16)

            HStack(spacing: 3) {
                Text("EV")
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(.tertiary)
                Text("\(engine.exposure, specifier: "%+.1f")")
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(width: 32, alignment: .trailing)
            }
            Slider(value: $engine.exposure, in: -10...10, step: 0.1)
                .frame(width: 70)
                .controlSize(.mini)
        }
    }

    // MARK: - Button Helpers

    /// Compact inline slider with monospaced label + readout. Used for the
    /// single-knob tonemap operators that don't justify opening the popover.
    @ViewBuilder
    func inlineSlider(label: String,
                      value: Binding<Double>,
                      range: ClosedRange<Double>,
                      step: Double,
                      format: String,
                      width: CGFloat) -> some View {
        HStack(spacing: 3) {
            Text(label)
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(.tertiary)
            Text(String(format: format, value.wrappedValue))
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 28, alignment: .trailing)
        }
        Slider(value: value, in: range, step: step)
            .frame(width: width)
            .controlSize(.mini)
    }

    func iconButton(_ systemName: String, size: CGFloat = 13, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: size, weight: .medium))
                .foregroundStyle(Theme.text.opacity(0.82))
                .frame(width: 28, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(IconButtonStyle())
    }

    func compactButton(_ label: String, icon: String, color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: icon)
                    .foregroundStyle(color)
                Text(label)
            }
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(Theme.text.opacity(0.9))
        }
        .buttonStyle(GhostButtonStyle())
    }

    // MARK: - File Open

    func openFile(for side: MediaSide) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = mediaContentTypes()
        // Allow a single file, multiple frames, or a folder. Multiple files or a
        // folder load as an image sequence on this side.
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.message = "Select a video/image, multiple frames, or a folder for \(side == .a ? "A (left)" : "B (right)")"
        panel.treatsFilePackagesAsDirectories = false
        if panel.runModal() == .OK, !panel.urls.isEmpty {
            engine.loadForSide(panel.urls, side: side)
        }
    }

    func mediaContentTypes() -> [UTType] {
        var types: [UTType] = [.movie, .video, .mpeg4Movie, .quickTimeMovie, .mpeg2Video, .image]
        // Resolve any extra extensions the system knows by file extension (covers
        // image formats like webp / exr / hdr / raw and exotic video containers).
        let extras = MediaType.videoExtensions.union(MediaType.imageExtensions)
        for ext in extras {
            if let t = UTType(filenameExtension: ext) {
                types.append(t)
            }
        }
        return types
    }
}

// MARK: - Window discovery
// Tiny NSViewRepresentable that captures its parent NSWindow when the view is
// added to the hierarchy. Used so each ContentView can tell when its own
// window becomes key (vs. some other window in the app).
private struct WindowAccessor: NSViewRepresentable {
    @Binding var window: NSWindow?
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { [weak view] in
            self.window = view?.window
        }
        return view
    }
    func updateNSView(_ nsView: NSView, context: Context) {}
}
