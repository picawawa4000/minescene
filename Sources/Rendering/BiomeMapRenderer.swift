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
        let sampleY: Int
    }

    private struct TileCoord: Hashable {
        let x: Int
        let z: Int
    }

    struct PendingKey: Hashable {
        let tileXIndex: Int
        let tileZIndex: Int
        let tree: TreeKey
    }

    private struct ProfileTotals {
        var fillCalls: Int = 0
        var fillTotalNs: UInt64 = 0
        var fillSnapshotNs: UInt64 = 0
        var fillSampleNs: UInt64 = 0
        var fillMissingTiles: Int = 0
        var fillVisibleTiles: Int = 0
        var verticesCalls: Int = 0
        var verticesBuildNs: UInt64 = 0
        var verticesBuilt: Int = 0
        var batchesScheduled: Int = 0
        var tilesScheduled: Int = 0
        var boundingTilesScheduled: Int = 0
        var batchesCompleted: Int = 0
        var tilesCompleted: Int = 0
        var boundingTilesCompleted: Int = 0
        var batchesFailed: Int = 0
        var batchRenderNs: UInt64 = 0
        var batchInsertNs: UInt64 = 0
        var lastReportNs: UInt64

        init(nowNs: UInt64 = DispatchTime.now().uptimeNanoseconds) {
            self.lastReportNs = nowNs
        }
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
    let baseScale: Int
    private let lockQueue = DispatchQueue(label: "BiomeTileCache.lock", attributes: .concurrent)
    private let workerQueue = DispatchQueue(label: "BiomeTileCache.worker", qos: .userInitiated, attributes: .concurrent)
    private let profileQueue = DispatchQueue(label: "BiomeTileCache.profile")
    private let generationSlots: DispatchSemaphore
    private let maxBatchSpanTiles: Int
    private var trees: [TreeKey: QuadTree] = [:]
    private var pending: Set<PendingKey> = []
    private var version: UInt64 = 0
    private var profileTotals = ProfileTotals()
    private let profilingEnabled: Bool = {
        #if DEBUG
        true
        #else
        ProcessInfo.processInfo.environment["MINESCENE_PROFILE"] == "1"
        #endif
    }()
    private let profileReportIntervalNs: UInt64 = 2_000_000_000
    private let placeholderColor: (UInt8, UInt8, UInt8, UInt8) = (255, 0, 255, 255)
    private let palette: BiomeColorPalette

    init(palette: BiomeColorPalette, tileSize: Int = 256, baseScale: Int = 4) {
        self.palette = palette
        self.tileSize = tileSize
        self.baseScale = max(1, baseScale)
        let envWorkers = ProcessInfo.processInfo.environment["MINESCENE_TILE_WORKERS"].flatMap(Int.init)
        let cpuWorkers = max(1, ProcessInfo.processInfo.activeProcessorCount - 1)
        let workerCount = max(1, min(8, envWorkers ?? min(2, cpuWorkers)))
        self.generationSlots = DispatchSemaphore(value: workerCount)
        self.maxBatchSpanTiles = 2
    }

    func clear() {
        lockQueue.sync(flags: .barrier) {
            trees.removeAll(keepingCapacity: false)
            pending.removeAll(keepingCapacity: false)
            version &+= 1
        }
    }

    func currentVersion(sampleY: Int = 256) -> UInt64 {
        _ = sampleY
        return lockQueue.sync { version }
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

        let treeKey = TreeKey(sampleY: sampleY)
        let tileOriginX = topLeftX
        let tileOriginZ = topLeftZ

        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let isComplete = fillPixelsFromTiles(
            worldGenerator: worldGenerator,
            treeKey: treeKey,
            topLeftX: topLeftX,
            topLeftZ: topLeftZ,
            width: width,
            height: height,
            scale: scale,
            sampleY: sampleY,
            pixels: &pixels
        )

        let map = BiomePixelMap(width: width, height: height, pixelsRGBA8: pixels)
        let currentVersion = lockQueue.sync { version }
        return (map, tileOriginX, tileOriginZ, currentVersion, isComplete)
    }

    func verticesAsync(
        worldGenerator: WorldGenerator,
        topLeftX: Int,
        topLeftZ: Int,
        width: Int,
        height: Int,
        scale: Int,
        sampleY: Int = 256
    ) throws -> (vertices: [VulkanEngine.Vertex2D], tileOriginX: Int, tileOriginZ: Int, version: UInt64, isComplete: Bool) {
        guard width > 0, height > 0 else {
            throw BiomeMapRendererError.invalidSize
        }
        guard scale > 0 else {
            throw BiomeMapRendererError.invalidSize
        }

        let treeKey = TreeKey(sampleY: sampleY)
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let isComplete = fillPixelsFromTiles(
            worldGenerator: worldGenerator,
            treeKey: treeKey,
            topLeftX: topLeftX,
            topLeftZ: topLeftZ,
            width: width,
            height: height,
            scale: scale,
            sampleY: sampleY,
            pixels: &pixels
        )

        var vertices: [VulkanEngine.Vertex2D] = []
        vertices.reserveCapacity(width * height * 6)
        let vertexBuildStartNs = DispatchTime.now().uptimeNanoseconds

        let cellSize = Float(scale)
        let originX = Float(topLeftX)
        let originZ = Float(topLeftZ)

        for y in 0..<height {
            for x in 0..<width {
                let baseIndex = (y * width + x) * 4
                let r = Float(pixels[baseIndex]) / 255.0
                let g = Float(pixels[baseIndex + 1]) / 255.0
                let b = Float(pixels[baseIndex + 2]) / 255.0
                let a = Float(pixels[baseIndex + 3]) / 255.0
                let color = SIMD4<Float>(x: r, y: g, z: b, w: a)

                let px0 = originX + Float(x) * cellSize
                let py0 = originZ + Float(y) * cellSize
                let px1 = px0 + cellSize
                let py1 = py0 + cellSize

                vertices.append(.init(position: SIMD2<Float>(x: px0, y: py1), color: color))
                vertices.append(.init(position: SIMD2<Float>(x: px1, y: py1), color: color))
                vertices.append(.init(position: SIMD2<Float>(x: px1, y: py0), color: color))
                vertices.append(.init(position: SIMD2<Float>(x: px0, y: py1), color: color))
                vertices.append(.init(position: SIMD2<Float>(x: px1, y: py0), color: color))
                vertices.append(.init(position: SIMD2<Float>(x: px0, y: py0), color: color))
            }
        }
        let vertexBuildNs = DispatchTime.now().uptimeNanoseconds - vertexBuildStartNs
        recordVertexBuildProfile(vertexCount: vertices.count, elapsedNs: vertexBuildNs)

        let currentVersion = lockQueue.sync { version }
        return (vertices, topLeftX, topLeftZ, currentVersion, isComplete)
    }

    private func fillPixelsFromTiles(
        worldGenerator: WorldGenerator,
        treeKey: TreeKey,
        topLeftX: Int,
        topLeftZ: Int,
        width: Int,
        height: Int,
        scale: Int,
        sampleY: Int,
        pixels: inout [UInt8]
    ) -> Bool {
        let fillStartNs = DispatchTime.now().uptimeNanoseconds
        let tileWorldSize = tileSize * baseScale
        let maxWorldX = topLeftX + max(0, width - 1) * scale
        let maxWorldZ = topLeftZ + max(0, height - 1) * scale
        let minTileX = BiomeQuadTreeCache.floorDiv(topLeftX, tileWorldSize)
        let maxTileX = BiomeQuadTreeCache.floorDiv(maxWorldX, tileWorldSize)
        let minTileZ = BiomeQuadTreeCache.floorDiv(topLeftZ, tileWorldSize)
        let maxTileZ = BiomeQuadTreeCache.floorDiv(maxWorldZ, tileWorldSize)

        var hasMissingTiles = false
        var cachedTiles: [TileCoord: BiomePixelMap] = [:]
        var tilesToSchedule: [TileCoord] = []
        cachedTiles.reserveCapacity((maxTileX - minTileX + 1) * (maxTileZ - minTileZ + 1))

        let snapshotStartNs = DispatchTime.now().uptimeNanoseconds
        lockQueue.sync {
            let tree = trees[treeKey]
            for tileZIndex in minTileZ...maxTileZ {
                for tileXIndex in minTileX...maxTileX {
                    let key = TileCoord(x: tileXIndex, z: tileZIndex)
                    if let tile = tree?.value(at: tileXIndex, tileZIndex) {
                        cachedTiles[key] = tile
                    } else {
                        hasMissingTiles = true
                        let pendingKey = PendingKey(tileXIndex: tileXIndex, tileZIndex: tileZIndex, tree: treeKey)
                        if !pending.contains(pendingKey) {
                            tilesToSchedule.append(key)
                        }
                    }
                }
            }
        }
        let snapshotNs = DispatchTime.now().uptimeNanoseconds - snapshotStartNs

        if !tilesToSchedule.isEmpty {
            scheduleTileGenerationBatch(
                tileCoords: tilesToSchedule,
                treeKey: treeKey,
                worldGenerator: worldGenerator,
                sampleY: sampleY
            )
        }

        let samplingStartNs = DispatchTime.now().uptimeNanoseconds
        let localStep = max(1, scale / baseScale)
        for y in 0..<height {
            let worldZ = topLeftZ + y * scale
            let tileZIndex = BiomeQuadTreeCache.floorDiv(worldZ, tileWorldSize)
            let localZ = BiomeQuadTreeCache.floorMod(worldZ, tileWorldSize) / baseScale
            var tileXIndex = BiomeQuadTreeCache.floorDiv(topLeftX, tileWorldSize)
            var localX = BiomeQuadTreeCache.floorMod(topLeftX, tileWorldSize) / baseScale
            var cachedTileXIndex = Int.min
            var rowTile: BiomePixelMap?
            for x in 0..<width {
                if tileXIndex != cachedTileXIndex {
                    cachedTileXIndex = tileXIndex
                    rowTile = cachedTiles[TileCoord(x: tileXIndex, z: tileZIndex)]
                }
                let base = (y * width + x) * 4

                if let tile = rowTile {
                    let srcBase = (localZ * tile.width + localX) * 4
                    pixels[base] = tile.pixelsRGBA8[srcBase]
                    pixels[base + 1] = tile.pixelsRGBA8[srcBase + 1]
                    pixels[base + 2] = tile.pixelsRGBA8[srcBase + 2]
                    pixels[base + 3] = tile.pixelsRGBA8[srcBase + 3]
                } else {
                    pixels[base] = placeholderColor.0
                    pixels[base + 1] = placeholderColor.1
                    pixels[base + 2] = placeholderColor.2
                    pixels[base + 3] = placeholderColor.3
                }

                localX += localStep
                if localX >= tileSize {
                    localX -= tileSize
                    tileXIndex += 1
                }
            }
        }
        let samplingNs = DispatchTime.now().uptimeNanoseconds - samplingStartNs
        let visibleTiles = (maxTileX - minTileX + 1) * (maxTileZ - minTileZ + 1)
        let missingTiles = max(0, visibleTiles - cachedTiles.count)
        let totalNs = DispatchTime.now().uptimeNanoseconds - fillStartNs
        recordFillProfile(
            totalNs: totalNs,
            snapshotNs: snapshotNs,
            sampleNs: samplingNs,
            missingTiles: missingTiles,
            visibleTiles: visibleTiles
        )

        return !hasMissingTiles
    }

    private func scheduleTileGenerationBatch(
        tileCoords: [TileCoord],
        treeKey: TreeKey,
        worldGenerator: WorldGenerator,
        sampleY: Int
    ) {
        guard !tileCoords.isEmpty else { return }

        // Keep generation batches spatially tight; this lowers worst-case render spikes.
        if tileCoords.count > maxBatchSpanTiles * maxBatchSpanTiles {
            var grouped: [TileCoord: [TileCoord]] = [:]
            grouped.reserveCapacity(tileCoords.count)
            for coord in tileCoords {
                let group = TileCoord(
                    x: BiomeQuadTreeCache.floorDiv(coord.x, maxBatchSpanTiles),
                    z: BiomeQuadTreeCache.floorDiv(coord.z, maxBatchSpanTiles)
                )
                grouped[group, default: []].append(coord)
            }
            for group in grouped.values {
                scheduleTileGenerationBatch(
                    tileCoords: group,
                    treeKey: treeKey,
                    worldGenerator: worldGenerator,
                    sampleY: sampleY
                )
            }
            return
        }

        let minTileX = tileCoords.map(\.x).min()!
        let maxTileX = tileCoords.map(\.x).max()!
        let minTileZ = tileCoords.map(\.z).min()!
        let maxTileZ = tileCoords.map(\.z).max()!
        let regionTileWidth = maxTileX - minTileX + 1
        let regionTileHeight = maxTileZ - minTileZ + 1
        let regionTileCount = regionTileWidth * regionTileHeight
        let regionTopLeftX = minTileX * tileSize * baseScale
        let regionTopLeftZ = minTileZ * tileSize * baseScale
        let tileCoordsSet = Set(tileCoords)
        recordBatchScheduled(tileCount: tileCoords.count, boundingTileCount: regionTileCount)

        lockQueue.sync(flags: .barrier) {
            for coord in tileCoords {
                pending.insert(PendingKey(tileXIndex: coord.x, tileZIndex: coord.z, tree: treeKey))
            }
        }

        workerQueue.async { [weak self] in
            guard let self else { return }
            self.generationSlots.wait()
            defer {
                self.generationSlots.signal()
            }
            let renderStartNs = DispatchTime.now().uptimeNanoseconds
            let generated = try? BiomeMapRenderer(palette: self.palette).render(
                worldGenerator: worldGenerator,
                topLeftX: regionTopLeftX,
                topLeftZ: regionTopLeftZ,
                width: regionTileWidth * self.tileSize,
                height: regionTileHeight * self.tileSize,
                scale: self.baseScale,
                sampleY: sampleY
            )
            let renderNs = DispatchTime.now().uptimeNanoseconds - renderStartNs
            self.lockQueue.async(flags: .barrier) {
                let insertStartNs = DispatchTime.now().uptimeNanoseconds
                if let generated {
                    let tree = self.trees[treeKey] ?? QuadTree()
                    for tileZ in minTileZ...maxTileZ {
                        for tileX in minTileX...maxTileX {
                            let coord = TileCoord(x: tileX, z: tileZ)
                            if !tileCoordsSet.contains(coord) {
                                continue
                            }
                            let tile = self.extractTile(
                                from: generated,
                                tileXOffset: tileX - minTileX,
                                tileZOffset: tileZ - minTileZ
                            )
                            tree.insert(tile, at: tileX, tileZ)
                        }
                    }
                    self.trees[treeKey] = tree
                    self.version &+= 1
                }
                for coord in tileCoords {
                    self.pending.remove(PendingKey(tileXIndex: coord.x, tileZIndex: coord.z, tree: treeKey))
                }
                let insertNs = DispatchTime.now().uptimeNanoseconds - insertStartNs
                self.recordBatchCompleted(
                    tileCount: tileCoords.count,
                    boundingTileCount: regionTileCount,
                    renderNs: renderNs,
                    insertNs: insertNs,
                    success: generated != nil
                )
            }
        }
    }

    private func extractTile(
        from source: BiomePixelMap,
        tileXOffset: Int,
        tileZOffset: Int
    ) -> BiomePixelMap {
        var tilePixels = [UInt8](repeating: 0, count: tileSize * tileSize * 4)
        for row in 0..<tileSize {
            let srcStart = (((tileZOffset * tileSize) + row) * source.width + tileXOffset * tileSize) * 4
            let srcEnd = srcStart + tileSize * 4
            let dstStart = row * tileSize * 4
            tilePixels.replaceSubrange(dstStart..<(dstStart + tileSize * 4), with: source.pixelsRGBA8[srcStart..<srcEnd])
        }
        return BiomePixelMap(width: tileSize, height: tileSize, pixelsRGBA8: tilePixels)
    }

    private static func floorDiv(_ value: Int, _ divisor: Int) -> Int {
        if value >= 0 {
            return value / divisor
        }
        return -(((-value) + divisor - 1) / divisor)
    }

    private static func floorMod(_ value: Int, _ divisor: Int) -> Int {
        let result = value % divisor
        return result >= 0 ? result : result + divisor
    }

    private func recordFillProfile(
        totalNs: UInt64,
        snapshotNs: UInt64,
        sampleNs: UInt64,
        missingTiles: Int,
        visibleTiles: Int
    ) {
        guard profilingEnabled else { return }
        profileQueue.async {
            self.profileTotals.fillCalls += 1
            self.profileTotals.fillTotalNs += totalNs
            self.profileTotals.fillSnapshotNs += snapshotNs
            self.profileTotals.fillSampleNs += sampleNs
            self.profileTotals.fillMissingTiles += missingTiles
            self.profileTotals.fillVisibleTiles += visibleTiles
            self.maybeReportProfileLocked(nowNs: DispatchTime.now().uptimeNanoseconds)
        }
    }

    private func recordVertexBuildProfile(vertexCount: Int, elapsedNs: UInt64) {
        guard profilingEnabled else { return }
        profileQueue.async {
            self.profileTotals.verticesCalls += 1
            self.profileTotals.verticesBuildNs += elapsedNs
            self.profileTotals.verticesBuilt += vertexCount
            self.maybeReportProfileLocked(nowNs: DispatchTime.now().uptimeNanoseconds)
        }
    }

    private func recordBatchScheduled(tileCount: Int, boundingTileCount: Int) {
        guard profilingEnabled else { return }
        profileQueue.async {
            self.profileTotals.batchesScheduled += 1
            self.profileTotals.tilesScheduled += tileCount
            self.profileTotals.boundingTilesScheduled += boundingTileCount
            self.maybeReportProfileLocked(nowNs: DispatchTime.now().uptimeNanoseconds)
        }
    }

    private func recordBatchCompleted(
        tileCount: Int,
        boundingTileCount: Int,
        renderNs: UInt64,
        insertNs: UInt64,
        success: Bool
    ) {
        guard profilingEnabled else { return }
        profileQueue.async {
            self.profileTotals.batchesCompleted += 1
            self.profileTotals.tilesCompleted += tileCount
            self.profileTotals.boundingTilesCompleted += boundingTileCount
            self.profileTotals.batchRenderNs += renderNs
            self.profileTotals.batchInsertNs += insertNs
            if !success {
                self.profileTotals.batchesFailed += 1
            }
            self.maybeReportProfileLocked(nowNs: DispatchTime.now().uptimeNanoseconds)
        }
    }

    private func maybeReportProfileLocked(nowNs: UInt64) {
        guard nowNs - profileTotals.lastReportNs >= profileReportIntervalNs else { return }

        let fillCalls = max(1, profileTotals.fillCalls)
        let batchesCompleted = max(1, profileTotals.batchesCompleted)
        let avgFillMs = Self.nsToMs(profileTotals.fillTotalNs) / Double(fillCalls)
        let avgSnapshotMs = Self.nsToMs(profileTotals.fillSnapshotNs) / Double(fillCalls)
        let avgSampleMs = Self.nsToMs(profileTotals.fillSampleNs) / Double(fillCalls)
        let avgMissingPct = profileTotals.fillVisibleTiles > 0
            ? 100.0 * Double(profileTotals.fillMissingTiles) / Double(profileTotals.fillVisibleTiles)
            : 0.0
        let avgRenderMs = Self.nsToMs(profileTotals.batchRenderNs) / Double(batchesCompleted)
        let avgInsertMs = Self.nsToMs(profileTotals.batchInsertNs) / Double(batchesCompleted)
        let avgBatchCoveragePct = profileTotals.boundingTilesCompleted > 0
            ? 100.0 * Double(profileTotals.tilesCompleted) / Double(profileTotals.boundingTilesCompleted)
            : 100.0
        let verticesCalls = max(1, profileTotals.verticesCalls)
        let avgVerticesBuildMs = Self.nsToMs(profileTotals.verticesBuildNs) / Double(verticesCalls)
        let avgVerticesCount = Double(profileTotals.verticesBuilt) / Double(verticesCalls)

        let line = String(
            format: "[Profiler][BiomeCache] fill:%d avg=%.2fms (snapshot=%.2fms sample=%.2fms missing=%.1f%%) vertices:%d avgBuild=%.2fms avgCount=%.0f queued:%d/%dtiles (bbox=%d) completed:%d/%dtiles (bbox=%d coverage=%.1f%%) failed:%d batch(avg render=%.2fms insert=%.2fms)",
            profileTotals.fillCalls,
            avgFillMs,
            avgSnapshotMs,
            avgSampleMs,
            avgMissingPct,
            profileTotals.verticesCalls,
            avgVerticesBuildMs,
            avgVerticesCount,
            profileTotals.batchesScheduled,
            profileTotals.tilesScheduled,
            profileTotals.boundingTilesScheduled,
            profileTotals.batchesCompleted,
            profileTotals.tilesCompleted,
            profileTotals.boundingTilesCompleted,
            avgBatchCoveragePct,
            profileTotals.batchesFailed,
            avgRenderMs,
            avgInsertMs
        )
        print(line)
        profileTotals = ProfileTotals(nowNs: nowNs)
    }

    private static func nsToMs(_ ns: UInt64) -> Double {
        Double(ns) / 1_000_000.0
    }
}

struct BiomeMapRenderer {
    let palette: BiomeColorPalette

    private struct RenderProfileTotals {
        var calls: Int = 0
        var totalNs: UInt64 = 0
        var generateNs: UInt64 = 0
        var mapNs: UInt64 = 0
        var samples: Int = 0
        var lastReportNs: UInt64

        init(nowNs: UInt64 = DispatchTime.now().uptimeNanoseconds) {
            self.lastReportNs = nowNs
        }
    }

    private static let renderProfileQueue = DispatchQueue(label: "BiomeMapRenderer.profile")
    private static let renderProfilingEnabled: Bool = {
        #if DEBUG
        true
        #else
        ProcessInfo.processInfo.environment["MINESCENE_PROFILE"] == "1"
        #endif
    }()
    private static let renderProfileIntervalNs: UInt64 = 2_000_000_000

    func render(
        worldGenerator: WorldGenerator,
        topLeftX: Int,
        topLeftZ: Int,
        width: Int,
        height: Int,
        scale: Int = 4,
        forceNoBaking: Bool = false,
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
        let fromScaledX = Self.floorDiv(Int32(topLeftX), scaleI)
        let fromScaledZ = Self.floorDiv(Int32(topLeftZ), scaleI)
        let toScaledX = Self.ceilDiv(Int32(topLeftX + width * scale), scaleI)
        let toScaledZ = Self.ceilDiv(Int32(topLeftZ + height * scale), scaleI)

        let alignedFromX = Int(fromScaledX * scaleI)
        let alignedFromZ = Int(fromScaledZ * scaleI)
        let alignedToX = Int(toScaledX * scaleI)
        let alignedToZ = Int(toScaledZ * scaleI)

        let fromPos = Self.makePosInt2D(x: alignedFromX, z: alignedFromZ)
        let toPos: PosInt2D = Self.makePosInt2D(x: alignedToX, z: alignedToZ)
        let biomes = try worldGenerator.generateBiomesInSquare(
            from: fromPos,
            to: toPos,
            atY: Int32(sampleY),
            in: RegistryKey(referencing: "minecraft:overworld"),
            scale: Int32(scale),
            forceNoBaking: forceNoBaking
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
                    let sampleX = Int(Self.floorDiv(Int32(worldX), scaleI) - fromScaledX)
                    let sampleZ = Int(Self.floorDiv(Int32(worldZ), scaleI) - fromScaledZ)
                    let index = sampleZ * sampleWidth + sampleX
                    biomeKey = (index >= 0 && index < biomes.count) ? biomes[index] : nil
                } else {
                    biomeKey = nil
                }

                let color = palette.rgba8(forBiomeID: biomeKey?.name)
                pixels.append(color.0)
                pixels.append(color.1)
                pixels.append(color.2)
                pixels.append(color.3)
            }
        }

        return BiomePixelMap(width: width, height: height, pixelsRGBA8: pixels)
    }

    func render(
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
                let color = palette.rgba8(forBiomeID: biomeId)
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
