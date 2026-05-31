// VMAF integration — compiled in only when built with FRAMEWISE_VMAF=1 and
// linked against a bundled libvmaf (see README → "Building with VMAF"). The
// whole file is gated so the default build never references libvmaf symbols.
//
// It computes per-frame VMAF between A (treated as the distorted/test side) and
// B (reference) by decoding both to a common-resolution YUV420p and streaming
// them through libvmaf's stateful C API, then reads the per-index scores back
// into the same TemporalSeries the strip already renders.
//
// NOTE: this code targets the libvmaf v2.x / v3 C API and could not be compiled
// in the authoring environment — validate against your installed libvmaf when
// you first enable the flag.
#if FRAMEWISE_VMAF

import Foundation
import AVFoundation
import CoreImage
import CoreGraphics

enum VMAFEngine {
    /// Built-in model version string (libvmaf ships these compiled in).
    private static let modelVersion = "vmaf_v0.6.1"
    private static let maxWidth = 1920

    static func scan(sourceA: TemporalSource, sourceB: TemporalSource,
                     duration: Double, fps: Double,
                     cancel: TemporalAnalyzer.Cancel,
                     progress: @escaping (Double) -> Void) -> TemporalSeries? {
        guard duration > 0, fps > 0 else { return nil }

        // Probe a reference resolution from A's first frame, cap width, force even.
        guard let (w0, h0) = probeSize(sourceA) ?? probeSize(sourceB) else { return nil }
        var w = min(maxWidth, w0)
        var h = Int(Double(h0) * Double(w) / Double(max(1, w0)))
        w &= ~1; h &= ~1
        guard w >= 2, h >= 2 else { return nil }

        let provA = makeProvider(sourceA, w: w, h: h)
        let provB = makeProvider(sourceB, w: w, h: h)

        var vmaf: OpaquePointer?
        var cfg = VmafConfiguration()
        cfg.log_level = VMAF_LOG_LEVEL_NONE
        cfg.n_threads = UInt32(max(1, ProcessInfo.processInfo.activeProcessorCount - 1))
        guard vmaf_init(&vmaf, cfg) == 0, let ctx = vmaf else { return nil }
        defer { vmaf_close(ctx) }

        var model: OpaquePointer?
        var mcfg = VmafModelConfig()
        guard modelVersion.withCString({ name -> Bool in
            mcfg.name = name
            return vmaf_model_load(&model, &mcfg, name) == 0
        }), let mdl = model else { return nil }
        defer { vmaf_model_destroy(mdl) }
        guard vmaf_use_features_from_model(ctx, mdl) == 0 else { return nil }

        let total = max(2, Int((duration * fps).rounded()))
        var produced = 0

        for i in 0..<total {
            if cancel.cancelled { return nil }
            let t = duration * Double(i) / Double(total - 1)
            guard let rgbaA = provA(t), let rgbaB = provB(t) else { break }

            var dist = VmafPicture(); var ref = VmafPicture()
            guard vmaf_picture_alloc(&dist, VMAF_PIX_FMT_YUV420P, 8, UInt32(w), UInt32(h)) == 0
            else { break }
            guard vmaf_picture_alloc(&ref, VMAF_PIX_FMT_YUV420P, 8, UInt32(w), UInt32(h)) == 0
            else { vmaf_picture_unref(&dist); break }

            fillYUV420(&dist, rgba: rgbaA, w: w, h: h)   // A = distorted
            fillYUV420(&ref,  rgba: rgbaB, w: w, h: h)   // B = reference

            // vmaf_read_pictures takes ownership of the picture buffers.
            if vmaf_read_pictures(ctx, &ref, &dist, UInt32(i)) != 0 { break }
            produced += 1
            if i % 4 == 0 { progress(Double(i + 1) / Double(total)) }
        }
        guard produced >= 2 else { return nil }
        // Flush.
        _ = vmaf_read_pictures(ctx, nil, nil, 0)

        var values = [Float](); values.reserveCapacity(produced)
        var times = [Double](); times.reserveCapacity(produced)
        for i in 0..<produced {
            var score: Double = 0
            if vmaf_score_at_index(ctx, mdl, &score, UInt32(i)) == 0 {
                values.append(Float(score))
                times.append(duration * Double(i) / Double(total - 1))
            }
        }
        guard values.count >= 2 else { return nil }

        // Worst = lowest VMAF, with non-maximum suppression for spread.
        let order = values.indices.sorted { values[$0] < values[$1] }
        let spacing = max(1, values.count / 24)
        var events: [Int] = []
        for idx in order where events.allSatisfy({ abs($0 - idx) >= spacing }) {
            events.append(idx); if events.count >= 6 { break }
        }
        return TemporalSeries(times: times, values: values,
                              events: events, worst: events.first, metric: .vmaf)
    }

    // MARK: Frame access

    private static func probeSize(_ s: TemporalSource) -> (Int, Int)? {
        switch s {
        case .video(let asset, _):
            let gen = AVAssetImageGenerator(asset: asset)
            gen.appliesPreferredTrackTransform = true
            guard let cg = try? gen.copyCGImage(at: .zero, actualTime: nil) else { return nil }
            return (cg.width, cg.height)
        case .sequence(let urls, _):
            guard let u = urls.first, let ci = CIImage(contentsOf: u) else { return nil }
            return (Int(ci.extent.width), Int(ci.extent.height))
        case .still(let ci):
            return (Int(ci.extent.width), Int(ci.extent.height))
        case .empty:
            return nil
        }
    }

    private static func makeProvider(_ source: TemporalSource, w: Int, h: Int) -> (Double) -> [UInt8]? {
        switch source {
        case .video(let asset, _):
            let gen = AVAssetImageGenerator(asset: asset)
            gen.appliesPreferredTrackTransform = true
            gen.requestedTimeToleranceBefore = .zero
            gen.requestedTimeToleranceAfter = CMTime(seconds: 0.05, preferredTimescale: 600)
            return { t in
                guard let cg = try? gen.copyCGImage(
                    at: CMTime(seconds: t, preferredTimescale: 600), actualTime: nil) else { return nil }
                return draw(cg, w, h)
            }
        case .sequence(let urls, let fps):
            let cictx = ScopeSampler.context
            return { t in
                guard !urls.isEmpty else { return nil }
                let idx = max(0, min(urls.count - 1, Int((t * fps).rounded())))
                guard let ci = CIImage(contentsOf: urls[idx]),
                      let cg = cictx.createCGImage(ci, from: ci.extent) else { return nil }
                return draw(cg, w, h)
            }
        case .still(let ci):
            let buf = ScopeSampler.context.createCGImage(ci, from: ci.extent).flatMap { draw($0, w, h) }
            return { _ in buf }
        case .empty:
            return { _ in nil }
        }
    }

    private static func draw(_ cg: CGImage, _ w: Int, _ h: Int) -> [UInt8]? {
        var px = [UInt8](repeating: 0, count: w * h * 4)
        let cs = CGColorSpaceCreateDeviceRGB()
        let info = CGImageAlphaInfo.premultipliedLast.rawValue
        let ok = px.withUnsafeMutableBytes { ptr -> Bool in
            guard let base = ptr.baseAddress,
                  let ctx = CGContext(data: base, width: w, height: h, bitsPerComponent: 8,
                                      bytesPerRow: w * 4, space: cs, bitmapInfo: info) else { return false }
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        return ok ? px : nil
    }

    // MARK: RGBA8 → YUV420p (BT.709 limited range)

    private static func fillYUV420(_ pic: inout VmafPicture, rgba: [UInt8], w: Int, h: Int) {
        guard let yp = pic.data.0?.assumingMemoryBound(to: UInt8.self),
              let up = pic.data.1?.assumingMemoryBound(to: UInt8.self),
              let vp = pic.data.2?.assumingMemoryBound(to: UInt8.self) else { return }
        let ys = Int(pic.stride.0), us = Int(pic.stride.1), vs = Int(pic.stride.2)

        func clamp8(_ x: Double) -> UInt8 { UInt8(max(0, min(255, x.rounded()))) }

        // Luma plane.
        for j in 0..<h {
            for i in 0..<w {
                let p = (j * w + i) * 4
                let r = Double(rgba[p]) / 255, g = Double(rgba[p + 1]) / 255, b = Double(rgba[p + 2]) / 255
                let y = 0.2126 * r + 0.7152 * g + 0.0722 * b
                yp[j * ys + i] = clamp8(16 + 219 * y)
            }
        }
        // Chroma planes, 2×2 averaged.
        for j in 0..<(h / 2) {
            for i in 0..<(w / 2) {
                var sb = 0.0, sr = 0.0, sy = 0.0
                for dj in 0..<2 {
                    for di in 0..<2 {
                        let x = min(w - 1, i * 2 + di), yy = min(h - 1, j * 2 + dj)
                        let p = (yy * w + x) * 4
                        let r = Double(rgba[p]) / 255, g = Double(rgba[p + 1]) / 255, b = Double(rgba[p + 2]) / 255
                        sy += 0.2126 * r + 0.7152 * g + 0.0722 * b
                        sb += b; sr += r
                    }
                }
                let yv = sy / 4, bv = sb / 4, rv = sr / 4
                let cb = (bv - yv) / 1.8556
                let cr = (rv - yv) / 1.5748
                up[j * us + i] = clamp8(128 + 224 * cb)
                vp[j * vs + i] = clamp8(128 + 224 * cr)
            }
        }
    }
}

#endif
