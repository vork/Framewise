import SwiftUI

// MARK: - Explorer panel
//
// Compact panel that sits between the comparison view and the controls bar
// when the user enables HDR-aware error exploration. Tile analysis runs in
// `MediaEngine.runAnalysis()` (background thread); this view is purely a
// presentation layer over `engine.analysisResult` + `engine.topRegions`.

struct ExplorerPanel: View {
    @ObservedObject var engine: MediaEngine

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.2)
            content
        }
        .background(Theme.panel)
    }

    // MARK: Header — category chips, fraction slider, highlight-style picker.

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "scope")
                .foregroundStyle(Theme.accentA)
                .font(.system(size: 13))
            Text("Error Exploration")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white)

            Spacer().frame(width: 8)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(ErrorCategory.allCases) { cat in
                        categoryChip(cat)
                    }
                }
                .padding(.vertical, 2)
            }

            Spacer(minLength: 8)

            topFractionControl
            highlightStylePicker

            Button {
                engine.runAnalysis()
            } label: {
                HStack(spacing: 4) {
                    if engine.isAnalyzing {
                        ProgressView().controlSize(.mini)
                            .progressViewStyle(.circular)
                    } else {
                        Image(systemName: "arrow.clockwise")
                    }
                    Text(engine.analysisResult == nil ? "Analyze" : "Re-analyze")
                }
                .font(.system(size: 11, weight: .semibold))
            }
            .buttonStyle(BrandButtonStyle())
            .disabled(!engine.hasMediaA || !engine.hasMediaB
                      || engine.isAnalyzing || engine.isPlaying || engine.isScrubbing)
            .help("Run tile-based error analysis on the current frame")

            Button {
                engine.explorerOpen = false
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.white.opacity(0.6))
                    .frame(width: 18, height: 18)
                    .background(Theme.panel2, in: Circle())
                    .overlay(Circle().stroke(Theme.border, lineWidth: 1))
            }
            .buttonStyle(.plain)
            .help("Close explorer (X)")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    @ViewBuilder
    private func categoryChip(_ cat: ErrorCategory) -> some View {
        let selected = engine.explorerCategory == cat
        Button {
            engine.explorerCategory = cat
            // Surfacing a new ranking — drop the focused outline so the user
            // sees the freshly-selected category cleanly.
            engine.focusedRegionID = nil
        } label: {
            HStack(spacing: 4) {
                Image(systemName: cat.icon)
                    .font(.system(size: 10))
                Text(cat.shortLabel)
                    .font(.system(size: 11, weight: selected ? .semibold : .regular))
            }
            .foregroundStyle(selected ? Theme.text : Theme.text.opacity(0.8))
        }
        .buttonStyle(GhostButtonStyle(active: selected))
        .help("\(cat.label): \(cat.detail)")
    }

    private var topFractionControl: some View {
        HStack(spacing: 4) {
            Text("Top")
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(.tertiary)
            Text(formatPct(engine.explorerTopFraction))
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 38, alignment: .trailing)
            // Log-mapped slider so 0.1% through 50% maps cleanly onto a small
            // control surface — linear would put the useful range in the first
            // few pixels.
            Slider(value: Binding(
                get: { logFromFraction(engine.explorerTopFraction) },
                set: { engine.explorerTopFraction = fractionFromLog($0) }
            ), in: 0...1)
            .frame(width: 80)
            .controlSize(.mini)
        }
        .help("Fraction of tiles surfaced (0.1% – 50%)")
    }

    private var highlightStylePicker: some View {
        Picker("", selection: $engine.highlightStyle) {
            ForEach(MediaEngine.HighlightStyle.allCases) { style in
                Text(style.label).tag(style)
            }
        }
        .pickerStyle(.segmented)
        .frame(width: 220)
        .help("How highlights render on the image")
    }

    // MARK: Content — region cards or empty/loading state.

    @ViewBuilder
    private var content: some View {
        if engine.isPlaying {
            statusRow(icon: "play.fill",
                      text: "Analysis pauses during playback — pause to refresh.")
        } else if engine.isScrubbing {
            statusRow(icon: "slider.horizontal.3",
                      text: "Analysis pauses while scrubbing — release the handle to refresh.")
        } else if engine.isAnalyzing {
            statusRow(icon: "hourglass", text: "Analyzing tiles…")
        } else if let result = engine.analysisResult {
            VStack(alignment: .leading, spacing: 0) {
                statsRow(result.stats)
                bucketsRow(result.stats.buckets)
                Divider().opacity(0.15)
                if engine.topRegions.isEmpty {
                    statusRow(icon: "checkmark.circle",
                              text: "No tiles passed the threshold — widen the top % slider or pick another category.")
                } else {
                    regionCards
                }
            }
        } else {
            statusRow(icon: "questionmark.circle",
                      text: "Run analysis to surface the highest-error regions and global metrics.")
        }
    }

    /// Headline scale-aware metrics row. Surfaces everything an HDR
    /// validation pipeline expects in one glance: linear and log-domain
    /// MAE/PSNR, structural similarity at one and multiple scales,
    /// CIE ΔE, the max / 99th percentile outliers, and the relative error.
    private func statsRow(_ stats: GlobalStats) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 0) {
                statCell("MAE",      String(format: "%.4f", stats.mae))
                statCell("MSE",      String(format: "%.5f", stats.mse))
                statCell("RMSE",     String(format: "%.4f", stats.rmse))
                statCell("PSNR",     String(format: "%.2f dB", stats.psnr))
                cellDivider
                statCell("log MAE",  String(format: "%.3f", stats.logSpaceMAE),
                         help: "Scale-aware: mean |log₁₀(A+ε) − log₁₀(B+ε)|")
                statCell("log PSNR", String(format: "%.2f dB", stats.logSpacePSNR),
                         help: "PSNR in log-luminance, 10-stop reference range")
                cellDivider
                statCell("SSIM",     String(format: "%.4f", stats.meanSSIM))
                statCell("MS-SSIM",  String(format: "%.4f", stats.msSSIM),
                         help: "Mean SSIM across 3 scales — texture loss check")
                statCell("ΔE",       String(format: "%.2f", stats.meanDeltaE),
                         help: "Mean CIE76 ΔE in L*a*b*")
                cellDivider
                statCell("Rel. err", String(format: "%.3f", stats.relativeError))
                statCell("Max err",  String(format: "%.3f", stats.maxAbsError))
                statCell("P99 err",  String(format: "%.3f", stats.p99AbsError),
                         help: "99th-percentile tile-max error (firefly indicator)")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        }
    }

    private var cellDivider: some View {
        Divider()
            .frame(height: 18)
            .padding(.horizontal, 6)
            .opacity(0.25)
    }

    private func statCell(_ name: String, _ value: String, help: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(name)
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(.tertiary)
            Text(value)
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundStyle(.white)
        }
        .padding(.horizontal, 6)
        .help(help ?? name)
    }

    /// Per-luminance-bucket bar — surfaces where the model fails along the
    /// brightness axis. Naive MAE/MSE in HDR is dominated by the brightest
    /// pixels; bucketing exposes whether the error sits in shadows, mid-
    /// tones, highlights, or super-highlights.
    private func bucketsRow(_ buckets: [LuminanceBucket]) -> some View {
        let maxMAE = max(0.0001, buckets.map(\.mae).max() ?? 1)
        return HStack(spacing: 8) {
            Text("Error by luminance")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.tertiary)
            ForEach(buckets) { b in
                bucketCell(b, maxMAE: maxMAE)
            }
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 6)
    }

    private func bucketCell(_ bucket: LuminanceBucket, maxMAE: Float) -> some View {
        let fill = CGFloat(max(0, min(1, bucket.mae / maxMAE)))
        let coverage = Int((bucket.coverage * 100).rounded())
        return VStack(alignment: .leading, spacing: 2) {
            Text(bucket.label)
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(.secondary)
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color.white.opacity(0.07))
                    .frame(width: 90, height: 6)
                RoundedRectangle(cornerRadius: 2)
                    .fill(colorForBucket(bucket.id))
                    .frame(width: 90 * fill, height: 6)
            }
            HStack(spacing: 4) {
                Text(String(format: "MAE %.3f", bucket.mae))
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.8))
                Text("·")
                    .foregroundStyle(.tertiary)
                Text("\(coverage)% px")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }
        }
        .help("\(bucket.label)\nMAE \(String(format: "%.4f", bucket.mae))\nRelative \(String(format: "%.3f", bucket.relativeError))\nCoverage \(coverage)%")
    }

    private func colorForBucket(_ id: Int) -> Color {
        switch id {
        case 0: return Color.blue.opacity(0.85)
        case 1: return Color.green.opacity(0.85)
        case 2: return Color.orange.opacity(0.85)
        default: return Color.red.opacity(0.85)
        }
    }

    private func statusRow(icon: String, text: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .foregroundStyle(.secondary)
            Text(text)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var regionCards: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(Array(engine.topRegions.enumerated()), id: \.element.id) { idx, region in
                    regionCard(rank: idx + 1, region: region)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
    }

    private func regionCard(rank: Int, region: ErrorRegion) -> some View {
        let cat = engine.explorerCategory
        let isFocused = engine.focusedRegionID == region.id
        return Button {
            engine.zoomToRegion(region)
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 4) {
                    Text("#\(rank)")
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.85))
                    Spacer()
                    Image(systemName: cat.icon)
                        .font(.system(size: 9))
                        .foregroundStyle(Theme.accentA.opacity(0.9))
                }
                Text(cat.formatScore(region.score(cat)))
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.white)
                Text(positionString(region))
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.55))
            }
            .frame(width: 84, alignment: .leading)
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isFocused ? AnyShapeStyle(Theme.brandSubtle)
                                    : AnyShapeStyle(Theme.panel2))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(isFocused ? Theme.accentA : Theme.border,
                            lineWidth: isFocused ? 1.5 : 1)
            )
        }
        .buttonStyle(.plain)
        .help("Tile (\(region.x), \(region.y))  ·  click to zoom in")
    }

    private func positionString(_ region: ErrorRegion) -> String {
        guard let size = engine.analysisResult?.analysisSize, size.width > 0, size.height > 0 else {
            return ""
        }
        // Display position in percent of the image so users can compare across
        // different-sized media without needing to know the analysis grid.
        let xPct = (Double(region.x) / Double(size.width)) * 100
        let yPct = (Double(region.y) / Double(size.height)) * 100
        return String(format: "%2.0f%%, %2.0f%%", xPct, yPct)
    }

    // MARK: Helpers

    private func formatPct(_ frac: Double) -> String {
        if frac < 0.01 { return String(format: "%.1f%%", frac * 100) }
        if frac < 0.1  { return String(format: "%.0f%%", frac * 100) }
        return String(format: "%.0f%%", frac * 100)
    }

    /// Map fraction in [0.001, 0.5] onto [0, 1] using log10, so the slider
    /// gives the user fine control near the bottom of the range.
    private func logFromFraction(_ f: Double) -> Double {
        let minL = log10(0.001)
        let maxL = log10(0.5)
        let l = log10(max(0.001, min(0.5, f)))
        return (l - minL) / (maxL - minL)
    }

    private func fractionFromLog(_ t: Double) -> Double {
        let minL = log10(0.001)
        let maxL = log10(0.5)
        let l = minL + (maxL - minL) * max(0, min(1, t))
        return pow(10, l)
    }
}
