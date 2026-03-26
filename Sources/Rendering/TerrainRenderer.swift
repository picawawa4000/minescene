import Foundation
import DPReader
import SwiftSDL
import Vulkan
import VulkanBindings
import simd

final class TerrainRenderer {
    struct MeshProfile {
        var generationSeconds: Double = 0
        var meshSeconds: Double = 0
        var uploadSeconds: Double = 0
    }

    struct ChunkCoord: Hashable {
        let x: Int
        let z: Int
    }

    private struct CompactBiomeEntry {
        let name: String
        let packedColor: UInt32
    }

    private struct CompactSection {
        let bitmap: [UInt64]
        let biomePalette: [CompactBiomeEntry]
        let biomeIndices: [UInt8]

        @inline(__always)
        func biomeEntry(atBlockIndex blockIndex: Int) -> CompactBiomeEntry {
            biomePalette[Int(biomeIndices[blockIndex])]
        }

        @inline(__always)
        func isSolid(atBlockIndex blockIndex: Int) -> Bool {
            let wordIndex = blockIndex >> 6
            let bitIndex = blockIndex & 63
            return (bitmap[wordIndex] & (UInt64(1) << UInt64(bitIndex))) != 0
        }
    }

    private struct CompactChunk {
        let minY: Int
        let height: Int
        let sections: [CompactSection]

        var sectionCount: Int { sections.count }

        @inline(__always)
        func section(at index: Int) -> CompactSection? {
            guard index >= 0, index < sections.count else {
                return nil
            }
            return sections[index]
        }

        @inline(__always)
        func biomeEntry(atLocalX x: Int, y: Int, z: Int) -> CompactBiomeEntry? {
            guard x >= 0, x < 16, y >= 0, y < height, z >= 0, z < 16 else {
                return nil
            }
            let sectionIndex = y >> 4
            let localY = y & 15
            let blockIndex = (localY << 8) | (z << 4) | x
            return sections[sectionIndex].biomeEntry(atBlockIndex: blockIndex)
        }

        @inline(__always)
        func isSolid(atLocalX x: Int, y: Int, z: Int) -> Bool {
            guard x >= 0, x < 16, y >= 0, y < height, z >= 0, z < 16 else {
                return false
            }
            let sectionIndex = y >> 4
            let localY = y & 15
            let blockIndex = (localY << 8) | (z << 4) | x
            return sections[sectionIndex].isSolid(atBlockIndex: blockIndex)
        }
    }

    private struct ChunkMeshSnapshot {
        let coord: ChunkCoord
        let revision: Int
        let chunk: CompactChunk
        let neighbors: [ChunkCoord: CompactChunk]
        let generationSeconds: Double
        let totalTargetChunks: Int
        let availableChunks: Int
    }

    struct ChunkMeshResult {
        let coord: ChunkCoord
        let revision: Int
        let vertices: [VulkanEngine.Vertex3D]
        let profile: MeshProfile
        let availableChunks: Int
        let totalTargetChunks: Int
    }

    struct ChunkRenderMesh {
        let buffer: VulkanOwnedBuffer
        let memory: VulkanOwnedDeviceMemory
        let vertexCount: UInt32
    }

    struct StreamDebugStatus {
        let generatedChunks: Int
        let inFlightGenerationChunks: Int
        let dirtyMeshChunks: Int
        let inFlightMeshChunks: Int
        let totalTargetChunks: Int
    }

    final class Streamer: @unchecked Sendable {
        private let worldGenerator: WorldGenerator
        private let generationWorkerCount: Int
        private let retargetAroundCameraMovement: Bool
        private let biomeColorPalette: BiomeColorPalette

        private let lock = NSLock()
        private let generationQueue = DispatchQueue(label: "TerrainRenderer.Generation", qos: .userInitiated, attributes: .concurrent)
        private let meshQueue = DispatchQueue(label: "TerrainRenderer.Mesh", qos: .userInitiated, attributes: .concurrent)

        private var renderRadius: Int
        private var orderedOffsets: [ChunkCoord]
        private var targetCenter: ChunkCoord?
        private var targetCameraBlock = SIMD3<Int>(Int.min, Int.min, Int.min)
        private var chunks: [ChunkCoord: CompactChunk] = [:]
        private var inFlightChunks: Set<ChunkCoord> = []
        private var activeGenerationWorkers = 0

        private var dirtyMeshChunks: Set<ChunkCoord> = []
        private var inFlightMeshChunks: Set<ChunkCoord> = []
        private var activeMeshWorkers = 0
        private var chunkMeshRevision: [ChunkCoord: Int] = [:]
        private var pendingMeshResults: [ChunkCoord: ChunkMeshResult] = [:]
        private var pendingRemovedChunks: Set<ChunkCoord> = []
        private var generationSecondsByChunk: [ChunkCoord: Double] = [:]

        init(
            worldGenerator: WorldGenerator,
            renderRadius: Int,
            generationWorkerCount: Int,
            retargetAroundCameraMovement: Bool,
            biomeColorPalette: BiomeColorPalette
        ) {
            self.worldGenerator = worldGenerator
            self.renderRadius = max(0, renderRadius)
            self.generationWorkerCount = max(1, generationWorkerCount)
            self.retargetAroundCameraMovement = retargetAroundCameraMovement
            self.biomeColorPalette = biomeColorPalette
            self.orderedOffsets = Self.makeOrderedOffsets(radius: self.renderRadius)
        }

        func adjustRenderRadius(by delta: Int) {
            var generationWorkersToStart = 0
            var meshWorkersToStart = 0

            lock.lock()
            let nextRadius = max(0, renderRadius + delta)
            guard nextRadius != renderRadius else {
                lock.unlock()
                return
            }

            renderRadius = nextRadius
            orderedOffsets = Self.makeOrderedOffsets(radius: renderRadius)

            if let center = targetCenter {
                let removed = pruneChunksLocked(around: center)
                for removedCoord in removed {
                    markChunkRemovedLocked(removedCoord)
                }
                for coord in chunks.keys {
                    markChunkDirtyLocked(coord)
                }
            }

            generationWorkersToStart = startGenerationWorkersLocked()
            meshWorkersToStart = startMeshWorkersLocked()
            lock.unlock()

            for _ in 0..<generationWorkersToStart {
                generationQueue.async { [self] in
                    generationWorkerLoop()
                }
            }
            for _ in 0..<meshWorkersToStart {
                meshQueue.async { [self] in
                    meshWorkerLoop()
                }
            }
        }

        func updateTarget(center: ChunkCoord, cameraBlock: SIMD3<Int>) {
            var generationWorkersToStart = 0
            var meshWorkersToStart = 0
            lock.lock()
            let effectiveCenter: ChunkCoord
            if retargetAroundCameraMovement || targetCenter == nil {
                effectiveCenter = center
            } else {
                effectiveCenter = targetCenter!
            }
            let centerChanged = targetCenter != effectiveCenter
            targetCenter = effectiveCenter
            targetCameraBlock = cameraBlock
            if centerChanged {
                let removed = pruneChunksLocked(around: effectiveCenter)
                for removedCoord in removed {
                    markChunkRemovedLocked(removedCoord)
                }
            }
            if centerChanged {
                for coord in chunks.keys {
                    markChunkDirtyLocked(coord)
                }
            }
            generationWorkersToStart = startGenerationWorkersLocked()
            meshWorkersToStart = startMeshWorkersLocked()
            lock.unlock()

            for _ in 0..<generationWorkersToStart {
                generationQueue.async { [self] in
                    generationWorkerLoop()
                }
            }
            for _ in 0..<meshWorkersToStart {
                meshQueue.async { [self] in
                    meshWorkerLoop()
                }
            }
        }

        func takeCompletedResults() -> (results: [ChunkMeshResult], removals: [ChunkCoord]) {
            lock.lock()
            defer { lock.unlock() }
            let results = pendingMeshResults.values.sorted { lhs, rhs in
                if lhs.coord.z != rhs.coord.z { return lhs.coord.z < rhs.coord.z }
                return lhs.coord.x < rhs.coord.x
            }
            let removals = pendingRemovedChunks.sorted { lhs, rhs in
                if lhs.z != rhs.z { return lhs.z < rhs.z }
                return lhs.x < rhs.x
            }
            pendingMeshResults.removeAll(keepingCapacity: true)
            pendingRemovedChunks.removeAll(keepingCapacity: true)
            return (results, removals)
        }

        func currentBiomeName(at cameraBlock: SIMD3<Int>) -> String? {
            let chunkCoord = ChunkCoord(
                x: floorDiv(cameraBlock.x, 16),
                z: floorDiv(cameraBlock.z, 16)
            )
            let localX = floorMod(cameraBlock.x, 16)
            let localZ = floorMod(cameraBlock.z, 16)

            lock.lock()
            defer { lock.unlock() }
            guard let chunk = chunks[chunkCoord] else {
                return nil
            }
            let localY = cameraBlock.y - chunk.minY
            guard localY >= 0, localY < chunk.height else {
                return nil
            }
            return chunk.biomeEntry(atLocalX: localX, y: localY, z: localZ)?.name
        }

        func debugStatus() -> StreamDebugStatus {
            lock.lock()
            defer { lock.unlock() }

            guard let center = targetCenter else {
                return StreamDebugStatus(
                    generatedChunks: 0,
                    inFlightGenerationChunks: 0,
                    dirtyMeshChunks: dirtyMeshChunks.count,
                    inFlightMeshChunks: inFlightMeshChunks.count,
                    totalTargetChunks: orderedOffsets.count
                )
            }

            let generatedChunks = chunks.keys.reduce(into: 0) { count, coord in
                if shouldKeepChunk(coord, around: center) {
                    count += 1
                }
            }
            let inFlightGenerationChunks = inFlightChunks.reduce(into: 0) { count, coord in
                if shouldKeepChunk(coord, around: center) {
                    count += 1
                }
            }

            return StreamDebugStatus(
                generatedChunks: generatedChunks,
                inFlightGenerationChunks: inFlightGenerationChunks,
                dirtyMeshChunks: dirtyMeshChunks.count,
                inFlightMeshChunks: inFlightMeshChunks.count,
                totalTargetChunks: orderedOffsets.count
            )
        }

        func requestMeshRebuild() {
            var meshWorkersToStart = 0

            lock.lock()
            for coord in chunks.keys {
                markChunkDirtyLocked(coord)
            }
            pendingMeshResults.removeAll(keepingCapacity: true)
            meshWorkersToStart = startMeshWorkersLocked()
            lock.unlock()

            for _ in 0..<meshWorkersToStart {
                meshQueue.async { [self] in
                    meshWorkerLoop()
                }
            }
        }

        private func generationWorkerLoop() {
            while true {
                let chunkCoord: ChunkCoord
                lock.lock()
                guard let nextChunk = nextMissingChunkLocked() else {
                    activeGenerationWorkers = max(0, activeGenerationWorkers - 1)
                    lock.unlock()
                    return
                }
                inFlightChunks.insert(nextChunk)
                chunkCoord = nextChunk
                lock.unlock()

                let generationStart = CFAbsoluteTimeGetCurrent()
                let protoChunk = ProtoChunk()
                let generationSucceeded = (try? worldGenerator.generateInto(protoChunk, at: PosInt2D(x: Int32(chunkCoord.x), z: Int32(chunkCoord.z)))) != nil
                let generationSeconds = CFAbsoluteTimeGetCurrent() - generationStart
                let compactChunk = generationSucceeded ? makeCompactChunk(from: protoChunk) : nil

                var generationWorkersToStart = 0
                var meshWorkersToStart = 0
                lock.lock()
                inFlightChunks.remove(chunkCoord)
                if let compactChunk, let center = targetCenter, shouldKeepChunk(chunkCoord, around: center) {
                    chunks[chunkCoord] = compactChunk
                    generationSecondsByChunk[chunkCoord] = generationSeconds
                    markChunkDirtyLocked(chunkCoord)
                    for neighbor in adjacentChunkCoords(to: chunkCoord) where chunks[neighbor] != nil {
                        markChunkDirtyLocked(neighbor)
                    }
                }
                let removed = pruneChunksLockedIfNeeded()
                for removedCoord in removed {
                    markChunkRemovedLocked(removedCoord)
                }
                generationWorkersToStart = startGenerationWorkersLocked()
                meshWorkersToStart = startMeshWorkersLocked()
                lock.unlock()

                for _ in 0..<generationWorkersToStart {
                    generationQueue.async { [self] in
                        generationWorkerLoop()
                    }
                }
                for _ in 0..<meshWorkersToStart {
                    meshQueue.async { [self] in
                        meshWorkerLoop()
                    }
                }
            }
        }

        private func nextMissingChunkLocked() -> ChunkCoord? {
            guard let center = targetCenter else {
                return nil
            }
            for offset in orderedOffsets {
                let coord = ChunkCoord(x: center.x + offset.x, z: center.z + offset.z)
                if chunks[coord] == nil && !inFlightChunks.contains(coord) {
                    return coord
                }
            }
            return nil
        }

        private func startGenerationWorkersLocked() -> Int {
            guard targetCenter != nil else {
                return 0
            }
            var started = 0
            while activeGenerationWorkers < generationWorkerCount, nextMissingChunkLocked() != nil {
                activeGenerationWorkers += 1
                started += 1
            }
            return started
        }

        private func nextDirtyChunkLocked() -> ChunkCoord? {
            guard let center = targetCenter else {
                return nil
            }
            let orderedLoaded = chunks.keys.sorted { lhs, rhs in
                let lhsDistance = max(abs(lhs.x - center.x), abs(lhs.z - center.z))
                let rhsDistance = max(abs(rhs.x - center.x), abs(rhs.z - center.z))
                if lhsDistance != rhsDistance { return lhsDistance < rhsDistance }
                if lhs.z != rhs.z { return lhs.z < rhs.z }
                return lhs.x < rhs.x
            }
            for coord in orderedLoaded where dirtyMeshChunks.contains(coord) && !inFlightMeshChunks.contains(coord) {
                return coord
            }
            return nil
        }

        private func startMeshWorkersLocked() -> Int {
            guard targetCenter != nil else {
                return 0
            }
            let meshWorkerLimit = max(1, generationWorkerCount)
            var started = 0
            while activeMeshWorkers < meshWorkerLimit, nextDirtyChunkLocked() != nil {
                activeMeshWorkers += 1
                started += 1
            }
            return started
        }

        private func meshWorkerLoop() {
            while true {
                let snapshot: ChunkMeshSnapshot
                lock.lock()
                guard let coord = nextDirtyChunkLocked(),
                      let chunk = chunks[coord] else {
                    activeMeshWorkers = max(0, activeMeshWorkers - 1)
                    lock.unlock()
                    return
                }
                dirtyMeshChunks.remove(coord)
                inFlightMeshChunks.insert(coord)
                let revision = chunkMeshRevision[coord] ?? 0
                let availableChunks = chunks.count
                var neighbors: [ChunkCoord: CompactChunk] = [coord: chunk]
                for neighbor in adjacentChunkCoords(to: coord) {
                    if let neighborChunk = chunks[neighbor] {
                        neighbors[neighbor] = neighborChunk
                    }
                }
                let generationSeconds = generationSecondsByChunk[coord] ?? 0
                lock.unlock()

                snapshot = ChunkMeshSnapshot(
                    coord: coord,
                    revision: revision,
                    chunk: chunk,
                    neighbors: neighbors,
                    generationSeconds: generationSeconds,
                    totalTargetChunks: orderedOffsets.count,
                    availableChunks: availableChunks
                )

                let result = buildChunkMesh(snapshot: snapshot)

                var meshWorkersToStart = 0
                lock.lock()
                inFlightMeshChunks.remove(coord)
                if chunks[coord] != nil, (chunkMeshRevision[coord] ?? 0) == result.revision {
                    pendingMeshResults[coord] = result
                    generationSecondsByChunk[coord] = 0
                }
                meshWorkersToStart = startMeshWorkersLocked()
                lock.unlock()

                for _ in 0..<meshWorkersToStart {
                    meshQueue.async { [self] in
                        meshWorkerLoop()
                    }
                }
            }
        }

        private func buildChunkMesh(snapshot: ChunkMeshSnapshot) -> ChunkMeshResult {
            var profile = MeshProfile(
                generationSeconds: snapshot.generationSeconds,
                meshSeconds: 0,
                uploadSeconds: 0
            )

            let meshStart = CFAbsoluteTimeGetCurrent()
            let vertices = buildGreedyMesh(coord: snapshot.coord, chunk: snapshot.chunk, neighbors: snapshot.neighbors)
            profile.meshSeconds = CFAbsoluteTimeGetCurrent() - meshStart

            return ChunkMeshResult(
                coord: snapshot.coord,
                revision: snapshot.revision,
                vertices: vertices,
                profile: profile,
                availableChunks: snapshot.availableChunks,
                totalTargetChunks: snapshot.totalTargetChunks
            )
        }

        private func makeCompactChunk(from protoChunk: ProtoChunk) -> CompactChunk {
            var sections: [CompactSection] = []
            sections.reserveCapacity(protoChunk.sectionCount)

            for sectionIndex in 0..<protoChunk.sectionCount {
                guard let section = protoChunk.section(at: sectionIndex) else {
                    continue
                }

                let bitmap = section.bitmap
                var biomePalette: [CompactBiomeEntry] = []
                biomePalette.reserveCapacity(8)
                var paletteIndexByName: [String: Int] = [:]
                var biomeIndices = [UInt8](repeating: 0, count: 16 * 16 * 16)

                for blockIndex in 0..<biomeIndices.count {
                    let x = blockIndex & 15
                    let z = (blockIndex >> 4) & 15
                    let y = (blockIndex >> 8) & 15
                    let localY = sectionIndex * ProtoChunk.sectionHeight + y
                    let biomeName = protoChunk.biome(
                        atLocal: PosInt3D(
                            x: Int32(x),
                            y: Int32(localY),
                            z: Int32(z)
                        )
                    )?.name ?? "unknown"

                    let paletteIndex: Int
                    if let existing = paletteIndexByName[biomeName] {
                        paletteIndex = existing
                    } else {
                        paletteIndex = biomePalette.count
                        precondition(paletteIndex < 256, "section biome palette exceeded UInt8 capacity")
                        paletteIndexByName[biomeName] = paletteIndex
                        biomePalette.append(
                            CompactBiomeEntry(
                                name: biomeName,
                                packedColor: biomeColorPalette.packedRGBA8(forBiomeID: biomeName)
                            )
                        )
                    }
                    biomeIndices[blockIndex] = UInt8(paletteIndex)
                }

                sections.append(
                    CompactSection(
                        bitmap: bitmap,
                        biomePalette: biomePalette,
                        biomeIndices: biomeIndices
                    )
                )
            }

            return CompactChunk(
                minY: Int(protoChunk.minY),
                height: Int(protoChunk.height),
                sections: sections
            )
        }

        private func pruneChunksLockedIfNeeded() -> [ChunkCoord] {
            guard let center = targetCenter else {
                let removed = Array(chunks.keys)
                chunks.removeAll(keepingCapacity: true)
                return removed
            }
            return pruneChunksLocked(around: center)
        }

        @discardableResult
        private func pruneChunksLocked(around center: ChunkCoord) -> [ChunkCoord] {
            var removed: [ChunkCoord] = []
            chunks = chunks.filter { coord, _ in
                let keep = shouldKeepChunk(coord, around: center, extraMargin: 1)
                if !keep {
                    removed.append(coord)
                }
                return keep
            }
            return removed
        }

        private func shouldKeepChunk(_ coord: ChunkCoord, around center: ChunkCoord, extraMargin: Int = 0) -> Bool {
            abs(coord.x - center.x) <= renderRadius + extraMargin && abs(coord.z - center.z) <= renderRadius + extraMargin
        }

        private func markChunkDirtyLocked(_ coord: ChunkCoord) {
            guard chunks[coord] != nil else {
                return
            }
            chunkMeshRevision[coord, default: 0] += 1
            dirtyMeshChunks.insert(coord)
        }

        private func markChunkRemovedLocked(_ coord: ChunkCoord) {
            dirtyMeshChunks.remove(coord)
            inFlightMeshChunks.remove(coord)
            chunkMeshRevision[coord, default: 0] += 1
            generationSecondsByChunk.removeValue(forKey: coord)
            pendingMeshResults.removeValue(forKey: coord)
            pendingRemovedChunks.insert(coord)
            for neighbor in adjacentChunkCoords(to: coord) where chunks[neighbor] != nil {
                markChunkDirtyLocked(neighbor)
            }
        }

        private func adjacentChunkCoords(to coord: ChunkCoord) -> [ChunkCoord] {
            [
                ChunkCoord(x: coord.x - 1, z: coord.z),
                ChunkCoord(x: coord.x + 1, z: coord.z),
                ChunkCoord(x: coord.x, z: coord.z - 1),
                ChunkCoord(x: coord.x, z: coord.z + 1)
            ]
        }

        private func floorDiv(_ value: Int, _ divisor: Int) -> Int {
            if value >= 0 {
                return value / divisor
            }
            return -(((-value) + divisor - 1) / divisor)
        }

        private func floorMod(_ value: Int, _ divisor: Int) -> Int {
            let result = value % divisor
            return result >= 0 ? result : result + divisor
        }

        private func buildGreedyMesh(
            coord: ChunkCoord,
            chunk: CompactChunk,
            neighbors: [ChunkCoord: CompactChunk]
        ) -> [VulkanEngine.Vertex3D] {
            var firstSolidSection = Int.max
            var lastSolidSection = Int.min
            for sectionIndex in 0..<chunk.sectionCount {
                guard let section = chunk.section(at: sectionIndex),
                      section.bitmap.contains(where: { $0 != 0 }) else {
                    continue
                }
                firstSolidSection = min(firstSolidSection, sectionIndex)
                lastSolidSection = max(lastSolidSection, sectionIndex)
            }

            guard firstSolidSection != Int.max, lastSolidSection != Int.min else {
                return []
            }

            let originX = coord.x * 16
            let originY = chunk.minY + firstSolidSection * ProtoChunk.sectionHeight
            let originZ = coord.z * 16
            let dims = [16, (lastSolidSection - firstSolidSection + 1) * ProtoChunk.sectionHeight, 16]

            var vertices: [VulkanEngine.Vertex3D] = []
            vertices.reserveCapacity(12_000)

            @inline(__always)
            func isOwnedLocal(_ x: Int, _ y: Int, _ z: Int) -> Bool {
                x >= 0 && x < dims[0] && y >= 0 && y < dims[1] && z >= 0 && z < dims[2]
            }

            @inline(__always)
            func packedBiomeColorForOwnedBlock(_ x: Int, _ y: Int, _ z: Int) -> UInt32 {
                let absoluteLocalY = firstSolidSection * ProtoChunk.sectionHeight + y
                return chunk.biomeEntry(atLocalX: x, y: absoluteLocalY, z: z)?.packedColor
                    ?? biomeColorPalette.packedRGBA8(forBiomeID: nil)
            }

            @inline(__always)
            func isSolidWorld(_ worldX: Int, _ worldY: Int, _ worldZ: Int) -> Bool {
                let queryCoord = ChunkCoord(
                    x: floorDiv(worldX, 16),
                    z: floorDiv(worldZ, 16)
                )
                guard let queryChunk = neighbors[queryCoord] else {
                    return false
                }
                let localX = floorMod(worldX, 16)
                let localZ = floorMod(worldZ, 16)
                let localY = worldY - queryChunk.minY
                guard localY >= 0, localY < queryChunk.height else {
                    return false
                }
                return queryChunk.isSolid(atLocalX: localX, y: localY, z: localZ)
            }

            @inline(__always)
            func localToWorld(_ x: Int, _ y: Int, _ z: Int) -> SIMD3<Int> {
                SIMD3<Int>(originX + x, originY + y, originZ + z)
            }

            @inline(__always)
            func solidAtLocalOrNeighbor(_ x: Int, _ y: Int, _ z: Int) -> Bool {
                if y < 0 || y >= dims[1] {
                    return false
                }
                let world = localToWorld(x, y, z)
                return isSolidWorld(world.x, world.y, world.z)
            }

            for d in 0..<3 {
                let u = (d + 1) % 3
                let v = (d + 2) % 3
                let maskSize = dims[u] * dims[v]
                var mask = [Int8](repeating: 0, count: maskSize)
                var maskColors = [UInt32](repeating: 0, count: maskSize)

                var q = [0, 0, 0]
                q[d] = 1
                var x = [0, 0, 0]
                x[d] = -1

                while x[d] < dims[d] {
                    var n = 0
                    for j in 0..<dims[v] {
                        x[v] = j
                        for i in 0..<dims[u] {
                            x[u] = i

                            let aLocal = [x[0], x[1], x[2]]
                            let bLocal = [x[0] + q[0], x[1] + q[1], x[2] + q[2]]
                            let aOwned = isOwnedLocal(aLocal[0], aLocal[1], aLocal[2])
                            let bOwned = isOwnedLocal(bLocal[0], bLocal[1], bLocal[2])
                            let aSolid = solidAtLocalOrNeighbor(aLocal[0], aLocal[1], aLocal[2])
                            let bSolid = solidAtLocalOrNeighbor(bLocal[0], bLocal[1], bLocal[2])

                            if aSolid == bSolid || (!aOwned && !bOwned) {
                                mask[n] = 0
                                maskColors[n] = 0
                            } else if aSolid && aOwned {
                                mask[n] = 1
                                maskColors[n] = packedBiomeColorForOwnedBlock(aLocal[0], aLocal[1], aLocal[2])
                            } else if bSolid && bOwned {
                                mask[n] = -1
                                maskColors[n] = packedBiomeColorForOwnedBlock(bLocal[0], bLocal[1], bLocal[2])
                            } else {
                                mask[n] = 0
                                maskColors[n] = 0
                            }
                            n += 1
                        }
                    }

                    x[d] += 1
                    n = 0

                    for j in 0..<dims[v] {
                        var i = 0
                        while i < dims[u] {
                            let c = mask[n]
                            if c == 0 {
                                i += 1
                                n += 1
                                continue
                            }

                            var width = 1
                            let basePackedColor = maskColors[n]
                            while i + width < dims[u],
                                  mask[n + width] == c,
                                  maskColors[n + width] == basePackedColor {
                                width += 1
                            }

                            var height = 1
                            var done = false
                            while j + height < dims[v], !done {
                                for k in 0..<width {
                                    let maskIndex = n + k + height * dims[u]
                                    if mask[maskIndex] != c || maskColors[maskIndex] != basePackedColor {
                                        done = true
                                        break
                                    }
                                }
                                if !done {
                                    height += 1
                                }
                            }

                            var du = [0, 0, 0]
                            var dv = [0, 0, 0]
                            du[u] = width
                            dv[v] = height

                            var p = [x[0], x[1], x[2]]
                            p[u] = i
                            p[v] = j

                            let p0 = SIMD3<Float>(
                                Float(originX + p[0]),
                                Float(originY + p[1]),
                                Float(originZ + p[2])
                            )
                            let p1 = SIMD3<Float>(
                                Float(originX + p[0] + du[0]),
                                Float(originY + p[1] + du[1]),
                                Float(originZ + p[2] + du[2])
                            )
                            let p2 = SIMD3<Float>(
                                Float(originX + p[0] + du[0] + dv[0]),
                                Float(originY + p[1] + du[1] + dv[1]),
                                Float(originZ + p[2] + du[2] + dv[2])
                            )
                            let p3 = SIMD3<Float>(
                                Float(originX + p[0] + dv[0]),
                                Float(originY + p[1] + dv[1]),
                                Float(originZ + p[2] + dv[2])
                            )
                            let faceColor = shadedBiomeColor(
                                packedBaseColor: basePackedColor,
                                axis: d,
                                positiveFace: c > 0
                            )

                            if c > 0 {
                                appendQuad(&vertices, a: p0, b: p1, c: p2, d: p3, color: faceColor)
                            } else {
                                appendQuad(&vertices, a: p0, b: p3, c: p2, d: p1, color: faceColor)
                            }

                            for dy in 0..<height {
                                for dx in 0..<width {
                                    mask[n + dx + dy * dims[u]] = 0
                                }
                            }

                            i += width
                            n += width
                        }
                    }
                }
            }

            return vertices
        }

        private func appendQuad(
            _ vertices: inout [VulkanEngine.Vertex3D],
            a: SIMD3<Float>,
            b: SIMD3<Float>,
            c: SIMD3<Float>,
            d: SIMD3<Float>,
            color: SIMD4<Float>
        ) {
            vertices.append(.init(position: a, color: color))
            vertices.append(.init(position: b, color: color))
            vertices.append(.init(position: c, color: color))
            vertices.append(.init(position: a, color: color))
            vertices.append(.init(position: c, color: color))
            vertices.append(.init(position: d, color: color))
        }

        private func shadedBiomeColor(packedBaseColor: UInt32, axis: Int, positiveFace: Bool) -> SIMD4<Float> {
            let brightness: Float
            switch (axis, positiveFace) {
            case (1, true):
                brightness = 1.00
            case (1, false):
                brightness = 0.58
            case (0, _):
                brightness = positiveFace ? 0.78 : 0.70
            case (2, _):
                brightness = positiveFace ? 0.88 : 0.82
            default:
                brightness = 0.75
            }

            let baseColor = unpackColor(packedBaseColor)
            return SIMD4<Float>(
                baseColor.x * brightness,
                baseColor.y * brightness,
                baseColor.z * brightness,
                baseColor.w
            )
        }

        private func unpackColor(_ packed: UInt32) -> SIMD4<Float> {
            SIMD4<Float>(
                Float(packed & 0xFF) / 255,
                Float((packed >> 8) & 0xFF) / 255,
                Float((packed >> 16) & 0xFF) / 255,
                Float((packed >> 24) & 0xFF) / 255
            )
        }

        private static func makeOrderedOffsets(radius: Int) -> [ChunkCoord] {
            var offsets: [ChunkCoord] = []
            offsets.reserveCapacity((radius * 2 + 1) * (radius * 2 + 1))
            for z in -radius...radius {
                for x in -radius...radius {
                    offsets.append(.init(x: x, z: z))
                }
            }
            offsets.sort { lhs, rhs in
                let lhsRing = max(abs(lhs.x), abs(lhs.z))
                let rhsRing = max(abs(rhs.x), abs(rhs.z))
                if lhsRing != rhsRing { return lhsRing < rhsRing }
                let lhsDistance = abs(lhs.x) + abs(lhs.z)
                let rhsDistance = abs(rhs.x) + abs(rhs.z)
                if lhsDistance != rhsDistance { return lhsDistance < rhsDistance }
                if lhs.z != rhs.z { return lhs.z < rhs.z }
                return lhs.x < rhs.x
            }
            return offsets
        }
    }

    let moveSpeed: Float
    let fastMoveMultiplier: Float
    let zoomMultiplier: Float
    let mouseSensitivity: Float
    private let profilingEnabled = ProcessInfo.processInfo.environment["MINESCENE_PROFILE"] == "1"
    let streamer: Streamer
    let hudShadowColor = SIMD4<Float>(0.08, 0.10, 0.16, 1.0)
    let hudXColor = SIMD4<Float>(0.85, 0.22, 0.22, 1.0)
    let hudYColor = SIMD4<Float>(0.22, 0.72, 0.28, 1.0)
    let hudZColor = SIMD4<Float>(0.12, 0.20, 0.46, 1.0)
    let hudFpsColor = SIMD4<Float>(0.62, 0.28, 0.78, 1.0)
    let hudBiomeColor = SIMD4<Float>(0.95, 0.55, 0.14, 1.0)
    let hudDebugColor = SIMD4<Float>(0.62, 0.52, 0.12, 1.0)
    let commandPromptBackgroundColor = SIMD4<Float>(0.0, 0.0, 0.0, 0.72)
    let commandPromptTextColor = SIMD4<Float>(1.0, 1.0, 1.0, 1.0)
    let commandPromptCursorColor = SIMD4<Float>(1.0, 1.0, 1.0, 0.55)
    let commandPromptCursorBlinkPeriod: Float = 0.5
    let commandLogHoldDuration: Float = 5.0
    let commandLogFadeDuration: Float = 5.0
    let commandLogBackgroundColor = SIMD4<Float>(0.0, 0.0, 0.0, 0.72)
    let commandLogErrorColor = SIMD4<Float>(0.92, 0.28, 0.24, 1.0)

    var externalCommandExecutor: ((String, String, TerrainRenderer) throws -> Bool)?
    var chunkMeshes: [ChunkCoord: ChunkRenderMesh] = [:]
    var hudBuffer: VulkanOwnedBuffer?
    var hudMemory: VulkanOwnedDeviceMemory?
    var hudVertexCount: UInt32 = 0
    var hudVertexCapacity = 0
    var lastHudText = ""
    var lastHudViewport = SIMD2<Int>(repeating: -1)
    var lastHudBiome = ""

    var cameraPosition = SIMD3<Float>(x: 0.0, y: 160.0, z: 0.0)
    var cameraYaw: Float = -.pi / 4.0
    var cameraPitch: Float = -.pi / 5.5
    var smoothedFps: Float = 0

    var keyW = false
    var keyA = false
    var keyS = false
    var keyD = false
    var keySpace = false
    var keyShift = false
    var keyR = false
    var keyX = false
    var commandPromptActive = false
    var commandPromptText = ""
    var commandPromptDraftText = ""
    var commandPromptCursorElapsed: Float = 0
    var commandPromptHistory: [String] = []
    var commandPromptHistoryIndex: Int?
    var commandLogEntries: [TerrainRendererCommandLogEntry] = []

    init(
        worldGenerator: WorldGenerator,
        biomeColorPalette: BiomeColorPalette,
        renderRadius: Int = 12,
        moveSpeed: Float = 32.0,
        fastMoveMultiplier: Float = 4.0,
        zoomMultiplier: Float = 4.0,
        mouseSensitivity: Float = 0.0025,
        generationWorkerCount: Int = max(1, ProcessInfo.processInfo.activeProcessorCount - 1)
    ) {
        self.moveSpeed = moveSpeed
        self.fastMoveMultiplier = fastMoveMultiplier
        self.zoomMultiplier = max(1, zoomMultiplier)
        self.mouseSensitivity = mouseSensitivity
        self.streamer = Streamer(
            worldGenerator: worldGenerator,
            renderRadius: renderRadius,
            generationWorkerCount: generationWorkerCount,
            retargetAroundCameraMovement: true,
            biomeColorPalette: biomeColorPalette
        )
    }

    func render(
        engine: VulkanEngine,
        window: OpaquePointer?,
        imageAvailable: VkSemaphore,
        renderFinishedByImage: [VkSemaphore]
    ) throws {
        try engine.device.waitForFences([engine.inFlightFence.fence], waitAll: true, timeout: UInt64.max)
        try applyCompletedBuildIfAvailable(engine: engine)

        var windowW: Int32 = 800
        var windowH: Int32 = 800
        if let window {
            SDL_GetWindowSize(window, &windowW, &windowH)
        }
        let width = max(1, Float(windowW))
        let height = max(1, Float(windowH))
        let aspect = width / height
        let baseFovYRadians: Float = 65.0 * .pi / 180.0
        let effectiveFovYRadians: Float
        if keyX {
            effectiveFovYRadians = 2 * atan(tan(baseFovYRadians * 0.5) / zoomMultiplier)
        } else {
            effectiveFovYRadians = baseFovYRadians
        }

        let view = lookAtRH(
            eye: cameraPosition,
            center: cameraPosition + viewForward(),
            up: SIMD3<Float>(0, 1, 0)
        )
        let projection = perspectiveRH(
            fovYRadians: effectiveFovYRadians,
            aspect: aspect,
            nearZ: 0.05,
            farZ: 2048.0
        )

        try engine.updateTransform3D(projection)
        try engine.updateModel3D(matrix_identity_float4x4)
        try engine.updateView3D(view)
        try engine.updateTransform2D(hudTransform(width: width, height: height))
        engine.setClearColor(SIMD4<Float>(0.63, 0.82, 0.98, 1.0))
        try updateHudIfNeeded(engine: engine, viewportWidth: Int(width), viewportHeight: Int(height))

        let imageIndex = try engine.device.acquireNextImage(from: engine.swapchain, semaphore: imageAvailable)
        guard Int(imageIndex) < renderFinishedByImage.count else {
            throw TerrainRendererError.invalidSwapchainImageIndex
        }
        let renderFinished = renderFinishedByImage[Int(imageIndex)]

        let batches: [VulkanEngine.DrawBatch3D] = chunkMeshes.keys.sorted { lhs, rhs in
            if lhs.z != rhs.z { return lhs.z < rhs.z }
            return lhs.x < rhs.x
        }.compactMap { coord in
            guard let mesh = chunkMeshes[coord], mesh.vertexCount > 0 else {
                return nil
            }
            return .init(buffer: mesh.buffer, vertexCount: mesh.vertexCount)
        }
        let hudBatches: [VulkanEngine.DrawBatch2D]
        if let hudBuffer, hudVertexCount > 0 {
            hudBatches = [.init(buffer: hudBuffer, vertexCount: hudVertexCount)]
        } else {
            hudBatches = []
        }

        try engine.drawBatches3DAnd2D(
            batches3D: batches,
            batches2D: hudBatches,
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

    private func applyCompletedBuildIfAvailable(engine: VulkanEngine) throws {
        let completed = streamer.takeCompletedResults()
        guard !completed.results.isEmpty || !completed.removals.isEmpty else {
            return
        }

        for coord in completed.removals {
            chunkMeshes.removeValue(forKey: coord)
        }

        for result in completed.results {
            chunkMeshes.removeValue(forKey: result.coord)

            let uploadStart = CFAbsoluteTimeGetCurrent()
            if !result.vertices.isEmpty {
                let (buffer, memory) = try engine.createVertexBuffer3D(result.vertices)
                chunkMeshes[result.coord] = ChunkRenderMesh(
                    buffer: buffer,
                    memory: memory,
                    vertexCount: UInt32(result.vertices.count)
                )
            }

            var profile = result.profile
            profile.uploadSeconds = CFAbsoluteTimeGetCurrent() - uploadStart
            logChunkMesh(
                coord: result.coord,
                profile: profile,
                vertexCount: result.vertices.count,
                availableChunks: result.availableChunks,
                totalTargetChunks: result.totalTargetChunks
            )
        }
    }

    private func logChunkMesh(
        coord: ChunkCoord,
        profile: MeshProfile,
        vertexCount: Int,
        availableChunks: Int,
        totalTargetChunks: Int
    ) {
        guard profilingEnabled else {
            return
        }
        let totalMs = (profile.generationSeconds + profile.meshSeconds + profile.uploadSeconds) * 1000
        print(
            String(
                format: "Chunk mesh: chunk=(%d,%d) available=%d/%d gen=%.1fms mesh=%.1fms upload=%.1fms total=%.1fms vertices=%d",
                coord.x,
                coord.z,
                availableChunks,
                totalTargetChunks,
                profile.generationSeconds * 1000,
                profile.meshSeconds * 1000,
                profile.uploadSeconds * 1000,
                totalMs,
                vertexCount
            )
        )
    }

    func discardChunkMeshes() {
        chunkMeshes.removeAll()
    }

    func requestChunkMeshRebuild() {
        streamer.requestMeshRebuild()
    }
}

enum TerrainRendererError: Error {
    case invalidSwapchainImageIndex
}
