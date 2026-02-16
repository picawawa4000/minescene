import Foundation
import SwiftSDL
import VulkanBindings
import Vulkan
import DPReader
import simd

@_silgen_name("SDL_Vulkan_GetInstanceExtensions")
private func sdlVulkanGetInstanceExtensions(_ count: UnsafeMutablePointer<UInt32>?) -> UnsafePointer<UnsafePointer<CChar>?>?

@main
final class MineSceneApp {
    private final class SDLRuntime {
        init() throws {
            try SDL_Init(.video)
        }

        deinit {
            SDL_Quit()
        }
    }

    private struct State {
        var topLeftX: Int = 0
        var topLeftZ: Int = 0
        var scale: Int = 4
        var dragging = false
        var lastMouseX = 0
        var lastMouseY = 0
        var mouseX = 0
        var mouseY = 0
        var dirty = true
    }

    private var state = State()
    private let sdl: SDLRuntime
    private var window: SDLObject<OpaquePointer>?
    private var instance: VulkanOwnedInstance?
    private var surface: VulkanOwnedSurface?
    private var engine: VulkanEngine?
    private var worldGenerator: WorldGenerator?
    private var imageAvailable: VulkanOwnedSemaphore?
    private var renderFinished: VulkanOwnedSemaphore?
    private let viewportWidth = 256
    private let viewportHeight = 256
    private let tileCache = BiomeQuadTreeCache(tileSize: 256)
    private var cachedTileOriginX = 0
    private var cachedTileOriginZ = 0
    private var cachedScale = 0
    private var cachedVersion: UInt64 = 0
    private var cachedVertices: [VulkanEngine.Vertex2D] = []

    init() throws {
        self.sdl = try SDLRuntime()
        let windowPtr = "MineScene".withCString { title in
            SDL_CreateWindow(title, 800, 800, SDL_WindowFlags.vulkan.rawValue | SDL_WindowFlags.resizable.rawValue)
        }
        guard let windowPtr else {
            throw SDL_Error.error
        }
        self.window = SDLObject<OpaquePointer>(windowPtr, tag: .custom("window"), destroy: { SDL_DestroyWindow($0) })

        var instanceFlags: VulkanInstanceCreateFlags = []
        var instanceExtensions = try MineSceneApp.getSdlVulkanInstanceExtensions()
        #if os(macOS)
        instanceFlags.insert(.enumeratePortability)
        instanceExtensions.append(VK_KHR_PORTABILITY_ENUMERATION_EXTENSION_NAME)
        #endif
        instanceExtensions = Array(Set(instanceExtensions))

        #if DEBUG
        let instanceLayers = ["VK_LAYER_KHRONOS_validation"]
        #else
        let instanceLayers: [String] = []
        #endif
        let instance = try VulkanOwnedInstance(
            flags: instanceFlags,
            enabledLayers: instanceLayers,
            enabledExtensions: instanceExtensions,
            appName: "minescene",
            appVersion: 1,
            engineName: nil,
            engineVersion: nil,
            apiVersion: VulkanAPIVersion.v1_3.rawValue
        )
        self.instance = instance

        guard let window else {
            throw SDL_Error.error
        }
        let surface = try createVulkanSurface(from: window, instance: instance)
        self.surface = surface

        let seed: UInt64 = 123456789
        let dataPackPath = "vanilla/1.21.11"
        let dataPackURL = URL(fileURLWithPath: dataPackPath, isDirectory: true)
        let dataPack = try DataPack(fromRootPath: dataPackURL)
        let worldGenerator = try WorldGenerator(withWorldSeed: seed, usingDataPacks: [dataPack], usingSettings: RegistryKey(referencing: "minecraft:overworld"))
        self.worldGenerator = worldGenerator

        let engine = try VulkanEngine(
            instance: instance,
            surface: surface,
            vertSpirvPath: "Shaders/SPIRV/colour2D.vert.spv",
            fragSpirvPath: "Shaders/SPIRV/colour2D.frag.spv",
            desiredExtent: .init(width: 800, height: 800)
        )
        self.engine = engine

        self.imageAvailable = try engine.device.createSemaphore()
        self.renderFinished = try engine.device.createSemaphore()
    }

    static func main() throws {
        let app = try MineSceneApp()
        try app.run()
    }

    func run() throws {
        var event = SDL_Event()
        var running = true
        while running {
            let previousMouseX = state.mouseX
            let previousMouseY = state.mouseY
            var polledMouseX: Float = 0
            var polledMouseY: Float = 0
            SDL_GetMouseState(&polledMouseX, &polledMouseY)
            state.mouseX = Int(polledMouseX)
            state.mouseY = Int(polledMouseY)
            if state.mouseX != previousMouseX || state.mouseY != previousMouseY {
                state.dirty = true
            }

            while SDL_PollEvent(&event) {
                switch event.eventType {
                case .quit:
                    running = false
                case .mouseButtonDown:
                    if event.button.button == SDL_BUTTON_LEFT {
                        state.dragging = true
                        state.lastMouseX = Int(event.button.x)
                        state.lastMouseY = Int(event.button.y)
                    }
                case .mouseButtonUp:
                    if event.button.button == SDL_BUTTON_LEFT {
                        state.dragging = false
                    }
                case .mouseWheel:
                    let dy = event.wheel.y
                    if dy > 0 {
                        state.scale = max(1, state.scale / 4)
                        state.dirty = true
                    } else if dy < 0 {
                        state.scale = min(64, state.scale * 4)
                        state.dirty = true
                    }
                default:
                    break
                }
            }

            if state.dragging {
                let x = state.mouseX
                let y = state.mouseY
                let dx = x - state.lastMouseX
                let invertedY = -y
                let invertedLastY = -state.lastMouseY
                let dz = invertedY - invertedLastY
                if dx != 0 || dz != 0 {
                    state.lastMouseX = x
                    state.lastMouseY = y
                    state.topLeftX -= dx * state.scale
                    state.topLeftZ -= dz * state.scale
                    state.dirty = true
                }
            }

            if state.dirty {
                try renderFrame()
                state.dirty = false
            }

            SDL_Delay(16)
        }

        if let engine {
            _ = try? engine.device.waitIdle()
        }
        imageAvailable = nil
        renderFinished = nil
        engine?.shutdown()
        engine = nil
        surface = nil
        instance = nil
        window = nil
    }

    private func renderFrame() throws {
        guard let worldGenerator, let engine else {
            return
        }
        let tileWorldSize = tileCache.tileSize * state.scale
        let tileOriginX = floorDiv(state.topLeftX, tileWorldSize) * tileWorldSize - tileWorldSize
        let tileOriginZ = floorDiv(state.topLeftZ, tileWorldSize) * tileWorldSize - tileWorldSize
        let mapWidth = viewportWidth + tileCache.tileSize * 2
        let mapHeight = viewportHeight + tileCache.tileSize * 2

        let mapResult = try tileCache.mapAsync(
            worldGenerator: worldGenerator,
            topLeftX: tileOriginX,
            topLeftZ: tileOriginZ,
            width: mapWidth,
            height: mapHeight,
            scale: state.scale
        )

        if cachedVertices.isEmpty ||
            tileOriginX != cachedTileOriginX ||
            tileOriginZ != cachedTileOriginZ ||
            state.scale != cachedScale ||
            mapResult.version != cachedVersion {
            cachedVertices = BiomeMapRenderer.makeVertices2D(from: mapResult.map)
            cachedTileOriginX = mapResult.tileOriginX
            cachedTileOriginZ = mapResult.tileOriginZ
            cachedScale = state.scale
            cachedVersion = mapResult.version
        }
        if !mapResult.isComplete {
            state.dirty = true
        }

        let offsetPixelsX = Float(state.topLeftX - cachedTileOriginX) / Float(state.scale)
        let offsetPixelsZ = Float(state.topLeftZ - cachedTileOriginZ) / Float(state.scale)
        let viewportW = Float(viewportWidth)
        let viewportH = Float(viewportHeight)

        // Map-space pixels -> viewport-space (top-left origin) -> NDC.
        let sx = 2.0 / viewportW
        let sy = 2.0 / viewportH
        let tx = -1.0 - 2.0 * offsetPixelsX / viewportW
        let ty = -1.0 - 2.0 * offsetPixelsZ / viewportH
        let transform = simd_float4x4(
            SIMD4<Float>(sx, 0.0, 0.0, 0.0),
            SIMD4<Float>(0.0, sy, 0.0, 0.0),
            SIMD4<Float>(0.0, 0.0, 1.0, 0.0),
            SIMD4<Float>(tx, ty, 0.0, 1.0)
        )
        try engine.updateTransform2D(transform)

        var windowW: Int32 = 800
        var windowH: Int32 = 800
        if let windowHandle = window {
            SDL_GetWindowSize(windowHandle.pointer, &windowW, &windowH)
        }

        let mapMouseX = Int(Float(state.mouseX) * Float(viewportWidth) / max(1.0, Float(windowW)))
        let mapMouseY = Int(Float(state.mouseY) * Float(viewportHeight) / max(1.0, Float(windowH)))
        let worldMouseX = state.topLeftX + mapMouseX * state.scale
        let worldMouseZ = state.topLeftZ + mapMouseY * state.scale
        let biomeID = hoveredBiomeID(atWorldX: worldMouseX, worldZ: worldMouseZ)

        let inverseTransform = simd_inverse(transform)
        let overlayVertices = makeCoordinateOverlayVertices(
            absoluteX: worldMouseX,
            absoluteZ: worldMouseZ,
            biomeID: biomeID,
            inverseTransform: inverseTransform
        )

        guard let imageAvailable, let renderFinished else {
            return
        }
        let imageIndex = try engine.device.acquireNextImage(from: engine.swapchain, semaphore: imageAvailable.semaphore)
        var frameVertices = cachedVertices
        frameVertices.append(contentsOf: overlayVertices)
        let (_vertexBuffer, _vertexMemory) = try engine.uploadVertices2D(
            frameVertices,
            framebufferIndex: Int(imageIndex),
            waitSemaphores: [imageAvailable.semaphore],
            signalSemaphores: [renderFinished.semaphore]
        )

        var swapchainHandle: VkSwapchainKHR? = engine.swapchain.swapchain
        var imageIndexVar = imageIndex
        try withUnsafePointer(to: &swapchainHandle) { swapchainPtr in
            try withUnsafePointer(to: &imageIndexVar) { imageIndexPtr in
                var renderFinishedSemaphore: VkSemaphore? = renderFinished.semaphore
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

        try engine.device.waitIdle()
    }

    private func floorDiv(_ value: Int, _ divisor: Int) -> Int {
        if value >= 0 {
            return value / divisor
        }
        return -(((-value) + divisor - 1) / divisor)
    }

    private func makeCoordinateOverlayVertices(
        absoluteX: Int,
        absoluteZ: Int,
        biomeID: String,
        inverseTransform: simd_float4x4
    ) -> [VulkanEngine.Vertex2D] {
        let biomeLine = sanitizeOverlayText("B:\(biomeID.uppercased())")
        let lines = [
            "X:\(absoluteX) Z:\(absoluteZ)",
            biomeLine
        ]
        let charW: Float = 0.018
        let charH: Float = 0.03
        let gap: Float = 0.006
        let margin: Float = 0.02
        let lineGap: Float = 0.012
        let textWidth = lines.map { Float($0.count) * (charW + gap) - gap }.max() ?? 0.0
        let textHeight = Float(lines.count) * charH + Float(max(0, lines.count - 1)) * lineGap
        let startX = 1.0 - margin - textWidth
        let topY: Float = 1.0 - margin
        let bgPadX: Float = 0.01
        let bgPadY: Float = 0.01

        var vertices: [VulkanEngine.Vertex2D] = []
        let totalChars = lines.reduce(0) { $0 + $1.count }
        vertices.reserveCapacity(totalChars * 6 * 35)

        // Background panel to keep text legible.
        appendQuadNDC(
            x0: startX - bgPadX,
            y0: topY + bgPadY,
            x1: startX + textWidth + bgPadX,
            y1: topY - textHeight - bgPadY,
            color: SIMD4<Float>(0.0, 0.0, 0.0, 0.7),
            inverseTransform: inverseTransform,
            vertices: &vertices
        )

        for lineIndex in 0..<lines.count {
            let text = lines[lineIndex]
            var cursorX = startX
            let lineTopY = topY - Float(lineIndex) * (charH + lineGap)
            for ch in text {
                if let bitmap = Self.glyphs[ch] {
                    for row in 0..<bitmap.count {
                        let line = Array(bitmap[bitmap.count - 1 - row])
                        for col in 0..<line.count where line[col] == "1" {
                            let px0 = cursorX + (Float(col) / 5.0) * charW
                            let py0 = lineTopY - (Float(row) / 7.0) * charH
                            let px1 = cursorX + (Float(col + 1) / 5.0) * charW
                            let py1 = lineTopY - (Float(row + 1) / 7.0) * charH
                            appendQuadNDC(
                                x0: px0,
                                y0: py0,
                                x1: px1,
                                y1: py1,
                                color: SIMD4<Float>(1.0, 1.0, 1.0, 1.0),
                                inverseTransform: inverseTransform,
                                vertices: &vertices
                            )
                        }
                    }
                }
                cursorX += charW + gap
            }
        }

        return vertices
    }

    private func hoveredBiomeID(atWorldX worldX: Int, worldZ: Int, sampleY: Int32 = 256) -> String {
        guard let worldGenerator else {
            return "UNKNOWN"
        }

        let scale = Int32(max(1, state.scale))
        let from = DPReader.PosInt2D(x: Int32(worldX), z: Int32(worldZ))
        let to = DPReader.PosInt2D(x: Int32(worldX) + scale, z: Int32(worldZ) + scale)
        let overworld = DPReader.RegistryKey<DPReader.Dimension>(referencing: "minecraft:overworld")

        do {
            guard
                let biomes = try worldGenerator.generateBiomesInSquare(
                    from: from,
                    to: to,
                    atY: sampleY,
                    in: overworld,
                    scale: scale
                ),
                let biome = biomes.first
            else {
                return "UNKNOWN"
            }
            return biome.name
        } catch {
            return "UNKNOWN"
        }
    }

    private func sanitizeOverlayText(_ text: String) -> String {
        String(text.map { Self.glyphs[$0] == nil ? "?" : $0 })
    }

    private func appendQuadNDC(
        x0: Float,
        y0: Float,
        x1: Float,
        y1: Float,
        color: SIMD4<Float>,
        inverseTransform: simd_float4x4,
        vertices: inout [VulkanEngine.Vertex2D]
    ) {
        let p0 = ndcToMapSpace(x: x0, y: y1, inverseTransform: inverseTransform)
        let p1 = ndcToMapSpace(x: x1, y: y1, inverseTransform: inverseTransform)
        let p2 = ndcToMapSpace(x: x1, y: y0, inverseTransform: inverseTransform)
        let p3 = ndcToMapSpace(x: x0, y: y0, inverseTransform: inverseTransform)

        vertices.append(.init(position: p0, color: color))
        vertices.append(.init(position: p1, color: color))
        vertices.append(.init(position: p2, color: color))
        vertices.append(.init(position: p0, color: color))
        vertices.append(.init(position: p2, color: color))
        vertices.append(.init(position: p3, color: color))
    }

    private func ndcToMapSpace(
        x: Float,
        y: Float,
        inverseTransform: simd_float4x4
    ) -> SIMD2<Float> {
        let out = inverseTransform * SIMD4<Float>(x, y, 0.0, 1.0)
        return SIMD2<Float>(out.x, out.y)
    }

    private static let glyphs: [Character: [String]] = [
        " ": ["00000", "00000", "00000", "00000", "00000", "00000", "00000"],
        "-": ["00000", "00000", "00000", "11111", "00000", "00000", "00000"],
        "_": ["00000", "00000", "00000", "00000", "00000", "00000", "11111"],
        ":": ["00000", "00100", "00000", "00000", "00100", "00000", "00000"],
        "?": ["01110", "10001", "00010", "00100", "00100", "00000", "00100"],
        "A": ["01110", "10001", "10001", "11111", "10001", "10001", "10001"],
        "B": ["11110", "10001", "10001", "11110", "10001", "10001", "11110"],
        "C": ["01110", "10001", "10000", "10000", "10000", "10001", "01110"],
        "D": ["11110", "10001", "10001", "10001", "10001", "10001", "11110"],
        "E": ["11111", "10000", "10000", "11110", "10000", "10000", "11111"],
        "F": ["11111", "10000", "10000", "11110", "10000", "10000", "10000"],
        "G": ["01110", "10001", "10000", "10111", "10001", "10001", "01110"],
        "H": ["10001", "10001", "10001", "11111", "10001", "10001", "10001"],
        "I": ["11111", "00100", "00100", "00100", "00100", "00100", "11111"],
        "J": ["00001", "00001", "00001", "00001", "10001", "10001", "01110"],
        "K": ["10001", "10010", "10100", "11000", "10100", "10010", "10001"],
        "L": ["10000", "10000", "10000", "10000", "10000", "10000", "11111"],
        "M": ["10001", "11011", "10101", "10101", "10001", "10001", "10001"],
        "N": ["10001", "10001", "11001", "10101", "10011", "10001", "10001"],
        "O": ["01110", "10001", "10001", "10001", "10001", "10001", "01110"],
        "P": ["11110", "10001", "10001", "11110", "10000", "10000", "10000"],
        "Q": ["01110", "10001", "10001", "10001", "10101", "10010", "01101"],
        "R": ["11110", "10001", "10001", "11110", "10100", "10010", "10001"],
        "S": ["01110", "10001", "10000", "01110", "00001", "10001", "01110"],
        "T": ["11111", "00100", "00100", "00100", "00100", "00100", "00100"],
        "U": ["10001", "10001", "10001", "10001", "10001", "10001", "01110"],
        "V": ["10001", "10001", "10001", "10001", "10001", "01010", "00100"],
        "W": ["10001", "10001", "10001", "10101", "10101", "10101", "01010"],
        "X": ["10001", "01010", "00100", "00100", "01010", "10001", "00000"],
        "Y": ["10001", "10001", "01010", "00100", "00100", "00100", "00100"],
        "Z": ["11111", "00010", "00100", "01000", "10000", "11111", "00000"],
        "0": ["01110", "10001", "10011", "10101", "11001", "10001", "01110"],
        "1": ["00100", "01100", "00100", "00100", "00100", "00100", "01110"],
        "2": ["01110", "10001", "00001", "00010", "00100", "01000", "11111"],
        "3": ["11110", "00001", "00001", "01110", "00001", "00001", "11110"],
        "4": ["00010", "00110", "01010", "10010", "11111", "00010", "00010"],
        "5": ["11111", "10000", "10000", "11110", "00001", "00001", "11110"],
        "6": ["01110", "10000", "10000", "11110", "10001", "10001", "01110"],
        "7": ["11111", "00001", "00010", "00100", "01000", "01000", "01000"],
        "8": ["01110", "10001", "10001", "01110", "10001", "10001", "01110"],
        "9": ["01110", "10001", "10001", "01111", "00001", "00001", "01110"],
    ]

    private static func getSdlVulkanInstanceExtensions() throws -> [String] {
        var count: UInt32 = 0
        guard let extensionsPtr = sdlVulkanGetInstanceExtensions(&count) else {
            throw SDL_Error.error
        }
        let buffer = UnsafeBufferPointer(start: extensionsPtr, count: Int(count))
        return buffer.compactMap { $0 }.map { String(cString: $0) }
    }
}
