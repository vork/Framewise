import SwiftUI

// MARK: - View options popover
//
// Houses the "pro viewing" controls that don't warrant permanent toolbar real
// estate: channel isolation, clipping / gamut warnings, playback-speed
// reduction, A/B alignment offset, and segment looping. Each section hides
// itself when it isn't applicable to the current media.

struct ViewOptionsButton: View {
    @ObservedObject var engine: MediaEngine
    @State private var isOpen = false

    /// True when any non-default viewing option is active — surfaces a brand
    /// dot on the button so the user knows something is engaged.
    private var anyActive: Bool {
        engine.channelMode != .rgb ||
        engine.clipWarning || engine.gamutWarning ||
        engine.playbackSpeed != .full ||
        engine.loopEnabled
    }

    var body: some View {
        Button { isOpen.toggle() } label: {
            ZStack(alignment: .topTrailing) {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Theme.text.opacity(0.85))
                    .frame(width: 24, height: 22)
                if anyActive {
                    Circle().fill(Theme.accentA).frame(width: 5, height: 5)
                        .offset(x: 2, y: -1)
                }
            }
        }
        .buttonStyle(GhostButtonStyle(active: isOpen || anyActive))
        .help("Viewing options — channels, warnings, speed, offset, loop")
        .popover(isPresented: $isOpen, arrowEdge: .bottom) {
            ViewOptionsPopover(engine: engine)
        }
    }
}

private struct ViewOptionsPopover: View {
    @ObservedObject var engine: MediaEngine

    private var bothVideo: Bool {
        engine.mediaKindA == .video && engine.mediaKindB == .video
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            channelSection
            Divider().opacity(0.4)
            warningsSection

            if engine.hasSequence {
                Divider().opacity(0.4)
                sequenceSection
            }
            if engine.hasTimeline {
                Divider().opacity(0.4)
                playbackSection
            }
            if false && bothVideo {
                Divider().opacity(0.4)
                offsetSection
            }
            if engine.hasTimeline {
                Divider().opacity(0.4)
                loopSection
            }
        }
        .padding(16)
        .frame(width: 320)
    }

    // MARK: Sequence frame rate

    private static let fpsPresets: [Double] = [23.976, 24, 25, 30, 50, 60]

    private var sequenceSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader("Sequence frame rate", systemImage: "film.stack")
            Picker("", selection: $engine.sequenceFrameRate) {
                ForEach(Self.fpsPresets, id: \.self) { fps in
                    Text(fpsLabel(fps)).tag(fps)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            Text("Image sequences carry no timing — pick the playback rate.")
                .font(.system(size: 10)).foregroundStyle(Theme.muted)
        }
    }

    private func fpsLabel(_ fps: Double) -> String {
        fps == fps.rounded() ? String(format: "%.0f", fps) : String(format: "%.2f", fps)
    }

    // MARK: Channels

    private var channelSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader("Channel", systemImage: "circle.lefthalf.filled")
            Picker("", selection: $engine.channelMode) {
                ForEach(ChannelMode.allCases) { ch in
                    Text(ch.short).tag(ch)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            Text("Press C to cycle. Isolates one channel as grayscale.")
                .font(.system(size: 10)).foregroundStyle(Theme.muted)
        }
    }

    // MARK: Warnings

    private var warningsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader("Warnings", systemImage: "exclamationmark.triangle")
            Toggle(isOn: $engine.clipWarning) {
                HStack(spacing: 6) {
                    swatch(.init(red: 1, green: 0, blue: 1))
                    swatch(.init(red: 0, green: 0.4, blue: 1))
                    Text("Clipping (blown / crushed)").font(.system(size: 11))
                }
            }
            .toggleStyle(.switch)
            Toggle(isOn: $engine.gamutWarning) {
                HStack(spacing: 6) {
                    swatch(.yellow)
                    Text("Out-of-gamut").font(.system(size: 11))
                }
            }
            .toggleStyle(.switch)
        }
    }

    // MARK: Playback speed

    private var playbackSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader("Playback speed", systemImage: "speedometer")
            Picker("", selection: $engine.playbackSpeed) {
                ForEach(PlaybackSpeed.allCases) { s in
                    Text(s.label).tag(s)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        }
    }

    // MARK: A/B offset

    private var offsetSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader("A/B offset", systemImage: "arrow.left.and.right")
            HStack(spacing: 8) {
                Button { engine.nudgeOffset(-1) } label: {
                    Image(systemName: "minus")
                }
                .buttonStyle(GhostButtonStyle())
                Text("\(engine.abOffsetFrames >= 0 ? "+" : "")\(engine.abOffsetFrames) fr")
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Theme.text)
                    .frame(width: 70)
                Button { engine.nudgeOffset(1) } label: {
                    Image(systemName: "plus")
                }
                .buttonStyle(GhostButtonStyle())
                Spacer()
                if engine.abOffsetFrames != 0 {
                    Button("Reset") { engine.abOffsetFrames = 0 }
                        .buttonStyle(GhostButtonStyle())
                        .font(.system(size: 11))
                }
            }
            Text("Shifts B relative to A to align clips that start a few frames apart.")
                .font(.system(size: 10)).foregroundStyle(Theme.muted)
        }
    }

    // MARK: Loop

    private var loopSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader("Segment loop", systemImage: "repeat")
            HStack(spacing: 8) {
                Toggle("On", isOn: Binding(
                    get: { engine.loopEnabled },
                    set: { _ in engine.toggleLoop() }
                ))
                .toggleStyle(.switch)
                Spacer()
                Button("Set In") { engine.setLoopIn() }
                    .buttonStyle(GhostButtonStyle())
                    .font(.system(size: 11))
                Button("Set Out") { engine.setLoopOut() }
                    .buttonStyle(GhostButtonStyle())
                    .font(.system(size: 11))
            }
            if engine.hasLoopRegion {
                Text("In \(timeStr(engine.loopStart))  ·  Out \(timeStr(engine.loopEnd))")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(Theme.muted)
            }
            Text("Keys: I / O set in/out, L toggles loop.")
                .font(.system(size: 10)).foregroundStyle(Theme.muted)
        }
    }

    // MARK: Helpers

    private func sectionHeader(_ title: String, systemImage: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: systemImage)
                .font(.system(size: 11))
                .foregroundStyle(Theme.accentA)
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.text)
        }
    }

    private func swatch(_ c: Color) -> some View {
        RoundedRectangle(cornerRadius: 2).fill(c).frame(width: 10, height: 10)
    }

    private func timeStr(_ s: Double) -> String {
        guard s.isFinite, s >= 0 else { return "0:00.00" }
        let m = Int(s) / 60, sec = Int(s) % 60
        let cs = Int((s.truncatingRemainder(dividingBy: 1)) * 100)
        return String(format: "%d:%02d.%02d", m, sec, cs)
    }
}
