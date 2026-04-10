import SwiftUI
import MetalKit
import CoreImage
import AVFoundation

// MARK: - Uniforms (must match Metal struct layout)

struct Uniforms {
    var viewportSize: SIMD2<Float> = .zero
    var sliderPosition: Float = 0.5
    var zoom: Float = 1.0
    var panOffset: SIMD2<Float> = .zero
    var videoAspect: SIMD2<Float> = SIMD2<Float>(16.0 / 9.0, 1.0)
    var viewAspect: SIMD2<Float> = SIMD2<Float>(16.0 / 9.0, 1.0)
    var hasVideoA: Int32 = 0
    var hasVideoB: Int32 = 0
    var showSlider: Int32 = 1
    var padding: Float = 0
}

// MARK: - NSViewRepresentable

struct MetalComparisonView: NSViewRepresentable {
    let engine: VideoEngine

    func makeCoordinator() -> Coordinator {
        Coordinator(engine: engine)
    }

    func makeNSView(context: Context) -> ComparisonMTKView {
        let view = context.coordinator.createView()
        return view
    }

    func updateNSView(_ nsView: ComparisonMTKView, context: Context) {
        // Engine reference doesn't change; Metal view reads from it directly
    }
}

// MARK: - Custom MTKView with mouse handling

class ComparisonMTKView: MTKView {
    weak var engine: VideoEngine?
    weak var coordinator: MetalComparisonView.Coordinator?

    private var isDraggingSlider = false
    private var isDraggingPan = false
    private var lastMousePoint: CGPoint = .zero

    override var acceptsFirstResponder: Bool { true }

    // Track which cursor is set
    private var isOpenHandCursor = false

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.activeInKeyWindow, .mouseMoved, .mouseEnteredAndExited],
            owner: self, userInfo: nil))
    }

    override func mouseDown(with event: NSEvent) {
        guard let engine else { return }
        let loc = convert(event.locationInWindow, from: nil)
        let normX = loc.x / bounds.width
        let sliderX = engine.sliderPosition

        if engine.hasVideoA && engine.hasVideoB && abs(normX - sliderX) < 0.025 {
            isDraggingSlider = true
            NSCursor.resizeLeftRight.set()
        } else {
            isDraggingPan = true
            lastMousePoint = loc
            NSCursor.closedHand.set()
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let engine else { return }
        let loc = convert(event.locationInWindow, from: nil)

        if isDraggingSlider {
            let newPos = max(0.01, min(0.99, loc.x / bounds.width))
            Task { @MainActor in engine.sliderPosition = newPos }
        } else if isDraggingPan {
            let dx = (loc.x - lastMousePoint.x) / bounds.width
            let dy = (loc.y - lastMousePoint.y) / bounds.height
            lastMousePoint = loc
            Task { @MainActor in
                engine.panOffset = CGPoint(
                    x: engine.panOffset.x + dx / engine.zoom,
                    y: engine.panOffset.y - dy / engine.zoom
                )
            }
        }
    }

    override func mouseUp(with event: NSEvent) {
        isDraggingSlider = false
        isDraggingPan = false
        updateCursorForPosition(convert(event.locationInWindow, from: nil))
    }

    override func mouseMoved(with event: NSEvent) {
        updateCursorForPosition(convert(event.locationInWindow, from: nil))
    }

    override func scrollWheel(with event: NSEvent) {
        guard let engine else { return }
        let loc = convert(event.locationInWindow, from: nil)

        // Use scrollingDeltaY for zoom
        var factor: Double
        if event.hasPreciseScrollingDeltas {
            factor = 1.0 + Double(event.scrollingDeltaY) * 0.005
        } else {
            factor = 1.0 + Double(event.scrollingDeltaY) * 0.05
        }
        factor = max(0.8, min(1.25, factor))

        Task { @MainActor in
            engine.zoomAtPoint(factor: factor, viewPoint: loc, viewSize: self.bounds.size)
        }
    }

    override func magnify(with event: NSEvent) {
        guard let engine else { return }
        let loc = convert(event.locationInWindow, from: nil)
        let factor = 1.0 + Double(event.magnification)
        Task { @MainActor in
            engine.zoomAtPoint(factor: factor, viewPoint: loc, viewSize: self.bounds.size)
        }
    }

    override func keyDown(with event: NSEvent) {
        // Let the SwiftUI key handlers deal with it
        super.keyDown(with: event)
    }

    private func updateCursorForPosition(_ loc: CGPoint) {
        guard let engine, engine.hasVideoA && engine.hasVideoB else {
            NSCursor.arrow.set()
            return
        }
        let normX = loc.x / bounds.width
        if abs(normX - engine.sliderPosition) < 0.025 {
            NSCursor.resizeLeftRight.set()
            isOpenHandCursor = false
        } else if engine.zoom > 1.05 {
            NSCursor.openHand.set()
            isOpenHandCursor = true
        } else {
            NSCursor.arrow.set()
            isOpenHandCursor = false
        }
    }
}

// MARK: - Coordinator (Metal rendering)

extension MetalComparisonView {
    @MainActor
    class Coordinator: NSObject, MTKViewDelegate {
        let engine: VideoEngine
        var device: MTLDevice!
        var commandQueue: MTLCommandQueue!
        var pipelineState: MTLRenderPipelineState!
        var ciContext: CIContext!

        // Intermediate textures (rendered from CIImage, sampled in comparison pass)
        var textureA: MTLTexture?
        var textureB: MTLTexture?
        var textureSizeA: CGSize = .zero
        var textureSizeB: CGSize = .zero

        // Placeholder 1x1 black texture for when no video is loaded
        var placeholderTexture: MTLTexture!

        init(engine: VideoEngine) {
            self.engine = engine
            super.init()
        }

        func createView() -> ComparisonMTKView {
            guard let device = MTLCreateSystemDefaultDevice() else {
                fatalError("Metal is not supported on this device")
            }
            self.device = device
            self.commandQueue = device.makeCommandQueue()!

            // CIContext for color-managed pixel buffer → texture rendering
            let colorSpace = CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3)!
            self.ciContext = CIContext(mtlDevice: device, options: [
                .workingColorSpace: colorSpace,
                .cacheIntermediates: false
            ])

            // Create render pipeline
            do {
                let library = try device.makeLibrary(source: metalShaderSource, options: nil)
                let desc = MTLRenderPipelineDescriptor()
                desc.vertexFunction = library.makeFunction(name: "vertexMain")
                desc.fragmentFunction = library.makeFunction(name: "fragmentMain")
                desc.colorAttachments[0].pixelFormat = .rgba16Float
                pipelineState = try device.makeRenderPipelineState(descriptor: desc)
            } catch {
                fatalError("Failed to create Metal pipeline: \(error)")
            }

            // Placeholder texture
            let desc = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .rgba16Float, width: 1, height: 1, mipmapped: false)
            desc.usage = [.shaderRead]
            placeholderTexture = device.makeTexture(descriptor: desc)!

            // Create MTKView
            let view = ComparisonMTKView(frame: .zero, device: device)
            view.engine = engine
            view.coordinator = self
            view.delegate = self
            view.colorPixelFormat = .rgba16Float
            view.clearColor = MTLClearColor(red: 0.03, green: 0.03, blue: 0.03, alpha: 1)
            view.framebufferOnly = true
            view.preferredFramesPerSecond = 120 // Match ProMotion if available

            // Enable EDR for HDR display
            if let metalLayer = view.layer as? CAMetalLayer {
                metalLayer.wantsExtendedDynamicRangeContent = true
                metalLayer.colorspace = CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3)
            }

            return view
        }

        // MARK: - MTKViewDelegate

        nonisolated func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
            // Nothing to do; we use drawableSize each frame
        }

        nonisolated func draw(in view: MTKView) {
            // Bridge to MainActor since engine is @MainActor
            MainActor.assumeIsolated {
                self.performDraw(in: view)
            }
        }

        private func performDraw(in view: MTKView) {
            guard let drawable = view.currentDrawable,
                  let rpd = view.currentRenderPassDescriptor else { return }

            let cb = commandQueue.makeCommandBuffer()!
            let drawableSize = view.drawableSize

            // Get current playback time
            let itemTime = engine.playerA?.currentTime() ?? engine.playerB?.currentTime() ?? .zero

            // Update texture A from pixel buffer
            if let output = engine.videoOutputA,
               output.hasNewPixelBuffer(forItemTime: itemTime),
               let pb = output.copyPixelBuffer(forItemTime: itemTime, itemTimeForDisplay: nil) {
                textureA = renderPixelBufferToTexture(pb, existingTexture: textureA, sizeMemo: &textureSizeA, commandBuffer: cb)
            }

            // Update texture B from pixel buffer
            if let output = engine.videoOutputB,
               output.hasNewPixelBuffer(forItemTime: itemTime),
               let pb = output.copyPixelBuffer(forItemTime: itemTime, itemTimeForDisplay: nil) {
                textureB = renderPixelBufferToTexture(pb, existingTexture: textureB, sizeMemo: &textureSizeB, commandBuffer: cb)
            }

            // Build uniforms
            let ar = engine.referenceAspectRatio
            var uniforms = Uniforms(
                viewportSize: SIMD2<Float>(Float(drawableSize.width), Float(drawableSize.height)),
                sliderPosition: Float(engine.sliderPosition),
                zoom: Float(engine.zoom),
                panOffset: SIMD2<Float>(Float(engine.panOffset.x), Float(engine.panOffset.y)),
                videoAspect: SIMD2<Float>(Float(ar), 1.0),
                viewAspect: SIMD2<Float>(Float(drawableSize.width / drawableSize.height), 1.0),
                hasVideoA: engine.hasVideoA ? 1 : 0,
                hasVideoB: engine.hasVideoB ? 1 : 0,
                showSlider: (engine.hasVideoA && engine.hasVideoB) ? 1 : 0,
                padding: 0
            )

            // Render comparison
            let encoder = cb.makeRenderCommandEncoder(descriptor: rpd)!
            encoder.setRenderPipelineState(pipelineState)
            encoder.setVertexBytes(&uniforms, length: MemoryLayout<Uniforms>.size, index: 0)
            encoder.setFragmentBytes(&uniforms, length: MemoryLayout<Uniforms>.size, index: 0)
            encoder.setFragmentTexture(textureA ?? placeholderTexture, index: 0)
            encoder.setFragmentTexture(textureB ?? placeholderTexture, index: 1)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            encoder.endEncoding()

            cb.present(drawable)
            cb.commit()
        }

        // MARK: - Pixel Buffer → Texture via CIImage (handles HDR color management)

        private func renderPixelBufferToTexture(
            _ pixelBuffer: CVPixelBuffer,
            existingTexture: MTLTexture?,
            sizeMemo: inout CGSize,
            commandBuffer: MTLCommandBuffer
        ) -> MTLTexture? {
            let width = CVPixelBufferGetWidth(pixelBuffer)
            let height = CVPixelBufferGetHeight(pixelBuffer)
            let newSize = CGSize(width: width, height: height)

            // Create or resize texture if needed
            var texture = existingTexture
            if texture == nil || sizeMemo != newSize {
                let desc = MTLTextureDescriptor.texture2DDescriptor(
                    pixelFormat: .rgba16Float,
                    width: width,
                    height: height,
                    mipmapped: false
                )
                desc.usage = [.shaderRead, .renderTarget, .shaderWrite]
                texture = device.makeTexture(descriptor: desc)
                sizeMemo = newSize
            }

            guard let tex = texture else { return nil }

            // CIImage from pixel buffer (inherits source color space from CVPixelBuffer metadata)
            let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
            let targetColorSpace = CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3)!

            // Scale CIImage to texture size if they differ (shouldn't normally happen)
            var image = ciImage
            if Int(ciImage.extent.width) != width || Int(ciImage.extent.height) != height {
                let sx = CGFloat(width) / ciImage.extent.width
                let sy = CGFloat(height) / ciImage.extent.height
                image = ciImage.transformed(by: CGAffineTransform(scaleX: sx, y: sy))
            }

            let bounds = CGRect(x: 0, y: 0, width: width, height: height)
            ciContext.render(image, to: tex, commandBuffer: commandBuffer, bounds: bounds, colorSpace: targetColorSpace)

            return tex
        }
    }
}
