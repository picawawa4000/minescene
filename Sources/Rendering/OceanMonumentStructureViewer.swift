import Foundation
import SwiftSDL
import Vulkan
import DPReader

final class OceanMonumentStructureViewer {
    private struct RenderBlock {
        let blockID: String
        let position: SIMD3<Int>
        let textureName: String
        let tint: SIMD4<Float>
        let isOpaque: Bool
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

    private let structureRenderer: StructureRenderer
    private var prepared = false

    init(repository: VanillaAssetRepository) {
        self.structureRenderer = StructureRenderer(repository: repository)
    }

    var keycodeForAction: ((KeybindAction) -> SDL_Keycode)? {
        get { structureRenderer.keycodeForAction }
        set { structureRenderer.keycodeForAction = newValue }
    }

    func prepare(engine: VulkanEngine) throws {
        guard !prepared else {
            return
        }

        let worldSeed: UInt64 = 123_456_789
        let startChunk = PosInt2D(x: 0, z: 0)
        let result = OceanMonument.generate(
            worldSeed: worldSeed,
            startChunk: startChunk,
            context: OceanMonumentGenerationContext(
                seaLevel: 63,
                minimumWorldY: -64,
                blockSampler: { _ in BlockState(type: Block(withID: "minecraft:air")) }
            )
        )
        let origin = SIMD3<Int32>(
            result.graph.boundingBox.minX,
            result.graph.boundingBox.minY,
            result.graph.boundingBox.minZ
        )

        var blocks: [RenderBlock] = []
        blocks.reserveCapacity(result.blocks.allTouchedBlocks().count)
        var unsupportedBlockIDs: Set<String> = []

        for (position, state) in result.blocks.allTouchedBlocks() {
            guard let block = makeBlockInstance(
                blockID: state.type.id,
                position: position,
                origin: origin
            ) else {
                if state.type.id != "minecraft:air" {
                    unsupportedBlockIDs.insert(state.type.id)
                }
                continue
            }
            blocks.append(block)
        }

        let quads = buildQuads(from: blocks)
        try structureRenderer.setQuads(quads, engine: engine)
        prepared = true

        let summary = """
        Prepared ocean monument structure viewer with \(blocks.count) blocks and \(quads.count) quads, \(result.graph.pieces.count) pieces, orientation \(result.graph.orientation.rawValue), seed \(worldSeed), start chunk (0, 0), normalized origin (\(origin.x), \(origin.y), \(origin.z))
        """
        FileHandle.standardError.write(Data((summary + "\n").utf8))
        if !unsupportedBlockIDs.isEmpty {
            let skippedList = unsupportedBlockIDs.sorted().joined(separator: ", ")
            let message = "Ocean monument viewer skipped unsupported block ids: \(skippedList)\n"
            FileHandle.standardError.write(Data(message.utf8))
        }
        if !result.elderGuardians.isEmpty {
            let message = "Ocean monument viewer omitted \(result.elderGuardians.count) elder guardians because DPReader only exposes their positions.\n"
            FileHandle.standardError.write(Data(message.utf8))
        }
    }

    func handleEvent(_ event: SDL_Event, window _: OpaquePointer?) {
        structureRenderer.handleEvent(event)
    }

    func update(deltaTime: Float) {
        structureRenderer.update(deltaTime: deltaTime)
    }

    func render(
        engine: VulkanEngine,
        window: OpaquePointer?,
        imageAvailable: VkSemaphore,
        renderFinishedByImage: [VkSemaphore]
    ) throws {
        try prepare(engine: engine)
        try structureRenderer.render(
            engine: engine,
            window: window,
            imageAvailable: imageAvailable,
            renderFinishedByImage: renderFinishedByImage
        )
    }

    private func makeBlockInstance(
        blockID: String,
        position: PosInt3D,
        origin: SIMD3<Int32>
    ) -> RenderBlock? {
        guard blockID != "minecraft:air" else {
            return nil
        }

        let localPosition = SIMD3<Int>(
            Int(position.x - origin.x),
            Int(position.y - origin.y),
            Int(position.z - origin.z)
        )

        switch blockID {
        case "minecraft:prismarine":
            return .init(
                blockID: blockID,
                position: localPosition,
                textureName: "minecraft:block/prismarine",
                tint: SIMD4<Float>(repeating: 1),
                isOpaque: true
            )
        case "minecraft:prismarine_bricks":
            return .init(
                blockID: blockID,
                position: localPosition,
                textureName: "minecraft:block/prismarine_bricks",
                tint: SIMD4<Float>(repeating: 1),
                isOpaque: true
            )
        case "minecraft:dark_prismarine":
            return .init(
                blockID: blockID,
                position: localPosition,
                textureName: "minecraft:block/dark_prismarine",
                tint: SIMD4<Float>(repeating: 1),
                isOpaque: true
            )
        case "minecraft:sea_lantern":
            return .init(
                blockID: blockID,
                position: localPosition,
                textureName: "minecraft:block/sea_lantern",
                tint: SIMD4<Float>(repeating: 1),
                isOpaque: true
            )
        case "minecraft:gold_block":
            return .init(
                blockID: blockID,
                position: localPosition,
                textureName: "minecraft:block/gold_block",
                tint: SIMD4<Float>(repeating: 1),
                isOpaque: true
            )
        case "minecraft:wet_sponge":
            return .init(
                blockID: blockID,
                position: localPosition,
                textureName: "minecraft:block/wet_sponge",
                tint: SIMD4<Float>(repeating: 1),
                isOpaque: true
            )
        case "minecraft:water":
            return .init(
                blockID: blockID,
                position: localPosition,
                textureName: "minecraft:block/water_still",
                tint: SIMD4<Float>(1, 1, 1, 0.55),
                isOpaque: false
            )
        default:
            return nil
        }
    }

    private func buildQuads(from blocks: [RenderBlock]) -> [StructureRenderer.TexturedQuad] {
        let blocksByPosition = Dictionary(uniqueKeysWithValues: blocks.map { ($0.position, $0) })
        var quads: [StructureRenderer.TexturedQuad] = []
        quads.reserveCapacity(blocks.count * 3)

        for block in blocks {
            let origin = SIMD3<Float>(
                Float(block.position.x),
                Float(block.position.y),
                Float(block.position.z)
            )
            for face in Face.allCases {
                let neighborPosition = block.position &+ face.neighborOffset
                if let neighbor = blocksByPosition[neighborPosition],
                   shouldCull(faceBetween: block, and: neighbor) {
                    continue
                }
                quads.append(
                    StructureRenderer.TexturedQuad(
                        corners: face.corners(at: origin),
                        textureName: block.textureName,
                        tint: block.tint
                    )
                )
            }
        }

        return quads
    }

    private func shouldCull(faceBetween block: RenderBlock, and neighbor: RenderBlock) -> Bool {
        if block.isOpaque && neighbor.isOpaque {
            return true
        }
        if block.blockID == "minecraft:water" && neighbor.blockID == "minecraft:water" {
            return true
        }
        return false
    }
}
