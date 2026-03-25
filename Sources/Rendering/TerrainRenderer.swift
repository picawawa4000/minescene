import Foundation
import DPReader
import SwiftSDL
import Vulkan
import VulkanBindings
import simd

final class TerrainRenderer {
    private struct MeshProfile {
        var generationSeconds: Double = 0
        var meshSeconds: Double = 0
        var uploadSeconds: Double = 0
    }

    private struct ChunkCoord: Hashable {
        let x: Int
        let z: Int
    }

    private struct ChunkMeshSnapshot {
        let coord: ChunkCoord
        let revision: Int
        let chunk: ProtoChunk
        let neighbors: [ChunkCoord: ProtoChunk]
        let generationSeconds: Double
        let totalTargetChunks: Int
        let availableChunks: Int
    }

    private struct ChunkMeshResult {
        let coord: ChunkCoord
        let revision: Int
        let vertices: [VulkanEngine.Vertex3D]
        let profile: MeshProfile
        let availableChunks: Int
        let totalTargetChunks: Int
    }

    private struct ChunkRenderMesh {
        let buffer: VulkanOwnedBuffer
        let memory: VulkanOwnedDeviceMemory
        let vertexCount: UInt32
    }

    private struct StreamDebugStatus {
        let generatedChunks: Int
        let inFlightGenerationChunks: Int
        let dirtyMeshChunks: Int
        let inFlightMeshChunks: Int
        let totalTargetChunks: Int
    }

    private final class Streamer: @unchecked Sendable {
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
        private var chunks: [ChunkCoord: ProtoChunk] = [:]
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
            let blockChanged = targetCameraBlock != cameraBlock
            targetCenter = effectiveCenter
            targetCameraBlock = cameraBlock
            if centerChanged {
                let removed = pruneChunksLocked(around: effectiveCenter)
                for removedCoord in removed {
                    markChunkRemovedLocked(removedCoord)
                }
            }
            if centerChanged || blockChanged {
                if centerChanged {
                    for coord in chunks.keys {
                        markChunkDirtyLocked(coord)
                    }
                }
                requestRebuildLocked()
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
            let localY = cameraBlock.y - Int(chunk.minY)
            guard localY >= 0, localY < Int(chunk.height) else {
                return nil
            }
            return chunk.biome(
                atLocal: PosInt3D(
                    x: Int32(localX),
                    y: Int32(localY),
                    z: Int32(localZ)
                )
            )?.name
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

                var generationWorkersToStart = 0
                var meshWorkersToStart = 0
                lock.lock()
                inFlightChunks.remove(chunkCoord)
                if generationSucceeded, let center = targetCenter, shouldKeepChunk(chunkCoord, around: center) {
                    chunks[chunkCoord] = protoChunk
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

        private func requestRebuildLocked() {
            _ = startMeshWorkersLocked()
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
                var neighbors: [ChunkCoord: ProtoChunk] = [coord: chunk]
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
            chunk: ProtoChunk,
            neighbors: [ChunkCoord: ProtoChunk]
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
            let originY = Int(chunk.minY) + firstSolidSection * ProtoChunk.sectionHeight
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
                let biome = chunk.biome(
                    atLocal: PosInt3D(
                        x: Int32(x),
                        y: Int32(absoluteLocalY),
                        z: Int32(z)
                    )
                )
                return biomeColorPalette.packedRGBA8(forBiomeID: biome?.name)
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
                let localY = worldY - Int(queryChunk.minY)
                guard localY >= 0, localY < Int(queryChunk.height) else {
                    return false
                }
                return queryChunk.isTerrain(
                    atLocal: PosInt3D(
                        x: Int32(localX),
                        y: Int32(localY),
                        z: Int32(localZ)
                    )
                )
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

    private let moveSpeed: Float
    private let fastMoveMultiplier: Float
    private let mouseSensitivity: Float
    private let profilingEnabled = ProcessInfo.processInfo.environment["MINESCENE_PROFILE"] == "1"
    private let streamer: Streamer
    private let hudShadowColor = SIMD4<Float>(0.08, 0.10, 0.16, 1.0)
    private let hudXColor = SIMD4<Float>(0.85, 0.22, 0.22, 1.0)
    private let hudYColor = SIMD4<Float>(0.22, 0.72, 0.28, 1.0)
    private let hudZColor = SIMD4<Float>(0.12, 0.20, 0.46, 1.0)
    private let hudFpsColor = SIMD4<Float>(0.62, 0.28, 0.78, 1.0)
    private let hudBiomeColor = SIMD4<Float>(0.95, 0.55, 0.14, 1.0)
    private let hudDebugColor = SIMD4<Float>(0.62, 0.52, 0.12, 1.0)

    private var chunkMeshes: [ChunkCoord: ChunkRenderMesh] = [:]
    private var hudBuffer: VulkanOwnedBuffer?
    private var hudMemory: VulkanOwnedDeviceMemory?
    private var hudVertexCount: UInt32 = 0
    private var hudVertexCapacity = 0
    private var lastHudText = ""
    private var lastHudViewport = SIMD2<Int>(repeating: -1)
    private var lastHudBiome = ""

    private var cameraPosition = SIMD3<Float>(x: 0.0, y: 160.0, z: 0.0)
    private var cameraYaw: Float = -.pi / 4.0
    private var cameraPitch: Float = -.pi / 5.5
    private var smoothedFps: Float = 0

    private var keyW = false
    private var keyA = false
    private var keyS = false
    private var keyD = false
    private var keySpace = false
    private var keyShift = false
    private var keyR = false

    init(
        worldGenerator: WorldGenerator,
        biomeColorPalette: BiomeColorPalette,
        renderRadius: Int = 12,
        moveSpeed: Float = 32.0,
        fastMoveMultiplier: Float = 4.0,
        mouseSensitivity: Float = 0.0025,
        generationWorkerCount: Int = max(1, ProcessInfo.processInfo.activeProcessorCount - 1)
    ) {
        self.moveSpeed = moveSpeed
        self.fastMoveMultiplier = fastMoveMultiplier
        self.mouseSensitivity = mouseSensitivity
        self.streamer = Streamer(
            worldGenerator: worldGenerator,
            renderRadius: renderRadius,
            generationWorkerCount: generationWorkerCount,
            retargetAroundCameraMovement: true,
            biomeColorPalette: biomeColorPalette
        )
    }

    func handleEvent(_ event: SDL_Event) {
        switch event.eventType {
        case .keyDown:
            if event.key.repeat {
                return
            }
            setKeyState(key: event.key.key, pressed: true)
        case .keyUp:
            setKeyState(key: event.key.key, pressed: false)
        case .mouseMotion:
            let delta = event.motion.relative(as: Float.self)
            cameraYaw += delta.x * mouseSensitivity
            cameraPitch -= delta.y * mouseSensitivity
            cameraPitch = max(-(.pi / 2.0 - 0.01), min(.pi / 2.0 - 0.01, cameraPitch))
        default:
            break
        }
    }

    private func setKeyState(key: SDL_Keycode, pressed: Bool) {
        switch key {
        case SDLK_W:
            keyW = pressed
        case SDLK_A:
            keyA = pressed
        case SDLK_S:
            keyS = pressed
        case SDLK_D:
            keyD = pressed
        case SDLK_SPACE:
            keySpace = pressed
        case SDLK_LSHIFT, SDLK_RSHIFT:
            keyShift = pressed
        case SDLK_R:
            keyR = pressed
        case SDLK_LEFTBRACKET:
            if pressed {
                streamer.adjustRenderRadius(by: -1)
            }
        case SDLK_RIGHTBRACKET:
            if pressed {
                streamer.adjustRenderRadius(by: 1)
            }
        default:
            break
        }
    }

    func update(deltaTime: Float) {
        if deltaTime > 0 {
            let instantaneousFps = min(240, 1 / deltaTime)
            if smoothedFps == 0 {
                smoothedFps = instantaneousFps
            } else {
                smoothedFps += (instantaneousFps - smoothedFps) * 0.12
            }
        }

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
        if keyW { movement += horizontalForward }
        if keyS { movement -= horizontalForward }
        if keyD { movement += horizontalRight }
        if keyA { movement -= horizontalRight }
        if keySpace { movement.y += 1 }
        if keyShift { movement.y -= 1 }

        if simd_length_squared(movement) > 0 {
            movement = simd_normalize(movement)
            let currentMoveSpeed = moveSpeed * (keyR ? fastMoveMultiplier : 1)
            cameraPosition += movement * currentMoveSpeed * max(0, deltaTime)
        }

        let cameraBlock = SIMD3<Int>(
            Int(floor(cameraPosition.x)),
            Int(floor(cameraPosition.y)),
            Int(floor(cameraPosition.z))
        )
        let cameraChunk = ChunkCoord(
            x: floorDiv(cameraBlock.x, 16),
            z: floorDiv(cameraBlock.z, 16)
        )
        streamer.updateTarget(center: cameraChunk, cameraBlock: cameraBlock)
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

        let view = lookAtRH(
            eye: cameraPosition,
            center: cameraPosition + viewForward(),
            up: SIMD3<Float>(0, 1, 0)
        )
        let projection = perspectiveRH(
            fovYRadians: 65.0 * .pi / 180.0,
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

    private func viewForward() -> SIMD3<Float> {
        let cp = cos(cameraPitch)
        return normalizeOrZero(SIMD3<Float>(
            x: cos(cameraYaw) * cp,
            y: sin(cameraPitch),
            z: sin(cameraYaw) * cp
        ))
    }

    private func updateHudIfNeeded(engine: VulkanEngine, viewportWidth: Int, viewportHeight: Int) throws {
        let biomeText = currentBiomeHudText()
        let debugLines = currentDebugHudLines()
        let positionRuns = [
            HudTextRun(text: String(format: "X: %.1f ", Double(cameraPosition.x)), color: hudXColor),
            HudTextRun(text: String(format: "Y: %.1f ", Double(cameraPosition.y)), color: hudYColor),
            HudTextRun(text: String(format: "Z: %.1f", Double(cameraPosition.z)), color: hudZColor)
        ]
        let fpsRuns = [
            HudTextRun(text: String(format: "FPS: %.0f", Double(smoothedFps)), color: hudFpsColor)
        ]
        let biomeRuns = [
            HudTextRun(text: biomeText, color: hudBiomeColor)
        ]
        let debugRuns = debugLines.map { [HudTextRun(text: $0, color: hudDebugColor)] }
        let hudText = ([positionRuns, fpsRuns, biomeRuns] + debugRuns)
            .flatMap { $0.map(\.text) }
            .joined(separator: "\n")
        let viewport = SIMD2<Int>(viewportWidth, viewportHeight)
        guard hudText != lastHudText || viewport != lastHudViewport || biomeText != lastHudBiome else {
            return
        }

        let vertices = makeHudVertices(
            viewportWidth: viewportWidth,
            leftLines: [positionRuns, fpsRuns],
            rightLines: [biomeRuns] + debugRuns
        )
        if vertices.isEmpty {
            hudVertexCount = 0
            lastHudText = hudText
            lastHudViewport = viewport
            lastHudBiome = biomeText
            return
        }

        if hudBuffer == nil || hudMemory == nil || vertices.count > hudVertexCapacity {
            hudBuffer = nil
            hudMemory = nil
            hudVertexCapacity = max(vertices.count, max(256, hudVertexCapacity * 2))
            let (buffer, memory) = try engine.createVertexBuffer2DCapacity(hudVertexCapacity)
            hudBuffer = buffer
            hudMemory = memory
        }

        guard let hudBuffer, let hudMemory else {
            return
        }

        hudVertexCount = try engine.updateVertexBuffer2D(
            vertices,
            buffer: hudBuffer,
            memory: hudMemory,
            capacity: hudVertexCapacity
        )
        lastHudText = hudText
        lastHudViewport = viewport
        lastHudBiome = biomeText
    }

    private struct HudTextRun {
        let text: String
        let color: SIMD4<Float>
    }

    private struct HudStyle {
        let cellSize: Float
        let glyphAdvance: Float
        let lineAdvance: Float
    }

    private enum HudAlignment {
        case left
        case right
    }

    private func makeHudVertices(
        viewportWidth: Int,
        leftLines: [[HudTextRun]],
        rightLines: [[HudTextRun]]
    ) -> [VulkanEngine.Vertex2D] {
        let standardStyle = HudStyle(cellSize: 5, glyphAdvance: 20, lineAdvance: 34)
        let compactStyle = HudStyle(cellSize: 3, glyphAdvance: 12, lineAdvance: 16)
        let shadowOffset = SIMD2<Float>(1, 1)
        let leftOrigin = SIMD2<Float>(12, 12)
        let rightMargin: Float = 12

        var vertices: [VulkanEngine.Vertex2D] = []
        let characterCount = (leftLines + rightLines).flatMap { $0 }.reduce(0) { $0 + $1.text.count }
        vertices.reserveCapacity(characterCount * 180)

        appendHudLines(
            leftLines,
            originX: leftOrigin.x,
            originY: leftOrigin.y,
            viewportWidth: Float(viewportWidth),
            alignment: .left,
            style: standardStyle,
            shadowOffset: shadowOffset,
            into: &vertices
        )
        appendHudLines(
            rightLines,
            originX: Float(viewportWidth) - rightMargin,
            originY: leftOrigin.y,
            viewportWidth: Float(viewportWidth),
            alignment: .right,
            style: compactStyle,
            shadowOffset: shadowOffset,
            into: &vertices
        )

        return vertices
    }

    private func appendHudLines(
        _ lines: [[HudTextRun]],
        originX: Float,
        originY: Float,
        viewportWidth: Float,
        alignment: HudAlignment,
        style: HudStyle,
        shadowOffset: SIMD2<Float>,
        into vertices: inout [VulkanEngine.Vertex2D]
    ) {
        for (lineIndex, lineRuns) in lines.enumerated() {
            let lineWidth = hudLineWidth(lineRuns, glyphAdvance: style.glyphAdvance)
            let startX: Float
            switch alignment {
            case .left:
                startX = originX
            case .right:
                startX = max(0, min(originX - lineWidth, viewportWidth - lineWidth))
            }

            var cursorX = startX
            let lineY = originY + Float(lineIndex) * style.lineAdvance
            for run in lineRuns {
                for character in run.text {
                    let glyph = Self.hudGlyphs[character] ?? Self.hudGlyphs[" "]!
                    appendGlyph(
                        glyph,
                        origin: SIMD2<Float>(cursorX + shadowOffset.x, lineY + shadowOffset.y),
                        cellSize: style.cellSize,
                        color: hudShadowColor,
                        into: &vertices
                    )
                    appendGlyph(
                        glyph,
                        origin: SIMD2<Float>(cursorX, lineY),
                        cellSize: style.cellSize,
                        color: run.color,
                        into: &vertices
                    )
                    cursorX += style.glyphAdvance
                }
            }
        }
    }

    private func hudLineWidth(_ runs: [HudTextRun], glyphAdvance: Float) -> Float {
        Float(runs.reduce(0) { $0 + $1.text.count }) * glyphAdvance
    }

    private func currentBiomeHudText() -> String {
        let cameraBlock = SIMD3<Int>(
            Int(floor(cameraPosition.x)),
            Int(floor(cameraPosition.y)),
            Int(floor(cameraPosition.z))
        )
        let biomeName = streamer.currentBiomeName(at: cameraBlock) ?? "unknown"
        return "BIOME: \(formatBiomeName(biomeName))"
    }

    private func currentDebugHudLines() -> [String] {
        let status = streamer.debugStatus()
        return [
            "CHUNKS: \(status.generatedChunks)/\(status.totalTargetChunks)",
            "GEN: \(status.inFlightGenerationChunks) MESH: \(status.inFlightMeshChunks)",
            "DIRTY: \(status.dirtyMeshChunks) DRAWN: \(chunkMeshes.count)"
        ]
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
                appendHudQuad(
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

    private func appendHudQuad(
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

    private func hudTransform(width: Float, height: Float) -> simd_float4x4 {
        simd_float4x4(
            SIMD4<Float>(2 / width, 0, 0, 0),
            SIMD4<Float>(0, 2 / height, 0, 0),
            SIMD4<Float>(0, 0, 1, 0),
            SIMD4<Float>(-1, -1, 0, 1)
        )
    }

    private func normalizeOrZero(_ v: SIMD3<Float>) -> SIMD3<Float> {
        let lenSq = simd_length_squared(v)
        if lenSq <= 1e-8 {
            return .zero
        }
        return v / sqrt(lenSq)
    }

    private func floorDiv(_ value: Int, _ divisor: Int) -> Int {
        if value >= 0 {
            return value / divisor
        }
        return -(((-value) + divisor - 1) / divisor)
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
        "G": ["011", "100", "101", "101", "011"],
        "H": ["101", "101", "111", "101", "101"],
        "I": ["111", "010", "010", "010", "111"],
        "J": ["001", "001", "001", "101", "010"],
        "K": ["101", "101", "110", "101", "101"],
        "L": ["100", "100", "100", "100", "111"],
        "M": ["101", "111", "111", "101", "101"],
        "N": ["101", "111", "111", "111", "101"],
        "O": ["010", "101", "101", "101", "010"],
        "Q": ["010", "101", "101", "111", "011"],
        "R": ["110", "101", "110", "101", "101"],
        "T": ["111", "010", "010", "010", "010"],
        "U": ["101", "101", "101", "101", "111"],
        "V": ["101", "101", "101", "101", "010"],
        "W": ["101", "101", "111", "111", "101"],
        "X": ["101", "101", "010", "101", "101"],
        "Y": ["101", "101", "010", "010", "010"],
        "Z": ["111", "001", "010", "100", "111"],
        "F": ["111", "100", "110", "100", "100"],
        "P": ["110", "101", "110", "100", "100"],
        "S": ["111", "100", "111", "001", "111"],
        "/": ["001", "001", "010", "100", "100"],
        ":": ["000", "010", "000", "010", "000"],
        ".": ["000", "000", "000", "000", "010"],
        "-": ["000", "000", "111", "000", "000"],
        " ": ["000", "000", "000", "000", "000"]
    ]
}

enum TerrainRendererError: Error {
    case invalidSwapchainImageIndex
}
