import Foundation
@preconcurrency import DPReader
import SwiftSDL
import Vulkan
import VulkanBindings
#if canImport(simd)
import simd
#endif

final class BiomeMapViewRenderer: @unchecked Sendable {
    private struct HudStyle {
        let cellSize: Float
        let glyphAdvance: Float
        let lineAdvance: Float
    }

    private struct MapRequestKey: Equatable {
        let origin: SIMD2<Int>
        let mapSize: SIMD2<Int>
        let sampleY: Int
        let scale: Int
    }

    private struct CompletedMapResult {
        let request: MapRequestKey
        let vertices: [VulkanEngine.Vertex2D]
        let isComplete: Bool
    }

    private struct CompletedHoverResult {
        let sample: SIMD3<Int>
        let text: String
    }

    private let worldGenerator: WorldGenerator
    private let cache: BiomeQuadTreeCache
    private let baseScale: Int
    private let maxZoomStep: Int
    private let biomeOverlayStyle = HudStyle(cellSize: 3, glyphAdvance: 12, lineAdvance: 16)
    private let gridLabelStyle = HudStyle(cellSize: 1.5, glyphAdvance: 6, lineAdvance: 8)
    private let gridScreenSpacing = 128
    private let gridLineColor = SIMD4<Float>(0.0, 0.0, 0.0, 0.18)
    private let biomeOverlayTextColor = SIMD4<Float>(1.0, 1.0, 1.0, 1.0)
    private let gridTextColor = SIMD4<Float>(0.62, 0.52, 0.08, 1.0)
    private let biomeOverlayBackgroundColor = SIMD4<Float>(0.0, 0.0, 0.0, 0.55)
    private let zoomStepThreshold: Float = 3
    private let zoomWheelUnitsPerDisplayStep: Float = 8
    private let zoomAnimationRate: Float = 14
    private let incompleteMapRefreshInterval: Float = 0.12
    private let mapRequestQueue = DispatchQueue(label: "BiomeMapViewRenderer.map", qos: .userInitiated)
    private let hoverSampleQueue = DispatchQueue(label: "BiomeMapViewRenderer.hover", qos: .userInitiated)
    private let stateLock = NSLock()

    private var centerX: Float = 0
    private var centerZ: Float = 0
    private var sampleY = 256
    private var zoomStep = 0
    private var pendingZoomWheel: Float = 0
    private var displayZoomStep: Float = 0
    private var targetDisplayZoomStep: Float = 0
    private var elapsedTime: Float = 0
    private var nextIncompleteMapRefreshTime: Float = 0
    private var mousePosition = SIMD2<Float>(repeating: -.greatestFiniteMagnitude)
    private var draggingMap = false
    private var zoomAnchorWorld: SIMD2<Float>?
    private var zoomAnchorScreen: SIMD2<Float>?

    private var mapBuffer: VulkanOwnedBuffer?
    private var mapMemory: VulkanOwnedDeviceMemory?
    private var mapVertexCount: UInt32 = 0
    private var mapVertexCapacity = 0
    private var overlayBuffer: VulkanOwnedBuffer?
    private var overlayMemory: VulkanOwnedDeviceMemory?
    private var overlayVertexCount: UInt32 = 0
    private var overlayVertexCapacity = 0

    private var lastRenderedMapRequest: MapRequestKey?
    private var lastRenderedMapIsComplete = false

    private var mapWorkerRunning = false
    private var activeMapRequest: MapRequestKey?
    private var pendingMapRequest: MapRequestKey?
    private var completedMapResult: CompletedMapResult?
    private var hoverWorkerRunning = false
    private var activeHoverSample: SIMD3<Int>?
    private var pendingHoverSample: SIMD3<Int>?
    private var completedHoverResult: CompletedHoverResult?

    private var hoveredBiomeText = "BIOME: UNKNOWN"
    private var hoveredBiomeSample = SIMD3<Int>(repeating: Int.max)
    private var lastOverlaySignature = ""

    init(
        worldGenerator: WorldGenerator,
        biomeColorPalette: BiomeColorPalette,
        scale: Int = 4
    ) {
        self.worldGenerator = worldGenerator
        self.cache = BiomeQuadTreeCache(palette: biomeColorPalette)
        self.baseScale = max(1, scale)

        self.maxZoomStep = Self.maxZoomStep(
            baseScale: self.baseScale,
            gridScreenSpacing: self.gridScreenSpacing,
            maxGridWorldSize: 2048
        )
    }

    private var currentSamplingScale: Int {
        baseScale << zoomStep
    }

    private var currentViewScale: Float {
        Float(baseScale) * pow(2, displayZoomStep)
    }

    func recenter(on worldPosition: SIMD3<Float>) {
        centerX = worldPosition.x
        centerZ = worldPosition.z
        sampleY = Int(floor(worldPosition.y))
        invalidateMapAndOverlay()
    }

    func handleEvent(_ event: SDL_Event, window: OpaquePointer?) {
        switch event.eventType {
        case .mouseButtonDown:
            let position = event.button.position(as: Float.self)
            mousePosition = position
            if event.button.button == SDL_BUTTON_LEFT {
                draggingMap = true
            }
        case .mouseButtonUp:
            mousePosition = event.button.position(as: Float.self)
            if event.button.button == SDL_BUTTON_LEFT {
                draggingMap = false
            }
        case .mouseMotion:
            let position = event.motion.position(as: Float.self)
            if draggingMap {
                clearZoomAnchor()
                let delta = position - mousePosition
                centerX -= delta.x * currentViewScale
                centerZ -= delta.y * currentViewScale
            }
            mousePosition = position
        case .mouseWheel:
            guard event.wheel.y != 0 else {
                return
            }
            let viewport = currentViewport(window: window)
            let focusPosition = isMouseInsideViewport(viewport)
                ? mousePosition
                : SIMD2<Float>(Float(viewport.x) * 0.5, Float(viewport.y) * 0.5)
            let focusWorld = worldPositionFloat(atScreenPosition: focusPosition, viewport: viewport)

            let directionMultiplier: Float = event.wheel.direction == SDL_MOUSEWHEEL_FLIPPED ? -1 : 1
            let wheelDelta = event.wheel.y * directionMultiplier
            targetDisplayZoomStep = clamp(
                targetDisplayZoomStep - (wheelDelta / zoomWheelUnitsPerDisplayStep),
                min: 0,
                max: Float(maxZoomStep)
            )
            zoomAnchorWorld = focusWorld
            zoomAnchorScreen = focusPosition
            if pendingZoomWheel != 0, pendingZoomWheel.sign != wheelDelta.sign {
                pendingZoomWheel = 0
            }
            pendingZoomWheel += wheelDelta

            var nextZoomStep = zoomStep
            while pendingZoomWheel >= zoomStepThreshold {
                nextZoomStep = max(0, nextZoomStep - 1)
                pendingZoomWheel -= zoomStepThreshold
            }
            while pendingZoomWheel <= -zoomStepThreshold {
                nextZoomStep = min(maxZoomStep, nextZoomStep + 1)
                pendingZoomWheel += zoomStepThreshold
            }
            if nextZoomStep != zoomStep {
                zoomStep = nextZoomStep
                nextIncompleteMapRefreshTime = 0
            }
        default:
            break
        }
    }

    func update(deltaTime: Float) {
        elapsedTime += max(0, deltaTime)
        let smoothing = 1 - exp(-zoomAnimationRate * max(0, deltaTime))
        displayZoomStep += (targetDisplayZoomStep - displayZoomStep) * smoothing
        if abs(displayZoomStep - targetDisplayZoomStep) < 0.001 {
            displayZoomStep = targetDisplayZoomStep
        }
    }

    func discardData() {
        cache.clear()
        mapBuffer = nil
        mapMemory = nil
        mapVertexCount = 0
        mapVertexCapacity = 0
        overlayBuffer = nil
        overlayMemory = nil
        overlayVertexCount = 0
        overlayVertexCapacity = 0
        lastRenderedMapRequest = nil
        lastRenderedMapIsComplete = false
        stateLock.lock()
        mapWorkerRunning = false
        activeMapRequest = nil
        pendingMapRequest = nil
        completedMapResult = nil
        hoverWorkerRunning = false
        activeHoverSample = nil
        pendingHoverSample = nil
        completedHoverResult = nil
        stateLock.unlock()
        hoveredBiomeSample = SIMD3<Int>(repeating: Int.max)
        hoveredBiomeText = "BIOME: UNKNOWN"
        lastOverlaySignature = ""
        nextIncompleteMapRefreshTime = 0
        clearZoomAnchor()
    }

    func render(
        engine: VulkanEngine,
        window: OpaquePointer?,
        imageAvailable: VkSemaphore,
        renderFinishedByImage: [VkSemaphore]
    ) throws {
        try engine.device.waitForFences([engine.inFlightFence.fence], waitAll: true, timeout: UInt64.max)

        let viewport = currentViewport(window: window)
        applyZoomAnchorIfNeeded(viewport: viewport)
        try updateHoveredBiomeIfNeeded(viewport: viewport)
        try engine.updateTransform2D(worldTransform(viewport: viewport))
        engine.setClearColor(SIMD4<Float>(0.0, 0.0, 0.0, 1.0))
        try updateMapIfNeeded(engine: engine, viewport: viewport)
        try updateOverlayIfNeeded(engine: engine, viewport: viewport)

        let imageIndex = try engine.device.acquireNextImage(from: engine.swapchain, semaphore: imageAvailable)
        guard Int(imageIndex) < renderFinishedByImage.count else {
            throw TerrainRendererError.invalidSwapchainImageIndex
        }
        let renderFinished = renderFinishedByImage[Int(imageIndex)]

        var batches: [VulkanEngine.DrawBatch2D] = []
        if let mapBuffer, mapVertexCount > 0 {
            batches.append(.init(buffer: mapBuffer, vertexCount: mapVertexCount))
        }
        if let overlayBuffer, overlayVertexCount > 0 {
            batches.append(.init(buffer: overlayBuffer, vertexCount: overlayVertexCount))
        }

        try engine.drawBatches2D(
            batches,
            framebufferIndex: Int(imageIndex),
            waitSemaphores: [imageAvailable],
            signalSemaphores: [renderFinished]
        )

        var swapchainHandle: VkSwapchainKHR? = engine.swapchain.swapchain
        var imageIndexVar = imageIndex
        try withUnsafePointer(to: &swapchainHandle) { swapchainPtr in
            try withUnsafePointer(to: &imageIndexVar) { imageIndexPtr in
                var renderFinishedSemaphore: VkSemaphore? = renderFinished
                try withUnsafePointer(to: &renderFinishedSemaphore) { semaphorePtr in
                    var presentInfo = VkPresentInfoKHR(
                        sType: VK_STRUCTURE_TYPE_PRESENT_INFO_KHR,
                        pNext: nil,
                        waitSemaphoreCount: 1,
                        pWaitSemaphores: semaphorePtr,
                        swapchainCount: 1,
                        pSwapchains: swapchainPtr,
                        pImageIndices: imageIndexPtr,
                        pResults: nil
                    )
                    try engine.device.present(queue: engine.graphicsQueue, presentInfo: &presentInfo)
                }
            }
        }
    }

    private func updateHoveredBiomeIfNeeded(viewport: SIMD2<Int>) throws {
        if let completedHover = takeCompletedHoverResult(),
           completedHover.sample == hoveredBiomeSample {
            hoveredBiomeText = completedHover.text
            lastOverlaySignature = ""
        }

        guard let hoverWorld = hoveredWorldPosition(viewport: viewport) else {
            let defaultText = "BIOME: UNKNOWN"
            if hoveredBiomeText != defaultText {
                hoveredBiomeText = defaultText
                lastOverlaySignature = ""
            }
            return
        }

        let sample = SIMD3<Int>(hoverWorld.x, sampleY, hoverWorld.y)
        guard sample != hoveredBiomeSample else {
            return
        }

        hoveredBiomeSample = sample
        scheduleHoverSampleIfNeeded(sample)
    }

    private func updateMapIfNeeded(engine: VulkanEngine, viewport: SIMD2<Int>) throws {
        let request = currentMapRequest(viewport: viewport)

        if let completed = takeCompletedMapResult() {
            try uploadMapVertices(completed.vertices, engine: engine)
            lastRenderedMapRequest = completed.request
            lastRenderedMapIsComplete = completed.isComplete
            if completed.request == request, !completed.isComplete {
                nextIncompleteMapRefreshTime = elapsedTime + incompleteMapRefreshInterval
            }
        }

        let requestChanged = request != lastRenderedMapRequest

        if requestChanged {
            scheduleMapRequestIfNeeded(request)
        } else if !lastRenderedMapIsComplete, elapsedTime >= nextIncompleteMapRefreshTime {
            scheduleMapRequestIfNeeded(request)
            nextIncompleteMapRefreshTime = elapsedTime + incompleteMapRefreshInterval
        }
    }

    private func uploadMapVertices(_ vertices: [VulkanEngine.Vertex2D], engine: VulkanEngine) throws {
        if mapBuffer == nil || mapMemory == nil || vertices.count > mapVertexCapacity {
            mapBuffer = nil
            mapMemory = nil
            mapVertexCapacity = max(vertices.count, max(256, mapVertexCapacity * 2))
            let (buffer, memory) = try engine.createVertexBuffer2DCapacity(mapVertexCapacity)
            mapBuffer = buffer
            mapMemory = memory
        }

        guard let mapBuffer, let mapMemory else {
            return
        }

        mapVertexCount = try engine.updateVertexBuffer2D(
            vertices,
            buffer: mapBuffer,
            memory: mapMemory,
            capacity: mapVertexCapacity
        )
    }

    private func updateOverlayIfNeeded(engine: VulkanEngine, viewport: SIMD2<Int>) throws {
        let signature = "\(viewport.x)x\(viewport.y):\(sampleY):\(Int(round(centerX * 100)))"
            + ":\(Int(round(centerZ * 100))):\(currentSamplingScale):\(Int(round(currentViewScale * 1000))):\(hoveredBiomeText)"
        guard overlayBuffer == nil || signature != lastOverlaySignature else {
            return
        }

        let vertices = makeOverlayVertices(viewport: viewport)
        if overlayBuffer == nil || overlayMemory == nil || vertices.count > overlayVertexCapacity {
            overlayBuffer = nil
            overlayMemory = nil
            overlayVertexCapacity = max(vertices.count, max(512, overlayVertexCapacity * 2))
            let (buffer, memory) = try engine.createVertexBuffer2DCapacity(overlayVertexCapacity)
            overlayBuffer = buffer
            overlayMemory = memory
        }

        guard let overlayBuffer, let overlayMemory else {
            return
        }

        overlayVertexCount = try engine.updateVertexBuffer2D(
            vertices,
            buffer: overlayBuffer,
            memory: overlayMemory,
            capacity: overlayVertexCapacity
        )
        lastOverlaySignature = signature
    }

    private func makeOverlayVertices(viewport: SIMD2<Int>) -> [VulkanEngine.Vertex2D] {
        var vertices: [VulkanEngine.Vertex2D] = []
        vertices.reserveCapacity(32_768)

        appendGrid(viewport: viewport, into: &vertices)
        appendBiomeOverlay(viewport: viewport, into: &vertices)

        return vertices
    }

    private func appendBiomeOverlay(
        viewport: SIMD2<Int>,
        into vertices: inout [VulkanEngine.Vertex2D]
    ) {
        let lineWidth = textWidth(hoveredBiomeText, style: biomeOverlayStyle)
        let paddingX = 8 as Float
        let paddingY = 6 as Float
        let originX = max(0, Float(viewport.x) - 12 - lineWidth)
        let origin = worldPositionFloat(
            atScreenPosition: SIMD2<Float>(originX, 12),
            viewport: viewport
        )
        let backgroundOrigin = worldPositionFloat(
            atScreenPosition: SIMD2<Float>(max(0, originX - paddingX), max(0, 12 - paddingY)),
            viewport: viewport
        )
        let backgroundMax = worldPositionFloat(
            atScreenPosition: SIMD2<Float>(
                min(Float(viewport.x), originX + lineWidth + paddingX),
                min(Float(viewport.y), 12 + biomeOverlayStyle.lineAdvance + paddingY)
            ),
            viewport: viewport
        )
        appendQuad(
            minX: backgroundOrigin.x,
            minY: backgroundOrigin.y,
            maxX: backgroundMax.x,
            maxY: backgroundMax.y,
            color: biomeOverlayBackgroundColor,
            into: &vertices
        )
        appendText(
            hoveredBiomeText,
            origin: origin,
            style: worldSpaceStyle(for: biomeOverlayStyle),
            color: biomeOverlayTextColor,
            into: &vertices
        )
    }

    private func appendGrid(
        viewport: SIMD2<Int>,
        into vertices: inout [VulkanEngine.Vertex2D]
    ) {
        let gridWorldSpacing = currentSamplingScale * gridScreenSpacing
        let topLeft = currentTopLeftWorld(viewport: viewport)
        let worldWidth = Float(viewport.x) * currentViewScale
        let worldHeight = Float(viewport.y) * currentViewScale
        let maxWorldX = topLeft.x + worldWidth
        let maxWorldZ = topLeft.y + worldHeight
        let pixelWorldSize = currentViewScale
        let labelStyle = worldSpaceStyle(for: gridLabelStyle)

        let firstGridX = floorDiv(Int(floor(topLeft.x)), gridWorldSpacing) * gridWorldSpacing
        let firstGridZ = floorDiv(Int(floor(topLeft.y)), gridWorldSpacing) * gridWorldSpacing

        var gridXs: [Int] = []
        var worldX = firstGridX
        while Float(worldX) <= maxWorldX {
            gridXs.append(worldX)
            appendQuad(
                minX: Float(worldX),
                minY: topLeft.y,
                maxX: Float(worldX) + pixelWorldSize,
                maxY: maxWorldZ,
                color: gridLineColor,
                into: &vertices
            )
            worldX += gridWorldSpacing
        }

        var gridZs: [Int] = []
        var worldZ = firstGridZ
        while Float(worldZ) <= maxWorldZ {
            gridZs.append(worldZ)
            appendQuad(
                minX: topLeft.x,
                minY: Float(worldZ),
                maxX: maxWorldX,
                maxY: Float(worldZ) + pixelWorldSize,
                color: gridLineColor,
                into: &vertices
            )
            worldZ += gridWorldSpacing
        }

        for worldZ in gridZs {
            for worldX in gridXs {
                let label = "\(worldX), \(worldZ)"
                let labelOrigin = SIMD2<Float>(
                    Float(worldX) + 4 * pixelWorldSize,
                    Float(worldZ) - labelStyle.lineAdvance
                )
                appendText(
                    label,
                    origin: labelOrigin,
                    style: labelStyle,
                    color: gridTextColor,
                    into: &vertices
                )
            }
        }
    }

    private func appendText(
        _ text: String,
        origin: SIMD2<Float>,
        style: HudStyle,
        color: SIMD4<Float>,
        into vertices: inout [VulkanEngine.Vertex2D]
    ) {
        var cursorX = origin.x
        for character in text {
            let glyph = Self.hudGlyphs[character] ?? Self.hudGlyphs[" "]!
            appendGlyph(
                glyph,
                origin: SIMD2<Float>(cursorX, origin.y),
                cellSize: style.cellSize,
                color: color,
                into: &vertices
            )
            cursorX += style.glyphAdvance
        }
    }

    private func textWidth(_ text: String, style: HudStyle) -> Float {
        Float(text.count) * style.glyphAdvance
    }

    private func appendGlyph(
        _ glyph: [String],
        origin: SIMD2<Float>,
        cellSize: Float,
        color: SIMD4<Float>,
        into vertices: inout [VulkanEngine.Vertex2D]
    ) {
        for (rowIndex, row) in glyph.enumerated() {
            for (columnIndex, pixel) in row.enumerated() where pixel != "0" {
                let minX = origin.x + Float(columnIndex) * cellSize
                let minY = origin.y + Float(rowIndex) * cellSize
                appendQuad(
                    minX: minX,
                    minY: minY,
                    maxX: minX + cellSize,
                    maxY: minY + cellSize,
                    color: color,
                    into: &vertices
                )
            }
        }
    }

    private func appendQuad(
        minX: Float,
        minY: Float,
        maxX: Float,
        maxY: Float,
        color: SIMD4<Float>,
        into vertices: inout [VulkanEngine.Vertex2D]
    ) {
        let p0 = SIMD2<Float>(minX, minY)
        let p1 = SIMD2<Float>(maxX, minY)
        let p2 = SIMD2<Float>(maxX, maxY)
        let p3 = SIMD2<Float>(minX, maxY)
        vertices.append(.init(position: p0, color: color))
        vertices.append(.init(position: p1, color: color))
        vertices.append(.init(position: p2, color: color))
        vertices.append(.init(position: p0, color: color))
        vertices.append(.init(position: p2, color: color))
        vertices.append(.init(position: p3, color: color))
    }

    private func currentViewport(window: OpaquePointer?) -> SIMD2<Int> {
        var windowW: Int32 = 800
        var windowH: Int32 = 800
        if let window {
            SDL_GetWindowSize(window, &windowW, &windowH)
        }
        return SIMD2<Int>(max(1, Int(windowW)), max(1, Int(windowH)))
    }

    private func currentTopLeftWorld(viewport: SIMD2<Int>) -> SIMD2<Float> {
        SIMD2<Float>(
            centerX - (Float(viewport.x) * currentViewScale) * 0.5,
            centerZ - (Float(viewport.y) * currentViewScale) * 0.5
        )
    }

    private func isMouseInsideViewport(_ viewport: SIMD2<Int>) -> Bool {
        mousePosition.x >= 0
            && mousePosition.y >= 0
            && mousePosition.x < Float(viewport.x)
            && mousePosition.y < Float(viewport.y)
    }

    private func hoveredWorldPosition(viewport: SIMD2<Int>) -> SIMD2<Int>? {
        guard isMouseInsideViewport(viewport) else {
            return nil
        }
        return sampledWorldPosition(atScreenPosition: mousePosition, viewport: viewport)
    }

    private func worldPositionFloat(atScreenPosition screenPosition: SIMD2<Float>, viewport: SIMD2<Int>) -> SIMD2<Float> {
        let topLeft = currentTopLeftWorld(viewport: viewport)
        return SIMD2<Float>(
            topLeft.x + screenPosition.x * currentViewScale,
            topLeft.y + screenPosition.y * currentViewScale
        )
    }

    private func sampledWorldPosition(atScreenPosition screenPosition: SIMD2<Float>, viewport: SIMD2<Int>) -> SIMD2<Int> {
        let worldPosition = worldPositionFloat(atScreenPosition: screenPosition, viewport: viewport)
        return SIMD2<Int>(
            Int(floor(worldPosition.x)),
            Int(floor(worldPosition.y))
        )
    }

    private func worldSpaceStyle(for style: HudStyle) -> HudStyle {
        let scale = currentViewScale
        return HudStyle(
            cellSize: style.cellSize * scale,
            glyphAdvance: style.glyphAdvance * scale,
            lineAdvance: style.lineAdvance * scale
        )
    }

    private func invalidateMapAndOverlay() {
        lastRenderedMapRequest = nil
        lastRenderedMapIsComplete = false
        hoveredBiomeSample = SIMD3<Int>(repeating: Int.max)
        lastOverlaySignature = ""
        nextIncompleteMapRefreshTime = 0
        clearZoomAnchor()
    }

    private func sampleBiomeName(atWorldX worldX: Int, worldZ: Int) throws -> String? {
        let from = PosInt2D(x: Int32(worldX), z: Int32(worldZ))
        let to = PosInt2D(x: Int32(worldX + 1), z: Int32(worldZ + 1))
        let biomes = try worldGenerator.generateBiomesInSquare(
            from: from,
            to: to,
            atY: Int32(sampleY),
            in: RegistryKey(referencing: "minecraft:overworld"),
            scale: 1
        )
        return biomes?.first?.name
    }

    private func formatBiomeName(_ biomeName: String) -> String {
        let trimmedNamespace: Substring
        if let colonIndex = biomeName.lastIndex(of: ":") {
            trimmedNamespace = biomeName[biomeName.index(after: colonIndex)...]
        } else {
            trimmedNamespace = Substring(biomeName)
        }

        return trimmedNamespace
            .split(separator: "_")
            .map { token in
                guard let first = token.first else { return "" }
                return String(first).uppercased() + token.dropFirst().lowercased()
            }
            .joined(separator: " ")
            .uppercased()
    }

    private func floorDiv(_ value: Int, _ divisor: Int) -> Int {
        if value >= 0 {
            return value / divisor
        }
        return -(((-value) + divisor - 1) / divisor)
    }

    private func scheduleMapRequestIfNeeded(_ request: MapRequestKey) {
        stateLock.lock()
        if activeMapRequest == request || pendingMapRequest == request {
            stateLock.unlock()
            return
        }
        pendingMapRequest = request
        let shouldStartWorker = !mapWorkerRunning
        if shouldStartWorker {
            mapWorkerRunning = true
        }
        stateLock.unlock()

        guard shouldStartWorker else {
            return
        }

        mapRequestQueue.async { [weak self] in
            self?.runMapRequestWorker()
        }
    }

    private func takeCompletedMapResult() -> CompletedMapResult? {
        stateLock.lock()
        defer { stateLock.unlock() }
        let result = completedMapResult
        completedMapResult = nil
        return result
    }

    private func scheduleHoverSampleIfNeeded(_ sample: SIMD3<Int>) {
        stateLock.lock()
        if activeHoverSample == sample || pendingHoverSample == sample {
            stateLock.unlock()
            return
        }
        pendingHoverSample = sample
        let shouldStartWorker = !hoverWorkerRunning
        if shouldStartWorker {
            hoverWorkerRunning = true
        }
        stateLock.unlock()

        guard shouldStartWorker else {
            return
        }

        hoverSampleQueue.async { [weak self] in
            self?.runHoverSampleWorker()
        }
    }

    private func takeCompletedHoverResult() -> CompletedHoverResult? {
        stateLock.lock()
        defer { stateLock.unlock() }
        let result = completedHoverResult
        completedHoverResult = nil
        return result
    }

    private func runMapRequestWorker() {
        while true {
            stateLock.lock()
            guard let request = pendingMapRequest else {
                activeMapRequest = nil
                mapWorkerRunning = false
                stateLock.unlock()
                return
            }
            pendingMapRequest = nil
            activeMapRequest = request
            stateLock.unlock()

            let completed: CompletedMapResult?
            if let result = try? cache.verticesAsync(
                worldGenerator: worldGenerator,
                topLeftX: request.origin.x,
                topLeftZ: request.origin.y,
                width: request.mapSize.x,
                height: request.mapSize.y,
                scale: request.scale,
                sampleY: request.sampleY
            ) {
                completed = CompletedMapResult(
                    request: request,
                    vertices: result.vertices,
                    isComplete: result.isComplete
                )
            } else {
                completed = nil
            }

            stateLock.lock()
            if activeMapRequest == request {
                completedMapResult = completed
                activeMapRequest = nil
            }
            stateLock.unlock()
        }
    }

    private func runHoverSampleWorker() {
        while true {
            stateLock.lock()
            guard let sample = pendingHoverSample else {
                activeHoverSample = nil
                hoverWorkerRunning = false
                stateLock.unlock()
                return
            }
            pendingHoverSample = nil
            activeHoverSample = sample
            stateLock.unlock()

            let text: String
            if let biomeName = try? sampleBiomeName(atWorldX: sample.x, worldZ: sample.z) {
                text = "BIOME: \(formatBiomeName(biomeName))"
            } else {
                text = "BIOME: UNKNOWN"
            }

            stateLock.lock()
            if activeHoverSample == sample {
                completedHoverResult = CompletedHoverResult(sample: sample, text: text)
                activeHoverSample = nil
            }
            stateLock.unlock()
        }
    }

    private func currentMapRequest(viewport: SIMD2<Int>) -> MapRequestKey {
        let topLeft = currentTopLeftWorld(viewport: viewport)
        let samplingScale = currentSamplingScale
        let worldWidth = Float(viewport.x) * currentViewScale
        let worldHeight = Float(viewport.y) * currentViewScale
        let originX = floorDiv(Int(floor(topLeft.x)), samplingScale) * samplingScale
        let originZ = floorDiv(Int(floor(topLeft.y)), samplingScale) * samplingScale
        let width = max(
            1,
            Int(ceil((topLeft.x + worldWidth - Float(originX)) / Float(samplingScale))) + 1
        )
        let height = max(
            1,
            Int(ceil((topLeft.y + worldHeight - Float(originZ)) / Float(samplingScale))) + 1
        )
        return MapRequestKey(
            origin: SIMD2<Int>(originX, originZ),
            mapSize: SIMD2<Int>(width, height),
            sampleY: sampleY,
            scale: samplingScale
        )
    }

    private func applyZoomAnchorIfNeeded(viewport: SIMD2<Int>) {
        guard let zoomAnchorWorld, let zoomAnchorScreen else {
            return
        }
        centerX = zoomAnchorWorld.x + (Float(viewport.x) * 0.5 - zoomAnchorScreen.x) * currentViewScale
        centerZ = zoomAnchorWorld.y + (Float(viewport.y) * 0.5 - zoomAnchorScreen.y) * currentViewScale
        if displayZoomStep == targetDisplayZoomStep {
            clearZoomAnchor()
        }
    }

    private func clearZoomAnchor() {
        zoomAnchorWorld = nil
        zoomAnchorScreen = nil
    }

    private func clamp(_ value: Float, min minValue: Float, max maxValue: Float) -> Float {
        Swift.max(minValue, Swift.min(maxValue, value))
    }

    private static func maxZoomStep(baseScale: Int, gridScreenSpacing: Int, maxGridWorldSize: Int) -> Int {
        var zoomCap = 0
        var zoomWorldScale = max(1, baseScale)
        let maxWorldScale = max(zoomWorldScale, maxGridWorldSize / max(1, gridScreenSpacing))
        while zoomWorldScale * 2 <= maxWorldScale {
            zoomWorldScale *= 2
            zoomCap += 1
        }
        return zoomCap
    }

    private func worldTransform(viewport: SIMD2<Int>) -> simd_float4x4 {
        let width = Float(viewport.x)
        let height = Float(viewport.y)
        let scale = currentViewScale
        let topLeft = currentTopLeftWorld(viewport: viewport)
        let translateX = -1 - (2 * topLeft.x / (width * scale))
        let translateY = -1 - (2 * topLeft.y / (height * scale))

        return simd_float4x4(
            SIMD4<Float>(2 / (width * scale), 0, 0, 0),
            SIMD4<Float>(0, 2 / (height * scale), 0, 0),
            SIMD4<Float>(0, 0, 1, 0),
            SIMD4<Float>(translateX, translateY, 0, 1)
        )
    }

    private static let hudGlyphs: [Character: [String]] = [
        "0": ["111", "101", "101", "101", "111"],
        "1": ["010", "110", "010", "010", "111"],
        "2": ["111", "001", "111", "100", "111"],
        "3": ["111", "001", "111", "001", "111"],
        "4": ["101", "101", "111", "001", "001"],
        "5": ["111", "100", "111", "001", "111"],
        "6": ["111", "100", "111", "101", "111"],
        "7": ["111", "001", "001", "001", "001"],
        "8": ["111", "101", "111", "101", "111"],
        "9": ["111", "101", "111", "001", "111"],
        "A": ["010", "101", "111", "101", "101"],
        "B": ["110", "101", "110", "101", "110"],
        "C": ["011", "100", "100", "100", "011"],
        "D": ["110", "101", "101", "101", "110"],
        "E": ["111", "100", "110", "100", "111"],
        "F": ["111", "100", "110", "100", "100"],
        "G": ["011", "100", "101", "101", "011"],
        "H": ["101", "101", "111", "101", "101"],
        "I": ["111", "010", "010", "010", "111"],
        "J": ["001", "001", "001", "101", "010"],
        "K": ["101", "101", "110", "101", "101"],
        "L": ["100", "100", "100", "100", "111"],
        "M": ["101", "111", "111", "101", "101"],
        "N": ["101", "111", "111", "111", "101"],
        "O": ["010", "101", "101", "101", "010"],
        "P": ["110", "101", "110", "100", "100"],
        "Q": ["010", "101", "101", "111", "011"],
        "R": ["110", "101", "110", "101", "101"],
        "S": ["111", "100", "111", "001", "111"],
        "T": ["111", "010", "010", "010", "010"],
        "U": ["101", "101", "101", "101", "111"],
        "V": ["101", "101", "101", "101", "010"],
        "W": ["101", "101", "111", "111", "101"],
        "X": ["101", "101", "010", "101", "101"],
        "Y": ["101", "101", "010", "010", "010"],
        "Z": ["111", "001", "010", "100", "111"],
        "a": ["000", "011", "101", "111", "101"],
        "b": ["100", "110", "101", "110", "101"],
        "c": ["000", "011", "100", "100", "011"],
        "d": ["001", "011", "101", "101", "011"],
        "e": ["000", "011", "111", "100", "011"],
        "f": ["001", "010", "111", "010", "010"],
        "g": ["000", "011", "101", "011", "001"],
        "h": ["100", "110", "101", "101", "101"],
        "i": ["010", "000", "110", "010", "111"],
        "j": ["001", "000", "001", "101", "010"],
        "k": ["100", "101", "110", "101", "101"],
        "l": ["110", "010", "010", "010", "111"],
        "m": ["000", "111", "111", "101", "101"],
        "n": ["000", "110", "101", "101", "101"],
        "o": ["000", "010", "101", "101", "010"],
        "p": ["000", "110", "101", "110", "100"],
        "q": ["000", "011", "101", "011", "001"],
        "r": ["000", "101", "110", "100", "100"],
        "s": ["000", "011", "110", "011", "110"],
        "t": ["010", "111", "010", "010", "001"],
        "u": ["000", "101", "101", "101", "011"],
        "v": ["000", "101", "101", "101", "010"],
        "w": ["000", "101", "111", "111", "101"],
        "x": ["000", "101", "010", "010", "101"],
        "y": ["000", "101", "101", "011", "001"],
        "z": ["000", "111", "001", "010", "111"],
        "/": ["001", "001", "010", "100", "100"],
        ":": ["000", "010", "000", "010", "000"],
        ".": ["000", "000", "000", "000", "010"],
        ",": ["000", "000", "000", "010", "100"],
        "-": ["000", "000", "111", "000", "000"],
        "_": ["000", "000", "000", "000", "111"],
        "=": ["000", "111", "000", "111", "000"],
        "[": ["110", "100", "100", "100", "110"],
        "]": ["011", "001", "001", "001", "011"],
        "@": ["111", "101", "111", "100", "011"],
        "~": ["000", "101", "010", "000", "000"],
        "^": ["010", "101", "000", "000", "000"],
        "!": ["010", "010", "010", "000", "010"],
        "?": ["111", "001", "010", "000", "010"],
        "'": ["010", "010", "000", "000", "000"],
        "\"": ["101", "101", "000", "000", "000"],
        " ": ["000", "000", "000", "000", "000"]
    ]
}
