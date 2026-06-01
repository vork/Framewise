import CoreImage
import CoreGraphics
import Foundation
import simd

// MARK: - Public types

/// A class of error the analyzer scores tiles against. Each category uses a
/// fitting loss appropriate to its phenomenon (relative error for highlight
/// bias, signed-mean for shadow bias, ΔE in CIE-L*a*b* for color shift, etc.)
/// rather than reusing a single global formula. Tile rankings differ between
/// categories so the user can ask the dataset different questions.
enum ErrorCategory: Int, CaseIterable, Identifiable, Hashable {
    case overall          = 0   // mean |A − B|
    case highlightBias    = 1   // relative error in bright pixels
    case shadowBias       = 2   // mean error in dark pixels (signed magnitude)
    case colorShift       = 3   // CIE76 ΔE in L*a*b* (D65)
    case fireflies        = 4   // max-pixel-error dominated tiles
    case denoisingBlur    = 5   // reference holds more high-frequency energy
    case textureLoss      = 6   // 1 − SSIM
    case ringing          = 7   // Laplacian residual at strong edges
    case banding          = 8   // quantization banding: flat regions that should have gradients

    var id: Int { rawValue }

    var label: String {
        switch self {
        case .overall:        return "Overall"
        case .highlightBias:  return "Highlight bias"
        case .shadowBias:     return "Shadow bias"
        case .colorShift:     return "Color shift"
        case .fireflies:      return "Fireflies"
        case .denoisingBlur:  return "Denoising blur"
        case .textureLoss:    return "Texture loss"
        case .ringing:        return "Ringing"
        case .banding:        return "Banding"
        }
    }

    var shortLabel: String {
        switch self {
        case .overall:        return "Overall"
        case .highlightBias:  return "Highlights"
        case .shadowBias:     return "Shadows"
        case .colorShift:     return "Color"
        case .fireflies:      return "Fireflies"
        case .denoisingBlur:  return "Blur"
        case .textureLoss:    return "Texture"
        case .ringing:        return "Ringing"
        case .banding:        return "Banding"
        }
    }

    var icon: String {
        switch self {
        case .overall:        return "square.grid.3x3"
        case .highlightBias:  return "sun.max"
        case .shadowBias:     return "moon"
        case .colorShift:     return "paintpalette"
        case .fireflies:      return "sparkles"
        case .denoisingBlur:  return "drop.halffull"
        case .textureLoss:    return "circle.dotted"
        case .ringing:        return "waveform"
        case .banding:        return "rectangle.split.3x1"
        }
    }

    var detail: String {
        switch self {
        case .overall:        return "mean |A − B|"
        case .highlightBias:  return "|A − B| / max(B, ε) where max(A,B) is bright"
        case .shadowBias:     return "mean (A − B) in dark pixels (signed magnitude)"
        case .colorShift:     return "CIE76 ΔE in L*a*b* (D65)"
        case .fireflies:      return "max-pixel-error / mean-error − 1"
        case .denoisingBlur:  return "‖∇A‖ − ‖∇B‖ / ‖∇A‖ (B lost high freq)"
        case .textureLoss:    return "1 − SSIM (8-bit normalized luma)"
        case .ringing:        return "|∇²A − ∇²B| weighted by edge strength in B"
        case .banding:        return "flat-pixel ratio × luma range (CAMBI-inspired)"
        }
    }

    /// Format a score for display. Some categories produce naturally small
    /// numbers (deltaE in single-digit, abs-err in <1) and some produce
    /// percentage-scale (1-SSIM), so emit something readable in each case.
    func formatScore(_ value: Float) -> String {
        guard value.isFinite else { return "—" }
        switch self {
        case .colorShift:
            return String(format: "ΔE %.2f", value)
        case .textureLoss:
            return String(format: "%.3f", value)
        case .fireflies, .denoisingBlur, .ringing, .banding:
            return String(format: "%.2f", value)
        case .highlightBias:
            return String(format: "%.2f", value)
        case .shadowBias, .overall:
            if value >= 1 { return String(format: "%.2f", value) }
            return String(format: "%.4f", value)
        }
    }
}

/// One analyzed tile. Coordinates are in pixels of the analysis grid (which
/// may be a downsampled version of the source image — see
/// `AnalysisResult.imageSize` for the actual media size). `scores` is indexed
/// by `ErrorCategory.rawValue`.
struct ErrorRegion: Identifiable, Equatable {
    let id: UUID
    var x: Int          // top-left x (top-down origin)
    var y: Int          // top-left y (top-down origin)
    var width: Int
    var height: Int
    var scores: [Float]

    func score(_ cat: ErrorCategory) -> Float { scores[cat.rawValue] }

    /// Rect in normalized texture-coordinate space the shader uses (bottom-left
    /// origin, Y up). `imageSize` is the analysis grid size, not the media.
    func tcRect(imageSize: CGSize) -> SIMD4<Float> {
        let w = Float(imageSize.width), h = Float(imageSize.height)
        let umin = Float(x) / w
        let uwidth = Float(width) / w
        let vmin = 1.0 - Float(y + height) / h
        let vheight = Float(height) / h
        return SIMD4<Float>(umin, vmin, uwidth, vheight)
    }

    static func == (lhs: ErrorRegion, rhs: ErrorRegion) -> Bool { lhs.id == rhs.id }
}

/// Per-luminance-bucket mean error. HDR pipelines need this because a naive
/// MSE is usually dominated by a few very bright pixels — buckets surface
/// where the model is actually failing.
struct LuminanceBucket: Identifiable, Equatable {
    let id: Int
    var label: String          // e.g. "shadows ≤0.05"
    var lowerLuminance: Float  // inclusive
    var upperLuminance: Float  // exclusive
    var mae: Float
    var relativeError: Float
    var coverage: Float        // fraction of pixels in this bucket
}

/// Scale-aware global statistics for the analysis pass. Both linear-domain
/// and log-domain metrics are computed — naive MSE/PSNR on HDR data overfits
/// to bright pixels, so the log-domain numbers are usually what you want to
/// compare across exposures.
struct GlobalStats {
    var mae: Float              // mean absolute error (linear sRGB, ext.)
    var mse: Float              // mean squared error (linear)
    var rmse: Float             // sqrt(mse)
    var psnr: Float             // 10·log10(1/mse) in dB (linear)
    var relativeError: Float    // mean |A−B| / (|B|+ε)
    var logSpaceMAE: Float      // mean |log(A+ε) − log(B+ε)| (log10)
    var logSpacePSNR: Float     // PSNR computed on log-domain values
    var meanSSIM: Float         // tile-mean SSIM (luma)
    var msSSIM: Float           // multiscale SSIM (3 scales)
    var meanDeltaE: Float       // tile-mean CIE76 ΔE
    var maxAbsError: Float      // worst single-pixel error
    var p99AbsError: Float      // 99th-percentile pixel error (approx via tile maxes)
    var buckets: [LuminanceBucket]
}

struct AnalysisResult {
    var regions: [ErrorRegion]
    /// Global per-category average across the whole image.
    var globalScores: [Float]
    /// PSNR computed against the analysis-grid linear-sRGB samples.
    var psnr: Float
    /// Comprehensive scale-aware global statistics (HDR-friendly).
    var stats: GlobalStats
    /// Size of the analysis grid (may be downsampled from the media).
    var analysisSize: CGSize
    var tileSize: Int
    /// Timestamp the analysis was generated at, used to invalidate when media
    /// changes underneath.
    var timestamp: Date

    func global(_ cat: ErrorCategory) -> Float { globalScores[cat.rawValue] }

    /// Top fraction of regions ranked by the given category. `fraction` in
    /// (0, 1]; result is at least one region as long as we have any. Regions
    /// with non-finite scores are excluded.
    func top(_ cat: ErrorCategory, fraction: Double, maxCount: Int = 64) -> [ErrorRegion] {
        let cleaned = regions.filter { $0.score(cat).isFinite }
        guard !cleaned.isEmpty else { return [] }
        let sorted = cleaned.sorted { $0.score(cat) > $1.score(cat) }
        let count = max(1, min(maxCount, Int((Double(sorted.count) * fraction).rounded(.up))))
        return Array(sorted.prefix(count))
    }
}

// MARK: - Analyzer

/// Background-thread analyzer. Renders both sides into matching linear-sRGB
/// float buffers (so HDR EXR / HDR HEIC content keeps its extended range) and
/// computes per-tile category scores. Cheap enough to run interactively on
/// modern hardware even at 1024-on-long-side analysis resolution.
final class ErrorAnalyzer: @unchecked Sendable {
    static let shared = ErrorAnalyzer()

    private let tileSize = 32
    private let maxAnalysisDim = 1024

    /// Dedicated CIContext so analysis renders don't contend with the live
    /// renderer's MTL context. Software path is plenty fast for one-shot reads.
    private let ctx: CIContext = CIContext(options: [
        .workingColorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!,
        .useSoftwareRenderer: true,
        .cacheIntermediates: false,
    ])
    private let outColorSpace: CGColorSpace = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!

    /// Run analysis on `a` and `b`. The two CIImages may have different sizes
    /// or origins; both are scaled into a common analysis grid (downsampled to
    /// at most `maxAnalysisDim` on the long side).
    func analyze(a: CIImage, b: CIImage) -> AnalysisResult? {
        let aExt = a.extent
        let longest = max(aExt.width, aExt.height)
        guard longest > 0 else { return nil }
        let scale = min(1.0, CGFloat(maxAnalysisDim) / longest)
        let w = max(tileSize, Int((aExt.width * scale).rounded()))
        let h = max(tileSize, Int((aExt.height * scale).rounded()))
        // Snap to multiples of tileSize so tiles aren't ragged.
        let wT = (w / tileSize) * tileSize
        let hT = (h / tileSize) * tileSize
        guard wT >= tileSize, hT >= tileSize else { return nil }

        guard let aBuf = renderToFloats(a, w: wT, h: hT) else { return nil }
        guard let bBuf = renderToFloats(b, w: wT, h: hT) else {
            aBuf.deallocate()
            return nil
        }
        defer {
            aBuf.deallocate()
            bBuf.deallocate()
        }

        let tilesX = wT / tileSize
        let tilesY = hT / tileSize
        var regions: [ErrorRegion] = []
        regions.reserveCapacity(tilesX * tilesY)

        var globalSums = [Float](repeating: 0, count: ErrorCategory.allCases.count)
        var globalMSE: Float = 0
        // Accumulators for the new HDR-aware global stats.
        var sumMAE: Float = 0
        var sumRel: Float = 0
        var sumLogMAE: Float = 0
        var sumLogSqErr: Float = 0
        var sumSSIM: Float = 0
        var sumDeltaE: Float = 0
        var maxAbsErr: Float = 0
        var tileMaxes: [Float] = []
        tileMaxes.reserveCapacity(tilesX * tilesY)
        // 4 luminance buckets: shadows, mid, highlights, super-highlights (HDR).
        let bucketRanges: [(Float, Float)] = [
            (-.infinity, 0.05),
            (0.05, 0.5),
            (0.5, 1.0),
            (1.0, .infinity)
        ]
        let bucketLabels = ["shadows ≤0.05", "mid 0.05–0.5", "highlights 0.5–1", "HDR >1"]
        var bucketMAE = [Float](repeating: 0, count: 4)
        var bucketRel = [Float](repeating: 0, count: 4)
        var bucketCount = [Float](repeating: 0, count: 4)

        for ty in 0..<tilesY {
            for tx in 0..<tilesX {
                let r = computeTile(a: aBuf, b: bBuf, w: wT, h: hT,
                                    x: tx * tileSize, y: ty * tileSize,
                                    size: tileSize)
                regions.append(ErrorRegion(id: UUID(),
                                           x: tx * tileSize,
                                           y: ty * tileSize,
                                           width: tileSize,
                                           height: tileSize,
                                           scores: r.scores))
                for i in 0..<globalSums.count { globalSums[i] += r.scores[i] }
                globalMSE += r.mse
                sumMAE += r.meanAbsErr
                sumRel += r.meanRelErr
                sumLogMAE += r.logMAE
                sumLogSqErr += r.logSqErr
                sumSSIM += r.ssim
                sumDeltaE += r.scores[ErrorCategory.colorShift.rawValue]
                if r.maxAbsErr > maxAbsErr { maxAbsErr = r.maxAbsErr }
                tileMaxes.append(r.maxAbsErr)
                for i in 0..<4 {
                    bucketMAE[i] += r.bucketMAE[i]
                    bucketRel[i] += r.bucketRel[i]
                    bucketCount[i] += r.bucketCount[i]
                }
            }
        }

        let n = Float(tilesX * tilesY)
        let pixelCount = Float(wT * hT)
        for i in 0..<globalSums.count { globalSums[i] /= n }
        let mse = max(globalMSE / n, 1e-12)
        let psnr = 10 * log10f(1.0 / mse)

        let mae = sumMAE / n
        let rmse = sqrtf(mse)
        let rel = sumRel / n
        let logMAE = sumLogMAE / n
        let logMSE = max(sumLogSqErr / n, 1e-12)
        // log-domain PSNR uses a fixed reference range of 10 stops (log10 of
        // 2^10 ≈ 3.01) so the dB number is comparable across exposures.
        let logRange: Float = 3.01
        let logPSNR = 10 * log10f((logRange * logRange) / logMSE)
        let meanSSIM = sumSSIM / n
        let meanDeltaE = sumDeltaE / n

        // Multiscale SSIM approximation: average SSIM at 1x, 2x downsample,
        // and 4x downsample. Simple but a useful HDR-aware texture metric.
        let msSSIM = multiscaleSSIM(a: aBuf, b: bBuf, w: wT, h: hT)

        // 99th-percentile via tile-max sort. Coarse but cheap — useful for
        // catching firefly-dominated frames.
        tileMaxes.sort()
        let p99Index = max(0, min(tileMaxes.count - 1, Int(Double(tileMaxes.count) * 0.99)))
        let p99 = tileMaxes.isEmpty ? 0 : tileMaxes[p99Index]

        var buckets: [LuminanceBucket] = []
        for i in 0..<4 {
            let c = bucketCount[i]
            let coverage = c / pixelCount
            buckets.append(LuminanceBucket(
                id: i,
                label: bucketLabels[i],
                lowerLuminance: bucketRanges[i].0,
                upperLuminance: bucketRanges[i].1,
                mae: c > 0 ? bucketMAE[i] / c : 0,
                relativeError: c > 0 ? bucketRel[i] / c : 0,
                coverage: coverage
            ))
        }

        let stats = GlobalStats(
            mae: mae,
            mse: mse,
            rmse: rmse,
            psnr: psnr,
            relativeError: rel,
            logSpaceMAE: logMAE,
            logSpacePSNR: logPSNR,
            meanSSIM: meanSSIM,
            msSSIM: msSSIM,
            meanDeltaE: meanDeltaE,
            maxAbsError: maxAbsErr,
            p99AbsError: p99,
            buckets: buckets
        )

        return AnalysisResult(
            regions: regions,
            globalScores: globalSums,
            psnr: psnr,
            stats: stats,
            analysisSize: CGSize(width: wT, height: hT),
            tileSize: tileSize,
            timestamp: Date()
        )
    }

    // MARK: - Multiscale SSIM

    /// Average tile SSIM over the original grid and two 2x downsamples. Coarse
    /// approximation of MS-SSIM that nonetheless captures structure loss at
    /// multiple scales (denoising blur, soft fine detail).
    private func multiscaleSSIM(a: UnsafeMutablePointer<SIMD4<Float>>,
                                b: UnsafeMutablePointer<SIMD4<Float>>,
                                w: Int, h: Int) -> Float {
        var scaleSums: [Float] = []
        scaleSums.append(meanTileSSIM(a: a, b: b, w: w, h: h))

        var curW = w, curH = h
        var curA = a
        var curB = b
        var owned: [UnsafeMutablePointer<SIMD4<Float>>] = []
        for _ in 0..<2 {
            let nw = curW / 2, nh = curH / 2
            if nw < tileSize || nh < tileSize { break }
            let da = downsample2x(curA, w: curW, h: curH)
            let db = downsample2x(curB, w: curW, h: curH)
            owned.append(da)
            owned.append(db)
            curA = da
            curB = db
            curW = nw
            curH = nh
            scaleSums.append(meanTileSSIM(a: curA, b: curB, w: curW, h: curH))
        }
        for ptr in owned { ptr.deallocate() }
        if scaleSums.isEmpty { return 1 }
        return scaleSums.reduce(0, +) / Float(scaleSums.count)
    }

    /// Compute mean SSIM by stepping through tile-sized windows; reuses the
    /// per-tile SSIM logic from `computeTile`.
    private func meanTileSSIM(a: UnsafeMutablePointer<SIMD4<Float>>,
                              b: UnsafeMutablePointer<SIMD4<Float>>,
                              w: Int, h: Int) -> Float {
        let tilesX = w / tileSize
        let tilesY = h / tileSize
        guard tilesX > 0 && tilesY > 0 else { return 1 }
        var sum: Float = 0
        for ty in 0..<tilesY {
            for tx in 0..<tilesX {
                let r = computeTile(a: a, b: b, w: w, h: h,
                                    x: tx * tileSize, y: ty * tileSize,
                                    size: tileSize)
                sum += r.ssim
            }
        }
        return sum / Float(tilesX * tilesY)
    }

    /// 2× box-filter downsample for multiscale SSIM. Returns a new heap buffer
    /// the caller is responsible for deallocating.
    private func downsample2x(_ src: UnsafeMutablePointer<SIMD4<Float>>,
                              w: Int, h: Int) -> UnsafeMutablePointer<SIMD4<Float>> {
        let nw = w / 2, nh = h / 2
        let out = UnsafeMutablePointer<SIMD4<Float>>.allocate(capacity: nw * nh)
        for j in 0..<nh {
            for i in 0..<nw {
                let i0 = i * 2, j0 = j * 2
                let p = src[j0 * w + i0]
                    + src[j0 * w + i0 + 1]
                    + src[(j0 + 1) * w + i0]
                    + src[(j0 + 1) * w + i0 + 1]
                out[j * nw + i] = p * 0.25
            }
        }
        return out
    }

    // MARK: - Rendering helpers

    /// Render `image` into a planar RGBA-float buffer of `w × h`. Returns nil
    /// on allocation failure.
    private func renderToFloats(_ image: CIImage, w: Int, h: Int) -> UnsafeMutablePointer<SIMD4<Float>>? {
        // Translate to (0,0) and scale to target — CIImage's extent origin can
        // be non-zero after EXIF orientation, and the long-side downsample lets
        // us hit a consistent grid for both A and B.
        var img = image
        if img.extent.origin != .zero {
            img = img.transformed(by: CGAffineTransform(
                translationX: -img.extent.origin.x,
                y: -img.extent.origin.y))
        }
        let sx = CGFloat(w) / max(img.extent.width, 1)
        let sy = CGFloat(h) / max(img.extent.height, 1)
        if sx != 1 || sy != 1 {
            img = img.transformed(by: CGAffineTransform(scaleX: sx, y: sy))
        }

        let buffer = UnsafeMutablePointer<SIMD4<Float>>.allocate(capacity: w * h)
        // Zero-init so any failed render still gives finite values.
        for i in 0..<(w * h) { buffer[i] = .zero }

        let bounds = CGRect(x: 0, y: 0, width: w, height: h)
        ctx.render(img,
                   toBitmap: UnsafeMutableRawPointer(buffer),
                   rowBytes: w * MemoryLayout<SIMD4<Float>>.stride,
                   bounds: bounds,
                   format: .RGBAf,
                   colorSpace: outColorSpace)
        return buffer
    }

    // MARK: - Per-tile metrics

    private struct TileResult {
        var scores: [Float]
        var mse: Float
        var meanAbsErr: Float
        var meanRelErr: Float
        var logMAE: Float           // mean |log10(A+ε) − log10(B+ε)|
        var logSqErr: Float         // mean of squared log-domain error
        var ssim: Float             // luma SSIM (used for MS-SSIM aggregation)
        var maxAbsErr: Float
        var bucketMAE: [Float]      // luma bucket sums (4 buckets)
        var bucketRel: [Float]
        var bucketCount: [Float]
    }

    /// One pass over a tile that accumulates every per-pixel statistic we need,
    /// then derives category scores. Two passes total over each tile pixel
    /// (one for sums, one for SSIM variance/covariance).
    private func computeTile(a: UnsafeMutablePointer<SIMD4<Float>>,
                             b: UnsafeMutablePointer<SIMD4<Float>>,
                             w: Int, h: Int, x: Int, y: Int, size: Int) -> TileResult {
        let count = Float(size * size)

        var sumAbsErr: Float = 0
        var sumSqErr: Float = 0
        var maxErr: Float = 0

        var sumRelBright: Float = 0
        var brightCount: Float = 0

        var sumDark: Float = 0
        var darkCount: Float = 0

        var sumDeltaE: Float = 0

        var sumGradA: Float = 0
        var sumGradB: Float = 0

        var sumLapDiff: Float = 0
        var sumEdgeB: Float = 0

        // Banding detection (CAMBI-inspired): track luma range and count of
        // near-zero-gradient ("flat") pixels per side.
        var lumaMinA: Float = .greatestFiniteMagnitude, lumaMaxA: Float = -.greatestFiniteMagnitude
        var lumaMinB: Float = .greatestFiniteMagnitude, lumaMaxB: Float = -.greatestFiniteMagnitude
        var flatCountA: Float = 0
        var flatCountB: Float = 0
        var gradientSamples: Float = 0

        var muA: Float = 0, muB: Float = 0

        // Scale-aware (log-domain) and relative accumulators. Log10 with a
        // small offset is robust against zero/dark pixels and gives an HDR
        // pipeline a metric that doesn't get overwhelmed by single bright
        // pixels.
        var sumRelErr: Float = 0
        var sumLogMAE: Float = 0
        var sumLogSqErr: Float = 0

        // Luminance buckets accumulated against pixel max-luminance
        // (so HDR specular peaks land in the >1 bucket even when B is dark).
        var bucketMAE  = [Float](repeating: 0, count: 4)
        var bucketRel  = [Float](repeating: 0, count: 4)
        var bucketCount = [Float](repeating: 0, count: 4)

        for j in 0..<size {
            let yy = y + j
            for i in 0..<size {
                let xx = x + i
                let idx = yy * w + xx
                var pa = a[idx]
                var pb = b[idx]
                // Guard against NaN/Inf in HDR sources.
                pa = sanitize(pa)
                pb = sanitize(pb)

                let aRGB = SIMD3<Float>(pa.x, pa.y, pa.z)
                let bRGB = SIMD3<Float>(pb.x, pb.y, pb.z)
                let d = aRGB - bRGB
                let ad = SIMD3<Float>(Swift.abs(d.x), Swift.abs(d.y), Swift.abs(d.z))
                let pixelErr = (ad.x + ad.y + ad.z) / 3
                sumAbsErr += pixelErr
                sumSqErr += pixelErr * pixelErr
                if pixelErr > maxErr { maxErr = pixelErr }

                let lumA = 0.2126 * aRGB.x + 0.7152 * aRGB.y + 0.0722 * aRGB.z
                let lumB = 0.2126 * bRGB.x + 0.7152 * bRGB.y + 0.0722 * bRGB.z
                muA += lumA
                muB += lumB

                if lumA < lumaMinA { lumaMinA = lumA }
                if lumA > lumaMaxA { lumaMaxA = lumA }
                if lumB < lumaMinB { lumaMinB = lumB }
                if lumB > lumaMaxB { lumaMaxB = lumB }

                // Relative-error contribution per pixel. ε prevents shadow
                // pixels from blowing up the metric.
                sumRelErr += pixelErr / (Swift.abs(lumB) + 0.01)

                // Log-domain error: log10(A+ε) − log10(B+ε), averaged over
                // channels. Robust under exposure changes — a 2× brightening
                // produces a constant log10(2) ≈ 0.301 offset regardless of
                // the brightness level the pixel sits at.
                let epsL: Float = 0.001
                let logA = SIMD3<Float>(
                    log10f(Swift.abs(aRGB.x) + epsL),
                    log10f(Swift.abs(aRGB.y) + epsL),
                    log10f(Swift.abs(aRGB.z) + epsL)
                )
                let logB = SIMD3<Float>(
                    log10f(Swift.abs(bRGB.x) + epsL),
                    log10f(Swift.abs(bRGB.y) + epsL),
                    log10f(Swift.abs(bRGB.z) + epsL)
                )
                let logD = logA - logB
                let logErr = (Swift.abs(logD.x) + Swift.abs(logD.y) + Swift.abs(logD.z)) / 3
                sumLogMAE += logErr
                sumLogSqErr += logErr * logErr

                // Luminance bucket — pick the band using max(luma) so very
                // bright streaks land in the HDR bucket.
                let lumBand = max(lumA, lumB)
                let bIdx: Int = {
                    if lumBand <= 0.05 { return 0 }
                    if lumBand <= 0.5  { return 1 }
                    if lumBand <= 1.0  { return 2 }
                    return 3
                }()
                bucketMAE[bIdx] += pixelErr
                bucketRel[bIdx] += pixelErr / (Swift.abs(lumB) + 0.01)
                bucketCount[bIdx] += 1

                let maxLum = max(lumA, lumB)
                if maxLum >= 0.8 {
                    let denom = max(Swift.abs(lumB), 0.1)
                    sumRelBright += pixelErr / denom
                    brightCount += 1
                }
                if maxLum <= 0.05 {
                    // Use signed mean so over- vs under-shoot in shadows
                    // averages out — large signed bias is what we surface.
                    sumDark += (lumA - lumB)
                    darkCount += 1
                }

                let labA = linearSRGBToLab(aRGB)
                let labB = linearSRGBToLab(bRGB)
                let labD = labA - labB
                sumDeltaE += sqrtf(labD.x * labD.x + labD.y * labD.y + labD.z * labD.z)

                // Gradient / Laplacian — skip the 1-pixel border so neighbors
                // stay inside the analysis buffer. Tile boundaries can still
                // read outside the tile but the snap-to-tileSize layout
                // guarantees never outside the full grid.
                if xx > 0 && xx < w - 1 && yy > 0 && yy < h - 1 {
                    let lA = SIMD3<Float>(a[idx - 1].x, a[idx - 1].y, a[idx - 1].z)
                    let rA = SIMD3<Float>(a[idx + 1].x, a[idx + 1].y, a[idx + 1].z)
                    let uA = SIMD3<Float>(a[idx - w].x, a[idx - w].y, a[idx - w].z)
                    let dA2 = SIMD3<Float>(a[idx + w].x, a[idx + w].y, a[idx + w].z)
                    let lB = SIMD3<Float>(b[idx - 1].x, b[idx - 1].y, b[idx - 1].z)
                    let rB = SIMD3<Float>(b[idx + 1].x, b[idx + 1].y, b[idx + 1].z)
                    let uB = SIMD3<Float>(b[idx - w].x, b[idx - w].y, b[idx - w].z)
                    let dB2 = SIMD3<Float>(b[idx + w].x, b[idx + w].y, b[idx + w].z)

                    let gxA = lumOf(rA) - lumOf(lA)
                    let gyA = lumOf(dA2) - lumOf(uA)
                    let gxB = lumOf(rB) - lumOf(lB)
                    let gyB = lumOf(dB2) - lumOf(uB)
                    let gA = sqrtf(gxA * gxA + gyA * gyA)
                    let gB = sqrtf(gxB * gxB + gyB * gyB)
                    sumGradA += gA
                    sumGradB += gB

                    // Banding: count pixels with near-zero gradient as "flat".
                    let bandingEps: Float = 0.005
                    if gA < bandingEps { flatCountA += 1 }
                    if gB < bandingEps { flatCountB += 1 }
                    gradientSamples += 1

                    let lapA = lumOf(lA) + lumOf(rA) + lumOf(uA) + lumOf(dA2) - 4 * lumA
                    let lapB = lumOf(lB) + lumOf(rB) + lumOf(uB) + lumOf(dB2) - 4 * lumB
                    let edgeWeight = gB                  // weight ringing by where B has edges
                    sumLapDiff += Swift.abs(lapA - lapB) * edgeWeight
                    sumEdgeB += edgeWeight
                }
            }
        }

        let meanAbsErr = sumAbsErr / count
        let mse = sumSqErr / count

        muA /= count
        muB /= count

        // Second pass for SSIM variance/covariance using stored means.
        var varA: Float = 0, varB: Float = 0, cov: Float = 0
        for j in 0..<size {
            let yy = y + j
            for i in 0..<size {
                let idx = yy * w + (x + i)
                let pa = sanitize(a[idx])
                let pb = sanitize(b[idx])
                let lumA = 0.2126 * pa.x + 0.7152 * pa.y + 0.0722 * pa.z
                let lumB = 0.2126 * pb.x + 0.7152 * pb.y + 0.0722 * pb.z
                let dA = lumA - muA
                let dB = lumB - muB
                varA += dA * dA
                varB += dB * dB
                cov += dA * dB
            }
        }
        varA /= count
        varB /= count
        cov /= count

        // SSIM with L≈1 normalization; HDR clamps so very-bright tiles still
        // produce a finite structural score.
        let C1: Float = 0.0001
        let C2: Float = 0.0009
        let muAc = clampUnit(muA)
        let muBc = clampUnit(muB)
        let ssimNum = (2 * muAc * muBc + C1) * (2 * cov + C2)
        let ssimDen = (muAc * muAc + muBc * muBc + C1) * (varA + varB + C2)
        let ssim = ssimDen > 0 ? ssimNum / ssimDen : 1.0
        let textureLoss = max(0, 1 - ssim)

        let highlightBias  = brightCount > 0 ? sumRelBright / brightCount : 0
        let shadowBias     = darkCount > 0 ? Swift.abs(sumDark / darkCount) : 0
        let colorShift     = sumDeltaE / count
        let fireflyScore   = maxErr > 0 ? max(0, (maxErr / max(meanAbsErr, 0.001)) - 1) * maxErr : 0
        let denoisingBlur  = (sumGradA + 1e-6) > 0 ? max(0, (sumGradA - sumGradB)) / (sumGradA + 1e-6) : 0
        let ringing        = sumEdgeB > 0 ? sumLapDiff / sumEdgeB : 0

        // Banding: tiles with a wide luma range but many flat (near-zero gradient)
        // pixels indicate quantization banding. Score is the flat-pixel ratio
        // scaled by the luma range so uniform dark/bright tiles don't trigger.
        // We compare A vs B to surface where A has MORE banding than B.
        let bandingScore: Float = {
            guard gradientSamples > 0 else { return 0 }
            let rangeA = lumaMaxA - lumaMinA
            let rangeB = lumaMaxB - lumaMinB
            let flatRatioA = flatCountA / gradientSamples
            let flatRatioB = flatCountB / gradientSamples
            let bandA = flatRatioA * rangeA
            let bandB = flatRatioB * rangeB
            return max(0, bandA - bandB)
        }()

        var scores = [Float](repeating: 0, count: ErrorCategory.allCases.count)
        scores[ErrorCategory.overall.rawValue]       = meanAbsErr
        scores[ErrorCategory.highlightBias.rawValue] = highlightBias
        scores[ErrorCategory.shadowBias.rawValue]    = shadowBias
        scores[ErrorCategory.colorShift.rawValue]    = colorShift
        scores[ErrorCategory.fireflies.rawValue]     = fireflyScore
        scores[ErrorCategory.denoisingBlur.rawValue] = denoisingBlur
        scores[ErrorCategory.textureLoss.rawValue]   = textureLoss
        scores[ErrorCategory.ringing.rawValue]       = ringing
        scores[ErrorCategory.banding.rawValue]       = bandingScore

        return TileResult(
            scores: scores,
            mse: mse,
            meanAbsErr: meanAbsErr,
            meanRelErr: sumRelErr / count,
            logMAE: sumLogMAE / count,
            logSqErr: sumLogSqErr / count,
            ssim: ssim,
            maxAbsErr: maxErr,
            bucketMAE: bucketMAE,
            bucketRel: bucketRel,
            bucketCount: bucketCount
        )
    }

    // MARK: - Math helpers

    private func lumOf(_ rgb: SIMD3<Float>) -> Float {
        0.2126 * rgb.x + 0.7152 * rgb.y + 0.0722 * rgb.z
    }

    /// Clamp a single channel to [0, 1] for use in normalized statistics.
    /// HDR values >1 still contribute to all the unclamped metrics; this
    /// clamp only stabilises SSIM and Lab where the formulas are undefined
    /// outside the display range.
    private func clampUnit(_ v: Float) -> Float { max(0, min(1, v)) }

    private func sanitize(_ v: SIMD4<Float>) -> SIMD4<Float> {
        SIMD4<Float>(
            v.x.isFinite ? v.x : 0,
            v.y.isFinite ? v.y : 0,
            v.z.isFinite ? v.z : 0,
            v.w.isFinite ? v.w : 1
        )
    }

    /// Linear sRGB (D65) → CIE-L*a*b* (D65). HDR values are clamped to [0,1]
    /// for the Lab transform — outside that range Lab isn't perceptually
    /// meaningful and would dominate the score with arbitrary magnitudes.
    private func linearSRGBToLab(_ rgb: SIMD3<Float>) -> SIMD3<Float> {
        let r = clampUnit(rgb.x), g = clampUnit(rgb.y), b = clampUnit(rgb.z)
        let X = 0.4124564 * r + 0.3575761 * g + 0.1804375 * b
        let Y = 0.2126729 * r + 0.7151522 * g + 0.0721750 * b
        let Z = 0.0193339 * r + 0.1191920 * g + 0.9503041 * b
        let Xn: Float = 0.95047, Yn: Float = 1.0, Zn: Float = 1.08883
        let fx = labF(X / Xn)
        let fy = labF(Y / Yn)
        let fz = labF(Z / Zn)
        let L = 116 * fy - 16
        let aS = 500 * (fx - fy)
        let bS = 200 * (fy - fz)
        return SIMD3<Float>(L, aS, bS)
    }

    private func labF(_ t: Float) -> Float {
        let delta: Float = 6.0 / 29.0
        let delta3 = delta * delta * delta
        if t > delta3 { return powf(t, 1.0 / 3.0) }
        return t / (3 * delta * delta) + 4.0 / 29.0
    }
}
