# Framewise

A native macOS app for side-by-side video and image comparison with a split-view slider and error visualization. Built with Swift, Metal, AVFoundation, and Core Image.

![macOS 14+](https://img.shields.io/badge/macOS-14%2B-blue)
![Swift](https://img.shields.io/badge/Swift-5.9-orange)
![Metal](https://img.shields.io/badge/GPU-Metal-purple)

## Features

- **Side-by-side comparison** with draggable slider — videos, still images, or any mix of the two
- **Error visualization mode** — view the difference between the two sources with multiple error metrics and tonemapping options (inspired by [tev](https://github.com/Tom94/tev))
- **Drag-and-drop** — drop a video or image onto the left or right half of the window to load it as A or B
- **HDR support** — HDR videos, EXR/HDR HEIC stills, and wide-gamut images flow through Core Image and display on EDR-capable screens; SDR falls back automatically
- **4K and beyond** — handles any resolution your hardware supports
- **Deep zoom** — zoom up to 200x to inspect individual pixels
- **Pixel inspection** — when zoomed in close, shows pixel grid lines and per-channel RGB values overlaid on each pixel (HDR-aware, inspired by [tev](https://github.com/Tom94/tev)). Works in both Split and Error modes.
- **Exposure & gamma control** — adjust in both split and error modes, available even with a single video
- **Frame-accurate sync** — both videos stay perfectly synchronized
- **Frame stepping** — navigate frame by frame with arrow keys
- **Go to frame** — jump to any frame number directly
- **Persistent settings** — display mode, error metric, and visualization mode are remembered across sessions
- **Multiple windows** — `⌘N` opens an independent comparison window; compare as many pairs as your hardware allows
- **All modern formats**
  - **Video:** H.264, HEVC, ProRes, AV1, VP9, and anything AVFoundation supports
  - **Image:** PNG, JPEG, WebP, HEIC/HEIF, TIFF, BMP, OpenEXR, Radiance HDR, and Camera RAW (via ImageIO)
- **In-app help** — press `?` to see all keyboard shortcuts

## Display Modes

### Split Mode
Side-by-side comparison with a draggable slider. Video A is shown on the left, video B on the right. Drag the handle to reveal more of either side.

### Error Mode
Visualizes the pixel-level difference between the two videos. Toggle with `E` or the segmented control in the toolbar.

**Error Metrics** (cycle with `M`):

| Metric | Formula | Use case |
|--------|---------|----------|
| Error | `A - B` | Signed difference — see direction of change |
| Absolute Error | `abs(A - B)` | Magnitude of difference |
| Squared Error | `(A - B)²` | Emphasizes larger differences |
| Relative Absolute | `abs(A - B) / (abs(B) + ε)` | Normalized by reference brightness |
| Relative Squared | `(A - B)² / (B² + ε)` | Normalized squared difference |

**Visualization Modes** (cycle with `F`):

| Mode | Description |
|------|-------------|
| Gamma | Sign-preserving gamma curve with adjustable γ parameter |
| False Color | Logarithmic heatmap (black → blue → cyan → green → yellow → red → white) |
| Pos/Neg | Green = positive difference, Red = negative difference |

**Exposure & Gamma:**
- **Exposure (EV):** -10 to +10 stops. Scales the image by `2^EV`. Works in both split and error modes.
- **Gamma (γ):** 0.1 to 5.0. Controls the display gamma curve.

## Controls

| Action | Input |
|--------|-------|
| Play / Pause | `Space` |
| Step forward / back | `Right` / `Left` arrow |
| Zoom in / out | Scroll wheel, pinch, or `Up` / `Down` arrow |
| Zoom presets | `1` `2` `4` `8` |
| Pan | Click and drag |
| Move slider | Drag the comparison handle |
| Reset view | `R` |
| Go to start / end | `Home` / `End` |
| Toggle Split / Error mode | `E` |
| Cycle error metric | `M` |
| Cycle visualization mode | `F` |
| Increase / decrease exposure | `]` / `[` |
| Increase / decrease gamma | `}` / `{` (Shift + `]` / `[`) |
| Reset exposure & gamma | `0` |
| Toggle pixel inspection | `P` |
| Show keyboard shortcuts | `?` |

**Drag-and-drop:** Drop a video or image file onto the left half of the window to load it as A, or onto the right half for B. A blue or orange highlight indicates which side will receive the file. **Drop two files at once** and they'll be loaded into A and B as a fresh comparison pair (drop position is ignored for multi-file drops). You can mix kinds — e.g. compare a rendered EXR against the encoded video, or two stills against each other.

**Open With Framewise:** Framewise registers as a viewer for video and image types, so it appears in Finder's _Open With_ menu. Selecting two files and choosing _Open With → Framewise_ loads them as a comparison pair. You can also drag files onto the app icon in the Dock or run `open -a Framewise file1.exr file2.exr` from the terminal.

## Building

Requires **Xcode Command Line Tools** on macOS 14+.

```bash
./build.sh
open "Framewise.app"
```

The build script compiles Swift sources, generates the app icon from `App Exports/`, and creates a signed `.app` bundle.

### Code-signed build

To build with a Developer ID certificate (required for notarization):

```bash
CODESIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" ./build.sh
```

## GitHub Actions

The included workflow (`.github/workflows/build.yml`) builds a **universal binary** (Apple Silicon + Intel), with optional code-signing and notarization.

### Required secrets for notarization

| Secret | Description |
|--------|-------------|
| `MACOS_CERTIFICATE_P12` | Base64-encoded `.p12` certificate |
| `MACOS_CERTIFICATE_PASSWORD` | Password for the `.p12` file |
| `MACOS_CERT_NAME` | Certificate name, e.g. `Developer ID Application: Name (TEAMID)` |
| `APPLE_ID` | Apple ID email for notarization |
| `APPLE_APP_PASSWORD` | App-specific password from appleid.apple.com |
| `APPLE_TEAM_ID` | Apple Developer Team ID |

Without these secrets, the workflow still builds and produces an ad-hoc signed artifact.

### Versioning

`CFBundleShortVersionString` and `CFBundleVersion` are stamped at build time by `scripts/apply-version.sh` (called from both `build.sh` and the GitHub Actions workflow):

| Plist key | Source |
|-----------|--------|
| `CFBundleShortVersionString` | Latest `v*` git tag with the leading `v` stripped, falling back to `0.0.0` on a tag-less repo. |
| `CFBundleVersion` | `git rev-list --count HEAD` — a monotonic build number. Falls back to `1`. |

Either can be overridden by exporting `MARKETING_VERSION` / `BUILD_VERSION` before invoking the build:

```bash
MARKETING_VERSION=2.5.0 BUILD_VERSION=99 ./build.sh
```

The source `Info.plist` keeps placeholder values (`1.0` / `1`); the stamping touches only the copy inside the built `.app`, so `git status` stays clean.

### Creating a release

Push a version tag to trigger the full build + release pipeline. The bundled version automatically picks up the tag.

```bash
git tag v1.0.0
git push origin v1.0.0
```

## Architecture

| File | Purpose |
|------|---------|
| `FramewiseApp.swift` | App entry point |
| `ContentView.swift` | SwiftUI UI layout, controls, and help overlay |
| `MediaEngine.swift` | Per-side media state (videos via AVPlayer, images via CIImage), playback synchronization, hover-sample readback, persisted settings |
| `MetalComparisonView.swift` | Metal rendering pipeline, CIImage color management, drag-and-drop |
| `ShaderSource.swift` | Metal shaders — split view, error metrics, tonemapping, drop highlight |

The rendering pipeline uses **CIImage** for color-managed pixel buffer conversion (handling HDR/SDR automatically) and a **Metal** shader for both the split-view composition and error visualization with zoom/pan support.

## License

MIT
