# Video Comparison

A native macOS app for side-by-side video comparison with a split-view slider. Built with Swift, Metal, and AVFoundation.

![macOS 14+](https://img.shields.io/badge/macOS-14%2B-blue)
![Swift](https://img.shields.io/badge/Swift-5.9-orange)
![Metal](https://img.shields.io/badge/GPU-Metal-purple)

## Features

- **Side-by-side comparison** with draggable slider
- **HDR support** — displays HDR content on capable screens via EDR, falls back to SDR automatically
- **4K and beyond** — handles any resolution your hardware supports
- **Deep zoom** — zoom up to 200x to inspect individual pixels
- **Frame-accurate sync** — both videos stay perfectly synchronized
- **Frame stepping** — navigate frame by frame with arrow keys
- **Go to frame** — jump to any frame number
- **All modern formats** — H.264, HEVC, ProRes, AV1, VP9, and anything AVFoundation supports

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

## Building

Requires **Xcode Command Line Tools** on macOS 14+.

```bash
./build.sh
open "Video Comparison.app"
```

The build script compiles Swift sources, generates the app icon from `icon.png`, and creates a signed `.app` bundle.

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

### Creating a release

Push a version tag to trigger the full build + release pipeline:

```bash
git tag v1.0.0
git push origin v1.0.0
```

## Architecture

| File | Purpose |
|------|---------|
| `VideoComparisonApp.swift` | App entry point |
| `ContentView.swift` | SwiftUI UI layout and controls |
| `VideoEngine.swift` | Dual AVPlayer management and synchronization |
| `MetalComparisonView.swift` | Metal rendering pipeline with CIImage color management |
| `ShaderSource.swift` | Metal vertex/fragment shaders for the comparison view |

The rendering pipeline uses **CIImage** for color-managed pixel buffer conversion (handling HDR/SDR automatically) and a **Metal** shader for the split-view composition with zoom/pan support.

## License

MIT
