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
    float2 videoAspect;
    float2 viewAspect;
    int hasVideoA;
    int hasVideoB;
    int showSlider;
    int displayMode;    // 0=split, 1=error
    int errorMetric;    // 0=error, 1=abs, 2=squared, 3=relAbs, 4=relSquared
    int tonemapMode;    // 0=gamma, 1=falseColor, 2=posNeg
    float exposure;
    float gamma;
    int dropHighlight;  // -1=none, 0=left, 1=right
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
        default: return abs(diff);
    }
}

// ── Tonemapping / visualization ──────────────────────────────────────
float3 applyTonemap(float3 col, int mode, float exposure, float gamma) {
    // Apply exposure (in stops)
    col = pow(2.0, exposure) * col;

    switch (mode) {
        case 0: {
            // Gamma: sign-preserving power curve
            return sign(col) * pow(abs(col), float3(1.0 / gamma));
        }
        case 1: {
            // False Color: logarithmic mapping to colormap
            float avg = (col.r + col.g + col.b) / 3.0;
            float t = log2(avg + 0.03125) / 10.0 + 0.5;
            return falseColorMap(t);
        }
        case 2: {
            // Positive/Negative: green = positive, red = negative
            float avg = (col.r + col.g + col.b) / 3.0;
            float pos = max(avg, 0.0);
            float neg = max(-avg, 0.0);
            return float3(neg, pos, 0.0);
        }
        default:
            return col;
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
    float videoAR = u.videoAspect.x;

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
                             texture2d<float> texA [[texture(0)]],
                             texture2d<float> texB [[texture(1)]]) {
    constexpr sampler s(filter::linear, address::clamp_to_edge);

    float2 tc = in.texCoord;
    bool inBounds = (tc.x >= 0.0 && tc.x <= 1.0 && tc.y >= 0.0 && tc.y <= 1.0);

    if (!inBounds) {
        return float4(0.03, 0.03, 0.03, 1.0);
    }

    // ── ERROR MODE ───────────────────────────────────────────────
    if (u.displayMode == 1 && u.hasVideoA != 0 && u.hasVideoB != 0) {
        float3 a = texA.sample(s, tc).rgb;
        float3 b = texB.sample(s, tc).rgb;
        float3 err = computeError(a, b, u.errorMetric);
        float3 mapped = applyTonemap(err, u.tonemapMode, u.exposure, u.gamma);
        return float4(mapped, 1.0);
    }

    // ── SPLIT MODE ───────────────────────────────────────────────
    float normX = in.position.x / u.viewportSize.x;
    float4 color;

    if (normX < u.sliderPosition && u.hasVideoA != 0) {
        color = texA.sample(s, tc);
    } else if (u.hasVideoB != 0) {
        color = texB.sample(s, tc);
    } else if (u.hasVideoA != 0) {
        color = texA.sample(s, tc);
    } else {
        color = float4(0.08, 0.08, 0.08, 1.0);
    }

    // CIImage outputs sRGB-encoded values. Decode to linear for processing,
    // then apply the selected visualization mode (same pipeline as error mode).
    {
        float3 linear = pow(max(color.rgb, 0.0), float3(2.2));
        color.rgb = applyTonemap(linear, u.tonemapMode, u.exposure, u.gamma);
    }

    // ── Comparison slider ────────────────────────────────────────
    if (u.showSlider != 0 && (u.hasVideoA != 0 || u.hasVideoB != 0)) {
        float sliderPx = u.sliderPosition * u.viewportSize.x;
        float dx = abs(in.position.x - sliderPx);

        if (dx < 1.0) {
            color = float4(1.0, 1.0, 1.0, 1.0);
        } else if (dx < 3.0) {
            color = mix(color, float4(0.0, 0.0, 0.0, 1.0), 0.4);
        }

        float2 handleCenter = float2(sliderPx, u.viewportSize.y * 0.5);
        float handleDist = length(float2(in.position.x, in.position.y) - handleCenter);
        if (handleDist < 16.0) {
            color = float4(1.0, 1.0, 1.0, 1.0);
        } else if (handleDist < 18.0) {
            color = float4(0.2, 0.2, 0.2, 1.0);
        }

        float2 rel = float2(in.position.x, in.position.y) - handleCenter;
        if (rel.x > -12.0 && rel.x < -4.0 && abs(rel.y) < (rel.x + 12.0) * 0.7) {
            color = float4(0.2, 0.2, 0.2, 1.0);
        }
        if (rel.x > 4.0 && rel.x < 12.0 && abs(rel.y) < (12.0 - rel.x) * 0.7) {
            color = float4(0.2, 0.2, 0.2, 1.0);
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
            color = float4(mix(color.rgb, tint, 0.25), 1.0);
        }
        // Divider line down the center
        float cx = u.viewportSize.x * 0.5;
        if (abs(in.position.x - cx) < 1.5) {
            color = float4(1.0);
        }
    }

    return color;
}
"""
