# Changelog

All notable changes to Framewise are documented in this file.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and
this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

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
