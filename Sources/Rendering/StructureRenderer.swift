import Foundation
import SwiftSDL
import Vulkan
import VulkanBindings
#if canImport(simd)
import simd
#endif

final class StructureRenderer {
    struct TexturedQuad {
        let corners: [SIMD3<Float>]
        let textureName: String
        let tint: SIMD4<Float>
        let textureCoordinates: [SIMD2<Float>]

        init(
            corners: [SIMD3<Float>],
            textureName: String,
            tint: SIMD4<Float> = SIMD4<Float>(repeating: 1),
            textureCoordinates: [SIMD2<Float>] = [
                SIMD2<Float>(0, 0),
                SIMD2<Float>(1, 0),
                SIMD2<Float>(1, 1),
                SIMD2<Float>(0, 1)
            ]
        ) {
            self.corners = corners
            self.textureName = textureName
            self.tint = tint
            self.textureCoordinates = textureCoordinates
        }
    }

    struct FaceTextures {
        let up: String
        let down: String
        let north: String
        let south: String
        let east: String
        let west: String

        static func uniform(_ texture: String) -> FaceTextures {
            FaceTextures(up: texture, down: texture, north: texture, south: texture, east: texture, west: texture)
        }
    }

    struct BlockInstance {
        let position: SIMD3<Int>
        let textures: FaceTextures
        let tint: SIMD4<Float>
        let isOpaque: Bool

        init(
            position: SIMD3<Int>,
            textures: FaceTextures,
            tint: SIMD4<Float> = SIMD4<Float>(repeating: 1),
            isOpaque: Bool = true
        ) {
            self.position = position
            self.textures = textures
            self.tint = tint
            self.isOpaque = isOpaque
        }
    }

    enum Error: Swift.Error {
        case texturedPipelineUnavailable
        case invalidAtlasFrame(String)
        case invalidSwapchainImageIndex
    }

    private struct Bounds {
        var min: SIMD3<Float>
        var max: SIMD3<Float>

        static let empty = Bounds(
            min: SIMD3<Float>(repeating: .greatestFiniteMagnitude),
            max: SIMD3<Float>(repeating: -.greatestFiniteMagnitude)
        )

        var center: SIMD3<Float> {
            (min + max) * 0.5
        }

        var radius: Float {
            Swift.max(max.x - min.x, Swift.max(max.y - min.y, max.z - min.z)) * 0.5
        }
    }

    private enum Face: CaseIterable {
        case up
        case down
        case north
        case south
        case east
        case west

        var neighborOffset: SIMD3<Int> {
            switch self {
            case .up:
                return SIMD3<Int>(0, 1, 0)
            case .down:
                return SIMD3<Int>(0, -1, 0)
            case .north:
                return SIMD3<Int>(0, 0, -1)
            case .south:
                return SIMD3<Int>(0, 0, 1)
            case .east:
                return SIMD3<Int>(1, 0, 0)
            case .west:
                return SIMD3<Int>(-1, 0, 0)
            }
        }

        func texture(from textures: FaceTextures) -> String {
            switch self {
            case .up:
                return textures.up
            case .down:
                return textures.down
            case .north:
                return textures.north
            case .south:
                return textures.south
            case .east:
                return textures.east
            case .west:
                return textures.west
            }
        }

        func corners(at origin: SIMD3<Float>) -> [SIMD3<Float>] {
            switch self {
            case .up:
                return [
                    origin + SIMD3<Float>(0, 1, 0),
                    origin + SIMD3<Float>(1, 1, 0),
                    origin + SIMD3<Float>(1, 1, 1),
                    origin + SIMD3<Float>(0, 1, 1)
                ]
            case .down:
                return [
                    origin + SIMD3<Float>(0, 0, 0),
                    origin + SIMD3<Float>(0, 0, 1),
                    origin + SIMD3<Float>(1, 0, 1),
                    origin + SIMD3<Float>(1, 0, 0)
                ]
            case .north:
                return [
                    origin + SIMD3<Float>(0, 0, 0),
                    origin + SIMD3<Float>(1, 0, 0),
                    origin + SIMD3<Float>(1, 1, 0),
                    origin + SIMD3<Float>(0, 1, 0)
                ]
            case .south:
                return [
                    origin + SIMD3<Float>(1, 0, 1),
                    origin + SIMD3<Float>(0, 0, 1),
                    origin + SIMD3<Float>(0, 1, 1),
                    origin + SIMD3<Float>(1, 1, 1)
                ]
            case .east:
                return [
                    origin + SIMD3<Float>(1, 0, 0),
                    origin + SIMD3<Float>(1, 0, 1),
                    origin + SIMD3<Float>(1, 1, 1),
                    origin + SIMD3<Float>(1, 1, 0)
                ]
            case .west:
                return [
                    origin + SIMD3<Float>(0, 0, 1),
                    origin + SIMD3<Float>(0, 0, 0),
                    origin + SIMD3<Float>(0, 1, 0),
                    origin + SIMD3<Float>(0, 1, 1)
                ]
            }
        }
    }

    private let assetLoader: VanillaAssetLoader
    private var blocks: [BlockInstance] = []
    private var meshBuffer: VulkanOwnedBuffer?
    private var meshMemory: VulkanOwnedDeviceMemory?
    private var meshVertexCount: UInt32 = 0
    private var meshVertexCapacity = 0
    private var meshTexture: VulkanEngine.Texture2D?
    private var meshBounds = Bounds(min: .zero, max: SIMD3<Float>(repeating: 1))
    private var orbitYaw: Float = -.pi / 4
    private var orbitPitch: Float = .pi / 7
    private var orbitDistance: Float = 8
    private var rotating = false

    init(repository: VanillaAssetRepository, assetLoader: VanillaAssetLoader? = nil) {
        if let assetLoader {
            self.assetLoader = assetLoader
        } else {
            self.assetLoader = VanillaAssetLoader(repository: repository)
        }
    }

    func setBlocks(_ blocks: [BlockInstance], engine: VulkanEngine) throws {
        self.blocks = blocks
        try setTexturedQuads(makeTexturedQuads(from: blocks), engine: engine)
    }

    func setQuads(_ quads: [TexturedQuad], engine: VulkanEngine) throws {
        blocks.removeAll(keepingCapacity: false)
        try setTexturedQuads(quads, engine: engine)
    }

    func clear() {
        blocks.removeAll(keepingCapacity: false)
        meshBuffer = nil
        meshMemory = nil
        meshVertexCount = 0
        meshVertexCapacity = 0
        meshTexture = nil
        meshBounds = Bounds(min: .zero, max: SIMD3<Float>(repeating: 1))
    }

    func handleEvent(_ event: SDL_Event) {
        switch event.eventType {
        case .mouseButtonDown:
            if event.button.button == SDL_BUTTON_LEFT {
                rotating = true
            }
        case .mouseButtonUp:
            if event.button.button == SDL_BUTTON_LEFT {
                rotating = false
            }
        case .mouseMotion:
            guard rotating else {
                return
            }
            let delta = event.motion.relative(as: Float.self)
            orbitYaw += delta.x * 0.01
            orbitPitch = clamp(orbitPitch - delta.y * 0.01, min: -(.pi / 2 - 0.05), max: .pi / 2 - 0.05)
        case .mouseWheel:
            let directionMultiplier: Float = event.wheel.direction == SDL_MOUSEWHEEL_FLIPPED ? -1 : 1
            orbitDistance = max(1.5, orbitDistance - Float(event.wheel.y) * directionMultiplier * 0.75)
        default:
            break
        }
    }

    func update(deltaTime _: Float) {}

    func render(
        engine: VulkanEngine,
        window: OpaquePointer?,
        imageAvailable: VkSemaphore,
        renderFinishedByImage: [VkSemaphore]
    ) throws {
        guard engine.hasTextured3DPipeline else {
            throw Error.texturedPipelineUnavailable
        }
        guard let meshBuffer, meshVertexCount > 0, let meshTexture else {
            return
        }

        try engine.device.waitForFences([engine.inFlightFence.fence], waitAll: true, timeout: UInt64.max)
        try engine.bindTextureTextured3D(meshTexture)

        let viewport = currentViewport(window: window)
        let aspect = max(1, Float(viewport.x)) / max(1, Float(viewport.y))
        let view = lookAtRH(
            eye: cameraPosition(),
            center: meshBounds.center,
            up: SIMD3<Float>(0, 1, 0)
        )
        let projection = perspectiveRH(
            fovYRadians: 55 * .pi / 180,
            aspect: aspect,
            nearZ: 0.05,
            farZ: 512
        )

        try engine.updateTransformTextured3D(projection)
        try engine.updateModelTextured3D(matrix_identity_float4x4)
        try engine.updateViewTextured3D(view)
        engine.setClearColor(SIMD4<Float>(0.12, 0.13, 0.16, 1))

        let imageIndex = try engine.device.acquireNextImage(from: engine.swapchain, semaphore: imageAvailable)
        guard Int(imageIndex) < renderFinishedByImage.count else {
            throw Error.invalidSwapchainImageIndex
        }
        let renderFinished = renderFinishedByImage[Int(imageIndex)]

        try engine.drawBatchesTextured3D(
            [.init(buffer: meshBuffer, vertexCount: meshVertexCount, modelOffset: SIMD4<Float>(repeating: 0))],
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

    private func buildMesh(from blocks: [BlockInstance]) throws -> (
        vertices: [VulkanEngine.VertexTextured3D],
        atlas: VanillaTextureImage,
        bounds: Bounds
    ) {
        try buildMesh(from: makeTexturedQuads(from: blocks))
    }

    private func buildMesh(from quads: [TexturedQuad]) throws -> (
        vertices: [VulkanEngine.VertexTextured3D],
        atlas: VanillaTextureImage,
        bounds: Bounds
    ) {
        let textureNames = quads.map(\.textureName)
        let atlasBuild = try assetLoader.buildAtlas(textureNames: textureNames)

        var vertices: [VulkanEngine.VertexTextured3D] = []
        vertices.reserveCapacity(max(6, quads.count * 6))
        var bounds = Bounds.empty

        for quad in quads {
            guard let frame = atlasBuild.frames[quad.textureName] else {
                throw Error.invalidAtlasFrame(quad.textureName)
            }
            for corner in quad.corners {
                bounds.min = componentwiseMin(bounds.min, corner)
                bounds.max = componentwiseMax(bounds.max, corner)
            }
            appendFace(
                vertices: &vertices,
                corners: quad.corners,
                atlasFrame: frame,
                tint: quad.tint,
                textureCoordinates: quad.textureCoordinates
            )
        }

        if quads.isEmpty {
            bounds = Bounds(min: .zero, max: SIMD3<Float>(repeating: 1))
        }

        return (vertices, atlasBuild.image, bounds)
    }

    private func makeTexturedQuads(from blocks: [BlockInstance]) -> [TexturedQuad] {
        let opaquePositions = Set(blocks.filter(\.isOpaque).map(\.position))
        var quads: [TexturedQuad] = []
        quads.reserveCapacity(max(6, blocks.count * 3))

        for block in blocks {
            let blockOrigin = SIMD3<Float>(Float(block.position.x), Float(block.position.y), Float(block.position.z))
            for face in Face.allCases {
                let neighborPosition = SIMD3<Int>(
                    block.position.x + face.neighborOffset.x,
                    block.position.y + face.neighborOffset.y,
                    block.position.z + face.neighborOffset.z
                )
                if block.isOpaque && opaquePositions.contains(neighborPosition) {
                    continue
                }
                quads.append(
                    TexturedQuad(
                        corners: face.corners(at: blockOrigin),
                        textureName: face.texture(from: block.textures),
                        tint: block.tint
                    )
                )
            }
        }

        return quads
    }

    private func setTexturedQuads(_ quads: [TexturedQuad], engine: VulkanEngine) throws {
        let meshBuild = try buildMesh(from: quads)
        if meshBuffer == nil || meshMemory == nil || meshBuild.vertices.count > meshVertexCapacity {
            meshBuffer = nil
            meshMemory = nil
            meshVertexCapacity = max(meshBuild.vertices.count, max(256, meshVertexCapacity * 2))
            let (buffer, memory) = try engine.createVertexBufferTextured3DCapacity(meshVertexCapacity)
            meshBuffer = buffer
            meshMemory = memory
        }

        if let meshBuffer, let meshMemory {
            meshVertexCount = try engine.updateVertexBufferTextured3D(
                meshBuild.vertices,
                buffer: meshBuffer,
                memory: meshMemory,
                capacity: meshVertexCapacity
            )
        } else {
            meshVertexCount = 0
        }

        meshTexture = try engine.createTexture2D(
            width: meshBuild.atlas.width,
            height: meshBuild.atlas.height,
            rgba8: meshBuild.atlas.rgba8
        )
        meshBounds = meshBuild.bounds
        refocusCamera()
    }

    private func appendFace(
        vertices: inout [VulkanEngine.VertexTextured3D],
        corners: [SIMD3<Float>],
        atlasFrame: SIMD4<Float>,
        tint: SIMD4<Float>,
        textureCoordinates: [SIMD2<Float>]
    ) {
        let uv0 = atlasUV(atlasFrame: atlasFrame, localUV: textureCoordinates[0])
        let uv1 = atlasUV(atlasFrame: atlasFrame, localUV: textureCoordinates[1])
        let uv2 = atlasUV(atlasFrame: atlasFrame, localUV: textureCoordinates[2])
        let uv3 = atlasUV(atlasFrame: atlasFrame, localUV: textureCoordinates[3])

        vertices.append(.init(position: corners[0], color: tint, textureCoordinates: uv0))
        vertices.append(.init(position: corners[1], color: tint, textureCoordinates: uv1))
        vertices.append(.init(position: corners[2], color: tint, textureCoordinates: uv2))
        vertices.append(.init(position: corners[0], color: tint, textureCoordinates: uv0))
        vertices.append(.init(position: corners[2], color: tint, textureCoordinates: uv2))
        vertices.append(.init(position: corners[3], color: tint, textureCoordinates: uv3))
    }

    private func atlasUV(atlasFrame: SIMD4<Float>, localUV: SIMD2<Float>) -> SIMD2<Float> {
        SIMD2<Float>(
            atlasFrame.x + (atlasFrame.z - atlasFrame.x) * localUV.x,
            atlasFrame.y + (atlasFrame.w - atlasFrame.y) * localUV.y
        )
    }

    private func refocusCamera() {
        orbitDistance = max(4, meshBounds.radius * 3.2 + 2)
    }

    private func cameraPosition() -> SIMD3<Float> {
        let center = meshBounds.center
        let horizontal = cos(orbitPitch) * orbitDistance
        return center + SIMD3<Float>(
            x: cos(orbitYaw) * horizontal,
            y: sin(orbitPitch) * orbitDistance,
            z: sin(orbitYaw) * horizontal
        )
    }

    private func currentViewport(window: OpaquePointer?) -> SIMD2<Int> {
        var windowW: Int32 = 800
        var windowH: Int32 = 800
        if let window {
            SDL_GetWindowSize(window, &windowW, &windowH)
        }
        return SIMD2<Int>(max(1, Int(windowW)), max(1, Int(windowH)))
    }

    private func lookAtRH(eye: SIMD3<Float>, center: SIMD3<Float>, up: SIMD3<Float>) -> simd_float4x4 {
        let f = simd_normalize(center - eye)
        let s = simd_normalize(simd_cross(f, up))
        let u = simd_cross(s, f)
        return simd_float4x4(
            SIMD4<Float>(s.x, u.x, -f.x, 0),
            SIMD4<Float>(s.y, u.y, -f.y, 0),
            SIMD4<Float>(s.z, u.z, -f.z, 0),
            SIMD4<Float>(-simd_dot(s, eye), -simd_dot(u, eye), simd_dot(f, eye), 1)
        )
    }

    private func perspectiveRH(fovYRadians: Float, aspect: Float, nearZ: Float, farZ: Float) -> simd_float4x4 {
        let y = 1 / tan(fovYRadians * 0.5)
        let x = y / aspect
        let z = farZ / (nearZ - farZ)
        return simd_float4x4(
            SIMD4<Float>(x, 0, 0, 0),
            SIMD4<Float>(0, -y, 0, 0),
            SIMD4<Float>(0, 0, z, -1),
            SIMD4<Float>(0, 0, z * nearZ, 0)
        )
    }

    private func clamp(_ value: Float, min lowerBound: Float, max upperBound: Float) -> Float {
        Swift.max(lowerBound, Swift.min(upperBound, value))
    }

    private func componentwiseMin(_ lhs: SIMD3<Float>, _ rhs: SIMD3<Float>) -> SIMD3<Float> {
        SIMD3<Float>(
            Swift.min(lhs.x, rhs.x),
            Swift.min(lhs.y, rhs.y),
            Swift.min(lhs.z, rhs.z)
        )
    }

    private func componentwiseMax(_ lhs: SIMD3<Float>, _ rhs: SIMD3<Float>) -> SIMD3<Float> {
        SIMD3<Float>(
            Swift.max(lhs.x, rhs.x),
            Swift.max(lhs.y, rhs.y),
            Swift.max(lhs.z, rhs.z)
        )
    }
}
