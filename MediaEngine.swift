import AVFoundation
import Combine
import CoreImage
import ImageIO
import Metal
import QuartzCore

enum MediaSide { case a, b }
enum MediaKind: Int { case video = 0, image = 1, sequence = 2 }

/// A numbered image sequence loaded onto one side and played back as frames.
struct ImageSequence: Equatable {
    var urls: [URL]
    var fps: Double
    var index: Int
}

/// Pure helpers for recognizing image sequences from dropped / opened paths.
enum SequenceScan {
    /// Split a filename stem into (prefix, numeric value, suffix, ext) using the
    /// LAST run of digits in the stem. Returns nil when there's no digit run.
    private static func parts(_ url: URL) -> (prefix: String, number: Int, suffix: String, ext: String)? {
        let ext = url.pathExtension.lowercased()
        let stem = url.deletingPathExtension().lastPathComponent
        let chars = Array(stem)
        var i = chars.count - 1
        while i >= 0 && !chars[i].isNumber { i -= 1 }   // skip trailing suffix
        guard i >= 0 else { return nil }
        let runEnd = i + 1
        while i >= 0 && chars[i].isNumber { i -= 1 }
        let runStart = i + 1
        let numStr = String(chars[runStart..<runEnd])
        guard let n = Int(numStr) else { return nil }
        return (String(chars[0..<runStart]), n, String(chars[runEnd...]), ext)
    }

    /// Dominant numbered image sequence within a URL set, sorted by frame number.
    /// Returns nil unless some pattern group has ≥2 members.
    static func sequence(from urls: [URL]) -> [URL]? {
        let images = urls.filter { MediaType.isImage($0) }
        guard images.count >= 2 else { return nil }
        var groups: [String: [(Int, URL)]] = [:]
        for u in images {
            guard let p = parts(u) else { continue }
            groups["\(p.prefix)\u{0}\(p.suffix)\u{0}\(p.ext)", default: []].append((p.number, u))
        }
        guard let best = groups.values.filter({ $0.count >= 2 }).max(by: { $0.count < $1.count })
        else { return nil }
        return best.sorted { $0.0 < $1.0 }.map { $0.1 }
    }

    /// All images inside a folder (one level) as a sequence — the dominant
    /// numbered pattern if there is one, otherwise everything natural-sorted.
    static func sequence(inFolder folder: URL) -> [URL]? {
        guard let items = try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: nil) else { return nil }
        let images = items.filter { MediaType.isImage($0) }
        guard !images.isEmpty else { return nil }
        if let seq = sequence(from: images), seq.count >= 2 { return seq }
        return images.sorted { naturalLess($0.lastPathComponent, $1.lastPathComponent) }
    }

    static func naturalLess(_ a: String, _ b: String) -> Bool {
        a.localizedStandardCompare(b) == .orderedAscending
    }

    static func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
    }
}

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
    case blink = 1
    case error = 2
}

/// Channel isolation for the displayed image. Applied after tonemapping so the
/// user inspects exactly what's on screen.
enum ChannelMode: Int, CaseIterable, Identifiable {
    case rgb = 0, red = 1, green = 2, blue = 3, alpha = 4, luma = 5
    var id: Int { rawValue }
    var label: String {
        switch self {
        case .rgb:   return "RGB"
        case .red:   return "Red"
        case .green: return "Green"
        case .blue:  return "Blue"
        case .alpha: return "Alpha"
        case .luma:  return "Luma"
        }
    }
    /// One-glyph badge for the compact toolbar readout.
    var short: String {
        switch self {
        case .rgb:   return "RGB"
        case .red:   return "R"
        case .green: return "G"
        case .blue:  return "B"
        case .alpha: return "A"
        case .luma:  return "L"
        }
    }
}

/// Discrete playback-speed reductions offered in the UI. Slowing playback is
/// the most reliable way to spot temporal artifacts (judder, flicker, denoiser
/// instability) frame-to-frame.
enum PlaybackSpeed: Double, CaseIterable, Identifiable {
    case full = 1.0
    case half = 0.5
    case quarter = 0.25
    case tenth = 0.1
    var id: Double { rawValue }
    var label: String {
        switch self {
        case .full:    return "1×"
        case .half:    return "½×"
        case .quarter: return "¼×"
        case .tenth:   return "0.1×"
        }
    }
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
    // Image sequences reuse this exact path — the engine swaps `image*` for the
    // current frame and bumps the version, so the renderer needs no new logic.
    private(set) var imageA: CIImage?
    private(set) var imageB: CIImage?
    @Published private(set) var imageVersionA: Int = 0
    @Published private(set) var imageVersionB: Int = 0

    // MARK: - Image sequences
    private(set) var sequenceA: ImageSequence?
    private(set) var sequenceB: ImageSequence?

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

    /// True when at least one side holds an AVPlayer-backed video.
    var hasPlayableVideo: Bool {
        mediaKindA == .video || mediaKindB == .video
    }
    /// True when at least one side is an image sequence.
    var hasSequence: Bool {
        mediaKindA == .sequence || mediaKindB == .sequence
    }
    /// Anything the transport can drive — videos or image sequences.
    var hasTimeline: Bool { hasPlayableVideo || hasSequence }
    /// Frame rate of whichever side owns the timeline (A wins).
    var timelineFPS: Double {
        if mediaKindA == .video || mediaKindA == .sequence { return max(1, frameRateA) }
        if mediaKindB == .video || mediaKindB == .sequence { return max(1, frameRateB) }
        return 24
    }

    // Error visualization (persisted)
    @Published var displayMode: DisplayMode = .split {
        didSet {
            if displayMode == .blink {
                if !blinkActive { blinkActive = true; blinkShowingA = true }
            } else {
                if blinkActive { exitBlink() }
                UserDefaults.standard.set(displayMode.rawValue, forKey: "displayMode")
            }
        }
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

    // MARK: - Channel isolation & clipping / gamut warnings

    /// Which channel(s) to display. Purely a view transform — no effect on the
    /// underlying samples used for hover readouts or analysis.
    @Published var channelMode: ChannelMode = .rgb

    /// Highlight pixels that hit display black (0) or display white (1) after
    /// the current exposure / tonemap — the classic "am I clipping on screen"
    /// overlay. Crushed shadows tint blue, blown highlights tint magenta.
    @Published var clipWarning: Bool = false

    /// Highlight out-of-display-gamut pixels — any channel that goes negative in
    /// the working linear space, which is what wide-gamut (P3 / Rec.2020) values
    /// do when squeezed toward sRGB. Tints yellow.
    @Published var gamutWarning: Bool = false

    func cycleChannel() {
        let next = (channelMode.rawValue + 1) % ChannelMode.allCases.count
        channelMode = ChannelMode(rawValue: next) ?? .rgb
    }

    // MARK: - Scopes (histogram / waveform / vectorscope)

    @Published var scopesOpen: Bool = false {
        didSet {
            UserDefaults.standard.set(scopesOpen, forKey: "scopesOpen")
            if scopesOpen && !oldValue { triggerScopesIfNeeded() }
        }
    }
    @Published var scopeMode: ScopeMode = .histogram {
        didSet { UserDefaults.standard.set(scopeMode.rawValue, forKey: "scopeMode") }
    }
    @Published private(set) var scopeDataA: ScopeData?
    @Published private(set) var scopeDataB: ScopeData?
    private var isComputingScopes = false

    func toggleScopes() { scopesOpen.toggle() }

    // MARK: - Temporal error graph

    @Published var temporalOpen: Bool = false {
        didSet {
            UserDefaults.standard.set(temporalOpen, forKey: "temporalOpen")
            if temporalOpen && !oldValue && temporalSeries == nil { runTemporalScan() }
        }
    }
    @Published var temporalScanMode: TemporalScanMode = .sampled
    @Published var temporalMetric: TemporalMetric = .mae
    @Published private(set) var temporalSeries: TemporalSeries?
    @Published private(set) var isScanningTemporal = false
    @Published private(set) var temporalProgress: Double = 0
    private var temporalCancel: TemporalAnalyzer.Cancel?

    func toggleTemporal() { temporalOpen.toggle() }

    func cancelTemporalScan() {
        temporalCancel?.cancelled = true
        temporalCancel = nil
        isScanningTemporal = false
    }

    func invalidateTemporalSeries() {
        cancelTemporalScan()
        temporalSeries = nil
    }

    /// Scan the timeline computing the chosen metric per (sampled or every)
    /// frame on a background task. Needs both sides and a timeline.
    func runTemporalScan() {
        guard hasMediaA, hasMediaB, hasTimeline, duration > 0, !isScanningTemporal else { return }
        let sa = temporalSource(.a), sb = temporalSource(.b)
        let dur = duration, fps = timelineFPS
        let scanMode = temporalScanMode, metric = temporalMetric
        let existingSeries = temporalSeries
        let cancel = TemporalAnalyzer.Cancel()
        temporalCancel = cancel
        isScanningTemporal = true
        temporalProgress = 0
        Task.detached(priority: .userInitiated) { [weak self] in
            let series: TemporalSeries?
            if scanMode == .aroundSpikes, let existing = existingSeries {
                series = TemporalAnalyzer.scanAroundSpikes(
                    sourceA: sa, sourceB: sb, duration: dur, fps: fps,
                    metric: metric, baseSeries: existing, cancel: cancel,
                    progress: { p in Task { @MainActor in self?.temporalProgress = p } })
            } else {
                series = TemporalAnalyzer.scan(
                    sourceA: sa, sourceB: sb, duration: dur, fps: fps,
                    detailed: scanMode == .everyFrame, metric: metric, cancel: cancel,
                    progress: { p in Task { @MainActor in self?.temporalProgress = p } })
            }
            guard let self else { return }
            await MainActor.run {
                guard self.temporalCancel === cancel else { return }
                if let series { self.temporalSeries = series }
                self.isScanningTemporal = false
                self.temporalProgress = 1
                self.temporalCancel = nil
            }
        }
    }

    private func temporalSource(_ side: MediaSide) -> TemporalSource {
        switch side == .a ? mediaKindA : mediaKindB {
        case .video:
            if let item = (side == .a ? playerA : playerB)?.currentItem {
                return .video(item.asset, max(1, side == .a ? frameRateA : frameRateB))
            }
            return .empty
        case .sequence:
            if let s = side == .a ? sequenceA : sequenceB { return .sequence(s.urls, max(1, s.fps)) }
            return .empty
        case .image:
            if let img = side == .a ? imageA : imageB { return .still(img) }
            return .empty
        case .none:
            return .empty
        }
    }

    /// Recompute scopes for the current frame. Called by the renderer when a new
    /// frame lands; the in-flight guard naturally throttles during playback so
    /// work never piles up (frames are simply sampled).
    func triggerScopesIfNeeded() {
        guard scopesOpen, !isComputingScopes else { return }
        let aImg = latestCIImageA, bImg = latestCIImageB
        guard aImg != nil || bImg != nil else { scopeDataA = nil; scopeDataB = nil; return }
        isComputingScopes = true
        Task.detached(priority: .utility) { [weak self] in
            let da = aImg.flatMap { ScopeSampler.compute($0) }
            let db = bImg.flatMap { ScopeSampler.compute($0) }
            guard let self else { return }
            await MainActor.run {
                self.scopeDataA = da
                self.scopeDataB = db
                self.isComputingScopes = false
            }
        }
    }

    // MARK: - Blink comparison
    //
    // Shows a single side full-frame and flips A↔B in place — the "blink
    // comparator". Works during playback: the players keep running, only the
    // displayed texture changes. Requires both sides loaded.
    @Published var blinkActive: Bool = false
    @Published var blinkShowingA: Bool = true
    @Published var blinkAuto: Bool = false { didSet { updateBlinkTimer() } }
    /// Auto-flip period (seconds) when `blinkAuto` is on.
    @Published var blinkInterval: Double = 0.4 { didSet { if blinkAuto { updateBlinkTimer() } } }
    private var blinkTimer: Timer?

    /// Single-key action (the `B` key): enter blink showing A when off, then
    /// flip A↔B on each subsequent press.
    func blinkSwap() {
        guard hasMediaA && hasMediaB else { return }
        if blinkActive {
            blinkShowingA.toggle()
        } else {
            blinkActive = true
            blinkShowingA = true
        }
    }

    /// Toolbar toggle: turn blink fully on (showing A) or fully off.
    func toggleBlink() {
        guard hasMediaA && hasMediaB else { exitBlink(); return }
        if blinkActive { exitBlink() } else { blinkActive = true; blinkShowingA = true }
    }

    func exitBlink() {
        if blinkAuto { blinkAuto = false }   // stops the timer via didSet
        blinkActive = false
    }

    private func updateBlinkTimer() {
        blinkTimer?.invalidate()
        blinkTimer = nil
        guard blinkAuto, blinkActive else { return }
        let interval = max(0.05, blinkInterval)
        blinkTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.blinkActive else { return }
                self.blinkShowingA.toggle()
            }
        }
    }

    // MARK: - Playback speed & A/B sync offset & segment loop

    /// Playback rate multiplier. Applied live to the AVPlayers when playing;
    /// the sequence ticker reads it directly.
    @Published var playbackSpeed: PlaybackSpeed = .full {
        didSet {
            guard isPlaying else { return }
            playerA?.rate = Float(playbackSpeed.rawValue)
            playerB?.rate = Float(playbackSpeed.rawValue)
        }
    }

    /// Frame rate applied to loaded image sequences. Image files carry no
    /// timing, so the user picks it; changing it re-times the whole timeline.
    @Published var sequenceFrameRate: Double = 24 {
        didSet {
            let fps = max(1, sequenceFrameRate)
            if mediaKindA == .sequence { frameRateA = fps; sequenceA?.fps = fps }
            if mediaKindB == .sequence { frameRateB = fps; sequenceB?.fps = fps }
            recalculateDuration()
            refreshSequenceFrames()
        }
    }

    /// Frame offset applied to side B relative to side A, to align renders vs.
    /// captures (or two encodes) that start a few frames apart. Positive shifts
    /// B later. Re-seeks B immediately when changed while paused; during
    /// playback, re-syncs B with rate preservation via completion handler.
    @Published var abOffsetFrames: Int = 0

    /// B's playback offset as a CMTime, derived from B's frame rate.
    private var abOffsetTime: CMTime {
        CMTime(seconds: Double(abOffsetFrames) / max(1, frameRateB), preferredTimescale: 9000)
    }

    /// Target time for B given A's time, clamped to ≥ 0.
    private func offsetTimeForB(_ base: CMTime) -> CMTime {
        let t = CMTimeAdd(base, abOffsetTime)
        return t.seconds < 0 ? .zero : t
    }

    private func applyOffsetSeek() {
        guard let pB = playerB else { return }
        let aTime = playerA?.currentTime() ?? pB.currentTime()
        pB.seek(to: offsetTimeForB(aTime), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    func nudgeOffset(_ delta: Int) {
        abOffsetFrames = max(-600, min(600, abOffsetFrames + delta))
    }

    /// Segment loop (in / out points, in seconds). When enabled, playback wraps
    /// from `loopEnd` back to `loopStart`.
    @Published var loopEnabled: Bool = false
    @Published var loopStart: Double = 0
    @Published var loopEnd: Double = 0

    /// True when a usable loop region exists (in < out).
    var hasLoopRegion: Bool { loopEnd > loopStart + 1e-4 }

    func setLoopIn()  { loopStart = currentTime; if loopEnd <= loopStart { loopEnd = duration } }
    func setLoopOut() { loopEnd = currentTime; if loopStart >= loopEnd { loopStart = 0 } }
    func clearLoop()  { loopEnabled = false; loopStart = 0; loopEnd = 0 }
    func toggleLoop() {
        if loopEnabled { loopEnabled = false }
        else {
            if !hasLoopRegion { loopStart = 0; loopEnd = duration }
            loopEnabled = hasLoopRegion
        }
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
    #if FRAMEWISE_VMAF
    @Published private(set) var frameVMAFScores: FrameVMAFScores?
    #endif
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
        if let v = DisplayMode(rawValue: ud.integer(forKey: "displayMode")), v != .blink { displayMode = v }
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
        if ud.object(forKey: "scopesOpen") != nil {
            scopesOpen = ud.bool(forKey: "scopesOpen")
        }
        if let v = ScopeMode(rawValue: ud.integer(forKey: "scopeMode")) {
            scopeMode = v
        }
        if ud.object(forKey: "temporalOpen") != nil {
            temporalOpen = ud.bool(forKey: "temporalOpen")
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

    // MARK: - Sequence-aware loading

    /// Explicit side load (Open A / Open B dialog): a single file is a still, a
    /// folder or ≥2 files become a sequence on that side.
    func loadForSide(_ urls: [URL], side: MediaSide) {
        if urls.count == 1, SequenceScan.isDirectory(urls[0]) {
            if let seq = SequenceScan.sequence(inFolder: urls[0]) { loadSequence(urls: seq, side: side) }
            return
        }
        let files = urls.filter { MediaType.isSupported($0) }
        if files.isEmpty { return }
        if files.count == 1 { loadMedia(url: files[0], side: side); return }
        let seq = SequenceScan.sequence(from: files)
            ?? files.filter { MediaType.isImage($0) }
                    .sorted { SequenceScan.naturalLess($0.lastPathComponent, $1.lastPathComponent) }
        if seq.count >= 2 { loadSequence(urls: seq, side: side) }
        else { loadMedia(url: files[0], side: side) }
    }

    /// Drag-and-drop routing. A folder, or ≥3 files forming a sequence, load as
    /// a sequence on the drop side. Exactly 2 files keep the A/B pair behavior;
    /// a single file loads on the drop side.
    func loadDropped(_ urls: [URL], dropSide: MediaSide) {
        if let dir = urls.first(where: { SequenceScan.isDirectory($0) }) {
            if let seq = SequenceScan.sequence(inFolder: dir) { loadSequence(urls: seq, side: dropSide) }
            return
        }
        let files = urls.filter { MediaType.isSupported($0) }
        guard !files.isEmpty else { return }
        if files.count >= 3 {
            let seq = SequenceScan.sequence(from: files)
                ?? files.filter { MediaType.isImage($0) }
                        .sorted { SequenceScan.naturalLess($0.lastPathComponent, $1.lastPathComponent) }
            if seq.count >= 2 { loadSequence(urls: seq, side: dropSide); return }
        }
        if files.count == 1 { loadMedia(url: files[0], side: dropSide) }
        else { loadMediaBatch(urls: files) }
    }

    /// Load a numbered image sequence onto a side and seat it at frame 0. A
    /// one-frame "sequence" degrades to a still.
    func loadSequence(urls: [URL], side: MediaSide) {
        let frames = urls.filter { MediaType.isImage($0) }
        guard let first = frames.first else { return }
        if frames.count == 1 { loadImage(url: first, side: side); return }
        clearAnalysis()
        let fps = max(1, sequenceFrameRate)
        let seq = ImageSequence(urls: frames, fps: fps, index: 0)
        let name = "\(first.lastPathComponent) … (\(frames.count) frames)"
        switch side {
        case .a:
            playerA?.pause(); playerA = nil; videoOutputA = nil
            sequenceA = seq
            hasMediaA = true
            mediaNameA = name
            mediaKindA = .sequence
            frameRateA = fps
        case .b:
            playerB?.pause(); playerB = nil; videoOutputB = nil
            sequenceB = seq
            hasMediaB = true
            mediaNameB = name
            mediaKindB = .sequence
            frameRateB = fps
        }
        loadSequenceFrameImage(first, side: side)   // uploads frame 0 + sets size
        currentTime = 0
        recalculateDuration()
        setupTimeObserver()
        if hasMediaA && hasMediaB { syncPlayersNow() }
    }

    /// Decode (lazily) one sequence frame and route it through the image upload
    /// path. CIImage(contentsOf:) is lazy, so this is cheap — the real decode
    /// happens in the renderer's CIContext during the draw.
    private func loadSequenceFrameImage(_ url: URL, side: MediaSide) {
        let opts: [CIImageOption: Any] = [.expandToHDR: true]
        guard let raw = CIImage(contentsOf: url, options: opts) ?? CIImage(contentsOf: url) else { return }
        let exif = (raw.properties[kCGImagePropertyOrientation as String] as? Int32) ?? 1
        let image = raw.oriented(forExifOrientation: exif)
        let size = CGSize(width: image.extent.width, height: image.extent.height)
        switch side {
        case .a:
            imageA = image; latestCIImageA = image; imageVersionA &+= 1
            if size.width > 0, size.height > 0 { mediaSizeA = size }
        case .b:
            imageB = image; latestCIImageB = image; imageVersionB &+= 1
            if size.width > 0, size.height > 0 { mediaSizeB = size }
        }
    }

    /// Seat each sequence side on the frame matching the current timeline time.
    func refreshSequenceFrames() {
        refreshSequenceSide(.a)
        refreshSequenceSide(.b)
    }

    private func refreshSequenceSide(_ side: MediaSide) {
        guard var s = (side == .a ? sequenceA : sequenceB), !s.urls.isEmpty else { return }
        let fps = max(1, side == .a ? frameRateA : frameRateB)
        let idx = max(0, min(s.urls.count - 1, Int((currentTime * fps).rounded())))
        guard idx != s.index else { return }
        s.index = idx
        if side == .a { sequenceA = s } else { sequenceB = s }
        loadSequenceFrameImage(s.urls[idx], side: side)
    }

    // ── Sequence playback ticker (used when no AVPlayer video is present) ──
    private var seqTicker: Timer?
    private var seqAnchorWall: CFTimeInterval = 0
    private var seqAnchorTime: Double = 0

    private func startSequenceTicker() {
        stopSequenceTicker()
        seqAnchorWall = CACurrentMediaTime()
        seqAnchorTime = currentTime
        seqTicker = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.sequenceTick() }
        }
    }

    private func stopSequenceTicker() {
        seqTicker?.invalidate()
        seqTicker = nil
    }

    private func sequenceTick() {
        guard isPlaying, !hasPlayableVideo else { return }
        let now = CACurrentMediaTime()
        var t = seqAnchorTime + (now - seqAnchorWall) * playbackSpeed.rawValue

        if loopEnabled, hasLoopRegion, t >= loopEnd {
            t = loopStart
            seqAnchorWall = now
            seqAnchorTime = loopStart
        } else if duration > 0, t >= duration {
            currentTime = duration
            updateSeqDerivedState()
            refreshSequenceFrames()
            pause()
            return
        }
        currentTime = max(0, t)
        updateSeqDerivedState()
        refreshSequenceFrames()
    }

    private func updateSeqDerivedState() {
        currentFrame = Int(currentTime * timelineFPS)
        if !isScrubbing, duration > 0 { seekPosition = currentTime / duration }
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
            sequenceA = nil
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
            sequenceB = nil
            latestCIImageB = nil
            hoverSampleB = nil
            hasMediaB = false
            mediaNameB = nil
            mediaKindB = nil
        }
        recalculateDuration()
        if !(hasMediaA && hasMediaB) {
            displayMode = .split
        }
        if !hasSequence { stopSequenceTicker() }
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
        case .image, .sequence: return true
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
        // Sequences contribute frameCount / fps.
        if let s = sequenceA { longest = max(longest, Double(s.urls.count) / max(1, frameRateA)) }
        if let s = sequenceB { longest = max(longest, Double(s.urls.count) / max(1, frameRateB)) }
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
        guard hasTimeline else { return }
        if loopEnabled && hasLoopRegion && currentTime >= loopEnd - 1e-3 {
            seek(to: CMTime(seconds: loopStart, preferredTimescale: 9000))
        }
        let rate = Float(playbackSpeed.rawValue)
        isPlaying = true
        if !hasPlayableVideo && hasSequence { startSequenceTicker() }
        playerA?.rate = rate
        playerB?.rate = rate
    }

    func pause() {
        playerA?.rate = 0
        playerB?.rate = 0
        stopSequenceTicker()
        isPlaying = false
    }

    func stepForward() {
        pause()
        if hasPlayableVideo {
            playerA?.currentItem?.step(byCount: 1)
            playerB?.currentItem?.step(byCount: 1)
            updateTimeFromPlayer()
            refreshSequenceFrames()
        } else {
            seek(to: CMTime(seconds: currentTime + 1.0 / timelineFPS, preferredTimescale: 9000))
        }
    }

    func stepBackward() {
        pause()
        if hasPlayableVideo {
            playerA?.currentItem?.step(byCount: -1)
            playerB?.currentItem?.step(byCount: -1)
            updateTimeFromPlayer()
            refreshSequenceFrames()
        } else {
            seek(to: CMTime(seconds: max(0, currentTime - 1.0 / timelineFPS), preferredTimescale: 9000))
        }
    }

    func seekToStart() {
        seek(to: .zero)
    }

    func seekToEnd() {
        // Sequence-only: land on the last frame via the unified seek path.
        if !hasPlayableVideo {
            let last = max(0, duration - 1.0 / timelineFPS)
            seek(to: CMTime(seconds: last, preferredTimescale: 9000))
            return
        }
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
            self?.refreshSequenceFrames()
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
        seek(to: CMTime(seconds: Double(frame) / timelineFPS, preferredTimescale: 9000))
    }

    func seek(to time: CMTime) {
        playerA?.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
        playerB?.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
        if hasPlayableVideo {
            updateTimeFromPlayer()
        } else {
            // Sequence-only: AVPlayer has no clock, so set the time directly.
            let secs = max(0, time.seconds.isFinite ? time.seconds : 0)
            currentTime = duration > 0 ? min(duration, secs) : secs
            updateSeqDerivedState()
            if isPlaying { seqAnchorWall = CACurrentMediaTime(); seqAnchorTime = currentTime }
        }
        refreshSequenceFrames()
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
            pB.seek(to: time)
        }
        if let pA = playerA, hasMediaB && !hasMediaA {
            pA.seek(to: time)
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
                // A sequence paired with a video follows the video's clock.
                if self.hasSequence { self.refreshSequenceFrames() }

                // Segment loop: wrap back to the in point once we cross out.
                if self.isPlaying, self.loopEnabled, self.hasLoopRegion,
                   time.seconds >= self.loopEnd - 1e-3 {
                    self.seek(to: CMTime(seconds: self.loopStart, preferredTimescale: 9000))
                    let rate = Float(self.playbackSpeed.rawValue)
                    self.playerA?.rate = rate
                    self.playerB?.rate = rate
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
            #if FRAMEWISE_VMAF
            let vmafResult = VMAFEngine.analyzeFrame(a: aImage, b: bImage)
            #endif
            guard let self else { return }
            await MainActor.run {
                self.analysisResult = result
                #if FRAMEWISE_VMAF
                self.frameVMAFScores = vmafResult
                #endif
                self.isAnalyzing = false
                self.focusedRegionID = nil
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
    /// closes the explorer panel. Also invalidates the scope and temporal
    /// results, which are keyed to the loaded pair.
    func clearAnalysis() {
        analysisResult = nil
        focusedRegionID = nil
        scopeDataA = nil
        scopeDataB = nil
        if isScanningTemporal { cancelTemporalScan() }
        temporalSeries = nil
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
