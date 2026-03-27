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
    var keycodeForAction: ((KeybindAction) -> SDL_Keycode)?
    private var blocks: [BlockInstance] = []
    private var texturedQuads: [TexturedQuad] = []
    private var meshBuffer: VulkanOwnedBuffer?
    private var meshMemory: VulkanOwnedDeviceMemory?
    private var meshVertexCount: UInt32 = 0
    private var meshVertexCapacity = 0
    private var meshTexture: VulkanEngine.Texture2D?
    private var currentAnimationTick: Float = 0
    private var atlasAnimationSignature: [String: Int] = [:]
    private var meshBounds = Bounds(min: .zero, max: SIMD3<Float>(repeating: 1))
    private var cameraPosition = SIMD3<Float>(0, 2, -6)
    private var cameraYaw: Float = .pi / 4
    private var cameraPitch: Float = -.pi / 7
    private var moveSpeed: Float = 6
    private var fastMoveMultiplier: Float = 4
    private var mouseSensitivity: Float = 0.0025
    private var keyForward = false
    private var keyLeft = false
    private var keyBackward = false
    private var keyRight = false
    private var keyUp = false
    private var keyDown = false
    private var keyFastMove = false

    init(repository: VanillaAssetRepository, assetLoader: VanillaAssetLoader? = nil) {
        if let assetLoader {
            self.assetLoader = assetLoader
        } else {
            self.assetLoader = VanillaAssetLoader(repository: repository)
        }
    }

    func setBlocks(_ blocks: [BlockInstance], engine: VulkanEngine) throws {
        self.blocks = blocks
        let quads = makeTexturedQuads(from: blocks)
        texturedQuads = quads
        try setTexturedQuads(quads, engine: engine)
    }

    func setQuads(_ quads: [TexturedQuad], engine: VulkanEngine) throws {
        blocks.removeAll(keepingCapacity: false)
        texturedQuads = quads
        try setTexturedQuads(quads, engine: engine)
    }

    func clear() {
        blocks.removeAll(keepingCapacity: false)
        meshBuffer = nil
        meshMemory = nil
        meshVertexCount = 0
        meshVertexCapacity = 0
        meshTexture = nil
        texturedQuads.removeAll(keepingCapacity: false)
        atlasAnimationSignature.removeAll(keepingCapacity: false)
        currentAnimationTick = 0
        meshBounds = Bounds(min: .zero, max: SIMD3<Float>(repeating: 1))
    }

    func handleEvent(_ event: SDL_Event) {
        switch event.eventType {
        case .keyDown:
            if event.key.repeat {
                return
            }
            setKeyState(event.key.key, pressed: true)
        case .keyUp:
            setKeyState(event.key.key, pressed: false)
        case .mouseMotion:
            let delta = event.motion.relative(as: Float.self)
            cameraYaw += delta.x * mouseSensitivity
            cameraPitch = clamp(cameraPitch - delta.y * mouseSensitivity, min: -(.pi / 2 - 0.05), max: .pi / 2 - 0.05)
        default:
            break
        }
    }

    func update(deltaTime: Float) {
        currentAnimationTick += max(0, deltaTime) * 20
        let horizontalForward = normalizeOrZero(SIMD3<Float>(
            x: cos(cameraYaw),
            y: 0,
            z: sin(cameraYaw)
        ))
        let horizontalRight = normalizeOrZero(SIMD3<Float>(
            x: -horizontalForward.z,
            y: 0,
            z: horizontalForward.x
        ))

        var movement = SIMD3<Float>(repeating: 0)
        if keyForward { movement += horizontalForward }
        if keyBackward { movement -= horizontalForward }
        if keyRight { movement += horizontalRight }
        if keyLeft { movement -= horizontalRight }
        if keyUp { movement.y += 1 }
        if keyDown { movement.y -= 1 }

        if simd_length_squared(movement) > 0 {
            movement = simd_normalize(movement)
            let speed = moveSpeed * (keyFastMove ? fastMoveMultiplier : 1)
            cameraPosition += movement * (speed * max(0, deltaTime))
        }
    }

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
        try updateAnimatedAtlasIfNeeded(engine: engine)
        try engine.bindTextureTextured3D(meshTexture)

        let viewport = currentViewport(window: window)
        let aspect = max(1, Float(viewport.x)) / max(1, Float(viewport.y))
        let farPlane = max(2048, meshBounds.radius * 12 + 256)
        let view = lookAtRH(
            eye: cameraPosition,
            center: cameraPosition + viewForward(),
            up: SIMD3<Float>(0, 1, 0)
        )
        let projection = perspectiveRH(
            fovYRadians: 55 * .pi / 180,
            aspect: aspect,
            nearZ: 0.05,
            farZ: farPlane
        )

        try engine.updateTransformTextured3D(projection)
        try engine.updateModelTextured3D(matrix_identity_float4x4)
        try engine.updateViewTextured3D(view)
        engine.setClearColor(SIMD4<Float>(0.63, 0.82, 0.98, 1.0))

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
        bounds: Bounds,
        animationSignature: [String: Int]
    ) {
        try buildMesh(from: makeTexturedQuads(from: blocks))
    }

    private func buildMesh(from quads: [TexturedQuad]) throws -> (
        vertices: [VulkanEngine.VertexTextured3D],
        atlas: VanillaTextureImage,
        bounds: Bounds,
        animationSignature: [String: Int]
    ) {
        let textureNames = quads.map(\.textureName)
        let atlasBuild = try assetLoader.buildAtlas(
            textureNames: textureNames,
            animationTick: Int(currentAnimationTick.rounded(.down))
        )

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

        return (vertices, atlasBuild.image, bounds, atlasBuild.animationSignature)
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
        atlasAnimationSignature = meshBuild.animationSignature
        meshBounds = meshBuild.bounds
        refocusCamera()
    }

    private func updateAnimatedAtlasIfNeeded(engine: VulkanEngine) throws {
        guard let meshTexture, !texturedQuads.isEmpty else {
            return
        }
        let atlasBuild = try assetLoader.buildAtlas(
            textureNames: texturedQuads.map(\.textureName),
            animationTick: Int(currentAnimationTick.rounded(.down))
        )
        guard atlasBuild.animationSignature != atlasAnimationSignature else {
            return
        }
        try engine.updateTexture2D(meshTexture, rgba8: atlasBuild.image.rgba8)
        atlasAnimationSignature = atlasBuild.animationSignature
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
        vertices.append(.init(position: corners[2], color: tint, textureCoordinates: uv2))
        vertices.append(.init(position: corners[1], color: tint, textureCoordinates: uv1))
        vertices.append(.init(position: corners[0], color: tint, textureCoordinates: uv0))
        vertices.append(.init(position: corners[3], color: tint, textureCoordinates: uv3))
        vertices.append(.init(position: corners[2], color: tint, textureCoordinates: uv2))
    }

    private func atlasUV(atlasFrame: SIMD4<Float>, localUV: SIMD2<Float>) -> SIMD2<Float> {
        SIMD2<Float>(
            atlasFrame.x + (atlasFrame.z - atlasFrame.x) * localUV.x,
            atlasFrame.y + (atlasFrame.w - atlasFrame.y) * localUV.y
        )
    }

    private func refocusCamera() {
        cameraYaw = .pi / 4
        cameraPitch = -.pi / 7
        let distance = max(4, meshBounds.radius * 1.6 + 4)
        let forward = viewForward()
        cameraPosition = meshBounds.center - forward * distance
    }

    private func setKeyState(_ key: SDL_Keycode, pressed: Bool) {
        if keyMatches(key, action: .moveForward) {
            keyForward = pressed
        }
        if keyMatches(key, action: .moveLeft) {
            keyLeft = pressed
        }
        if keyMatches(key, action: .moveBackward) {
            keyBackward = pressed
        }
        if keyMatches(key, action: .moveRight) {
            keyRight = pressed
        }
        if keyMatches(key, action: .moveUp) {
            keyUp = pressed
        }
        if keyMatches(key, action: .moveDown) {
            keyDown = pressed
        }
        if keyMatches(key, action: .fastMove) {
            keyFastMove = pressed
        }
    }

    private func keyMatches(_ key: SDL_Keycode, action: KeybindAction) -> Bool {
        key == (keycodeForAction?(action) ?? action.defaultValue.keycode)
    }

    private func viewForward() -> SIMD3<Float> {
        let cp = cos(cameraPitch)
        return normalizeOrZero(SIMD3<Float>(
            x: cos(cameraYaw) * cp,
            y: sin(cameraPitch),
            z: sin(cameraYaw) * cp
        ))
    }

    private func normalizeOrZero(_ v: SIMD3<Float>) -> SIMD3<Float> {
        let lenSq = simd_length_squared(v)
        if lenSq <= 1e-8 {
            return .zero
        }
        return v / sqrt(lenSq)
    }

    private func simd_length_squared(_ v: SIMD3<Float>) -> Float {
        simd_dot(v, v)
    }

    private func simd_dot(_ lhs: SIMD3<Float>, _ rhs: SIMD3<Float>) -> Float {
        lhs.x * rhs.x + lhs.y * rhs.y + lhs.z * rhs.z
    }

    private func simd_normalize(_ v: SIMD3<Float>) -> SIMD3<Float> {
        let length = sqrt(simd_length_squared(v))
        if length <= 0 {
            return .zero
        }
        return v / length
    }

    private func simd_cross(_ lhs: SIMD3<Float>, _ rhs: SIMD3<Float>) -> SIMD3<Float> {
        SIMD3<Float>(
            lhs.y * rhs.z - lhs.z * rhs.y,
            lhs.z * rhs.x - lhs.x * rhs.z,
            lhs.x * rhs.y - lhs.y * rhs.x
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
