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
        }
    }
}

extension TonemapMode {
    var label: String {
        switch self {
        case .gamma: return "Gamma"
        case .falseColor: return "False Color"
        case .positiveNegative: return "Pos/Neg"
        }
    }
}

// MARK: - Content View

struct ContentView: View {
    @StateObject private var engine = MediaEngine()
    @State private var frameInput: String = ""
    @State private var showHelp = false

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                MetalComparisonView(engine: engine)

                // Media name overlays
                VStack {
                    HStack(alignment: .top) {
                        if let name = engine.mediaNameA {
                            mediaLabel(name, color: .blue) {
                                engine.unloadMedia(side: .a)
                            }
                            .padding(.leading, 12)
                            .padding(.top, 10)
                        }
                        Spacer()
                        if let name = engine.mediaNameB {
                            mediaLabel(name, color: .orange) {
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

            controlsBar
        }
        .background(Color.black)
        .preferredColorScheme(.dark)
        .focusable()
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
            if engine.displayMode == .error {
                let next = (engine.errorMetric.rawValue + 1) % ErrorMetric.allCases.count
                engine.errorMetric = ErrorMetric(rawValue: next)!
            }
            return .handled
        }
        .onKeyPress("f") {
            let next = (engine.tonemapMode.rawValue + 1) % TonemapMode.allCases.count
            engine.tonemapMode = TonemapMode(rawValue: next)!
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
        // ── Help ─────────────────────────────────────────────
        .onKeyPress("?") { showHelp.toggle(); return .handled }
        .onKeyPress(.escape) {
            if showHelp { showHelp = false; return .handled }
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
        .background(.black.opacity(0.65), in: RoundedRectangle(cornerRadius: 6))
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
                sampleChip(label: "A", color: .blue, sample: s)
            }
            if let s = b {
                sampleChip(label: "B", color: .orange, sample: s)
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
        .background(.black.opacity(0.65), in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(.white.opacity(0.08), lineWidth: 1)
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
        let d = a.rgba - b.rgba
        return HStack(spacing: 6) {
            Text("\u{0394}")
                .foregroundStyle(.white.opacity(0.85))
            channelText("R", d.x, tint: .red.opacity(0.8))
            channelText("G", d.y, tint: .green.opacity(0.8))
            channelText("B", d.z, tint: Color(red: 0.4, green: 0.6, blue: 1.0).opacity(0.8))
        }
        .font(.system(size: 11, weight: .medium, design: .monospaced))
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
            Text("Drop on the left half for A, the right half for B  ·  HDR EXR / HDR HEIC supported")
                .font(.system(size: 12))
                .foregroundStyle(.tertiary)
            HStack(spacing: 12) {
                Button("Open A") { openFile(for: .a) }
                Button("Open B") { openFile(for: .b) }
            }
            .buttonStyle(.bordered)
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
                            ("M", "Cycle error metric"),
                            ("F", "Cycle visualization mode"),
                            ("Drag handle", "Move split slider"),
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
            .shadow(color: .black.opacity(0.5), radius: 30)
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
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 4))
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
            // Timeline (only when at least one side is a video)
            if engine.hasPlayableVideo {
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
                compactButton("Open A", icon: "a.square.fill", color: .blue) { openFile(for: .a) }
                compactButton("Open B", icon: "b.square.fill", color: .orange) { openFile(for: .b) }

                Spacer().frame(width: 4)

                if engine.hasPlayableVideo {
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

                if engine.hasPlayableVideo {
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
                        .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 4))
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
        .background(Color(white: 0.1))
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

            // Error metric picker: error mode only
            if engine.displayMode == .error {
                Divider().frame(height: 16)

                Picker("Metric", selection: $engine.errorMetric) {
                    ForEach(ErrorMetric.allCases, id: \.self) { m in
                        Text(m.label).tag(m)
                    }
                }
                .frame(width: 120)
                .help("Error metric (M to cycle)")
            }
        }

        // Visualization mode: available with any video loaded
        if engine.hasMediaA || engine.hasMediaB {
            Picker("Vis", selection: $engine.tonemapMode) {
                ForEach(TonemapMode.allCases, id: \.self) { m in
                    Text(m.label).tag(m)
                }
            }
            .frame(width: 120)
            .help("Visualization mode (F to cycle)")
        }

        // Exposure & gamma: available with any video loaded
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

            HStack(spacing: 3) {
                Text("\u{03B3}")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.tertiary)
                Text("\(engine.gamma, specifier: "%.1f")")
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(width: 24, alignment: .trailing)
            }
            Slider(value: $engine.gamma, in: 0.1...5.0, step: 0.1)
                .frame(width: 50)
                .controlSize(.mini)
        }
    }

    // MARK: - Button Helpers

    func iconButton(_ systemName: String, size: CGFloat = 13, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: size, weight: .medium))
                .foregroundStyle(.white.opacity(0.8))
                .frame(width: 28, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    func compactButton(_ label: String, icon: String, color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .foregroundStyle(color)
                Text(label)
            }
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.white.opacity(0.8))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 5))
        }
        .buttonStyle(.plain)
    }

    // MARK: - File Open

    func openFile(for side: MediaSide) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = mediaContentTypes()
        panel.allowsMultipleSelection = false
        panel.message = "Select video or image for \(side == .a ? "A (left)" : "B (right)")"
        panel.treatsFilePackagesAsDirectories = false
        if panel.runModal() == .OK, let url = panel.url {
            engine.loadMedia(url: url, side: side)
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
