import AVFoundation
import Combine
import CoreImage
import Metal
import QuartzCore

enum VideoSide { case a, b }

enum DisplayMode: Int, CaseIterable {
    case split = 0
    case error = 1
}

enum ErrorMetric: Int, CaseIterable {
    case error = 0
    case absoluteError = 1
    case squaredError = 2
    case relativeAbsolute = 3
    case relativeSquared = 4
}

enum TonemapMode: Int, CaseIterable {
    case gamma = 0
    case falseColor = 1
    case positiveNegative = 2
}

@MainActor
final class VideoEngine: ObservableObject {
    // MARK: - Players
    private(set) var playerA: AVPlayer?
    private(set) var playerB: AVPlayer?
    private(set) var videoOutputA: AVPlayerItemVideoOutput?
    private(set) var videoOutputB: AVPlayerItemVideoOutput?

    // MARK: - Published State
    @Published var isPlaying = false
    @Published var currentTime: Double = 0
    @Published var duration: Double = 0
    @Published var currentFrame: Int = 0
    @Published var seekPosition: Double = 0
    @Published var sliderPosition: Double = 0.5
    @Published var zoom: Double = 1.0
    @Published var panOffset: CGPoint = .zero
    @Published var hasVideoA = false
    @Published var hasVideoB = false
    @Published var videoNameA: String?
    @Published var videoNameB: String?

    // Error visualization
    @Published var displayMode: DisplayMode = .split
    @Published var errorMetric: ErrorMetric = .error
    @Published var tonemapMode: TonemapMode = .gamma
    @Published var exposure: Double = 0.0
    @Published var gamma: Double = 2.2

    var frameRateA: Double = 24
    var frameRateB: Double = 24
    var videoSizeA: CGSize = CGSize(width: 1920, height: 1080)
    var videoSizeB: CGSize = CGSize(width: 1920, height: 1080)

    // MARK: - Internal
    private var timeObserver: Any?
    private var cancellables = Set<AnyCancellable>()
    var isScrubbing = false

    var currentTimeString: String { formatTime(currentTime) }
    var durationString: String { formatTime(duration) }

    var referenceAspectRatio: Double {
        if hasVideoA { return videoSizeA.width / videoSizeA.height }
        if hasVideoB { return videoSizeB.width / videoSizeB.height }
        return 16.0 / 9.0
    }

    // MARK: - Load Video

    func loadVideo(url: URL, side: VideoSide) {
        let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        let playerItem = AVPlayerItem(asset: asset)

        // Request native pixel format with Metal compatibility
        let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [
            kCVPixelBufferMetalCompatibilityKey as String: true
        ])
        playerItem.add(output)

        let player = AVPlayer(playerItem: playerItem)
        player.actionAtItemEnd = .pause
        player.isMuted = true

        switch side {
        case .a:
            playerA?.pause()
            playerA = player
            videoOutputA = output
            hasVideoA = true
            videoNameA = url.lastPathComponent
        case .b:
            playerB?.pause()
            playerB = player
            videoOutputB = output
            hasVideoB = true
            videoNameB = url.lastPathComponent
        }

        // Load track info asynchronously
        Task { [weak self] in
            guard let self else { return }
            do {
                let tracks = try await asset.loadTracks(withMediaType: .video)
                guard let track = tracks.first else { return }

                let size = try await track.load(.naturalSize)
                let transform = try await track.load(.preferredTransform)
                let fps = try await track.load(.nominalFrameRate)
                let dur = try await asset.load(.duration)

                await MainActor.run {
                    let rotated = size.applying(transform)
                    let finalSize = CGSize(width: abs(rotated.width), height: abs(rotated.height))

                    switch side {
                    case .a:
                        self.frameRateA = max(1, Double(fps))
                        self.videoSizeA = finalSize
                    case .b:
                        self.frameRateB = max(1, Double(fps))
                        self.videoSizeB = finalSize
                    }

                    self.duration = max(self.duration, dur.seconds)
                    self.setupTimeObserver()

                    // Seek to the start to show first frame
                    player.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero)

                    // Sync with existing video
                    if self.hasVideoA && self.hasVideoB {
                        self.syncPlayersNow()
                    }
                }
            } catch {
                print("Failed to load video track: \(error)")
            }
        }
    }

    // MARK: - Transport

    func togglePlayPause() {
        if isPlaying { pause() } else { play() }
    }

    func play() {
        guard hasVideoA || hasVideoB else { return }
        syncPlayersNow()
        playerA?.rate = 1.0
        playerB?.rate = 1.0
        isPlaying = true
    }

    func pause() {
        playerA?.rate = 0
        playerB?.rate = 0
        isPlaying = false
    }

    func stepForward() {
        pause()
        playerA?.currentItem?.step(byCount: 1)
        playerB?.currentItem?.step(byCount: 1)
        updateTimeFromPlayer()
    }

    func stepBackward() {
        pause()
        playerA?.currentItem?.step(byCount: -1)
        playerB?.currentItem?.step(byCount: -1)
        updateTimeFromPlayer()
    }

    func seekToStart() {
        seek(to: .zero)
    }

    func seekToEnd() {
        let d = playerA?.currentItem?.duration ?? playerB?.currentItem?.duration ?? .zero
        if d.isValid && !d.isIndefinite {
            seek(to: d)
        }
    }

    func seekToPosition(_ position: Double) {
        isScrubbing = true
        let time = CMTime(seconds: position * duration, preferredTimescale: 9000)
        seek(to: time)
        // Brief delay before allowing time observer to update seekPosition
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            self?.isScrubbing = false
        }
    }

    func seekToFrame(_ frame: Int) {
        let time = CMTime(value: CMTimeValue(frame), timescale: CMTimeScale(frameRateA))
        seek(to: time)
    }

    func seek(to time: CMTime) {
        playerA?.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
        playerB?.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
        updateTimeFromPlayer()
    }

    // MARK: - Zoom & Pan

    func resetView() {
        zoom = 1.0
        panOffset = .zero
    }

    func zoomAtPoint(factor: Double, viewPoint: CGPoint, viewSize: CGSize) {
        let cx = viewPoint.x / viewSize.width
        let cy = 1.0 - viewPoint.y / viewSize.height

        let oldZoom = zoom
        let newZoom = max(0.1, min(200, oldZoom * factor))
        let invDiff = 1.0 / oldZoom - 1.0 / newZoom

        panOffset = CGPoint(
            x: (cx - 0.5) * invDiff + panOffset.x,
            y: (cy - 0.5) * invDiff + panOffset.y
        )
        zoom = newZoom
    }

    // MARK: - Private

    private func syncPlayersNow() {
        let time = playerA?.currentTime() ?? playerB?.currentTime() ?? .zero
        if let pB = playerB, hasVideoA {
            pB.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
        }
        if let pA = playerA, hasVideoB && !hasVideoA {
            pA.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
        }
    }

    private func setupTimeObserver() {
        if let old = timeObserver {
            (playerA ?? playerB)?.removeTimeObserver(old)
            timeObserver = nil
        }

        guard let player = playerA ?? playerB else { return }

        let interval = CMTime(value: 1, timescale: 30)
        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) {
            [weak self] time in
            guard let self else { return }
            Task { @MainActor in
                self.currentTime = time.seconds
                self.currentFrame = Int(time.seconds * self.frameRateA)
                if !self.isScrubbing && self.duration > 0 {
                    self.seekPosition = time.seconds / self.duration
                }

                // Re-sync player B if drifted
                if self.isPlaying, let pA = self.playerA, let pB = self.playerB {
                    let drift = abs(pA.currentTime().seconds - pB.currentTime().seconds)
                    if drift > 0.03 { // More than ~1 frame at 30fps
                        pB.seek(to: pA.currentTime(), toleranceBefore: .zero, toleranceAfter: .zero)
                    }
                }
            }
        }
    }

    private func updateTimeFromPlayer() {
        let time = playerA?.currentTime() ?? playerB?.currentTime() ?? .zero
        currentTime = time.seconds
        currentFrame = Int(time.seconds * frameRateA)
        if duration > 0 {
            seekPosition = time.seconds / duration
        }
    }

    private func formatTime(_ seconds: Double) -> String {
        guard seconds.isFinite && seconds >= 0 else { return "00:00:00.00" }
        let h = Int(seconds) / 3600
        let m = (Int(seconds) % 3600) / 60
        let s = Int(seconds) % 60
        let cs = Int((seconds.truncatingRemainder(dividingBy: 1)) * 100)
        if h > 0 {
            return String(format: "%d:%02d:%02d.%02d", h, m, s, cs)
        }
        return String(format: "%02d:%02d.%02d", m, s, cs)
    }
}
