import Foundation

let metalShaderSource = """
#include <metal_stdlib>
using namespace metal;

struct VertexOut {
    float4 position [[position]];
    float2 texCoord;
};

struct Uniforms {
    float2 viewportSize;
    float sliderPosition;
    float zoom;
    float2 panOffset;
    float2 mediaAspect;
    float2 viewAspect;
    float2 mediaSizeA;
    float2 mediaSizeB;
    int hasMediaA;
    int hasMediaB;
    int showSlider;
    int displayMode;    // 0=split, 1=blink, 2=error
    int errorMetric;    // 0=error, 1=abs, 2=squared, 3=relAbs, 4=relSquared
    int tonemapMode;    // 0=gamma, 1=falseColor, 2=posNeg
    float exposure;
    float gamma;
    int dropHighlight;  // -1=none, 0=left, 1=right
    int pixelInspect;   // 0=off, 1=auto
    int highlightCount; // 0..N analyzer rects to render
    int highlightMode;  // 0=off, 1=outline, 2=dim+outline, 3=focus single
    int highlightFocus; // index of focused rect, or -1
    float highlightTintR;
    float highlightTintG;
    float highlightTintB;
    // Reinhard extended whitepoint.
    float reinhardWhitepoint;
    // Hable piecewise-power-curve precomputed knots. CPU recomputes whenever
    // user-facing params change; shader does a small segment-select per pixel.
    float pwX0;
    float pwX1;
    float pwToeLnA;
    float pwToeB;
    float pwMidOffsetX;
    float pwMidLnA;
    float pwMidB;
    float pwShOffsetX;
    float pwShOffsetY;
    float pwShLnA;
    float pwShB;
    float pwInvScale;
    int blinkSide;      // -1=off, 0=show A full-frame, 1=show B full-frame
    int channelMode;    // 0=RGB, 1=R, 2=G, 3=B, 4=A, 5=Luma
    int clipWarn;       // 0=off, 1=highlight display clip
    int gamutWarn;      // 0=off, 1=highlight out-of-gamut
    float _pad0;
};

// ── False color map ──────────────────────────────────────────────────
// 7-stop piecewise linear: black → blue → cyan → green → yellow → red → white
float3 falseColorMap(float t) {
    t = clamp(t, 0.0, 1.0);
    const float3 stops[] = {
        float3(0.0, 0.0, 0.0),     // 0: black
        float3(0.0, 0.0, 0.6),     // 1: dark blue
        float3(0.0, 0.6, 1.0),     // 2: cyan
        float3(0.0, 1.0, 0.0),     // 3: green
        float3(1.0, 1.0, 0.0),     // 4: yellow
        float3(1.0, 0.0, 0.0),     // 5: red
        float3(1.0, 1.0, 1.0),     // 6: white
    };
    float s = t * 6.0;
    int idx = min(int(s), 5);
    float frac = s - float(idx);
    return mix(stops[idx], stops[idx + 1], frac);
}

// ── Error metrics ────────────────────────────────────────────────────
float3 computeError(float3 a, float3 b, int metric) {
    float3 diff = a - b;
    switch (metric) {
        case 0: return diff;                                    // Error (signed)
        case 1: return abs(diff);                               // Absolute Error
        case 2: return diff * diff;                             // Squared Error
        case 3: return abs(diff) / (abs(b) + 0.01);            // Relative Absolute Error
        case 4: return (diff * diff) / (b * b + 0.01);         // Relative Squared Error
        case 5: {
            // Log-luminance error — log10(|a|+ε) − log10(|b|+ε). Scale-aware
            // for HDR: a 2× exposure shift between A and B shows up as a
            // constant log10(2) ≈ 0.30 offset everywhere, instead of
            // dwarfing dark pixels under a single bright outlier.
            float3 eps = float3(0.001);
            return log10(abs(a) + eps) - log10(abs(b) + eps);
        }
        default: return abs(diff);
    }
}

// ── Tonemapping operators ────────────────────────────────────────────
// Each operator takes scene-linear (extended) sRGB and returns sRGB-encoded
// values in [0,1] ready for the display. Exposure (in stops) is applied
// first, identically for every mode.

// Extended Reinhard with whitepoint Lw: maps mid-grey to itself when Lw=∞
// and rolls a hard knee toward 1 around Lw. Applied per-channel; for purer
// luminance behavior we could go luma-only, but channel-wise tracks the
// per-channel error metrics the rest of the app uses.
float3 tonemapReinhard(float3 col, float Lw) {
    float3 num = col * (1.0 + col / (Lw * Lw));
    float3 den = 1.0 + col;
    return num / den;
}

// ACES filmic, Narkowicz fit. Single-line approximation of the full RRT+ODT;
// good enough for previewing and several orders of magnitude cheaper.
float3 tonemapACES(float3 x) {
    const float a = 2.51, b = 0.03, c = 2.43, d = 0.59, e = 0.14;
    return clamp((x * (a * x + b)) / (x * (c * x + d) + e), 0.0, 1.0);
}

// Hejl-Burgess-Dawson "filmic". Output is already in approximate sRGB
// (the gamma is baked into the curve), so do NOT apply gamma after.
float3 tonemapFilmic(float3 col) {
    float3 x = max(col - 0.004, 0.0);
    return (x * (6.2 * x + 0.5)) / (x * (6.2 * x + 1.7) + 0.06);
}

// Evaluate Hable's piecewise power curve for one channel. The CPU
// precomputes the segment coefficients; here we just pick the right one.
float pwEvalChannel(float x, constant Uniforms& u) {
    float xi = max(x, 0.0);
    float y;
    if (xi < u.pwX0) {
        // Toe — power curve through origin.
        if (xi <= 0.0) {
            y = 0.0;
        } else {
            y = exp(u.pwToeLnA + u.pwToeB * log(xi));
        }
    } else if (xi < u.pwX1) {
        // Middle — gamma'd linear: (m*x + b)^gamma  =
        //   exp(midLnA + midB * ln(x - midOffsetX))  with midOffsetX = -b/m.
        float t = xi - u.pwMidOffsetX;
        if (t <= 0.0) {
            y = 0.0;
        } else {
            y = exp(u.pwMidLnA + u.pwMidB * log(t));
        }
    } else {
        // Shoulder — mirrored power curve.
        float t = u.pwShOffsetX - xi;
        if (t <= 0.0) {
            y = u.pwShOffsetY;
        } else {
            y = u.pwShOffsetY - exp(u.pwShLnA + u.pwShB * log(t));
        }
    }
    return y * u.pwInvScale;
}

float3 tonemapPiecewise(float3 col, constant Uniforms& u) {
    return float3(pwEvalChannel(col.r, u),
                  pwEvalChannel(col.g, u),
                  pwEvalChannel(col.b, u));
}

// sRGB encoding gamma (used by Linear / Reinhard / ACES / Piecewise so the
// output is display-ready). Filmic and Gamma handle their own encoding.
float3 srgbEncode(float3 c) {
    c = max(c, 0.0);
    float3 lo = c * 12.92;
    float3 hi = 1.055 * pow(c, float3(1.0 / 2.4)) - 0.055;
    return mix(hi, lo, step(c, float3(0.0031308)));
}

float3 applyTonemap(float3 col, constant Uniforms& u) {
    // Pre-tonemap exposure adjustment in stops, applied uniformly.
    col = pow(2.0, u.exposure) * col;

    switch (u.tonemapMode) {
        case 0: {
            // Gamma — sign-preserving power curve. Keeps negative test
            // signals visible (used by the error-vis "Error" metric).
            return sign(col) * pow(abs(col), float3(1.0 / u.gamma));
        }
        case 1: {
            // False Color — log-luminance mapped to a 7-stop colormap.
            float avg = (col.r + col.g + col.b) / 3.0;
            float t = log2(avg + 0.03125) / 10.0 + 0.5;
            return falseColorMap(t);
        }
        case 2: {
            // Positive / Negative — green = positive, red = negative.
            float avg = (col.r + col.g + col.b) / 3.0;
            return float3(max(-avg, 0.0), max(avg, 0.0), 0.0);
        }
        case 3: {
            // Linear — clamp to display range, sRGB-encode.
            return srgbEncode(clamp(col, 0.0, 1.0));
        }
        case 4: {
            // Reinhard extended — soft rolloff toward whitepoint, sRGB-encode.
            return srgbEncode(tonemapReinhard(max(col, 0.0), max(u.reinhardWhitepoint, 1e-4)));
        }
        case 5: {
            // ACES — sRGB-encode (Narkowicz fit returns ~linear values).
            return srgbEncode(tonemapACES(max(col, 0.0)));
        }
        case 6: {
            // Filmic (HBD) — gamma is baked in, no further sRGB encoding.
            return tonemapFilmic(max(col, 0.0));
        }
        case 7: {
            // Piecewise (Hable). The precomputed curve is in linear space,
            // so sRGB-encode the result for the display.
            return srgbEncode(tonemapPiecewise(max(col, 0.0), u));
        }
        default:
            return col;
    }
}

// ── Bitmap font (3×5) for pixel-value overlay ────────────────────────
// Glyph indices: 0..9 = digits, 10 = '.', 11 = '-', 12 = ' ',
// 13 = 'N', 14 = 'A', 15 = 'I', 16 = 'F'.
// 15 bits per glyph, packed top-row first, MSB = top-left.
uint glyphBits(int g) {
    switch (g) {
        case 0:  return 0b111101101101111u; // 0
        case 1:  return 0b010110010010111u; // 1
        case 2:  return 0b111001111100111u; // 2
        case 3:  return 0b111001111001111u; // 3
        case 4:  return 0b101101111001001u; // 4
        case 5:  return 0b111100111001111u; // 5
        case 6:  return 0b111100111101111u; // 6
        case 7:  return 0b111001001001001u; // 7
        case 8:  return 0b111101111101111u; // 8
        case 9:  return 0b111101111001111u; // 9
        case 10: return 0b000000000000010u; // .
        case 11: return 0b000000111000000u; // -
        case 13: return 0b101111111101101u; // N
        case 14: return 0b010101111101101u; // A
        case 15: return 0b111010010010111u; // I
        case 16: return 0b111100111100100u; // F
        default: return 0u;                 // space / unknown
    }
}

bool glyphPixel(int g, int x, int y) {
    if (x < 0 || x > 2 || y < 0 || y > 4) return false;
    int idx = (4 - y) * 3 + (2 - x);
    return ((glyphBits(g) >> uint(idx)) & 1u) != 0u;
}

// Format a float into a fixed 6-character window, returned in chars[0..5]:
//   chars[0] = sign (' ' or '-')
//   chars[1..5] = magnitude, decimal placed for the active range
// HDR-aware: handles |v| up to ~9999 with at least 1 fractional digit
// while values are in single-digit range. Special cases: NaN, ±Inf.
struct CharBuf { int c[6]; };

CharBuf formatValue(float v) {
    CharBuf out;
    out.c[0] = 12; out.c[1] = 12; out.c[2] = 12;
    out.c[3] = 12; out.c[4] = 12; out.c[5] = 12;

    if (isnan(v)) {
        out.c[0] = 12;          // ' '
        out.c[1] = 12;          // ' '
        out.c[2] = 13;          // N
        out.c[3] = 14;          // A
        out.c[4] = 13;          // N
        out.c[5] = 12;          // ' '
        return out;
    }
    if (isinf(v)) {
        out.c[0] = (v < 0) ? 11 : 12;
        out.c[1] = 12;
        out.c[2] = 15;          // I
        out.c[3] = 13;          // N
        out.c[4] = 16;          // F
        out.c[5] = 12;
        return out;
    }

    bool neg = (v < 0.0);
    out.c[0] = neg ? 11 : 12;
    float a = clamp(abs(v), 0.0, 9999.999);

    if (a < 10.0) {
        // X.XXX
        int i = int(a);
        int frac = int(round((a - float(i)) * 1000.0));
        if (frac >= 1000) { i += 1; frac -= 1000; }
        out.c[1] = i % 10;
        out.c[2] = 10;
        out.c[3] = (frac / 100) % 10;
        out.c[4] = (frac / 10) % 10;
        out.c[5] = frac % 10;
    } else if (a < 100.0) {
        // XX.XX
        int i = int(a);
        int frac = int(round((a - float(i)) * 100.0));
        if (frac >= 100) { i += 1; frac -= 100; }
        out.c[1] = (i / 10) % 10;
        out.c[2] = i % 10;
        out.c[3] = 10;
        out.c[4] = (frac / 10) % 10;
        out.c[5] = frac % 10;
    } else if (a < 1000.0) {
        // XXX.X
        int i = int(a);
        int frac = int(round((a - float(i)) * 10.0));
        if (frac >= 10) { i += 1; frac -= 10; }
        out.c[1] = (i / 100) % 10;
        out.c[2] = (i / 10) % 10;
        out.c[3] = i % 10;
        out.c[4] = 10;
        out.c[5] = frac % 10;
    } else {
        // XXXX (no decimal point)
        int i = int(round(a));
        out.c[1] = (i / 1000) % 10;
        out.c[2] = (i / 100) % 10;
        out.c[3] = (i / 10) % 10;
        out.c[4] = i % 10;
        out.c[5] = 12;
    }
    return out;
}

// Draws 3 or 4 lines of values inside the [0,1]² cell.
// `showAlpha == true` adds a 4th line for the alpha channel; when false, only
// R/G/B are shown in the more compact 3-line layout.
// Returns rgba — alpha=0 if outside any glyph stroke.
//
// Layout (font-pixel grid):
//   margin 2 px | 6 chars × (3 cols + 1 gap) − 1 gap = 23 px | margin 2 px
//   margin 2 px | N lines × (5 rows + 1 gap) − 1 gap = 6N − 1 px | margin 2 px
// 3-line cell: 27×21,  4-line cell: 27×27.
float4 renderPixelText(float2 cellPos, float4 values, bool showAlpha,
                       float3 color0, float3 color1,
                       float3 color2, float3 color3) {
    int numLines  = showAlpha ? 4 : 3;
    float lineSpan = float(6 * numLines - 1);    // 17 or 23
    float H = lineSpan + 4.0;                    // 21 or 27

    // Flip Y so text reads top-down (cellPos.y=1 is top of cell in our space)
    float2 p = float2(cellPos.x, 1.0 - cellPos.y);

    const float W = 27.0;
    float fx = p.x * W - 2.0;
    float fy = p.y * H - 2.0;

    if (fx < 0.0 || fx >= 23.0 || fy < 0.0 || fy >= lineSpan) {
        return float4(0.0);
    }

    int x = int(fx);
    int y = int(fy);

    // Identify line and intra-line row using the 5-on / 1-off pattern.
    int line  = y / 6;
    int charY = y - line * 6;
    if (charY > 4) return float4(0.0);  // gap row between lines
    if (line >= numLines) return float4(0.0);

    int slot  = x / 4;
    int charX = x % 4;
    if (slot < 0 || slot >= 6) return float4(0.0);
    if (charX >= 3) return float4(0.0); // gap column between glyphs

    float v;
    float3 col;
    if (line == 0)      { v = values.r; col = color0; }
    else if (line == 1) { v = values.g; col = color1; }
    else if (line == 2) { v = values.b; col = color2; }
    else                { v = values.a; col = color3; }

    CharBuf buf = formatValue(v);
    int g = buf.c[slot];
    if (!glyphPixel(g, charX, charY)) return float4(0.0);
    return float4(col, 1.0);
}

// ── Channel isolation ─────────────────────────────────────────────────
// Maps the displayed color to a single channel (shown as grayscale) or luma.
float3 isolateChannel(float3 c, float a, int mode) {
    switch (mode) {
        case 1: return float3(c.r);
        case 2: return float3(c.g);
        case 3: return float3(c.b);
        case 4: return float3(a);
        case 5: return float3(dot(c, float3(0.2126, 0.7152, 0.0722)));
        default: return c;
    }
}

// ── Vertex shader ────────────────────────────────────────────────────
vertex VertexOut vertexMain(uint vid [[vertex_id]],
                            constant Uniforms &u [[buffer(0)]]) {
    float2 pos = float2((vid == 1) ? 3.0 : -1.0,
                        (vid == 2) ? 3.0 : -1.0);
    float2 uv = pos * 0.5 + 0.5;
    // CIImage renders with bottom-left origin into the texture,
    // so no Y-flip needed — the coordinate systems cancel out.

    // Aspect ratio fitting
    float viewAR = u.viewAspect.x;
    float videoAR = u.mediaAspect.x;

    if (viewAR > videoAR) {
        float scale = videoAR / viewAR;
        uv.x = (uv.x - 0.5) / scale + 0.5;
    } else {
        float scale = viewAR / videoAR;
        uv.y = (uv.y - 0.5) / scale + 0.5;
    }

    // Zoom and pan
    uv = (uv - 0.5) / u.zoom + 0.5 + u.panOffset;

    VertexOut out;
    out.position = float4(pos, 0, 1);
    out.texCoord = uv;
    return out;
}

// ── Fragment shader ──────────────────────────────────────────────────
fragment float4 fragmentMain(VertexOut in [[stage_in]],
                             constant Uniforms &u [[buffer(0)]],
                             constant float4 *highlights [[buffer(1)]],
                             texture2d<float> texA [[texture(0)]],
                             texture2d<float> texB [[texture(1)]]) {
    constexpr sampler sLinear(filter::linear, address::clamp_to_edge);

    float2 tc = in.texCoord;
    bool inBounds = (tc.x >= 0.0 && tc.x <= 1.0 && tc.y >= 0.0 && tc.y <= 1.0);

    if (!inBounds) {
        return float4(0.03, 0.03, 0.03, 1.0);
    }

    // ── Pixel-on-screen size (for grid + value overlay) ──────────
    // Use the active video's resolution so the grid aligns with real pixels.
    float2 sizeA = max(u.mediaSizeA, float2(1.0));
    float2 sizeB = max(u.mediaSizeB, float2(1.0));
    float2 refSize = (u.hasMediaA != 0) ? sizeA : sizeB;

    // Screen pixels per video pixel along each axis. Derivatives must be
    // evaluated in uniform control flow, so compute once up front.
    float dxTC = max(abs(dfdx(tc.x)), 1e-7);
    float dyTC = max(abs(dfdy(tc.y)), 1e-7);
    float pixelOnScreen = 1.0 / (dxTC * refSize.x);

    bool inspectEnabled = (u.pixelInspect != 0);
    bool useNearest = inspectEnabled && pixelOnScreen > 6.0;
    bool showGrid   = inspectEnabled && pixelOnScreen > 18.0;
    bool showText   = inspectEnabled && pixelOnScreen > 56.0;

    // Per-side nearest-pixel tap (so each video shows its own true sample)
    float2 tcA = tc;
    float2 tcB = tc;
    if (useNearest) {
        tcA = (floor(tc * sizeA) + 0.5) / sizeA;
        tcB = (floor(tc * sizeB) + 0.5) / sizeB;
    }

    // ── Compute base output color and the values to display ──────
    float4 outColor;
    float4 valuesToShow = float4(0.0, 0.0, 0.0, 1.0);
    bool valuesValid = false;
    // Blink overrides everything: show a single side full-frame and flip in
    // place. Requires both sides loaded; otherwise it's a no-op.
    bool blink = (u.blinkSide >= 0) && (u.hasMediaA != 0) && (u.hasMediaB != 0);
    bool isErrorMode = (u.displayMode == 2 && u.hasMediaA != 0 && u.hasMediaB != 0) && !blink;
    bool fragmentOnSideA = false;   // true if split-mode pixel reads from A
    // Raw (pre-tonemap, extended-range) sampled color of the displayed side,
    // kept for the out-of-gamut test (which needs the negative values that
    // tonemapping would clamp away).
    float3 sourceRaw = float3(0.0);
    bool haveSource = false;

    if (isErrorMode) {
        float4 a = texA.sample(sLinear, tcA);
        float4 b = texB.sample(sLinear, tcB);
        float3 err = computeError(a.rgb, b.rgb, u.errorMetric);
        // For error mode, alpha line shows the alpha difference (signed).
        valuesToShow = float4(err, a.a - b.a);
        valuesValid = true;
        float3 mapped = applyTonemap(err, u);
        outColor = float4(mapped, 1.0);
    } else {
        // Which side does this fragment show? Blink picks a fixed side;
        // otherwise the split slider decides per-column.
        bool wantA;
        if (blink) {
            wantA = (u.blinkSide == 0);
        } else {
            wantA = (in.position.x / u.viewportSize.x) < u.sliderPosition;
        }

        float4 color;
        if (wantA && u.hasMediaA != 0) {
            color = texA.sample(sLinear, tcA);
            valuesToShow = color;
            valuesValid = true;
            fragmentOnSideA = true;
        } else if (u.hasMediaB != 0) {
            color = texB.sample(sLinear, tcB);
            valuesToShow = color;
            valuesValid = true;
            fragmentOnSideA = false;
        } else if (u.hasMediaA != 0) {
            color = texA.sample(sLinear, tcA);
            valuesToShow = color;
            valuesValid = true;
            fragmentOnSideA = true;
        } else {
            color = float4(0.08, 0.08, 0.08, 1.0);
        }

        sourceRaw = color.rgb;
        haveSource = valuesValid;

        // CIImage outputs sRGB-encoded values. Decode to linear for processing,
        // then apply the selected visualization mode (same pipeline as error mode).
        float3 linear = pow(max(color.rgb, 0.0), float3(2.2));
        color.rgb = applyTonemap(linear, u);
        outColor = color;
    }

    // ── Channel isolation & clip / gamut warnings ────────────────
    // Keep the true displayed color so clip detection reads the image, not an
    // isolated channel.
    float3 dispColor = outColor.rgb;
    outColor.rgb = isolateChannel(outColor.rgb, outColor.a, u.channelMode);

    if (u.gamutWarn != 0 && haveSource &&
        (sourceRaw.r < -0.001 || sourceRaw.g < -0.001 || sourceRaw.b < -0.001)) {
        outColor.rgb = float3(1.0, 1.0, 0.0);          // out-of-gamut → yellow
    }
    if (u.clipWarn != 0) {
        bool blown = (dispColor.r >= 0.996 && dispColor.g >= 0.996 && dispColor.b >= 0.996);
        bool crush = (dispColor.r <= 0.004 && dispColor.g <= 0.004 && dispColor.b <= 0.004);
        if (blown)      outColor.rgb = float3(1.0, 0.0, 1.0);   // blown → magenta
        else if (crush) outColor.rgb = float3(0.0, 0.4, 1.0);   // crushed → blue
    }

    // ── Pixel grid overlay ───────────────────────────────────────
    if (showGrid && valuesValid) {
        // Use the size matching the video the fragment is sampling from.
        float2 gridSize = isErrorMode
            ? sizeA
            : (fragmentOnSideA ? sizeA : (u.hasMediaB != 0 ? sizeB : sizeA));
        float2 cellPos = fract(tc * gridSize);
        // Distance from nearest cell edge, converted to screen pixels.
        // cellPos is in cell-UV space (one cell = [0,1]); one cell spans
        // 1/gridSize in tc-space, and tc advances by d*TC per screen pixel,
        // so screen-pixel distance = cell-UV distance / (gridSize * d*TC).
        float2 d = min(cellPos, 1.0 - cellPos);
        float pxX = d.x / (gridSize.x * dxTC);
        float pxY = d.y / (gridSize.y * dyTC);
        float minPx = min(pxX, pxY);
        if (minPx < 1.0) {
            float bright = (outColor.r + outColor.g + outColor.b) / 3.0;
            float3 gridColor = (bright > 0.5) ? float3(0.0) : float3(1.0);
            // Soft ~1-screen-pixel-wide anti-aliased line.
            float a = 1.0 - smoothstep(0.0, 1.0, minPx);
            outColor.rgb = mix(outColor.rgb, gridColor, a * 0.55);
        }
    }

    // ── Pixel value overlay ──────────────────────────────────────
    if (showText && valuesValid) {
        float2 textSize = isErrorMode
            ? sizeA
            : (fragmentOnSideA ? sizeA : (u.hasMediaB != 0 ? sizeB : sizeA));
        float2 cellPos = fract(tc * textSize);
        // Contrast color picked from base output: dark text on bright cells,
        // bright text on dark cells. Channel-tinted so R/G/B(/A) lines are
        // identifiable at a glance.
        float bright = (outColor.r + outColor.g + outColor.b) / 3.0;
        bool darkCell = bright <= 0.5;
        float3 cR = darkCell ? float3(1.00, 0.55, 0.55) : float3(0.50, 0.00, 0.00);
        float3 cG = darkCell ? float3(0.55, 1.00, 0.55) : float3(0.00, 0.45, 0.00);
        float3 cB = darkCell ? float3(0.55, 0.75, 1.00) : float3(0.00, 0.10, 0.55);
        // Alpha line is colored neutrally so it's distinct from the RGB rows.
        float3 cA = darkCell ? float3(0.85, 0.85, 0.85) : float3(0.20, 0.20, 0.20);
        // Only show the alpha line when it carries information:
        //   • split mode: alpha differs from a fully-opaque pixel
        //   • error mode: any alpha delta worth reporting
        bool showAlpha = isErrorMode
            ? (abs(valuesToShow.a) > 0.001)
            : (abs(valuesToShow.a - 1.0) > 0.001);
        float4 t = renderPixelText(cellPos, valuesToShow, showAlpha,
                                   cR, cG, cB, cA);
        outColor.rgb = mix(outColor.rgb, t.rgb, t.a);
    }

    // ── Analyzer highlight rectangles ────────────────────────────
    // `highlights[i]` packs the rect as (uMin, vMin, uWidth, vHeight) in the
    // same texture-coordinate space `tc` lives in, so a rect at the bottom
    // of the image has vMin near 0. `tc` is already the post-aspect /
    // post-zoom / post-pan UV from the vertex shader, so we can compare
    // directly without any of the screen-space gymnastics the slider does.
    if (u.highlightMode > 0 && u.highlightCount > 0 && inBounds) {
        bool insideAny    = false;
        bool insideFocus  = false;
        bool onOutline    = false;
        bool onFocusOutline = false;
        float3 tint = float3(u.highlightTintR, u.highlightTintG, u.highlightTintB);

        // Outline thickness in tc-space, derived so it stays ~1.5 screen
        // pixels wide regardless of zoom.
        float thickU = 1.5 * dxTC;
        float thickV = 1.5 * dyTC;

        for (int i = 0; i < u.highlightCount; ++i) {
            float4 r = highlights[i];
            float uMin = r.x;
            float vMin = r.y;
            float uMax = r.x + r.z;
            float vMax = r.y + r.w;
            bool inside = (tc.x >= uMin && tc.x <= uMax &&
                           tc.y >= vMin && tc.y <= vMax);
            if (inside) {
                insideAny = true;
                bool isFocused = (i == u.highlightFocus);
                if (isFocused) insideFocus = true;
                float dU = min(tc.x - uMin, uMax - tc.x);
                float dV = min(tc.y - vMin, vMax - tc.y);
                if (dU < thickU || dV < thickV) {
                    onOutline = true;
                    if (isFocused) onFocusOutline = true;
                }
            }
        }

        // Mode semantics:
        //   1 = outline   → outlines only, image untouched
        //   2 = spotlight → dim everything outside the top regions
        //   3 = focus     → dim everything outside the user-focused region;
        //                   if no focus is set, fall back to spotlight
        if (u.highlightMode == 2 && !insideAny) {
            outColor.rgb *= 0.35;
        } else if (u.highlightMode == 3) {
            if (u.highlightFocus >= 0) {
                if (!insideFocus) outColor.rgb *= 0.25;
            } else if (!insideAny) {
                outColor.rgb *= 0.35;
            }
        }
        if (onOutline) {
            // Focused rect gets a brighter / hotter outline so the user can
            // tell which crop they currently clicked on.
            float3 outlineColor = onFocusOutline ? float3(1.0, 1.0, 1.0) : tint;
            outColor.rgb = mix(outColor.rgb, outlineColor, onFocusOutline ? 0.9 : 0.75);
        }
    }

    // ── Comparison slider (split mode only) ──────────────────────
    if (u.showSlider != 0 && (u.hasMediaA != 0 || u.hasMediaB != 0)) {
        float sliderPx = u.sliderPosition * u.viewportSize.x;
        float dx = abs(in.position.x - sliderPx);

        if (dx < 1.0) {
            outColor = float4(1.0, 1.0, 1.0, 1.0);
        } else if (dx < 3.0) {
            outColor = mix(outColor, float4(0.0, 0.0, 0.0, 1.0), 0.4);
        }

        float2 handleCenter = float2(sliderPx, u.viewportSize.y * 0.5);
        float handleDist = length(float2(in.position.x, in.position.y) - handleCenter);
        if (handleDist < 16.0) {
            outColor = float4(1.0, 1.0, 1.0, 1.0);
        } else if (handleDist < 18.0) {
            outColor = float4(0.2, 0.2, 0.2, 1.0);
        }

        float2 rel = float2(in.position.x, in.position.y) - handleCenter;
        if (rel.x > -12.0 && rel.x < -4.0 && abs(rel.y) < (rel.x + 12.0) * 0.7) {
            outColor = float4(0.2, 0.2, 0.2, 1.0);
        }
        if (rel.x > 4.0 && rel.x < 12.0 && abs(rel.y) < (12.0 - rel.x) * 0.7) {
            outColor = float4(0.2, 0.2, 0.2, 1.0);
        }
    }

    // ── Drop zone highlight ──────────────────────────────────────
    if (u.dropHighlight >= 0) {
        float normX = in.position.x / u.viewportSize.x;
        bool onLeft = (normX < 0.5);
        bool highlight = (u.dropHighlight == 0 && onLeft) || (u.dropHighlight == 1 && !onLeft);
        if (highlight) {
            float3 tint = (u.dropHighlight == 0)
                ? float3(0.2, 0.4, 1.0)   // blue for A
                : float3(1.0, 0.6, 0.1);  // orange for B
            outColor = float4(mix(outColor.rgb, tint, 0.25), 1.0);
        }
        // Divider line down the center
        float cx = u.viewportSize.x * 0.5;
        if (abs(in.position.x - cx) < 1.5) {
            outColor = float4(1.0);
        }
    }

    return outColor;
}
"""
