# Changelog

All notable changes to Framewise are documented in this file.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and
this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

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
