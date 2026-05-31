# Changelog

All notable changes to Framewise are documented in this file.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and
this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
- **Scopes** (`S`) — a histogram (RGB overlaid + luma), waveform, and
  vectorscope, shown side-by-side for A and B so two videos/renders can be
  compared at a glance. Computed off the main thread on a downscaled frame and
  refreshed as frames arrive (work is throttled so it never piles up).
- **Image sequence support** — drop a folder or multiple numbered frames (e.g.
  `render.0001.exr … render.0240.exr`), or pick them from the Open dialog, to
  load a playable image sequence onto a side. Sequences scrub, step, loop, and
  play back through the full transport, and pair with a video or another
  sequence. The playback frame rate is selectable (23.976 / 24 / 25 / 30 / 50 /
  60) in the viewing-options popover, since image frames carry no timing. A
  single file still loads as one still image.
- **Blink comparison** — press `B` to swap A↔B full-frame in place (the "blink
  comparator" technique), the fastest way to spot sub-pixel differences. Works
  during playback. `Esc` or the toolbar exits; an auto-flip mode with an
  adjustable rate is available in the new viewing-options popover. A center-top
  badge names the side currently shown.
- **Channel isolation** — `C` cycles RGB / R / G / B / Alpha / Luma, showing the
  selected channel as grayscale for inspection.
- **Clipping & gamut warnings** — optional overlays that flag blown highlights
  (magenta) and crushed shadows (blue) at the display range, and out-of-gamut
  pixels (yellow, negative working-space channels). Toggled in the popover.
- **Playback-speed reduction** — 1× / ½× / ¼× / 0.1× for frame-accurate review
  of temporal artifacts.
- **A/B alignment offset** — shift side B by ±N frames to align renders vs.
  captures (or two encodes) that start a few frames apart.
- **Segment looping** — set in/out points (`I` / `O`) and loop a segment (`L`)
  for repeated review of one passage.
- A consolidated **viewing-options popover** in the toolbar housing the controls
  above, each section hiding itself when not applicable to the loaded media.

### Changed
- Refreshed the visual style, adapting the design language of the sibling
  project [Pixelwise](https://github.com/vork/Pixelwise): a near-black,
  faintly-purple canvas (`#0B0B0F`), soft panel surfaces, and a signature
  purple→amber brand gradient. Primary calls-to-action (the empty-state
  **Open A/B** buttons and the explorer **Analyze** button) are now filled
  gradient buttons with a soft brand glow; toolbar and explorer controls use
  bordered "ghost" buttons whose edges light up purple on hover. The previous
  yellow active/selected accent (Explore toggle, category chips, tonemap
  settings, focus outlines, scope icons) is now the purple brand accent, and
  sliders/segmented pickers inherit it via a global tint. Keyboard-shortcut
  keycaps in the help overlay, the tonemap response curve, and the various
  panels (controls bar, explorer, media labels, pixel readout) were restyled
  to match. A/B side identity is tied to the brand-gradient endpoints —
  purple (A) and amber (B) — so the media labels and pixel-readout chips read
  as the two ends of the brand wash. All styling is centralised in a new
  `Theme.swift`.

## [0.6.2] - 2026-05-26

This is a republish of v0.6.0 + v0.6.1 with a CI fix. The v0.6.0 and v0.6.1
tags exist but their workflow runs failed and produced no downloadable
artifacts. The v0.6.2 binary contains every change listed under v0.6.0,
v0.6.1, and the fix below — see those sections for the full notes.

### Fixed
- Added `TonemapView.swift` to the GitHub Actions Swift compilation step
  for both the arm64 and x86_64 builds. v0.6.0 introduced the file in
  `build.sh` and the source tree, but the corresponding workflow update
  was missed, so CI tag-pushes for v0.6.0 and v0.6.1 failed with
  `cannot find 'TonemapSettingsButton' in scope` and never produced
  release artifacts.

## [0.6.1] - 2026-05-26

### Fixed
- Silenced two build warnings that emerged on top of v0.6.0: the
  Swift 6 sendability warning in `MediaEngine.runAnalysis` (caused by
  the `await MainActor.run` closure capturing `var self` from the
  enclosing `[weak self]` task — now promoted to a strong, immutable
  binding before the inner closure) and the two `var` → `let` lints
  for `bucketRanges` and `bucketLabels` in `ErrorAnalyzer.analyze`.
  No behaviour change.

## [0.6.0] - 2026-05-26

### Added
- HDR-aware error exploration panel (toggle with `X` or the toolbar
  **Explore** button; requires both A and B loaded). When open, Framewise
  runs a tile-based analysis of the current frame on a background thread
  and surfaces the worst-offending regions for the selected category.
- Eight error categories, each with its own fitting loss rather than a
  single global metric: **Overall** (mean |A−B|), **Highlight bias**
  (relative error in bright pixels), **Shadow bias** (signed mean in dark
  pixels), **Color shift** (CIE76 ΔE in CIE L*a*b* D65), **Fireflies**
  (max-pixel-error / mean-error − 1), **Denoising blur** (lost
  high-frequency gradient energy), **Texture loss** (1 − SSIM), and
  **Ringing** (Laplacian residual weighted by edge strength in B).
- Highlight styles for the surfaced regions: **off**, **outline only**,
  **dim everything outside**, and **focus single** (after clicking a
  region in the panel). All three on-screen styles are rendered in the
  shader so they survive zoom and pan.
- Click any region card in the panel to zoom and pan the comparison view
  to that region and mark it as focused.
- Live global statistics computed alongside the regions: MAE, MSE, RMSE,
  linear PSNR, mean relative error, log-domain MAE / PSNR, mean SSIM,
  multi-scale SSIM, mean ΔE, max and 99th-percentile pixel error, plus
  per-bucket MAE / relative-error for shadows (≤ 0.05), mid (0.05–0.5),
  highlights (0.5–1.0), and HDR (> 1.0).
- Top-N% slider to widen or narrow the set of surfaced regions, and an
  **Analyze / Re-analyze** button that refreshes the result. Auto-analysis
  re-runs when the frame changes, but only while playback is paused and
  the scrubber is settled.
- Four new tonemap operators in addition to the existing **Gamma**,
  **False Color**, and **Pos / Neg**: **Linear** (clamp + sRGB encode),
  **Reinhard** (extended with a tunable whitepoint), **ACES** (Narkowicz
  fit), **Filmic** (Hejl-Burgess-Dawson), and **Piecewise** (Hable filmic
  curve with six user-tunable parameters — toe strength / length,
  shoulder strength / length / angle, and gamma).
- Tonemap settings popover (gear button next to the visualization picker)
  with a live curve preview that mirrors the shader's per-channel
  response, a Reinhard whitepoint slider, and the six-parameter
  piecewise editor. Piecewise parameters are persisted via JSON in
  `UserDefaults`.
- New error metric **Log luminance** (`log10(A+ε) − log10(B+ε)`),
  HDR scale-aware. Cycled by `M` alongside the existing five metrics.

### Changed
- The tonemap picker and the `F`-key cycle now follow a canonical order
  that puts real display operators first
  (Linear → Gamma → Reinhard → ACES → Filmic → Piecewise) and the two
  error-visualization aids last (False Color → Pos / Neg).
- Starting playback or scrubbing now clears any in-flight analysis result
  and focus, so the Explorer panel never shows stale regions that don't
  correspond to the displayed frame. Pausing or releasing the scrubber
  re-runs analysis automatically when the panel is open.
- Error-metric picker tooltip clarifies that the metric drives both
  error-mode rendering and the hover / value readouts.

## [0.5.1] - 2026-05-06

### Fixed
- Fixed a crash that could occur when clicking the × button on a video
  badge. The periodic time observer is now tracked alongside the
  `AVPlayer` it was registered on, so unloading a side no longer leaves
  the observer's token attached to a deallocated player or attempts to
  remove it from the wrong one.

## [0.5.0] - 2026-05-06

### Added
- File-association support: Framewise registers as a viewer for common video
  and image types via `CFBundleDocumentTypes`, so files can be opened from
  Finder ("Open With → Framewise"), the Dock icon, or `open -a Framewise …`.
- Multi-file open: dropping two files onto the window — or selecting two
  in Finder and choosing _Open With → Framewise_ — loads them as side A and
  side B as a fresh comparison pair (drop position is ignored for
  multi-file drops). Single-file drops still respect the drop position.
- `URLRouter` dispatches URLs delivered to the app via
  `application(_:open:)` to the front-most window's engine, buffering URLs
  during cold launch until a window registers.
- Hover pixel readout chip: a bottom-anchored chip shows channel-tinted
  RGB(A) values for both sides plus a delta computed by the currently
  selected error metric, labelled with the metric symbol (`Δ`, `|Δ|`,
  `Δ²`, `|Δ|/(B+ε)`, `Δ²/(B²+ε)`).
- In-shader pixel value overlay now renders alpha when alpha is
  non-trivial: α ≠ 1 in split mode, or Δα ≠ 0 in error mode.
- The hover chip automatically hides when the in-shader pixel value
  overlay is active, so the two readouts no longer compete for the same
  screen real estate.
- Dynamic version stamping: `CFBundleShortVersionString` and
  `CFBundleVersion` are derived at build time from `git describe` /
  `git rev-list --count` by `scripts/apply-version.sh`, invoked from both
  `build.sh` and the GitHub Actions workflow. `MARKETING_VERSION` and
  `BUILD_VERSION` environment variables override the values when needed.
- Curated `CHANGELOG.md` shipped with the project; GitHub release notes
  for tagged builds are now sourced from the matching changelog section
  by the build workflow instead of auto-generated commit subjects.

### Changed
- Renamed `VideoEngine` to `MediaEngine`. Per-side state moved from
  `videoSizeA/B`, `hasVideoA/B`, `videoNameA/B`, `videoAspect`, and
  `referenceVideoSize` to the `media*` equivalents. The matching shader
  uniforms (`videoSizeA/B`, `videoAspect`, `hasVideoA/B`) were renamed to
  `mediaSizeA/B`, `mediaAspect`, and `hasMediaA/B`.
- Maximum zoom raised from 200× to 2000× so the in-shader pixel value
  overlay reliably triggers on high-resolution media (the overlay
  activates when a source pixel covers ≥ 56 screen pixels).
- `M` cycles the error metric in any display mode (previously gated to
  error mode). In split mode, the change is reflected in the hover chip's
  delta calculation and label symbol.

## [0.4.0] - 2026-05-05

### Added
- Image support on both sides (JPEG, PNG, WebP, HEIC, EXR, HDR, RAW, and
  any format `ImageIO` recognizes), classified by a new `MediaType` enum.
- Mixed video / image comparison: any combination of one or two images
  and / or videos is supported, with shader-side rendering kept identical
  for both sources.

### Changed
- `VideoEngine.loadVideo` is now `loadMedia(url:side:)` and dispatches to
  the appropriate loader. `unloadVideo` was renamed to `unloadMedia` and
  also clears cached `CIImage` state.
- Drag-and-drop and the file picker accept the union of supported video
  and image extensions; transport controls (timeline, play/pause, step)
  are hidden when no playable video is loaded.
- Duration and playhead recompute via `recalculateDuration()` whenever a
  side changes, so loading or unloading mixed media keeps the timeline
  consistent.

## [0.3.0] - 2026-05-04

### Added
- Pixel-level inspection: when zoomed in far enough, the renderer overlays
  a 1-pixel grid and the source RGB values directly inside each cell.
- `P` key toggles inspection (auto / off); the choice persists across
  launches.
- New shader uniforms `videoSizeA`, `videoSizeB`, and `pixelInspect`
  expose source resolutions to the fragment shader so the grid spacing and
  text rendering scale to the actual media.

## [0.2.3] - 2026-04-21

### Added
- Multi-window support: `File → New Window` (⌘N) opens a fresh comparison
  window with its own `VideoEngine` so multiple video pairs can be compared
  side by side. The window group is keyed `comparison` and each window
  manages its own state.

## [0.2.2] - 2026-04-10

### Changed
- Visualization mode (Gamma / False Color / Pos-Neg) and exposure / gamma
  controls are now available in split and single-video modes, not just
  error mode. The `F` key cycles visualization in any mode with at least
  one video loaded.
- Tonemapping pipeline unified: split, single-video, and error modes all
  decode to linear, apply exposure, run the selected tonemap, and re-encode
  with the user gamma — using the same `applyTonemap` helper.

## [0.2.1] - 2026-04-10

### Added
- Per-side unload: each video name badge now has an × button that releases
  that side's player, output, and metadata. The duration and playhead
  recompute from the remaining video, and the display falls back to split
  mode when only one side remains loaded.

## [0.2.0] - 2026-04-10

### Added
- Drag-and-drop loading: drop a video file onto the comparison view to
  load it. The drop position relative to the slider determines which side
  it targets.
- In-app help overlay (`?` to toggle, `Esc` to dismiss) listing every
  shortcut grouped by category.
- Persistence for display mode, error metric, and tonemap mode via
  `UserDefaults`, restored on launch.
- Keyboard exposure (`[` / `]`), gamma (`{` / `}`), and `0` to reset both
  to defaults.
- Keyboard zoom via `Up` / `Down` arrows.

## [0.1.0] - 2026-04-10

Initial public release as **Framewise**.

### Added
- Side-by-side video comparison with a Metal-rendered split slider and
  draggable handle.
- Synchronized dual `AVPlayer` playback with frame-accurate sync, frame
  stepping, and go-to-frame.
- Error visualization mode with five metrics — signed error, absolute
  error, squared error, relative absolute, relative squared — and three
  visualization modes — Gamma, False Color, and Pos / Neg.
- Exposure (`-10` to `+10` EV) and gamma (`0.1` to `5.0`) controls,
  applied uniformly to error visualization.
- HDR support via EDR on capable displays, with automatic SDR fallback.
- Zoom up to 200×, click-and-drag pan, and `1` / `2` / `4` / `8` zoom
  presets.
- Standard keybindings for play / pause, step, zoom, mode toggle, error
  metric cycling, visualization cycling, reset, and home / end.
- Support for any codec `AVFoundation` handles (H.264, HEVC, ProRes, AV1,
  VP9, …).
