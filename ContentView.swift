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
    @StateObject private var engine = VideoEngine()
    @State private var frameInput: String = ""

    var body: some View {
        VStack(spacing: 0) {
            // Video viewport with overlays
            ZStack {
                MetalComparisonView(engine: engine)

                // Video name overlays
                VStack {
                    HStack(alignment: .top) {
                        if let name = engine.videoNameA {
                            videoLabel(name, color: .blue)
                                .padding(.leading, 12)
                                .padding(.top, 10)
                        }
                        Spacer()
                        if let name = engine.videoNameB {
                            videoLabel(name, color: .orange)
                                .padding(.trailing, 12)
                                .padding(.top, 10)
                        }
                    }
                    Spacer()
                }
                .allowsHitTesting(false)

                // Empty state
                if !engine.hasVideoA && !engine.hasVideoB {
                    emptyStateView
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            controlsBar
        }
        .background(Color.black)
        .preferredColorScheme(.dark)
        .focusable()
        .onKeyPress(.space) { engine.togglePlayPause(); return .handled }
        .onKeyPress(.leftArrow) { engine.stepBackward(); return .handled }
        .onKeyPress(.rightArrow) { engine.stepForward(); return .handled }
        .onKeyPress(.upArrow) { engine.zoom = min(200, engine.zoom * 1.25); return .handled }
        .onKeyPress(.downArrow) { engine.zoom = max(0.1, engine.zoom / 1.25); return .handled }
        .onKeyPress(.home) { engine.seekToStart(); return .handled }
        .onKeyPress(.end) { engine.seekToEnd(); return .handled }
        .onKeyPress("r") { engine.resetView(); return .handled }
        .onKeyPress("1") { engine.zoom = 1.0; return .handled }
        .onKeyPress("2") { engine.zoom = 2.0; return .handled }
        .onKeyPress("4") { engine.zoom = 4.0; return .handled }
        .onKeyPress("8") { engine.zoom = 8.0; return .handled }
        .onKeyPress("e") {
            if engine.hasVideoA && engine.hasVideoB {
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
            if engine.displayMode == .error {
                let next = (engine.tonemapMode.rawValue + 1) % TonemapMode.allCases.count
                engine.tonemapMode = TonemapMode(rawValue: next)!
            }
            return .handled
        }
    }

    // MARK: - Video Label

    func videoLabel(_ name: String, color: Color) -> some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(name).lineLimit(1).truncationMode(.middle)
        }
        .font(.system(size: 12, weight: .medium, design: .monospaced))
        .foregroundStyle(.white)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(.black.opacity(0.65), in: RoundedRectangle(cornerRadius: 6))
    }

    // MARK: - Empty State

    var emptyStateView: some View {
        VStack(spacing: 16) {
            Image(systemName: "film.stack")
                .font(.system(size: 48, weight: .thin))
                .foregroundStyle(.secondary)
            Text("Open two videos to compare")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(.secondary)
            HStack(spacing: 12) {
                Button("Open Video A") { openFile(for: .a) }
                Button("Open Video B") { openFile(for: .b) }
            }
            .buttonStyle(.bordered)
        }
    }

    // MARK: - Controls Bar

    var controlsBar: some View {
        VStack(spacing: 0) {
            // Timeline
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

            // Transport + controls
            HStack(spacing: 6) {
                // Open buttons
                compactButton("Open A", icon: "a.square.fill", color: .blue) { openFile(for: .a) }
                compactButton("Open B", icon: "b.square.fill", color: .orange) { openFile(for: .b) }

                Spacer().frame(width: 4)

                // Transport
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

                // Display mode + error controls
                errorControls

                Spacer()

                // Frame info
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
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        }
        .background(Color(white: 0.1))
    }

    // MARK: - Error Controls

    @ViewBuilder
    var errorControls: some View {
        if engine.hasVideoA && engine.hasVideoB {
            // Display mode toggle
            Picker("", selection: $engine.displayMode) {
                ForEach(DisplayMode.allCases, id: \.self) { mode in
                    Label(mode.label, systemImage: mode.icon).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 120)
            .help("Toggle Split/Error mode (E)")

            if engine.displayMode == .error {
                Divider().frame(height: 16)

                // Error metric
                Picker("Metric", selection: $engine.errorMetric) {
                    ForEach(ErrorMetric.allCases, id: \.self) { m in
                        Text(m.label).tag(m)
                    }
                }
                .frame(width: 120)
                .help("Error metric (M to cycle)")

                // Tonemap mode
                Picker("Vis", selection: $engine.tonemapMode) {
                    ForEach(TonemapMode.allCases, id: \.self) { m in
                        Text(m.label).tag(m)
                    }
                }
                .frame(width: 120)
                .help("Visualization mode (F to cycle)")

                Divider().frame(height: 16)

                // Exposure
                HStack(spacing: 3) {
                    Text("EV")
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundStyle(.tertiary)
                    Text("\(engine.exposure, specifier: "%+.1f")")
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .frame(width: 32, alignment: .trailing)
                }
                Slider(value: $engine.exposure, in: -10...10, step: 0.5)
                    .frame(width: 70)
                    .controlSize(.mini)

                // Gamma (only in gamma tonemap mode)
                if engine.tonemapMode == .gamma {
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

    func openFile(for side: VideoSide) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = videoContentTypes()
        panel.allowsMultipleSelection = false
        panel.message = "Select video \(side == .a ? "A (left)" : "B (right)")"
        panel.treatsFilePackagesAsDirectories = false
        if panel.runModal() == .OK, let url = panel.url {
            engine.loadVideo(url: url, side: side)
        }
    }

    func videoContentTypes() -> [UTType] {
        var types: [UTType] = [.movie, .video, .mpeg4Movie, .quickTimeMovie, .mpeg2Video]
        let extensions = ["mkv", "webm", "avi", "ts", "m2ts", "mts", "flv", "wmv", "vob", "y4m"]
        for ext in extensions {
            if let type = UTType(filenameExtension: ext) {
                types.append(type)
            }
        }
        return types
    }
}
