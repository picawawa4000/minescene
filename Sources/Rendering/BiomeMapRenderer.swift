import Foundation
import DPReader
import simd

struct BiomePixelMap {
    let width: Int
    let height: Int
    let pixelsRGBA8: [UInt8]
}

enum BiomeMapRendererError: Error {
    case invalidSize
    case biomeSamplingUnavailable
}

final class BiomeQuadTreeCache {
    struct TreeKey: Hashable {
        let scale: Int
        let sampleY: Int
    }

    struct PendingKey: Hashable {
        let tileXIndex: Int
        let tileZIndex: Int
        let tree: TreeKey
    }

    private final class QuadNode {
        let originX: Int
        let originZ: Int
        let size: Int
        var tile: BiomePixelMap?
        var children: [QuadNode?]

        init(originX: Int, originZ: Int, size: Int) {
            self.originX = originX
            self.originZ = originZ
            self.size = size
            self.children = [nil, nil, nil, nil]
        }

        func contains(_ x: Int, _ z: Int) -> Bool {
            x >= originX && x < originX + size && z >= originZ && z < originZ + size
        }
    }

    private final class QuadTree {
        private var root: QuadNode?

        func value(at x: Int, _ z: Int) -> BiomePixelMap? {
            guard let root else { return nil }
            return value(in: root, x: x, z: z)
        }

        func insert(_ value: BiomePixelMap, at x: Int, _ z: Int) {
            if root == nil {
                let node = QuadNode(originX: x, originZ: z, size: 1)
                node.tile = value
                root = node
                return
            }
            while let root, !root.contains(x, z) {
                self.root = expandedRoot(containing: x, z, from: root)
            }
            if let root {
                insert(value, in: root, x: x, z: z)
            }
        }

        private func value(in node: QuadNode, x: Int, z: Int) -> BiomePixelMap? {
            if !node.contains(x, z) { return nil }
            if node.size == 1 { return node.tile }
            let (index, _, _) = childIndexAndOrigin(for: node, x: x, z: z)
            guard let child = node.children[index] else { return nil }
            return value(in: child, x: x, z: z)
        }

        private func insert(_ value: BiomePixelMap, in node: QuadNode, x: Int, z: Int) {
            if node.size == 1 {
                node.tile = value
                return
            }
            let (index, childOriginX, childOriginZ) = childIndexAndOrigin(for: node, x: x, z: z)
            let child: QuadNode
            if let existing = node.children[index] {
                child = existing
            } else {
                child = QuadNode(originX: childOriginX, originZ: childOriginZ, size: node.size / 2)
                node.children[index] = child
            }
            insert(value, in: child, x: x, z: z)
        }

        private func expandedRoot(containing x: Int, _ z: Int, from oldRoot: QuadNode) -> QuadNode {
            let oldSize = oldRoot.size
            let newSize = oldSize * 2
            let newOriginX = x < oldRoot.originX ? oldRoot.originX - oldSize : oldRoot.originX
            let newOriginZ = z < oldRoot.originZ ? oldRoot.originZ - oldSize : oldRoot.originZ
            let newRoot = QuadNode(originX: newOriginX, originZ: newOriginZ, size: newSize)
            let oldInEast = oldRoot.originX >= newOriginX + oldSize
            let oldInSouth = oldRoot.originZ >= newOriginZ + oldSize
            let childIndex = (oldInSouth ? 2 : 0) + (oldInEast ? 1 : 0)
            newRoot.children[childIndex] = oldRoot
            return newRoot
        }

        private func childIndexAndOrigin(for node: QuadNode, x: Int, z: Int) -> (Int, Int, Int) {
            let half = node.size / 2
            let splitX = node.originX + half
            let splitZ = node.originZ + half
            let east = x >= splitX
            let south = z >= splitZ
            let index = (south ? 2 : 0) + (east ? 1 : 0)
            let childOriginX = east ? splitX : node.originX
            let childOriginZ = south ? splitZ : node.originZ
            return (index, childOriginX, childOriginZ)
        }
    }

    let tileSize: Int
    private let lockQueue = DispatchQueue(label: "BiomeTileCache.lock", attributes: .concurrent)
    private let workerQueue = DispatchQueue(label: "BiomeTileCache.worker", qos: .userInitiated)
    private var trees: [TreeKey: QuadTree] = [:]
    private var pending: Set<PendingKey> = []
    private var version: UInt64 = 0
    private let placeholderColor: (UInt8, UInt8, UInt8, UInt8) = (255, 0, 255, 255)

    init(tileSize: Int = 256) {
        self.tileSize = tileSize
    }

    func mapAsync(
        worldGenerator: WorldGenerator,
        topLeftX: Int,
        topLeftZ: Int,
        width: Int,
        height: Int,
        scale: Int,
        sampleY: Int = 256
    ) throws -> (map: BiomePixelMap, tileOriginX: Int, tileOriginZ: Int, version: UInt64, isComplete: Bool) {
        guard width > 0, height > 0 else {
            throw BiomeMapRendererError.invalidSize
        }
        guard scale > 0 else {
            throw BiomeMapRendererError.invalidSize
        }

        let treeKey = TreeKey(scale: scale, sampleY: sampleY)
        let tileWorldSize = tileSize * scale
        let tileOriginXIndex = BiomeQuadTreeCache.floorDiv(topLeftX, tileWorldSize)
        let tileOriginZIndex = BiomeQuadTreeCache.floorDiv(topLeftZ, tileWorldSize)
        let tileOriginX = tileOriginXIndex * tileWorldSize
        let tileOriginZ = tileOriginZIndex * tileWorldSize
        let tilesX = (width + tileSize - 1) / tileSize
        let tilesZ = (height + tileSize - 1) / tileSize

        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        var isComplete = true

        for tz in 0..<tilesZ {
            for tx in 0..<tilesX {
                let tileXIndex = tileOriginXIndex + tx
                let tileZIndex = tileOriginZIndex + tz
                let tileWorldX = tileXIndex * tileWorldSize
                let tileWorldZ = tileZIndex * tileWorldSize
                let tile: BiomePixelMap?
                tile = lockQueue.sync {
                    trees[treeKey]?.value(at: tileXIndex, tileZIndex)
                }
                if tile == nil {
                    isComplete = false
                    scheduleTileGeneration(
                        tileXIndex: tileXIndex,
                        tileZIndex: tileZIndex,
                        treeKey: treeKey,
                        worldGenerator: worldGenerator,
                        topLeftX: tileWorldX,
                        topLeftZ: tileWorldZ,
                        scale: scale,
                        sampleY: sampleY
                    )
                }

                let copyWidth = min(tileSize, width - tx * tileSize)
                let copyHeight = min(tileSize, height - tz * tileSize)
                for y in 0..<copyHeight {
                    let destRow = (tz * tileSize + y) * width * 4
                    let destStart = destRow + tx * tileSize * 4
                    let count = copyWidth * 4
                    if let tile {
                        let srcRow = y * tile.width * 4
                        let srcStart = srcRow
                        pixels.replaceSubrange(destStart..<(destStart + count), with: tile.pixelsRGBA8[srcStart..<(srcStart + count)])
                    } else {
                        for i in 0..<copyWidth {
                            let base = destStart + i * 4
                            pixels[base] = placeholderColor.0
                            pixels[base + 1] = placeholderColor.1
                            pixels[base + 2] = placeholderColor.2
                            pixels[base + 3] = placeholderColor.3
                        }
                    }
                }
            }
        }

        let map = BiomePixelMap(width: width, height: height, pixelsRGBA8: pixels)
        let currentVersion = lockQueue.sync { version }
        return (map, tileOriginX, tileOriginZ, currentVersion, isComplete)
    }

    private func scheduleTileGeneration(
        tileXIndex: Int,
        tileZIndex: Int,
        treeKey: TreeKey,
        worldGenerator: WorldGenerator,
        topLeftX: Int,
        topLeftZ: Int,
        scale: Int,
        sampleY: Int
    ) {
        let pendingKey = PendingKey(tileXIndex: tileXIndex, tileZIndex: tileZIndex, tree: treeKey)
        let shouldSchedule: Bool = lockQueue.sync { !pending.contains(pendingKey) }
        guard shouldSchedule else { return }
        lockQueue.async(flags: .barrier) {
            self.pending.insert(pendingKey)
        }
        workerQueue.async { [weak self] in
            guard let self else { return }
            let generated: BiomePixelMap?
            generated = try? BiomeMapRenderer.render(
                worldGenerator: worldGenerator,
                topLeftX: topLeftX,
                topLeftZ: topLeftZ,
                width: self.tileSize,
                height: self.tileSize,
                scale: scale,
                sampleY: sampleY
            )
            self.lockQueue.async(flags: .barrier) {
                if let generated {
                    let tree = self.trees[treeKey] ?? QuadTree()
                    tree.insert(generated, at: tileXIndex, tileZIndex)
                    self.trees[treeKey] = tree
                    self.version &+= 1
                }
                self.pending.remove(pendingKey)
            }
        }
    }

    private static func floorDiv(_ value: Int, _ divisor: Int) -> Int {
        if value >= 0 {
            return value / divisor
        }
        return -(((-value) + divisor - 1) / divisor)
    }
}

struct BiomeMapRenderer {
    private static let biomeColors: [String: (UInt8, UInt8, UInt8, UInt8)] = [
        "minecraft:badlands": (200, 120, 60, 255),
        "minecraft:bamboo_jungle": (40, 170, 70, 255),
        "minecraft:basalt_deltas": (60, 60, 60, 255),
        "minecraft:beach": (230, 220, 170, 255),
        "minecraft:birch_forest": (80, 170, 80, 255),
        "minecraft:cherry_grove": (220, 160, 180, 255),
        "minecraft:cold_ocean": (40, 80, 180, 255),
        "minecraft:crimson_forest": (130, 20, 20, 255),
        "minecraft:dark_forest": (20, 80, 20, 255),
        "minecraft:deep_cold_ocean": (30, 70, 150, 255),
        "minecraft:deep_dark": (20, 30, 35, 255),
        "minecraft:deep_frozen_ocean": (90, 130, 200, 255),
        "minecraft:deep_lukewarm_ocean": (50, 140, 190, 255),
        "minecraft:deep_ocean": (20, 50, 120, 255),
        "minecraft:desert": (235, 220, 130, 255),
        "minecraft:dripstone_caves": (150, 120, 90, 255),
        "minecraft:end_barrens": (170, 180, 100, 255),
        "minecraft:end_highlands": (190, 200, 110, 255),
        "minecraft:end_midlands": (190, 200, 110, 255),
        "minecraft:eroded_badlands": (190, 110, 55, 255),
        "minecraft:flower_forest": (60, 170, 60, 255),
        "minecraft:forest": (34, 139, 34, 255),
        "minecraft:frozen_ocean": (120, 170, 230, 255),
        "minecraft:frozen_peaks": (210, 225, 240, 255),
        "minecraft:frozen_river": (160, 200, 255, 255),
        "minecraft:grove": (180, 220, 180, 255),
        "minecraft:ice_spikes": (200, 230, 255, 255),
        "minecraft:jagged_peaks": (200, 210, 230, 255),
        "minecraft:jungle": (30, 150, 50, 255),
        "minecraft:lukewarm_ocean": (60, 170, 210, 255),
        "minecraft:lush_caves": (60, 150, 80, 255),
        "minecraft:mangrove_swamp": (80, 100, 50, 255),
        "minecraft:meadow": (90, 180, 90, 255),
        "minecraft:mushroom_fields": (160, 80, 160, 255),
        "minecraft:nether_wastes": (160, 60, 40, 255),
        "minecraft:ocean": (30, 70, 160, 255),
        "minecraft:old_growth_birch_forest": (60, 150, 70, 255),
        "minecraft:old_growth_pine_taiga": (50, 110, 90, 255),
        "minecraft:old_growth_spruce_taiga": (45, 100, 85, 255),
        "minecraft:pale_garden": (140, 150, 140, 255),
        "minecraft:plains": (120, 180, 70, 255),
        "minecraft:river": (60, 110, 200, 255),
        "minecraft:savanna": (180, 180, 80, 255),
        "minecraft:savanna_plateau": (170, 170, 70, 255),
        "minecraft:small_end_islands": (180, 190, 105, 255),
        "minecraft:snowy_beach": (230, 240, 250, 255),
        "minecraft:snowy_plains": (230, 240, 250, 255),
        "minecraft:snowy_slopes": (220, 230, 240, 255),
        "minecraft:snowy_taiga": (190, 210, 220, 255),
        "minecraft:soul_sand_valley": (100, 80, 60, 255),
        "minecraft:sparse_jungle": (50, 160, 60, 255),
        "minecraft:stony_peaks": (130, 130, 130, 255),
        "minecraft:stony_shore": (120, 120, 120, 255),
        "minecraft:sunflower_plains": (130, 190, 75, 255),
        "minecraft:swamp": (70, 90, 50, 255),
        "minecraft:taiga": (60, 120, 100, 255),
        "minecraft:the_end": (200, 210, 120, 255),
        "minecraft:the_void": (0, 0, 0, 255),
        "minecraft:warm_ocean": (70, 200, 220, 255),
        "minecraft:warped_forest": (30, 130, 120, 255),
        "minecraft:windswept_forest": (70, 130, 90, 255),
        "minecraft:windswept_gravelly_hills": (110, 110, 110, 255),
        "minecraft:windswept_hills": (120, 120, 120, 255),
        "minecraft:windswept_savanna": (160, 160, 70, 255),
        "minecraft:wooded_badlands": (210, 130, 70, 255),
    ]
    private static let fallbackColor: (UInt8, UInt8, UInt8, UInt8) = (255, 0, 255, 255)

    static func render(
        worldGenerator: WorldGenerator,
        topLeftX: Int,
        topLeftZ: Int,
        width: Int,
        height: Int,
        scale: Int = 4,
        dimension: DPReader.RegistryKey<DPReader.Dimension> = DPReader.RegistryKey<DPReader.Dimension>(referencing: "minecraft:overworld"),
        sampleY: Int = 256
    ) throws -> BiomePixelMap {
        let _ = dimension
        guard width > 0, height > 0 else {
            throw BiomeMapRendererError.invalidSize
        }
        guard scale > 0 else {
            throw BiomeMapRendererError.invalidSize
        }

        let scaleI = Int32(scale)
        let fromScaledX = floorDiv(Int32(topLeftX), scaleI)
        let fromScaledZ = floorDiv(Int32(topLeftZ), scaleI)
        let toScaledX = ceilDiv(Int32(topLeftX + width * scale), scaleI)
        let toScaledZ = ceilDiv(Int32(topLeftZ + height * scale), scaleI)

        let alignedFromX = Int(fromScaledX * scaleI)
        let alignedFromZ = Int(fromScaledZ * scaleI)
        let alignedToX = Int(toScaledX * scaleI)
        let alignedToZ = Int(toScaledZ * scaleI)

        let fromPos = makePosInt2D(x: alignedFromX, z: alignedFromZ)
        let toPos = makePosInt2D(x: alignedToX, z: alignedToZ)
        let overworld = DPReader.RegistryKey<DPReader.Dimension>(referencing: "minecraft:overworld")
        let biomes = try worldGenerator.generateBiomesInSquare(
            from: fromPos,
            to: toPos,
            atY: Int32(sampleY),
            in: overworld,
            scale: Int32(scale)
        )

        let sampleWidth = Int(toScaledX - fromScaledX)

        var pixels = [UInt8]()
        pixels.reserveCapacity(width * height * 4)

        for z in 0..<height {
            for x in 0..<width {
                let biomeKey: DPReader.RegistryKey<DPReader.Biome>?
                if let biomes {
                    let worldX = topLeftX + x * scale
                    let worldZ = topLeftZ + z * scale
                    let sampleX = Int(floorDiv(Int32(worldX), scaleI) - fromScaledX)
                    let sampleZ = Int(floorDiv(Int32(worldZ), scaleI) - fromScaledZ)
                    let index = sampleZ * sampleWidth + sampleX
                    biomeKey = (index >= 0 && index < biomes.count) ? biomes[index] : nil
                } else {
                    biomeKey = nil
                }

                let biomeId = biomeKey?.name ?? "unknown"
                let color = biomeColors[biomeId] ?? fallbackColor
                pixels.append(color.0)
                pixels.append(color.1)
                pixels.append(color.2)
                pixels.append(color.3)
            }
        }

        return BiomePixelMap(width: width, height: height, pixelsRGBA8: pixels)
    }

    static func render(
        worldGenerator: WorldGenerator,
        topLeftX: Int,
        topLeftZ: Int,
        width: Int,
        height: Int,
        scale: Int = 4,
        biomeSampler: (WorldGenerator, Int, Int) throws -> String
    ) throws -> BiomePixelMap {
        guard width > 0, height > 0 else {
            throw BiomeMapRendererError.invalidSize
        }
        guard scale > 0 else {
            throw BiomeMapRendererError.invalidSize
        }

        var pixels = [UInt8]()
        pixels.reserveCapacity(width * height * 4)

        for z in 0..<height {
            for x in 0..<width {
                let biomeId = try biomeSampler(
                    worldGenerator,
                    topLeftX + (x / scale) * scale,
                    topLeftZ + (z / scale) * scale
                )
                let color = biomeColors[biomeId] ?? fallbackColor
                pixels.append(color.0)
                pixels.append(color.1)
                pixels.append(color.2)
                pixels.append(color.3)
            }
        }

        return BiomePixelMap(width: width, height: height, pixelsRGBA8: pixels)
    }

    static func makeVertices2D(from map: BiomePixelMap) -> [VulkanEngine.Vertex2D] {
        guard map.width > 0, map.height > 0 else {
            return []
        }

        var vertices: [VulkanEngine.Vertex2D] = []
        vertices.reserveCapacity(map.width * map.height * 6)

        for y in 0..<map.height {
            for x in 0..<map.width {
                let baseIndex = (y * map.width + x) * 4
                let r = Float(map.pixelsRGBA8[baseIndex]) / 255.0
                let g = Float(map.pixelsRGBA8[baseIndex + 1]) / 255.0
                let b = Float(map.pixelsRGBA8[baseIndex + 2]) / 255.0
                let a = Float(map.pixelsRGBA8[baseIndex + 3]) / 255.0
                let color = SIMD4<Float>(x: r, y: g, z: b, w: a)

                let px0 = Float(x)
                let py0 = Float(y)
                let px1 = px0 + 1.0
                let py1 = py0 + 1.0

                vertices.append(.init(position: SIMD2<Float>(x: px0, y: py1), color: color))
                vertices.append(.init(position: SIMD2<Float>(x: px1, y: py1), color: color))
                vertices.append(.init(position: SIMD2<Float>(x: px1, y: py0), color: color))

                vertices.append(.init(position: SIMD2<Float>(x: px0, y: py1), color: color))
                vertices.append(.init(position: SIMD2<Float>(x: px1, y: py0), color: color))
                vertices.append(.init(position: SIMD2<Float>(x: px0, y: py0), color: color))
            }
        }

        return vertices
    }

    private static func makePosInt2D(x: Int, z: Int) -> DPReader.PosInt2D {
        DPReader.PosInt2D(x: Int32(x), z: Int32(z))
    }

    private static func floorDiv(_ lhs: Int32, _ rhs: Int32) -> Int32 {
        if lhs >= 0 {
            return lhs / rhs
        }
        return -(((-lhs) + rhs - 1) / rhs)
    }

    private static func ceilDiv(_ lhs: Int32, _ rhs: Int32) -> Int32 {
        if lhs >= 0 {
            return (lhs + rhs - 1) / rhs
        }
        return -((-lhs) / rhs)
    }
}
