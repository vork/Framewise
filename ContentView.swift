import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @StateObject private var engine = VideoEngine()
    @State private var frameInput: String = ""
    @State private var isHoveringA = false
    @State private var isHoveringB = false

    var body: some View {
        VStack(spacing: 0) {
            // Video viewport with overlays
            ZStack {
                MetalComparisonView(engine: engine)

                // Video name overlays - pinned to top corners
                VStack {
                    HStack(alignment: .top) {
                        // A label - top left
                        if let name = engine.videoNameA {
                            videoLabel(name, color: .blue)
                                .padding(.leading, 12)
                                .padding(.top, 10)
                        }

                        Spacer()

                        // B label - top right
                        if let name = engine.videoNameB {
                            videoLabel(name, color: .orange)
                                .padding(.trailing, 12)
                                .padding(.top, 10)
                        }
                    }
                    Spacer()
                }
                .allowsHitTesting(false)

                // Drop zone hints when no video loaded
                if !engine.hasVideoA && !engine.hasVideoB {
                    emptyStateView
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            // Controls bar
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
    }

    // MARK: - Video Label

    func videoLabel(_ name: String, color: Color) -> some View {
        HStack(spacing: 6) {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
            Text(name)
                .lineLimit(1)
                .truncationMode(.middle)
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

            // Transport + info bar
            HStack(spacing: 6) {
                // Open buttons
                compactButton("Open A", icon: "a.square.fill", color: .blue) { openFile(for: .a) }
                    .onHover { isHoveringA = $0 }
                compactButton("Open B", icon: "b.square.fill", color: .orange) { openFile(for: .b) }
                    .onHover { isHoveringB = $0 }

                Spacer().frame(width: 8)

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

                Spacer()

                // Frame info
                HStack(spacing: 4) {
                    Text("Frame")
                        .foregroundStyle(.tertiary)
                    Text("\(engine.currentFrame)")
                        .foregroundStyle(.secondary)
                }
                .font(.system(size: 11, weight: .medium, design: .monospaced))

                // Go to frame
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

                Spacer().frame(width: 8)

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
