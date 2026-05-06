import AVFoundation
import Combine
import CoreImage
import ImageIO
import Metal
import QuartzCore

enum MediaSide { case a, b }
enum MediaKind: Int { case video = 0, image = 1 }

enum MediaType {
    static let imageExtensions: Set<String> = [
        "jpg", "jpeg", "png", "gif", "tif", "tiff", "bmp", "heic", "heif",
        "webp", "exr", "hdr", "dng", "cr2", "cr3", "nef", "arw", "raf",
        "orf", "pef", "rw2", "srw", "ico", "icns"
    ]
    static let videoExtensions: Set<String> = [
        "mov", "mp4", "m4v", "mkv", "webm", "avi", "ts", "m2ts",
        "mts", "flv", "wmv", "vob", "y4m", "mpg", "mpeg"
    ]
    static func isImage(_ url: URL) -> Bool {
        imageExtensions.contains(url.pathExtension.lowercased())
    }
    static func isVideo(_ url: URL) -> Bool {
        videoExtensions.contains(url.pathExtension.lowercased())
    }
    static func isSupported(_ url: URL) -> Bool {
        isImage(url) || isVideo(url)
    }
}

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

    /// Same formulas as the Metal `computeError` in `ShaderSource.swift`,
    /// using the same epsilon (0.01) for the relative metrics so the chip
    /// readout matches the on-screen pixels exactly.
    func apply(a: SIMD3<Float>, b: SIMD3<Float>) -> SIMD3<Float> {
        let diff = a - b
        switch self {
        case .error:            return diff
        case .absoluteError:    return abs(diff)
        case .squaredError:     return diff * diff
        case .relativeAbsolute:
            let denom = abs(b) + SIMD3<Float>(repeating: 0.01)
            return abs(diff) / denom
        case .relativeSquared:
            let denom = b * b + SIMD3<Float>(repeating: 0.01)
            return (diff * diff) / denom
        }
    }
}

private func abs(_ v: SIMD3<Float>) -> SIMD3<Float> {
    SIMD3<Float>(Swift.abs(v.x), Swift.abs(v.y), Swift.abs(v.z))
}

enum TonemapMode: Int, CaseIterable {
    case gamma = 0
    case falseColor = 1
    case positiveNegative = 2
}

@MainActor
final class MediaEngine: ObservableObject {
    // MARK: - Players (videos)
    private(set) var playerA: AVPlayer?
    private(set) var playerB: AVPlayer?
    private(set) var videoOutputA: AVPlayerItemVideoOutput?
    private(set) var videoOutputB: AVPlayerItemVideoOutput?

    // MARK: - Images
    // For image-mode media, the source CIImage is held here; the renderer
    // re-uploads to the comparison texture whenever `imageVersion*` changes.
    private(set) var imageA: CIImage?
    private(set) var imageB: CIImage?
    @Published private(set) var imageVersionA: Int = 0
    @Published private(set) var imageVersionB: Int = 0

    // MARK: - Published State
    @Published var isPlaying = false
    @Published var currentTime: Double = 0
    @Published var duration: Double = 0
    @Published var currentFrame: Int = 0
    @Published var seekPosition: Double = 0
    @Published var sliderPosition: Double = 0.5
    @Published var zoom: Double = 1.0
    @Published var panOffset: CGPoint = .zero
    @Published var hasMediaA = false
    @Published var hasMediaB = false
    @Published var mediaNameA: String?
    @Published var mediaNameB: String?
    @Published var mediaKindA: MediaKind?
    @Published var mediaKindB: MediaKind?

    /// True when at least one side holds something the transport can drive.
    var hasPlayableVideo: Bool {
        mediaKindA == .video || mediaKindB == .video
    }

    // Error visualization (persisted)
    @Published var displayMode: DisplayMode = .split {
        didSet { UserDefaults.standard.set(displayMode.rawValue, forKey: "displayMode") }
    }
    @Published var errorMetric: ErrorMetric = .error {
        didSet { UserDefaults.standard.set(errorMetric.rawValue, forKey: "errorMetric") }
    }
    @Published var tonemapMode: TonemapMode = .gamma {
        didSet { UserDefaults.standard.set(tonemapMode.rawValue, forKey: "tonemapMode") }
    }
    @Published var exposure: Double = 0.0
    @Published var gamma: Double = 2.2

    // Pixel inspection (auto-shows grid + RGB values when zoomed in close enough)
    @Published var pixelInspect: Bool = true {
        didSet { UserDefaults.standard.set(pixelInspect, forKey: "pixelInspect") }
    }

    // MARK: - Hover readout
    /// One sampled pixel from the source CIImage of one side, in linear sRGB
    /// (extended range, so HDR EXR / HDR HEIC values can exceed 1.0).
    struct PixelSample: Equatable {
        var pixel: CGPoint            // top-left origin, integer-aligned
        var rgba: SIMD4<Float>        // linear sRGB, extended
        var hasAlpha: Bool            // true when source has a non-opaque alpha channel
    }

    @Published private(set) var hoverSampleA: PixelSample?
    @Published private(set) var hoverSampleB: PixelSample?

    /// The most recent frame's CIImage for each side, used by hover-sampling.
    /// For images this is set by `loadImage`; for videos it is updated by the
    /// renderer every time it pulls a new pixel buffer.
    var latestCIImageA: CIImage?
    var latestCIImageB: CIImage?

    var frameRateA: Double = 24
    var frameRateB: Double = 24
    var mediaSizeA: CGSize = CGSize(width: 1920, height: 1080)
    var mediaSizeB: CGSize = CGSize(width: 1920, height: 1080)

    // MARK: - Internal
    private var timeObserver: Any?
    // Track which player the time observer was registered on. Without this,
    // removing the observer from `(playerA ?? playerB)` after one side is
    // unloaded picks the wrong player and AVPlayer fatal-errors (or worse,
    // dereferences a dangling token from the deallocated original owner).
    private weak var timeObserverOwner: AVPlayer?
    private var cancellables = Set<AnyCancellable>()
    var isScrubbing = false

    // Software-rendered context for 1×1 pixel readbacks. Software path avoids
    // contending with the rendering MTL CIContext on every mouse move and is
    // plenty fast for one-pixel reads.
    private lazy var sampleContext: CIContext = CIContext(options: [
        .workingColorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!,
        .useSoftwareRenderer: true,
        .cacheIntermediates: false,
    ])
    private let readoutColorSpace: CGColorSpace = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!

    // MARK: - Init (restore persisted settings)
    init() {
        let ud = UserDefaults.standard
        if let v = DisplayMode(rawValue: ud.integer(forKey: "displayMode")) { displayMode = v }
        if let v = ErrorMetric(rawValue: ud.integer(forKey: "errorMetric")) { errorMetric = v }
        if let v = TonemapMode(rawValue: ud.integer(forKey: "tonemapMode")) { tonemapMode = v }
        if ud.object(forKey: "pixelInspect") != nil {
            pixelInspect = ud.bool(forKey: "pixelInspect")
        }
    }

    var currentTimeString: String { formatTime(currentTime) }
    var durationString: String { formatTime(duration) }

    var referenceAspectRatio: Double {
        if hasMediaA { return mediaSizeA.width / mediaSizeA.height }
        if hasMediaB { return mediaSizeB.width / mediaSizeB.height }
        return 16.0 / 9.0
    }

    /// The size of whichever side is the reference for the layout (A wins).
    /// Returns nil when no media is loaded.
    var referenceMediaSize: CGSize? {
        if hasMediaA { return mediaSizeA }
        if hasMediaB { return mediaSizeB }
        return nil
    }

    /// Mirror of the shader's per-pixel-text threshold. When this returns true
    /// at the current zoom + view size, the in-shader overlay is drawing
    /// readable RGB(A) values inside every visible pixel cell, so the
    /// SwiftUI hover chip can be suppressed to avoid duplicate readouts.
    func inShaderTextOverlayActive(viewSize: CGSize) -> Bool {
        guard pixelInspect, let size = referenceMediaSize,
              size.width > 0, size.height > 0,
              viewSize.width > 0, viewSize.height > 0 else { return false }
        let fitScale = min(viewSize.width / size.width,
                           viewSize.height / size.height)
        let pixelOnScreen = fitScale * zoom
        return pixelOnScreen > 56.0  // matches `showText` in ShaderSource.swift
    }

    // MARK: - Load / Unload

    /// Dispatch loader: picks video or image path based on extension.
    /// Unsupported files are silently ignored (callers gate via `MediaType.isSupported`).
    func loadMedia(url: URL, side: MediaSide) {
        if MediaType.isImage(url) {
            loadImage(url: url, side: side)
        } else {
            loadVideo(url: url, side: side)
        }
    }

    /// Load 1+ files at once using natural side-selection rules:
    ///
    /// - 1 file: load into the first empty side; if both sides are full,
    ///   replace side A.
    /// - 2+ files: load files[0] → A and files[1] → B, replacing whatever
    ///   is currently on those sides. Extra files are ignored.
    ///
    /// Unsupported files are filtered out before routing.
    func loadMediaBatch(urls: [URL]) {
        let supported = urls.filter { MediaType.isSupported($0) }
        guard !supported.isEmpty else { return }

        if supported.count == 1 {
            let side: MediaSide
            if mediaKindA == nil { side = .a }
            else if mediaKindB == nil { side = .b }
            else { side = .a }
            loadMedia(url: supported[0], side: side)
            return
        }

        loadMedia(url: supported[0], side: .a)
        loadMedia(url: supported[1], side: .b)
    }

    func unloadMedia(side: MediaSide) {
        switch side {
        case .a:
            playerA?.pause()
            playerA = nil
            videoOutputA = nil
            imageA = nil
            latestCIImageA = nil
            hoverSampleA = nil
            hasMediaA = false
            mediaNameA = nil
            mediaKindA = nil
        case .b:
            playerB?.pause()
            playerB = nil
            videoOutputB = nil
            imageB = nil
            latestCIImageB = nil
            hoverSampleB = nil
            hasMediaB = false
            mediaNameB = nil
            mediaKindB = nil
        }
        recalculateDuration()
        // Fall back to split if both sides aren't loaded
        if !(hasMediaA && hasMediaB) {
            displayMode = .split
        }
        setupTimeObserver()
    }

    func loadVideo(url: URL, side: MediaSide) {
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
            imageA = nil
            hasMediaA = true
            mediaNameA = url.lastPathComponent
            mediaKindA = .video
        case .b:
            playerB?.pause()
            playerB = player
            videoOutputB = output
            imageB = nil
            hasMediaB = true
            mediaNameB = url.lastPathComponent
            mediaKindB = .video
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
                        self.mediaSizeA = finalSize
                    case .b:
                        self.frameRateB = max(1, Double(fps))
                        self.mediaSizeB = finalSize
                    }

                    self.duration = max(self.duration, dur.seconds)
                    self.setupTimeObserver()

                    // Seek to the start to show first frame
                    player.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero)

                    // Sync with existing video
                    if self.hasMediaA && self.hasMediaB {
                        self.syncPlayersNow()
                    }
                }
            } catch {
                print("Failed to load video track: \(error)")
            }
        }
    }

    /// Load a still image (jpg/png/webp/heic/exr/hdr/raw/etc.) onto the given side.
    /// Uses CIImage so HDR (EXR / HDR HEIC) and wide-gamut sources are preserved.
    func loadImage(url: URL, side: MediaSide) {
        // `expandToHDR` enables HDR gain-map decoding (HDR HEIC) on macOS 14+;
        // it's harmless for SDR images. EXR/HDR linear values flow through naturally.
        let opts: [CIImageOption: Any] = [.expandToHDR: true]
        guard let raw = CIImage(contentsOf: url, options: opts)
            ?? CIImage(contentsOf: url) else { return }

        // Apply EXIF orientation so camera-rotated JPEGs display upright.
        let exif = (raw.properties[kCGImagePropertyOrientation as String] as? Int32) ?? 1
        let image = raw.oriented(forExifOrientation: exif)

        let size = CGSize(width: image.extent.width, height: image.extent.height)
        guard size.width > 0, size.height > 0 else { return }

        switch side {
        case .a:
            playerA?.pause()
            playerA = nil
            videoOutputA = nil
            imageA = image
            latestCIImageA = image
            imageVersionA &+= 1
            hasMediaA = true
            mediaNameA = url.lastPathComponent
            mediaKindA = .image
            mediaSizeA = size
            frameRateA = 1
        case .b:
            playerB?.pause()
            playerB = nil
            videoOutputB = nil
            imageB = image
            latestCIImageB = image
            imageVersionB &+= 1
            hasMediaB = true
            mediaNameB = url.lastPathComponent
            mediaKindB = .image
            mediaSizeB = size
            frameRateB = 1
        }

        recalculateDuration()
        setupTimeObserver()
    }

    // MARK: - Hover sampling

    /// Update the hover sample at a normalized texture coordinate.
    /// `viewU/V` are in the post-aspect / post-zoom / post-pan tex-coord space,
    /// where (0,0) is the bottom-left of the image and (1,1) is the top-right —
    /// matching the convention used by the vertex shader.
    func setHover(viewU: Double, viewV: Double) {
        let inside = viewU >= 0 && viewU < 1 && viewV >= 0 && viewV < 1
        guard inside else { clearHover(); return }

        if let img = latestCIImageA {
            hoverSampleA = sample(image: img, size: mediaSizeA, u: viewU, v: viewV,
                                  hasAlpha: kindHasAlpha(.a))
        } else {
            hoverSampleA = nil
        }
        if let img = latestCIImageB {
            hoverSampleB = sample(image: img, size: mediaSizeB, u: viewU, v: viewV,
                                  hasAlpha: kindHasAlpha(.b))
        } else {
            hoverSampleB = nil
        }
    }

    func clearHover() {
        if hoverSampleA != nil { hoverSampleA = nil }
        if hoverSampleB != nil { hoverSampleB = nil }
    }

    /// Heuristic: assume video has no meaningful alpha; trust images to tell us.
    /// (Refining further would require sniffing the source via CGImageSource.)
    private func kindHasAlpha(_ side: MediaSide) -> Bool {
        switch side == .a ? mediaKindA : mediaKindB {
        case .image: return true
        default: return false
        }
    }

    private func sample(image: CIImage, size: CGSize, u: Double, v: Double,
                        hasAlpha: Bool) -> PixelSample? {
        let w = Int(size.width.rounded())
        let h = Int(size.height.rounded())
        guard w > 0, h > 0 else { return nil }

        let px = max(0, min(w - 1, Int(u * Double(w))))
        let py = max(0, min(h - 1, Int(v * Double(h))))

        // CIImage's coordinate system is bottom-left origin and may have a
        // non-zero extent origin (e.g. after `oriented(forExifOrientation:)`).
        let extent = image.extent
        let bounds = CGRect(x: CGFloat(px) + extent.origin.x,
                            y: CGFloat(py) + extent.origin.y,
                            width: 1, height: 1)

        var pixel = SIMD4<Float>.zero
        withUnsafeMutablePointer(to: &pixel) { ptr in
            sampleContext.render(image,
                                 toBitmap: UnsafeMutableRawPointer(ptr),
                                 rowBytes: 16,
                                 bounds: bounds,
                                 format: .RGBAf,
                                 colorSpace: readoutColorSpace)
        }

        // Translate to user-friendly top-left-origin pixel coordinates.
        let displayY = h - 1 - py
        return PixelSample(pixel: CGPoint(x: px, y: displayY),
                           rgba: pixel,
                           hasAlpha: hasAlpha)
    }

    private func recalculateDuration() {
        // Use the longest available video duration; images contribute 0.
        var longest: Double = 0
        if let item = playerA?.currentItem, item.duration.isValid, !item.duration.isIndefinite {
            longest = max(longest, item.duration.seconds)
        }
        if let item = playerB?.currentItem, item.duration.isValid, !item.duration.isIndefinite {
            longest = max(longest, item.duration.seconds)
        }
        duration = longest
        if longest == 0 {
            currentTime = 0
            currentFrame = 0
            seekPosition = 0
            isPlaying = false
        }
    }

    // MARK: - Transport

    func togglePlayPause() {
        if isPlaying { pause() } else { play() }
    }

    func play() {
        guard hasPlayableVideo else { return }
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
        // Seek each player to its own last displayable frame
        func seekPlayerToEnd(_ player: AVPlayer?, fps: Double) {
            guard let player, let item = player.currentItem else { return }
            let d = item.duration
            guard d.isValid && !d.isIndefinite else { return }
            let frameDuration = CMTime(seconds: 1.0 / fps, preferredTimescale: 9000)
            let target = CMTimeSubtract(d, frameDuration)
            player.seek(to: target, toleranceBefore: frameDuration, toleranceAfter: .zero)
        }
        seekPlayerToEnd(playerA, fps: frameRateA)
        seekPlayerToEnd(playerB, fps: frameRateB)
        // Defer time update to allow async seeks to land
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            self?.updateTimeFromPlayer()
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
        exposure = 0.0
        gamma = 2.2
    }

    /// Zoom range: 0.1× to 2000× so even 10K assets can reach the per-pixel
    /// text overlay threshold (~56 screen pixels per source pixel).
    static let maxZoom: Double = 2000

    func zoomAtPoint(factor: Double, viewPoint: CGPoint, viewSize: CGSize) {
        let cx = viewPoint.x / viewSize.width
        let cy = 1.0 - viewPoint.y / viewSize.height

        let oldZoom = zoom
        let newZoom = max(0.1, min(Self.maxZoom, oldZoom * factor))
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
        if let pB = playerB, hasMediaA {
            pB.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
        }
        if let pA = playerA, hasMediaB && !hasMediaA {
            pA.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
        }
    }

    private func setupTimeObserver() {
        if let old = timeObserver {
            // Only remove from the player the observer was actually attached
            // to. The owner may already be nil (deallocated when its side was
            // unloaded), in which case AVPlayer has cleaned up the observer
            // for us and there is nothing to remove.
            timeObserverOwner?.removeTimeObserver(old)
            timeObserver = nil
            timeObserverOwner = nil
        }

        guard let player = playerA ?? playerB else { return }

        let interval = CMTime(value: 1, timescale: 30)
        timeObserverOwner = player
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
