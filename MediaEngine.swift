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
    case logLuminance = 5         // log10(A+ε) − log10(B+ε) — HDR scale-aware

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
        case .logLuminance:
            // log10(|a|+ε) − log10(|b|+ε). Matches the shader; the absolute
            // value lets negative HDR values (which CIImage can carry) still
            // produce a well-defined log error.
            let eps = SIMD3<Float>(repeating: 0.001)
            return log10v(abs(a) + eps) - log10v(abs(b) + eps)
        }
    }
}

private func log10v(_ v: SIMD3<Float>) -> SIMD3<Float> {
    SIMD3<Float>(log10f(v.x), log10f(v.y), log10f(v.z))
}

private func abs(_ v: SIMD3<Float>) -> SIMD3<Float> {
    SIMD3<Float>(Swift.abs(v.x), Swift.abs(v.y), Swift.abs(v.z))
}

enum TonemapMode: Int, CaseIterable {
    case gamma = 0
    case falseColor = 1
    case positiveNegative = 2
    case linear = 3                 // clamp to [0,1], no curve
    case reinhard = 4               // extended Reinhard with whitepoint
    case aces = 5                   // Narkowicz fit
    case filmic = 6                 // Hejl-Burgess-Dawson (fixed)
    case piecewise = 7              // Hable filmic piecewise power curves (6 params)

    /// Whether this mode has user-tunable parameters beyond exposure.
    var hasParameters: Bool {
        switch self {
        case .gamma, .reinhard, .piecewise: return true
        case .linear, .aces, .filmic, .falseColor, .positiveNegative: return false
        }
    }
}

/// User-facing parameters for Hable's piecewise power curve. See
/// https://filmicworlds.com/blog/filmic-tonemapping-with-piecewise-power-curves/
/// Matches the parameter set in his reference C++ release.
struct PiecewiseTonemapParams: Equatable, Codable {
    /// 0..1 — toe curvature. 0 = linear into 0, 1 = full crush.
    var toeStrength: Float = 0.0
    /// 0..1 — fraction of input axis taken up by the toe.
    var toeLength: Float = 0.5
    /// 0..∞ — stops of headroom above mid grey before the shoulder rolls to 1.
    /// White point W is derived as `initialW + 2^shoulderStrength − 1`.
    var shoulderStrength: Float = 2.0
    /// 0..1 — fraction of the post-toe range taken by the shoulder.
    var shoulderLength: Float = 0.5
    /// 0..1 — how much the shoulder bends below the linear extension.
    var shoulderAngle: Float = 1.0
    /// >0 — internal curve gamma. 1.0 keeps the middle section truly linear;
    /// raise it to bake more of an "S-curve" into the response.
    var gamma: Float = 1.0
}

/// Precomputed knot coefficients for Hable's piecewise power curve. Computed
/// once on the CPU when params change; shader uses these directly per-pixel.
/// Each segment is a power curve in offset/scaled coordinates:
///   `y = ((x − offsetX) * scaleX)^B * exp(lnA) * scaleY + offsetY`
/// The middle segment is the same form (it's a gamma'd linear), the toe is
/// the form anchored at the origin, and the shoulder is mirrored through
/// the white point.
struct PiecewiseTonemapKnots: Equatable {
    var x0: Float = 0.25, y0: Float = 0.25
    var x1: Float = 0.75, y1: Float = 0.75
    var W: Float = 1.0
    var overshootX: Float = 0
    var overshootY: Float = 0

    // Toe: anchored at origin. y = exp(lnA + B*ln(x))
    var toeLnA: Float = 0, toeB: Float = 1
    // Middle: y = exp(midLnA + midB*ln(x - midOffsetX))  → (m*x+b)^gamma form.
    var midOffsetX: Float = 0
    var midLnA: Float = 0, midB: Float = 1
    // Shoulder: mirrored at (shoulderOffsetX, shoulderOffsetY).
    var shoulderOffsetX: Float = 1, shoulderOffsetY: Float = 1
    var shoulderLnA: Float = 0, shoulderB: Float = 1

    /// Multiplier baked into the curve so eval(W) == 1.
    var invScale: Float = 1.0
}

/// Port of Hable's `CalcDirectParamsFromUser` + `CreateCurve`. The two-step
/// process turns the 6 user knobs into segment coefficients with C1 continuity
/// at the knots, then normalizes so the white point lands at output 1.
func computePiecewiseKnots(_ p: PiecewiseTonemapParams) -> PiecewiseTonemapKnots {
    var k = PiecewiseTonemapKnots()

    let toeStrength = max(0, min(1, p.toeStrength))
    let toeLength = max(0, min(1, p.toeLength))
    let shoulderStrength = max(0, p.shoulderStrength)
    let shoulderLength = max(0, min(1, p.shoulderLength))
    let shoulderAngle = max(0, min(1, p.shoulderAngle))
    let gamma = max(0.01, p.gamma)

    // ── Direct params ───────────────────────────────────────────────
    // Toe end (pre-gamma): x0 spans the first half of `toeLength` along the
    // input axis; y0 collapses toward 0 as toeStrength → 1.
    let x0 = toeLength * 0.5
    let y0Pre = (1.0 - toeStrength) * x0

    let remainingY = max(1.0 - y0Pre, 1e-6)
    let initialW = x0 + remainingY      // white point with no extra headroom
    let y1Offset = (1.0 - shoulderLength) * remainingY
    let x1 = x0 + y1Offset
    let y1Pre = y0Pre + y1Offset

    // Stops of extra range — this is the key knob that turns shoulderStrength
    // from "wiggle the overshoot" into "move the white point".
    let extraW = exp2f(shoulderStrength) - 1.0
    let W = initialW + extraW

    let overshootX = (W * 2.0) * shoulderAngle
    let overshootYPre = 0.5 * shoulderStrength

    // ── Curve construction (gamma applied to y-axis endpoints) ──────
    // Middle segment slope/intercept BEFORE gamma. m is always positive
    // because the user params keep y0 ≤ x0 ≤ x1 with monotonic y.
    let m = (y1Pre - y0Pre) / max(x1 - x0, 1e-6)
    let b = y0Pre - m * x0

    k.x0 = x0
    k.x1 = x1
    k.W = W
    k.overshootX = overshootX

    // Post-gamma endpoints — the curve in display space is (m*x+b)^gamma.
    k.y0 = max(1e-5, powf(y0Pre, gamma))
    k.y1 = max(1e-5, powf(y1Pre, gamma))
    k.overshootY = powf(1.0 + overshootYPre, gamma) - 1.0
    k.shoulderOffsetX = 1.0 + overshootX
    k.shoulderOffsetY = 1.0 + k.overshootY

    // Middle: (m*x+b)^gamma  =  exp(gamma*ln(m) + gamma*ln(x - (-b/m)))
    k.midOffsetX = -b / max(m, 1e-6)
    k.midLnA = gamma * logf(max(m, 1e-6))
    k.midB = gamma

    // Slope of the (gamma'd) middle at x0 and x1 — used to anchor the toe
    // and shoulder power curves with C1 continuity.
    let toeM = derivLinearGamma(m: m, b: b, gamma: gamma, x: x0)
    let shoulderM = derivLinearGamma(m: m, b: b, gamma: gamma, x: x1)

    asSolvePowerCurve(x0: x0, y0: k.y0, m: toeM, lnA: &k.toeLnA, B: &k.toeB)

    let shX0 = (1.0 + overshootX) - x1
    let shY0 = (1.0 + k.overshootY) - k.y1
    asSolvePowerCurve(x0: shX0, y0: shY0, m: shoulderM,
                      lnA: &k.shoulderLnA, B: &k.shoulderB)

    // ── Normalize so eval(W) lands exactly on 1.0 ────────────────────
    let scale = evalPiecewise(x: W, knots: k)
    k.invScale = scale > 1e-6 ? 1.0 / scale : 1.0
    return k
}

/// Derivative of `(m*x + b)^gamma` at x. Used to extract the slope at the
/// knot boundaries so the toe and shoulder match the middle in slope.
private func derivLinearGamma(m: Float, b: Float, gamma: Float, x: Float) -> Float {
    let inside = max(1e-6, m * x + b)
    return gamma * powf(inside, gamma - 1) * m
}

/// Solve `y = exp(lnA + B*ln(x))` for B, lnA so the curve passes through
/// (x0, y0) with slope `m` at that point.
private func asSolvePowerCurve(x0: Float, y0: Float, m: Float,
                               lnA: inout Float, B: inout Float) {
    guard x0 > 1e-6, y0 > 1e-6, m > 1e-6 else { lnA = 0; B = 1; return }
    B = (m * x0) / y0
    lnA = logf(y0) - B * logf(x0)
}

/// CPU-side evaluation of the assembled curve (un-normalized — apply
/// `invScale` for display-space output). Mirrors the shader's pwEvalChannel.
func evalPiecewise(x: Float, knots k: PiecewiseTonemapKnots) -> Float {
    let xi = max(0, x)
    if xi < k.x0 {
        guard xi > 1e-6 else { return 0 }
        return expf(k.toeLnA + k.toeB * logf(xi))
    } else if xi < k.x1 {
        let u = xi - k.midOffsetX
        guard u > 1e-6 else { return 0 }
        return expf(k.midLnA + k.midB * logf(u))
    } else {
        let u = k.shoulderOffsetX - xi
        guard u > 1e-6 else { return k.shoulderOffsetY }
        return k.shoulderOffsetY - expf(k.shoulderLnA + k.shoulderB * logf(u))
    }
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
    @Published var isPlaying = false {
        didSet {
            if !oldValue && isPlaying {
                // Playback would make every new frame's overlay stale —
                // drop the analysis so the UI shows a "pause to refresh"
                // prompt instead of the previous frame's regions.
                analysisResult = nil
                focusedRegionID = nil
            } else if oldValue && !isPlaying {
                triggerAutoAnalysisIfNeeded()
            }
        }
    }
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
    @Published var gamma: Double = 2.2 {
        didSet { UserDefaults.standard.set(gamma, forKey: "tonemapGamma") }
    }
    /// Reinhard extended whitepoint — input luminance that maps to display 1.0.
    @Published var reinhardWhitepoint: Double = 4.0 {
        didSet { UserDefaults.standard.set(reinhardWhitepoint, forKey: "reinhardWhitepoint") }
    }
    /// Hable piecewise filmic parameters. Setting any of these recomputes the
    /// knot snapshot the shader reads.
    @Published var piecewiseParams: PiecewiseTonemapParams = PiecewiseTonemapParams() {
        didSet {
            piecewiseKnots = computePiecewiseKnots(piecewiseParams)
            persistPiecewiseParams()
        }
    }
    /// Precomputed shader-ready knots. Updated whenever piecewiseParams changes.
    @Published private(set) var piecewiseKnots: PiecewiseTonemapKnots =
        computePiecewiseKnots(PiecewiseTonemapParams())

    // Pixel inspection (auto-shows grid + RGB values when zoomed in close enough)
    @Published var pixelInspect: Bool = true {
        didSet { UserDefaults.standard.set(pixelInspect, forKey: "pixelInspect") }
    }

    // MARK: - Error exploration (HDR-aware tile analysis)

    /// How the on-image highlight overlay renders top-error tiles.
    enum HighlightStyle: Int, CaseIterable, Identifiable {
        case off = 0          // panel hidden, shader off
        case outline = 1      // outlined rectangles only
        case dim = 2          // dim everything outside the highlights
        case focus = 3        // only the focused rect is bright (used after click)

        var id: Int { rawValue }
        var label: String {
            switch self {
            case .off:     return "Off"
            case .outline: return "Outline"
            case .dim:     return "Spotlight"
            case .focus:   return "Focus"
            }
        }
    }

    /// True when the explorer panel is open. Persisted so the user's
    /// preference survives across launches.
    @Published var explorerOpen: Bool = false {
        didSet {
            UserDefaults.standard.set(explorerOpen, forKey: "explorerOpen")
            if explorerOpen && !oldValue {
                triggerAutoAnalysisIfNeeded()
            }
        }
    }
    @Published var explorerCategory: ErrorCategory = .overall {
        didSet { UserDefaults.standard.set(explorerCategory.rawValue, forKey: "explorerCategory") }
    }
    /// Fraction of regions to surface, 0.001 (0.1%) to 0.5 (50%).
    @Published var explorerTopFraction: Double = 0.01 {
        didSet { UserDefaults.standard.set(explorerTopFraction, forKey: "explorerTopFraction") }
    }
    @Published var highlightStyle: HighlightStyle = .outline {
        didSet { UserDefaults.standard.set(highlightStyle.rawValue, forKey: "highlightStyle") }
    }
    @Published private(set) var analysisResult: AnalysisResult?
    @Published private(set) var isAnalyzing: Bool = false
    @Published var focusedRegionID: UUID?

    /// Set when an auto-analysis request arrived while one was already running.
    /// The in-flight analysis is for the *previous* frame, so we need to re-run
    /// once it finishes to catch up to whatever the user is now looking at.
    private var pendingAutoAnalysis: Bool = false

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
    @Published var isScrubbing = false {
        didSet {
            if !oldValue && isScrubbing {
                analysisResult = nil
                focusedRegionID = nil
            } else if oldValue && !isScrubbing {
                triggerAutoAnalysisIfNeeded()
            }
        }
    }
    /// Generation counter so only the most recently scheduled "scrub ended"
    /// callback flips `isScrubbing` back to false. Without it, rapid slider
    /// updates queue overlapping resets and the flag flickers mid-drag.
    private var scrubResetGeneration: UInt64 = 0

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
        if ud.object(forKey: "explorerOpen") != nil {
            explorerOpen = ud.bool(forKey: "explorerOpen")
        }
        if let v = ErrorCategory(rawValue: ud.integer(forKey: "explorerCategory")) {
            explorerCategory = v
        }
        if ud.object(forKey: "explorerTopFraction") != nil {
            explorerTopFraction = max(0.001, min(0.5, ud.double(forKey: "explorerTopFraction")))
        }
        if let v = HighlightStyle(rawValue: ud.integer(forKey: "highlightStyle")) {
            highlightStyle = v
        }
        if ud.object(forKey: "tonemapGamma") != nil {
            gamma = ud.double(forKey: "tonemapGamma")
        }
        if ud.object(forKey: "reinhardWhitepoint") != nil {
            reinhardWhitepoint = max(0.1, ud.double(forKey: "reinhardWhitepoint"))
        }
        if let data = ud.data(forKey: "piecewiseParams"),
           let restored = try? JSONDecoder().decode(PiecewiseTonemapParams.self, from: data) {
            // Assigning triggers didSet → recomputes knots and re-persists,
            // which is fine: the re-persist is a no-op write of the same blob.
            piecewiseParams = restored
        }
    }

    private func persistPiecewiseParams() {
        if let data = try? JSONEncoder().encode(piecewiseParams) {
            UserDefaults.standard.set(data, forKey: "piecewiseParams")
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
        // Analysis is keyed to the loaded pair; invalidate on any media
        // change so the panel doesn't show stale regions.
        clearAnalysis()
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
        clearAnalysis()
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
        clearAnalysis()
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
        // Brief delay before allowing time observer to update seekPosition.
        // Generation counter ensures only the *last* update's reset fires —
        // earlier callbacks land mid-drag and would otherwise toggle the flag.
        scrubResetGeneration &+= 1
        let gen = scrubResetGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            guard let self, self.scrubResetGeneration == gen else { return }
            self.isScrubbing = false
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

    // MARK: - Error exploration

    /// Kick off a background analysis of the currently displayed frame on
    /// both sides. The result is published on the main actor when ready;
    /// the panel UI observes `analysisResult` / `isAnalyzing`.
    func runAnalysis() {
        guard hasMediaA, hasMediaB,
              let a = latestCIImageA, let b = latestCIImageB else { return }
        if isAnalyzing { return }
        isAnalyzing = true
        // Capture as Sendable values for the detached task.
        let aImage = a, bImage = b
        Task.detached(priority: .userInitiated) { [weak self] in
            let result = ErrorAnalyzer.shared.analyze(a: aImage, b: bImage)
            // Promote to a strong, immutable binding *before* the @Sendable
            // MainActor closure so Swift 6 doesn't flag the inner capture of
            // `var self` from the [weak self] outer scope.
            guard let self else { return }
            await MainActor.run {
                self.analysisResult = result
                self.isAnalyzing = false
                // Drop the previous focused region — its IDs no longer exist
                // in the freshly-computed regions list.
                self.focusedRegionID = nil
                // A frame change landed while we were analyzing the previous
                // frame; re-run so the surfaced result matches what's on screen.
                if self.pendingAutoAnalysis {
                    self.pendingAutoAnalysis = false
                    self.triggerAutoAnalysisIfNeeded()
                }
            }
        }
    }

    /// Run analysis automatically if the explorer is active and the player is
    /// settled (paused, not scrubbing). Called by the renderer when a new
    /// frame buffer lands, and on explorer open. Re-fires after an in-flight
    /// analysis completes if a new frame arrived in the meantime.
    func triggerAutoAnalysisIfNeeded() {
        guard explorerOpen, !isPlaying, !isScrubbing,
              hasMediaA, hasMediaB,
              latestCIImageA != nil, latestCIImageB != nil else { return }
        if isAnalyzing {
            pendingAutoAnalysis = true
            return
        }
        runAnalysis()
    }

    /// Discard the current analysis. Called when media reloads or the user
    /// closes the explorer panel.
    func clearAnalysis() {
        analysisResult = nil
        focusedRegionID = nil
    }

    /// Top regions for the active explorer settings.
    var topRegions: [ErrorRegion] {
        guard let result = analysisResult else { return [] }
        return result.top(explorerCategory, fraction: explorerTopFraction,
                          maxCount: 32)
    }

    /// Rects in tc-space (matching the shader's vertex output) for the active
    /// top-region selection. Returns at most `kMaxHighlightRects` (the
    /// renderer enforces the same cap defensively).
    func highlightShaderRects() -> [SIMD4<Float>] {
        guard explorerOpen,
              let result = analysisResult,
              highlightStyle != .off else { return [] }
        let regions = topRegions
        let imgSize = result.analysisSize
        return regions.map { $0.tcRect(imageSize: imgSize) }
    }

    /// Index of the currently focused region within `topRegions`, or -1.
    /// Used by the shader to give the focused outline a hotter color.
    func highlightFocusedIndex(in count: Int) -> Int {
        guard let id = focusedRegionID else { return -1 }
        let regions = topRegions
        for (i, r) in regions.enumerated() where r.id == id {
            return i < count ? i : -1
        }
        return -1
    }

    /// Mirror of `highlightStyle.rawValue` exposed as Int32 for the shader.
    /// Returns 0 when the explorer panel is closed, no analysis is loaded, or
    /// the highlight style is .off — keeps the shader a no-op.
    func highlightShaderMode() -> Int32 {
        guard explorerOpen, analysisResult != nil, highlightStyle != .off else { return 0 }
        return Int32(highlightStyle.rawValue)
    }

    /// Frame the camera on a region: pan the centre into the view and zoom
    /// in enough to fill ~70% of the viewport along whichever axis is bigger.
    /// Capped at 50× so the user lands in a useful inspection range rather
    /// than the per-pixel-text overlay.
    func zoomToRegion(_ region: ErrorRegion) {
        guard let result = analysisResult else { return }
        let gridW = result.analysisSize.width
        let gridH = result.analysisSize.height
        guard gridW > 0, gridH > 0 else { return }

        // Region centre in the same tc-space the vertex shader uses (y up).
        let cx = (Double(region.x) + Double(region.width) / 2) / Double(gridW)
        let cyTopDown = (Double(region.y) + Double(region.height) / 2) / Double(gridH)
        let cy = 1.0 - cyTopDown

        let tcW = Double(region.width) / Double(gridW)
        let tcH = Double(region.height) / Double(gridH)
        let span = max(tcW, tcH)
        // Aim for the region to fill ~70% of the smaller view dimension; clamp
        // hard so single-tile crops don't snap straight to 200×.
        let target = span > 0 ? min(50.0, max(2.0, 0.7 / span)) : zoom
        zoom = target
        panOffset = CGPoint(x: cx - 0.5, y: cy - 0.5)
        focusedRegionID = region.id
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
