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
    float2 videoAspect;    // (videoWidth/videoHeight, 1) or (1, videoHeight/videoWidth)
    float2 viewAspect;     // same but for view
    int hasVideoA;
    int hasVideoB;
    int showSlider;
    float padding;
};

// Full-screen triangle (3 verts, no index buffer needed)
vertex VertexOut vertexMain(uint vid [[vertex_id]],
                            constant Uniforms &u [[buffer(0)]]) {
    float2 pos = float2((vid == 1) ? 3.0 : -1.0,
                        (vid == 2) ? 3.0 : -1.0);
    float2 uv = pos * 0.5 + 0.5;
    // CIImage renders with bottom-left origin into the texture,
    // so no Y-flip needed — the coordinate systems cancel out.

    // Aspect ratio fitting: map view UV to video UV
    float viewAR = u.viewAspect.x;
    float videoAR = u.videoAspect.x;

    if (viewAR > videoAR) {
        // View wider than video -> pillarbox
        float scale = videoAR / viewAR;
        uv.x = (uv.x - 0.5) / scale + 0.5;
    } else {
        // View taller than video -> letterbox
        float scale = viewAR / videoAR;
        uv.y = (uv.y - 0.5) / scale + 0.5;
    }

    // Apply zoom and pan (in video-space)
    uv = (uv - 0.5) / u.zoom + 0.5 + u.panOffset;

    VertexOut out;
    out.position = float4(pos, 0, 1);
    out.texCoord = uv;
    return out;
}

fragment float4 fragmentMain(VertexOut in [[stage_in]],
                             constant Uniforms &u [[buffer(0)]],
                             texture2d<float> texA [[texture(0)]],
                             texture2d<float> texB [[texture(1)]]) {
    constexpr sampler s(filter::linear, address::clamp_to_edge);

    float2 tc = in.texCoord;
    bool inBounds = (tc.x >= 0.0 && tc.x <= 1.0 && tc.y >= 0.0 && tc.y <= 1.0);

    // Which side of the slider are we on?
    float normX = in.position.x / u.viewportSize.x;

    float4 color;
    if (!inBounds) {
        color = float4(0.03, 0.03, 0.03, 1.0);
    } else if (normX < u.sliderPosition && u.hasVideoA != 0) {
        color = texA.sample(s, tc);
    } else if (u.hasVideoB != 0) {
        color = texB.sample(s, tc);
    } else if (u.hasVideoA != 0) {
        color = texA.sample(s, tc);
    } else {
        color = float4(0.08, 0.08, 0.08, 1.0);
    }

    // Draw comparison slider
    if (u.showSlider != 0 && (u.hasVideoA != 0 || u.hasVideoB != 0)) {
        float sliderPx = u.sliderPosition * u.viewportSize.x;
        float dx = abs(in.position.x - sliderPx);

        // Thin line with shadow
        if (dx < 1.0) {
            color = float4(1.0, 1.0, 1.0, 1.0);
        } else if (dx < 3.0) {
            color = mix(color, float4(0.0, 0.0, 0.0, 1.0), 0.4);
        }

        // Handle circle in the center
        float2 handleCenter = float2(sliderPx, u.viewportSize.y * 0.5);
        float handleDist = length(float2(in.position.x, in.position.y) - handleCenter);
        if (handleDist < 16.0) {
            color = float4(1.0, 1.0, 1.0, 1.0);
        } else if (handleDist < 18.0) {
            color = float4(0.2, 0.2, 0.2, 1.0);
        }

        // Small triangles on the handle
        float2 rel = float2(in.position.x, in.position.y) - handleCenter;
        // Left triangle
        if (rel.x > -12.0 && rel.x < -4.0 && abs(rel.y) < (rel.x + 12.0) * 0.7) {
            color = float4(0.2, 0.2, 0.2, 1.0);
        }
        // Right triangle
        if (rel.x > 4.0 && rel.x < 12.0 && abs(rel.y) < (12.0 - rel.x) * 0.7) {
            color = float4(0.2, 0.2, 0.2, 1.0);
        }
    }

    return color;
}
"""
