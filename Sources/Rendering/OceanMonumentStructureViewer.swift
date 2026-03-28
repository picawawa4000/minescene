import Foundation
import SwiftSDL
import Vulkan
import DPReader

final class OceanMonumentStructureViewer {
    enum Error: Swift.Error {
        case biomeUnavailable(PosInt3D)
        case monumentPlacementNotFound(PosInt2D)
        case resolvedStructureMissing(PosInt2D)
        case unexpectedResolvedStructure(String)
    }

    static let structureSeed: Int64 = 123_456_789
    static let targetLocateBlockPosition = PosInt2D(x: 1200, z: 0)
    static let terrainChunkRadius: Int32 = 8

    private struct RenderBlock {
        let blockID: String
        let position: SIMD3<Int>
        let textureName: String
        let tint: SIMD4<Float>
        let isOpaque: Bool
    }

    private enum WorldBlockKind {
        case air
        case terrain
        case water
    }

    private struct ChunkKey: Hashable {
        let x: Int32
        let z: Int32
    }

    private final class GeneratedWorldSampler {
        private let worldGenerator: WorldGenerator
        private let seaLevel: Int32
        private let minimumWorldY: Int32
        private var chunks: [ChunkKey: ProtoChunk] = [:]

        init(worldGenerator: WorldGenerator, seaLevel: Int32, minimumWorldY: Int32) {
            self.worldGenerator = worldGenerator
            self.seaLevel = seaLevel
            self.minimumWorldY = minimumWorldY
        }

        func kind(at pos: PosInt3D) throws -> WorldBlockKind {
            if pos.y <= self.minimumWorldY + 1 {
                return .terrain
            }

            let chunkPos = PosInt2D(
                x: OceanMonumentStructureViewer.floorDiv(pos.x, by: Int32(ProtoChunk.sideLength)),
                z: OceanMonumentStructureViewer.floorDiv(pos.z, by: Int32(ProtoChunk.sideLength))
            )
            let chunk = try self.chunk(at: chunkPos)

            if pos.y < chunk.minY {
                return .terrain
            }
            if pos.y >= chunk.minY + chunk.height {
                return pos.y <= self.seaLevel ? .water : .air
            }

            let localPos = PosInt3D(
                x: pos.x - chunkPos.x * Int32(ProtoChunk.sideLength),
                y: pos.y - chunk.minY,
                z: pos.z - chunkPos.z * Int32(ProtoChunk.sideLength)
            )
            if chunk.isTerrain(atLocal: localPos) {
                return .terrain
            }
            return pos.y <= self.seaLevel ? .water : .air
        }

        func block(at pos: PosInt3D) throws -> BlockState {
            switch try self.kind(at: pos) {
            case .terrain:
                return BlockState(type: Block(withID: "minecraft:stone"))
            case .water:
                return BlockState(type: Block(withID: "minecraft:water"))
            case .air:
                return BlockState(type: Block(withID: "minecraft:air"))
            }
        }

        func chunk(at chunkPos: PosInt2D) throws -> ProtoChunk {
            let key = ChunkKey(x: chunkPos.x, z: chunkPos.z)
            if let cached = self.chunks[key] {
                return cached
            }

            let generated = ProtoChunk()
            try self.worldGenerator.generateInto(generated, at: chunkPos)
            self.chunks[key] = generated
            return generated
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
    private let worldGenerator: WorldGenerator
    private let structurePlacementSampler: StructurePlacementSampler
    private let overworldDimensionKey = RegistryKey<DPReader.Dimension>(referencing: "minecraft:overworld")
    private let oceanMonumentStructureSetKey = RegistryKey<StructureSet>(referencing: "minecraft:ocean_monuments")
    private var prepared = false

    init(
        repository: VanillaAssetRepository,
        worldGenerator: WorldGenerator,
        structurePlacementSampler: StructurePlacementSampler
    ) {
        self.structureRenderer = StructureRenderer(repository: repository)
        self.worldGenerator = worldGenerator
        self.structurePlacementSampler = structurePlacementSampler
    }

    var keycodeForAction: ((KeybindAction) -> SDL_Keycode)? {
        get { structureRenderer.keycodeForAction }
        set { structureRenderer.keycodeForAction = newValue }
    }

    func prepare(engine: VulkanEngine) throws {
        guard !prepared else {
            return
        }

        let worldSeed = UInt64(bitPattern: Self.structureSeed)
        let regionPos = PosInt2D(
            x: Self.floorDiv(Self.floorDiv(Self.targetLocateBlockPosition.x, by: 16), by: 32),
            z: Self.floorDiv(Self.floorDiv(Self.targetLocateBlockPosition.z, by: 16), by: 32)
        )
        guard let placementSample = try structurePlacementSampler.sampleStructureSet(
            inRegion: regionPos,
            for: oceanMonumentStructureSetKey
        ) else {
            throw Error.monumentPlacementNotFound(regionPos)
        }
        let biomeSamplePos = PosInt3D(x: placementSample.blockPos.x, y: 63, z: placementSample.blockPos.z)
        guard let biome = try worldGenerator.sampleBlockBiome(at: biomeSamplePos, in: overworldDimensionKey) else {
            throw Error.biomeUnavailable(biomeSamplePos)
        }
        guard let resolvedPlacement = try structurePlacementSampler.resolveStructureSet(
            inRegion: regionPos,
            biome: biome,
            for: oceanMonumentStructureSetKey
        ) else {
            throw Error.resolvedStructureMissing(regionPos)
        }
        guard resolvedPlacement.structureKey.name == "minecraft:monument" else {
            throw Error.unexpectedResolvedStructure(resolvedPlacement.structureKey.name)
        }
        let startChunk = resolvedPlacement.chunkPos
        let generatedWorldSampler = GeneratedWorldSampler(
            worldGenerator: worldGenerator,
            seaLevel: 63,
            minimumWorldY: -64
        )
        let result = OceanMonument.generate(
            worldSeed: worldSeed,
            startChunk: startChunk,
            context: OceanMonumentGenerationContext(
                seaLevel: 63,
                minimumWorldY: -64,
                blockSampler: { pos in
                    (try? generatedWorldSampler.block(at: pos)) ?? BlockState(type: Block(withID: "minecraft:air"))
                }
            )
        )
        let origin = SIMD3<Int32>(
            result.graph.boundingBox.minX,
            result.graph.boundingBox.minY,
            result.graph.boundingBox.minZ
        )
        let terrainBlocks = try generateTerrainBlocks(
            centeredOn: startChunk,
            radiusChunks: Self.terrainChunkRadius,
            sampler: generatedWorldSampler
        )
        var blocksByPosition = Dictionary(uniqueKeysWithValues: terrainBlocks.map { ($0.position, $0) })
        var unsupportedBlockIDs: Set<String> = []

        for (position, state) in result.blocks.allTouchedBlocks() {
            let worldPosition = SIMD3<Int>(Int(position.x), Int(position.y), Int(position.z))
            guard let block = makeMonumentBlockInstance(blockID: state.type.id, position: worldPosition) else {
                if state.type.id == "minecraft:air" {
                    blocksByPosition.removeValue(forKey: worldPosition)
                } else {
                    unsupportedBlockIDs.insert(state.type.id)
                }
                continue
            }
            blocksByPosition[worldPosition] = block
        }

        let renderOrigin = blocksByPosition.keys.reduce(
            SIMD3<Int>(
                Int(origin.x),
                Int(origin.y),
                Int(origin.z)
            )
        ) { partialResult, position in
            SIMD3<Int>(
                Swift.min(partialResult.x, position.x),
                Swift.min(partialResult.y, position.y),
                Swift.min(partialResult.z, position.z)
            )
        }
        let blocks = blocksByPosition.values.map { block in
            RenderBlock(
                blockID: block.blockID,
                position: block.position &- renderOrigin,
                textureName: block.textureName,
                tint: block.tint,
                isOpaque: block.isOpaque
            )
        }
        let quads = buildQuads(from: blocks)
        try structureRenderer.setQuads(quads, engine: engine)
        prepared = true

        let summary = """
        Prepared ocean monument structure viewer with \(blocks.count) blocks and \(quads.count) quads, \(terrainBlocks.count) terrain-shell blocks, chunk radius \(Self.terrainChunkRadius), \(result.graph.pieces.count) pieces, orientation \(result.graph.orientation.rawValue), seed \(worldSeed), start chunk (\(startChunk.x), \(startChunk.z)), locate block (\(placementSample.blockPos.x), \(placementSample.blockPos.z)), normalized origin (\(renderOrigin.x), \(renderOrigin.y), \(renderOrigin.z))
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

    private func generateTerrainBlocks(
        centeredOn centerChunk: PosInt2D,
        radiusChunks: Int32,
        sampler: GeneratedWorldSampler
    ) throws -> [RenderBlock] {
        let minChunkX = centerChunk.x - radiusChunks
        let maxChunkX = centerChunk.x + radiusChunks
        let minChunkZ = centerChunk.z - radiusChunks
        let maxChunkZ = centerChunk.z + radiusChunks
        let minWorldX = minChunkX * Int32(ProtoChunk.sideLength)
        let maxWorldXExclusive = (maxChunkX + 1) * Int32(ProtoChunk.sideLength)
        let minWorldZ = minChunkZ * Int32(ProtoChunk.sideLength)
        let maxWorldZExclusive = (maxChunkZ + 1) * Int32(ProtoChunk.sideLength)

        var blocks: [RenderBlock] = []

        for chunkZ in minChunkZ...maxChunkZ {
            for chunkX in minChunkX...maxChunkX {
                let chunkPos = PosInt2D(x: chunkX, z: chunkZ)
                let chunk = try sampler.chunk(at: chunkPos)
                let chunkStartX = chunkPos.x * Int32(ProtoChunk.sideLength)
                let chunkStartZ = chunkPos.z * Int32(ProtoChunk.sideLength)

                for localY in 0..<chunk.height {
                    let worldY = chunk.minY + localY
                    for localZ in 0..<Int32(ProtoChunk.sideLength) {
                        for localX in 0..<Int32(ProtoChunk.sideLength) {
                            let worldPosition = PosInt3D(
                                x: chunkStartX + localX,
                                y: worldY,
                                z: chunkStartZ + localZ
                            )
                            let localPosition = PosInt3D(x: localX, y: localY, z: localZ)
                            let blockKind: WorldBlockKind = chunk.isTerrain(atLocal: localPosition)
                                ? .terrain
                                : (worldY <= 63 ? .water : .air)
                            guard blockKind != .air else {
                                continue
                            }
                            guard try shouldRenderTerrainBlock(
                                kind: blockKind,
                                at: worldPosition,
                                minWorldX: minWorldX,
                                maxWorldXExclusive: maxWorldXExclusive,
                                minWorldZ: minWorldZ,
                                maxWorldZExclusive: maxWorldZExclusive,
                                sampler: sampler
                            ) else {
                                continue
                            }
                            if let block = makeTerrainBlockInstance(kind: blockKind, position: worldPosition) {
                                blocks.append(block)
                            }
                        }
                    }
                }
            }
        }

        return blocks
    }

    private func shouldRenderTerrainBlock(
        kind: WorldBlockKind,
        at worldPosition: PosInt3D,
        minWorldX: Int32,
        maxWorldXExclusive: Int32,
        minWorldZ: Int32,
        maxWorldZExclusive: Int32,
        sampler: GeneratedWorldSampler
    ) throws -> Bool {
        for face in Face.allCases {
            let neighborWorldPosition = PosInt3D(
                x: worldPosition.x + Int32(face.neighborOffset.x),
                y: worldPosition.y + Int32(face.neighborOffset.y),
                z: worldPosition.z + Int32(face.neighborOffset.z)
            )
            let neighborKind: WorldBlockKind
            if neighborWorldPosition.x < minWorldX
                || neighborWorldPosition.x >= maxWorldXExclusive
                || neighborWorldPosition.z < minWorldZ
                || neighborWorldPosition.z >= maxWorldZExclusive {
                neighborKind = .air
            } else {
                neighborKind = try sampler.kind(at: neighborWorldPosition)
            }

            switch kind {
            case .terrain:
                if neighborKind != .terrain {
                    return true
                }
            case .water:
                if neighborKind == .air {
                    return true
                }
            case .air:
                continue
            }
        }
        return false
    }

    private func makeTerrainBlockInstance(kind: WorldBlockKind, position: PosInt3D) -> RenderBlock? {
        let worldPosition = SIMD3<Int>(Int(position.x), Int(position.y), Int(position.z))
        switch kind {
        case .terrain:
            return .init(
                blockID: "minecraft:stone",
                position: worldPosition,
                textureName: "minecraft:block/stone",
                tint: SIMD4<Float>(repeating: 1),
                isOpaque: true
            )
        case .water:
            return .init(
                blockID: "minecraft:water",
                position: worldPosition,
                textureName: "minecraft:block/water_still",
                tint: SIMD4<Float>(1, 1, 1, 0.55),
                isOpaque: false
            )
        case .air:
            return nil
        }
    }

    private func makeMonumentBlockInstance(
        blockID: String,
        position: SIMD3<Int>
    ) -> RenderBlock? {
        guard blockID != "minecraft:air" else {
            return nil
        }

        switch blockID {
        case "minecraft:prismarine":
            return .init(
                blockID: blockID,
                position: position,
                textureName: "minecraft:block/prismarine",
                tint: SIMD4<Float>(repeating: 1),
                isOpaque: true
            )
        case "minecraft:prismarine_bricks":
            return .init(
                blockID: blockID,
                position: position,
                textureName: "minecraft:block/prismarine_bricks",
                tint: SIMD4<Float>(repeating: 1),
                isOpaque: true
            )
        case "minecraft:dark_prismarine":
            return .init(
                blockID: blockID,
                position: position,
                textureName: "minecraft:block/dark_prismarine",
                tint: SIMD4<Float>(repeating: 1),
                isOpaque: true
            )
        case "minecraft:sea_lantern":
            return .init(
                blockID: blockID,
                position: position,
                textureName: "minecraft:block/sea_lantern",
                tint: SIMD4<Float>(repeating: 1),
                isOpaque: true
            )
        case "minecraft:gold_block":
            return .init(
                blockID: blockID,
                position: position,
                textureName: "minecraft:block/gold_block",
                tint: SIMD4<Float>(repeating: 1),
                isOpaque: true
            )
        case "minecraft:wet_sponge":
            return .init(
                blockID: blockID,
                position: position,
                textureName: "minecraft:block/wet_sponge",
                tint: SIMD4<Float>(repeating: 1),
                isOpaque: true
            )
        case "minecraft:water":
            return .init(
                blockID: blockID,
                position: position,
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
        if block.blockID == "minecraft:water"
            && (neighbor.blockID == "minecraft:water" || neighbor.isOpaque) {
            return true
        }
        return false
    }

    private static func floorDiv(_ value: Int32, by divisor: Int32) -> Int32 {
        precondition(divisor > 0)
        let quotient = value / divisor
        let remainder = value % divisor
        return remainder < 0 ? quotient - 1 : quotient
    }
}
