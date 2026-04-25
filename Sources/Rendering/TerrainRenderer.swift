import Foundation
@preconcurrency import DPReader
import SwiftSDL
import Vulkan
import VulkanBindings
#if canImport(simd)
import simd
#endif

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

    @inline(__always)
    static func currentTimeSeconds() -> Double {
        ProcessInfo.processInfo.systemUptime
    }

    private struct CompactBiomeEntry {
        let name: String
        let packedColor: UInt32
    }

    private struct CompactSection {
        let sampleStride: Int
        let cellSideLength: Int
        let bitmap: [UInt64]
        let biomePalette: [CompactBiomeEntry]
        let biomeIndices: [UInt8]

        @inline(__always)
        func biomeEntry(atLocalX x: Int, y: Int, z: Int) -> CompactBiomeEntry {
            biomePalette[Int(biomeIndices[cellIndex(atLocalX: x, y: y, z: z)])]
        }

        @inline(__always)
        func isSolid(atLocalX x: Int, y: Int, z: Int) -> Bool {
            let blockIndex = cellIndex(atLocalX: x, y: y, z: z)
            let wordIndex = blockIndex >> 6
            let bitIndex = blockIndex & 63
            return (bitmap[wordIndex] & (UInt64(1) << UInt64(bitIndex))) != 0
        }

        var hasAnySolid: Bool {
            bitmap.contains(where: { $0 != 0 })
        }

        @inline(__always)
        private func cellIndex(atLocalX x: Int, y: Int, z: Int) -> Int {
            let cellX = x / sampleStride
            let cellY = y / sampleStride
            let cellZ = z / sampleStride
            return (cellY * cellSideLength + cellZ) * cellSideLength + cellX
        }
    }

    private struct CompactChunkLod {
        let sampleStride: Int
        let sections: [CompactSection]

        @inline(__always)
        func section(at index: Int) -> CompactSection? {
            guard index >= 0, index < sections.count else {
                return nil
            }
            return sections[index]
        }
    }

    private struct CompactChunk {
        let minY: Int
        let height: Int
        let lods: [CompactChunkLod]

        var minimumAvailableSampleStride: Int { lods.first?.sampleStride ?? 1 }
        var sectionCount: Int { lods[0].sections.count }

        @inline(__always)
        func section(at index: Int, sampleStride: Int = 1) -> CompactSection? {
            lod(forSampleStride: sampleStride).section(at: index)
        }

        @inline(__always)
        func biomeEntry(atLocalX x: Int, y: Int, z: Int, sampleStride: Int = 1) -> CompactBiomeEntry? {
            guard x >= 0, x < 16, y >= 0, y < height, z >= 0, z < 16 else {
                return nil
            }
            let sectionIndex = y >> 4
            let localY = y & 15
            return lod(forSampleStride: sampleStride).sections[sectionIndex].biomeEntry(
                atLocalX: x,
                y: localY,
                z: z
            )
        }

        @inline(__always)
        func isSolid(atLocalX x: Int, y: Int, z: Int, sampleStride: Int = 1) -> Bool {
            guard x >= 0, x < 16, y >= 0, y < height, z >= 0, z < 16 else {
                return false
            }
            let sectionIndex = y >> 4
            let localY = y & 15
            return lod(forSampleStride: sampleStride).sections[sectionIndex].isSolid(
                atLocalX: x,
                y: localY,
                z: z
            )
        }

        @inline(__always)
        private func lod(forSampleStride sampleStride: Int) -> CompactChunkLod {
            if let exact = lods.first(where: { $0.sampleStride == sampleStride }) {
                return exact
            }
            if let nextHigher = lods.first(where: { $0.sampleStride > sampleStride }) {
                return nextHigher
            }
            guard let coarsest = lods.last else {
                preconditionFailure("compact chunk has no LODs")
            }
            return coarsest
        }
    }

    struct TerrainLodSettings {
        var nearDistance: Int
        var stepDistance: Int
        var maxSampleStride: Int
    }

    private struct ChunkMeshSnapshot {
        let coord: ChunkCoord
        let revision: Int
        let chunk: CompactChunk
        let neighbors: [ChunkCoord: CompactChunk]
        let sampleStrideByChunk: [ChunkCoord: Int]
        let generationSeconds: Double
        let totalTargetChunks: Int
        let availableChunks: Int
    }

    struct ChunkMeshResult {
        let coord: ChunkCoord
        let revision: Int
        let origin: SIMD3<Int>
        let vertices: [VulkanEngine.Vertex3D]
        let profile: MeshProfile
        let availableChunks: Int
        let totalTargetChunks: Int
    }

    struct ChunkRenderMesh {
        let buffer: VulkanOwnedBuffer
        let memory: VulkanOwnedDeviceMemory
        let vertexCount: UInt32
        let origin: SIMD3<Int>
    }

    struct StreamDebugStatus {
        let generatedChunks: Int
        let inFlightGenerationChunks: Int
        let dirtyMeshChunks: Int
        let inFlightMeshChunks: Int
        let totalTargetChunks: Int
    }

    struct CinematicPreparationStatus {
        let readyChunks: Int
        let totalChunks: Int
        let generatingChunks: Int
        let meshingChunks: Int
    }

    struct Keyframe: Equatable {
        let position: SIMD3<Double>
        let yaw: Float
        let pitch: Float
    }

    struct CinematicPathSample {
        let position: SIMD3<Double>
        let yaw: Float
        let pitch: Float
        let timeFromStart: Double
    }

    struct CinematicPath {
        let samples: [CinematicPathSample]
        let totalDuration: Double
    }

    enum CinematicPlaybackPhase {
        case preparing
        case playing(startTimeSeconds: Double)
    }

    struct CinematicPlaybackSession {
        let path: CinematicPath
        let pinnedChunks: Set<ChunkCoord>
        var phase: CinematicPlaybackPhase
    }

    final class Streamer: @unchecked Sendable {
        private static let supportedSampleStrides = [1, 2, 4, 8, 16]
        private struct LODSnapshotKey: Equatable {
            let center: ChunkCoord
            let renderRadius: Int
            let nearDistance: Int
            let stepDistance: Int
            let maxSampleStride: Int
        }

        private struct LODSnapshotRequest {
            let key: LODSnapshotKey
            let origin: PosInt3D
            let radius: Int32
            let maxCellSizePower: Int
        }

        private final class LODSnapshot {
            let result: TerrainLODResult

            init(result: TerrainLODResult) {
                self.result = result
            }
        }

        private let worldGenerator: WorldGenerator
        private let generationWorkerCount: Int
        private let retargetAroundCameraMovement: Bool
        private let biomeColorPalette: BiomeColorPalette
        private let sampleLodLock = NSLock()
        private var cachedBaseLodCellSize: Int?
        private var lodSnapshotKey: LODSnapshotKey?
        private var lodSnapshot: LODSnapshot?

        private let lock = NSLock()
        private let generationQueue = DispatchQueue(label: "TerrainRenderer.Generation", qos: .userInitiated, attributes: .concurrent)
        private let meshQueue = DispatchQueue(label: "TerrainRenderer.Mesh", qos: .userInitiated, attributes: .concurrent)

        private var renderRadius: Int
        private var orderedOffsets: [ChunkCoord]
        private var terrainLodSettings: TerrainLodSettings
        private var targetCenter: ChunkCoord?
        private var targetCameraBlock = SIMD3<Int>(Int.min, Int.min, Int.min)
        private var pinnedChunks: Set<ChunkCoord> = []
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
            biomeColorPalette: BiomeColorPalette,
            terrainLodSettings: TerrainLodSettings
        ) {
            self.worldGenerator = worldGenerator
            self.renderRadius = max(0, renderRadius)
            self.generationWorkerCount = max(1, generationWorkerCount)
            self.retargetAroundCameraMovement = retargetAroundCameraMovement
            self.biomeColorPalette = biomeColorPalette
            self.terrainLodSettings = terrainLodSettings
            self.orderedOffsets = Self.makeOrderedOffsets(radius: self.renderRadius)
        }

        func adjustRenderRadius(by delta: Int) -> Int {
            setRenderRadius(to: renderRadius + delta)
        }

        func setRenderRadius(to requestedRadius: Int) -> Int {
            var generationWorkersToStart = 0
            var meshWorkersToStart = 0
            var currentRenderRadius = 0

            lock.lock()
            let nextRadius = max(0, requestedRadius)
            guard nextRadius != renderRadius else {
                currentRenderRadius = renderRadius
                lock.unlock()
                return currentRenderRadius
            }

            renderRadius = nextRadius
            currentRenderRadius = renderRadius
            orderedOffsets = Self.makeOrderedOffsets(radius: renderRadius)
            invalidateLodSnapshotLocked()

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
            return currentRenderRadius
        }

        func currentRenderRadius() -> Int {
            lock.lock()
            let currentRenderRadius = renderRadius
            lock.unlock()
            return currentRenderRadius
        }

        func setPinnedChunks(_ nextPinnedChunks: Set<ChunkCoord>) {
            var generationWorkersToStart = 0
            var meshWorkersToStart = 0

            lock.lock()
            pinnedChunks = nextPinnedChunks
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

        func pinnedChunksReady() -> Bool {
            lock.lock()
            defer { lock.unlock() }

            guard !pinnedChunks.isEmpty else {
                return true
            }

            for coord in pinnedChunks {
                if chunks[coord] == nil || inFlightChunks.contains(coord) {
                    return false
                }
                if dirtyMeshChunks.contains(coord) || inFlightMeshChunks.contains(coord) {
                    return false
                }
            }
            return true
        }

        func pinnedChunkPreparationStatus() -> CinematicPreparationStatus {
            lock.lock()
            defer { lock.unlock() }

            var readyChunks = 0
            var generatingChunks = 0
            var meshingChunks = 0

            for coord in pinnedChunks {
                let isLoaded = chunks[coord] != nil
                let isGenerating = inFlightChunks.contains(coord)
                let isMeshing = dirtyMeshChunks.contains(coord) || inFlightMeshChunks.contains(coord)

                if isLoaded && !isGenerating && !isMeshing {
                    readyChunks += 1
                }
                if isGenerating {
                    generatingChunks += 1
                }
                if isMeshing {
                    meshingChunks += 1
                }
            }

            return CinematicPreparationStatus(
                readyChunks: readyChunks,
                totalChunks: pinnedChunks.count,
                generatingChunks: generatingChunks,
                meshingChunks: meshingChunks
            )
        }

        func updateTarget(center: ChunkCoord, cameraBlock: SIMD3<Int>) {
            var generationWorkersToStart = 0
            var meshWorkersToStart = 0
            lock.lock()
            let previousCenter = targetCenter
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
                invalidateLodSnapshotLocked()
                let removed = pruneChunksLocked(around: effectiveCenter)
                for removedCoord in removed {
                    markChunkRemovedLocked(removedCoord)
                }
            }
            if centerChanged {
                let impactedChunks = impactedChunksForSampleStrideChangesLocked(
                    previousCenter: previousCenter,
                    previousSettings: terrainLodSettings,
                    nextCenter: effectiveCenter,
                    nextSettings: terrainLodSettings
                )
                invalidatePendingMeshResultsLocked(for: impactedChunks)
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
            let targetChunks = targetChunksLocked()
            let generatedChunks = targetChunks.reduce(into: 0) { count, coord in
                if chunks[coord] != nil {
                    count += 1
                }
            }
            let inFlightGenerationChunks = targetChunks.reduce(into: 0) { count, coord in
                if inFlightChunks.contains(coord) {
                    count += 1
                }
            }

            return StreamDebugStatus(
                generatedChunks: generatedChunks,
                inFlightGenerationChunks: inFlightGenerationChunks,
                dirtyMeshChunks: dirtyMeshChunks.count,
                inFlightMeshChunks: inFlightMeshChunks.count,
                totalTargetChunks: targetChunks.count
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

        func setTerrainLodSettings(
            nearDistance: Int,
            stepDistance: Int,
            maxSampleStride: Int
        ) {
            let normalized = TerrainLodSettings(
                nearDistance: max(0, nearDistance),
                stepDistance: max(1, stepDistance),
                maxSampleStride: Self.normalizedSampleStride(maxSampleStride)
            )
            var meshWorkersToStart = 0

            lock.lock()
            guard normalized.nearDistance != terrainLodSettings.nearDistance ||
                    normalized.stepDistance != terrainLodSettings.stepDistance ||
                    normalized.maxSampleStride != terrainLodSettings.maxSampleStride else {
                lock.unlock()
                return
            }

            let previousSettings = terrainLodSettings
            terrainLodSettings = normalized
            invalidateLodSnapshotLocked()
            let impactedChunks = impactedChunksForSampleStrideChangesLocked(
                previousCenter: targetCenter,
                previousSettings: previousSettings,
                nextCenter: targetCenter,
                nextSettings: normalized
            )
            invalidatePendingMeshResultsLocked(for: impactedChunks)
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
                let desiredSampleStride: Int
                let lodSnapshotRequest: LODSnapshotRequest?
                lock.lock()
                guard let nextChunk = nextMissingChunkLocked() else {
                    activeGenerationWorkers = max(0, activeGenerationWorkers - 1)
                    lock.unlock()
                    return
                }
                inFlightChunks.insert(nextChunk)
                chunkCoord = nextChunk
                desiredSampleStride = desiredGenerationSampleStrideLocked(for: nextChunk)
                lodSnapshotRequest = desiredSampleStride > 1 ? makeLodSnapshotRequestLocked() : nil
                lock.unlock()

                let generationStart = TerrainRenderer.currentTimeSeconds()
                let compactChunk = makeCompactChunk(
                    at: chunkCoord,
                    desiredSampleStride: desiredSampleStride,
                    lodSnapshotRequest: lodSnapshotRequest
                )
                let generationSeconds = TerrainRenderer.currentTimeSeconds() - generationStart

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
            if let center = targetCenter {
                for offset in orderedOffsets {
                    let coord = ChunkCoord(x: center.x + offset.x, z: center.z + offset.z)
                    if shouldGenerateChunkLocked(coord) {
                        return coord
                    }
                }
            }
            for coord in pinnedChunks.sorted(by: isHigherPriorityChunk(_:than:)) {
                if shouldGenerateChunkLocked(coord) {
                    return coord
                }
            }
            return nil
        }

        private func shouldGenerateChunkLocked(_ coord: ChunkCoord) -> Bool {
            guard !inFlightChunks.contains(coord) else {
                return false
            }
            guard let chunk = chunks[coord] else {
                return true
            }
            return chunk.minimumAvailableSampleStride > desiredGenerationSampleStrideLocked(for: coord)
        }

        private func desiredGenerationSampleStrideLocked(for coord: ChunkCoord) -> Int {
            if pinnedChunks.contains(coord) {
                return 1
            }
            return sampleStrideLocked(for: coord)
        }

        private func makeLodSnapshotRequestLocked() -> LODSnapshotRequest? {
            guard let center = targetCenter else {
                return nil
            }

            let originX = center.x * ProtoChunk.sideLength + (ProtoChunk.sideLength / 2)
            let originZ = center.z * ProtoChunk.sideLength + (ProtoChunk.sideLength / 2)
            let origin = PosInt3D(x: Int32(originX), y: 0, z: Int32(originZ))
            let farthestBlockDistance = renderRadius * ProtoChunk.sideLength + (ProtoChunk.sideLength - 1) + terrainLodSettings.maxSampleStride
            let baseCellSize = baseLodCellSizeLocked()
            let maxCellSizePower = terrainLodSettings.maxSampleStride <= 1 || terrainLodSettings.maxSampleStride <= baseCellSize
                ? 0
                : max(0, terrainLodSettings.maxSampleStride.trailingZeroBitCount - baseCellSize.trailingZeroBitCount)

            return LODSnapshotRequest(
                key: LODSnapshotKey(
                    center: center,
                    renderRadius: renderRadius,
                    nearDistance: terrainLodSettings.nearDistance,
                    stepDistance: terrainLodSettings.stepDistance,
                    maxSampleStride: terrainLodSettings.maxSampleStride
                ),
                origin: origin,
                radius: Int32(farthestBlockDistance),
                maxCellSizePower: maxCellSizePower
            )
        }

        private func startGenerationWorkersLocked() -> Int {
            guard targetCenter != nil || !pinnedChunks.isEmpty else {
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
            let targetChunks = targetChunksLocked()
            let orderedLoaded = chunks.keys
                .filter { targetChunks.contains($0) }
                .sorted(by: isHigherPriorityChunk(_:than:))
            for coord in orderedLoaded where dirtyMeshChunks.contains(coord) && !inFlightMeshChunks.contains(coord) {
                return coord
            }
            return nil
        }

        private func startMeshWorkersLocked() -> Int {
            guard targetCenter != nil || !pinnedChunks.isEmpty else {
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
                let sampleStrideByChunk = neighbors.keys.reduce(into: [ChunkCoord: Int]()) { sampleStrides, neighborCoord in
                    sampleStrides[neighborCoord] = sampleStrideLocked(for: neighborCoord)
                }
                let generationSeconds = generationSecondsByChunk[coord] ?? 0
                lock.unlock()

                snapshot = ChunkMeshSnapshot(
                    coord: coord,
                    revision: revision,
                    chunk: chunk,
                    neighbors: neighbors,
                    sampleStrideByChunk: sampleStrideByChunk,
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

            let meshStart = TerrainRenderer.currentTimeSeconds()
            let meshBuild = buildGreedyMesh(
                coord: snapshot.coord,
                chunk: snapshot.chunk,
                neighbors: snapshot.neighbors,
                sampleStrideByChunk: snapshot.sampleStrideByChunk
            )
            profile.meshSeconds = TerrainRenderer.currentTimeSeconds() - meshStart

            return ChunkMeshResult(
                coord: snapshot.coord,
                revision: snapshot.revision,
                origin: meshBuild.origin,
                vertices: meshBuild.vertices,
                profile: profile,
                availableChunks: snapshot.availableChunks,
                totalTargetChunks: snapshot.totalTargetChunks
            )
        }

        private func makeCompactChunk(
            at chunkCoord: ChunkCoord,
            desiredSampleStride: Int,
            lodSnapshotRequest: LODSnapshotRequest?
        ) -> CompactChunk? {
            if desiredSampleStride > 1,
               let coarseChunk = makeCompactChunkUsingSampleLOD(
                    at: chunkCoord,
                    desiredSampleStride: desiredSampleStride,
                    request: lodSnapshotRequest
               ) {
                return coarseChunk
            }

            let protoChunk = ProtoChunk()
            let generationSucceeded = (try? worldGenerator.generateInto(
                protoChunk,
                at: PosInt2D(x: Int32(chunkCoord.x), z: Int32(chunkCoord.z))
            )) != nil
            return generationSucceeded ? makeCompactChunk(from: protoChunk) : nil
        }

        private func makeCompactChunk(from protoChunk: ProtoChunk) -> CompactChunk {
            var fullResolutionSections: [CompactSection] = []
            fullResolutionSections.reserveCapacity(protoChunk.sectionCount)

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

                fullResolutionSections.append(
                    CompactSection(
                        sampleStride: 1,
                        cellSideLength: 16,
                        bitmap: bitmap,
                        biomePalette: biomePalette,
                        biomeIndices: biomeIndices
                    )
                )
            }

            let lods = Self.supportedSampleStrides.map { sampleStride in
                CompactChunkLod(
                    sampleStride: sampleStride,
                    sections: sampleStride == 1
                        ? fullResolutionSections
                        : makeLodSections(from: fullResolutionSections, sampleStride: sampleStride)
                )
            }

            return CompactChunk(
                minY: Int(protoChunk.minY),
                height: Int(protoChunk.height),
                lods: lods
            )
        }

        private func makeCompactChunkUsingSampleLOD(
            at chunkCoord: ChunkCoord,
            desiredSampleStride: Int,
            request: LODSnapshotRequest?
        ) -> CompactChunk? {
            guard let request,
                  let snapshot = lodSnapshot(for: request),
                  !snapshot.result.chunks.isEmpty else {
                return nil
            }

            let relevantColumns = relevantLodColumns(for: chunkCoord, in: snapshot.result)
            guard !relevantColumns.isEmpty else {
                return nil
            }

            let chunkMinX = chunkCoord.x * ProtoChunk.sideLength
            let chunkMinZ = chunkCoord.z * ProtoChunk.sideLength
            let baseSampleStride = relevantColumns.reduce(desiredSampleStride) { min($0, Int($1.cellSize)) }
            guard Self.supportedSampleStrides.contains(baseSampleStride),
                  desiredSampleStride >= baseSampleStride,
                  ProtoChunk.sideLength % baseSampleStride == 0 else {
                return nil
            }

            let minY = Int(snapshot.result.minY)
            let height = Int(snapshot.result.maxYExclusive - snapshot.result.minY)
            guard height > 0, height % ProtoChunk.sectionHeight == 0 else {
                return nil
            }

            let cellSideLength = ProtoChunk.sideLength / baseSampleStride
            let sectionCount = height / ProtoChunk.sectionHeight
            let baseCellCount = cellSideLength * cellSideLength * cellSideLength
            let baseBitmapWordCount = (baseCellCount + 63) >> 6

            struct SectionBuilder {
                var bitmap: [UInt64]
                var biomePalette: [CompactBiomeEntry]
                var paletteIndexByName: [String: Int]
                var biomeIndices: [UInt8]
            }

            let unknownBiome = CompactBiomeEntry(
                name: "unknown",
                packedColor: biomeColorPalette.packedRGBA8(forBiomeID: nil)
            )
            var sectionBuilders = (0..<sectionCount).map { _ in
                SectionBuilder(
                    bitmap: [UInt64](repeating: 0, count: baseBitmapWordCount),
                    biomePalette: [unknownBiome],
                    paletteIndexByName: [unknownBiome.name: 0],
                    biomeIndices: [UInt8](repeating: 0, count: baseCellCount)
                )
            }

            for column in relevantColumns {
                let localX = Int(column.x) - chunkMinX
                let localZ = Int(column.z) - chunkMinZ
                let localCellX = max(0, min(cellSideLength - 1, localX / baseSampleStride))
                let localCellZ = max(0, min(cellSideLength - 1, localZ / baseSampleStride))
                let columnCellSize = max(baseSampleStride, Int(column.cellSize))
                let span = max(1, columnCellSize / baseSampleStride)

                for (sampleIndex, isSolid) in column.samples.enumerated() {
                    guard isSolid else {
                        continue
                    }

                    let sampleY = minY + sampleIndex * columnCellSize
                    guard sampleY >= minY, sampleY < minY + height else {
                        continue
                    }
                    let localCellY = max(0, min((height / baseSampleStride) - 1, (sampleY - minY) / baseSampleStride))
                    let ySpan = max(1, columnCellSize / baseSampleStride)
                    let biomeName = column.samplePayloads?[sampleIndex].biome?.name
                    let biomeEntry = CompactBiomeEntry(
                        name: biomeName ?? "unknown",
                        packedColor: biomeColorPalette.packedRGBA8(forBiomeID: biomeName)
                    )

                    for dy in 0..<ySpan {
                        let filledCellY = localCellY + dy
                        guard filledCellY < height / baseSampleStride else {
                            break
                        }
                        let sectionIndex = filledCellY / (ProtoChunk.sectionHeight / baseSampleStride)
                        let localSectionCellY = filledCellY % (ProtoChunk.sectionHeight / baseSampleStride)
                        let paletteIndex: Int
                        if let existing = sectionBuilders[sectionIndex].paletteIndexByName[biomeEntry.name] {
                            paletteIndex = existing
                        } else {
                            paletteIndex = sectionBuilders[sectionIndex].biomePalette.count
                            precondition(paletteIndex < 256, "section biome palette exceeded UInt8 capacity")
                            sectionBuilders[sectionIndex].paletteIndexByName[biomeEntry.name] = paletteIndex
                            sectionBuilders[sectionIndex].biomePalette.append(biomeEntry)
                        }
                        for dz in 0..<span {
                            let filledCellZ = localCellZ + dz
                            guard filledCellZ < cellSideLength else {
                                break
                            }
                            for dx in 0..<span {
                                let filledCellX = localCellX + dx
                                guard filledCellX < cellSideLength else {
                                    break
                                }
                                let cellIndex = (localSectionCellY * cellSideLength + filledCellZ) * cellSideLength + filledCellX
                                let wordIndex = cellIndex >> 6
                                let bitIndex = cellIndex & 63
                                sectionBuilders[sectionIndex].bitmap[wordIndex] |= UInt64(1) << UInt64(bitIndex)
                                sectionBuilders[sectionIndex].biomeIndices[cellIndex] = UInt8(paletteIndex)
                            }
                        }
                    }
                }
            }

            let baseSections = sectionBuilders.map { builder in
                CompactSection(
                    sampleStride: baseSampleStride,
                    cellSideLength: cellSideLength,
                    bitmap: builder.bitmap,
                    biomePalette: builder.biomePalette,
                    biomeIndices: builder.biomeIndices
                )
            }
            let lods = Self.supportedSampleStrides
                .filter { $0 >= baseSampleStride }
                .map { sampleStride in
                    CompactChunkLod(
                        sampleStride: sampleStride,
                        sections: sampleStride == baseSampleStride
                            ? baseSections
                            : makeLodSections(from: baseSections, sampleStride: sampleStride)
                    )
                }

            return CompactChunk(
                minY: minY,
                height: height,
                lods: lods
            )
        }

        private func lodSnapshot(for request: LODSnapshotRequest) -> LODSnapshot? {
            sampleLodLock.lock()
            defer { sampleLodLock.unlock() }

            if lodSnapshotKey == request.key, let lodSnapshot {
                return lodSnapshot
            }

            guard let result = try? worldGenerator.sampleLOD(
                from: request.origin,
                radius: request.radius,
                startingRadius: Int32(request.key.nearDistance),
                radiusStep: Int32(request.key.stepDistance),
                maxCellSizePower: request.maxCellSizePower,
                threadCount: generationWorkerCount,
                payloads: [.biome]
            ) else {
                return nil
            }

            cachedBaseLodCellSize = max(1, Int(result.baseCellSize))
            let snapshot = LODSnapshot(result: result)
            lodSnapshotKey = request.key
            lodSnapshot = snapshot
            return snapshot
        }

        private func relevantLodColumns(for chunkCoord: ChunkCoord, in result: TerrainLODResult) -> [TerrainLODColumn] {
            let chunkMinX = chunkCoord.x * ProtoChunk.sideLength
            let chunkMaxXExclusive = chunkMinX + ProtoChunk.sideLength
            let chunkMinZ = chunkCoord.z * ProtoChunk.sideLength
            let chunkMaxZExclusive = chunkMinZ + ProtoChunk.sideLength
            var relevant: [TerrainLODColumn] = []

            for sourceChunkZ in (chunkCoord.z - 1)...chunkCoord.z {
                for sourceChunkX in (chunkCoord.x - 1)...chunkCoord.x {
                    let key = TerrainLODChunkKey(x: Int32(sourceChunkX), z: Int32(sourceChunkZ))
                    guard let chunkIndex = result.chunkIndex[key] else {
                        continue
                    }

                    for column in result.chunks[chunkIndex].columns {
                        let cellSize = max(1, Int(column.cellSize))
                        let columnMaxXExclusive = Int(column.x) + cellSize
                        let columnMaxZExclusive = Int(column.z) + cellSize
                        guard Int(column.x) < chunkMaxXExclusive,
                              columnMaxXExclusive > chunkMinX,
                              Int(column.z) < chunkMaxZExclusive,
                              columnMaxZExclusive > chunkMinZ else {
                            continue
                        }
                        relevant.append(column)
                    }
                }
            }

            return relevant
        }

        private func makeLodSections(
            from fullResolutionSections: [CompactSection],
            sampleStride: Int
        ) -> [CompactSection] {
            precondition(sampleStride > 1 && sampleStride <= ProtoChunk.sideLength, "invalid sample stride \(sampleStride)")
            let cellSideLength = ProtoChunk.sideLength / sampleStride
            let cellCount = cellSideLength * cellSideLength * cellSideLength
            let bitmapWordCount = (cellCount + 63) >> 6
            let sampleOffset = sampleStride >> 1

            return fullResolutionSections.map { sourceSection in
                var bitmap = [UInt64](repeating: 0, count: bitmapWordCount)
                var biomePalette: [CompactBiomeEntry] = []
                biomePalette.reserveCapacity(8)
                var paletteIndexByName: [String: Int] = [:]
                var biomeIndices = [UInt8](repeating: 0, count: cellCount)

                for cellIndex in 0..<cellCount {
                    let cellX = cellIndex % cellSideLength
                    let cellZ = (cellIndex / cellSideLength) % cellSideLength
                    let cellY = cellIndex / (cellSideLength * cellSideLength)
                    let sampleX = min(ProtoChunk.sideLength - 1, cellX * sampleStride + sampleOffset)
                    let sampleY = min(ProtoChunk.sectionHeight - 1, cellY * sampleStride + sampleOffset)
                    let sampleZ = min(ProtoChunk.sideLength - 1, cellZ * sampleStride + sampleOffset)

                    if sourceSection.isSolid(atLocalX: sampleX, y: sampleY, z: sampleZ) {
                        let wordIndex = cellIndex >> 6
                        let bitIndex = cellIndex & 63
                        bitmap[wordIndex] |= UInt64(1) << UInt64(bitIndex)
                    }

                    let biomeEntry = sourceSection.biomeEntry(atLocalX: sampleX, y: sampleY, z: sampleZ)
                    let paletteIndex: Int
                    if let existing = paletteIndexByName[biomeEntry.name] {
                        paletteIndex = existing
                    } else {
                        paletteIndex = biomePalette.count
                        precondition(paletteIndex < 256, "section biome palette exceeded UInt8 capacity")
                        paletteIndexByName[biomeEntry.name] = paletteIndex
                        biomePalette.append(biomeEntry)
                    }
                    biomeIndices[cellIndex] = UInt8(paletteIndex)
                }

                return CompactSection(
                    sampleStride: sampleStride,
                    cellSideLength: cellSideLength,
                    bitmap: bitmap,
                    biomePalette: biomePalette,
                    biomeIndices: biomeIndices
                )
            }
        }

        private func pruneChunksLockedIfNeeded() -> [ChunkCoord] {
            if let center = targetCenter {
                return pruneChunksLocked(around: center)
            }

            var removed: [ChunkCoord] = []
            chunks = chunks.filter { coord, _ in
                let keep = pinnedChunks.contains(coord)
                if !keep {
                    removed.append(coord)
                }
                return keep
            }
            return removed
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
            if pinnedChunks.contains(coord) {
                return true
            }
            return abs(coord.x - center.x) <= renderRadius + extraMargin && abs(coord.z - center.z) <= renderRadius + extraMargin
        }

        private func targetChunksLocked() -> Set<ChunkCoord> {
            var targets = pinnedChunks
            if let center = targetCenter {
                for offset in orderedOffsets {
                    targets.insert(ChunkCoord(x: center.x + offset.x, z: center.z + offset.z))
                }
            }
            return targets
        }

        private func isHigherPriorityChunk(_ lhs: ChunkCoord, than rhs: ChunkCoord) -> Bool {
            let center = targetCenter ?? ChunkCoord(
                x: floorDiv(targetCameraBlock.x == Int.min ? 0 : targetCameraBlock.x, 16),
                z: floorDiv(targetCameraBlock.z == Int.min ? 0 : targetCameraBlock.z, 16)
            )
            let lhsDistance = max(abs(lhs.x - center.x), abs(lhs.z - center.z))
            let rhsDistance = max(abs(rhs.x - center.x), abs(rhs.z - center.z))
            if lhsDistance != rhsDistance { return lhsDistance < rhsDistance }
            if lhs.z != rhs.z { return lhs.z < rhs.z }
            return lhs.x < rhs.x
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

        private func sampleStrideLocked(for coord: ChunkCoord) -> Int {
            guard let center = targetCenter else {
                return 1
            }
            let baseLodCellSize = baseLodCellSizeLocked()
            return sampleStride(for: coord, relativeTo: center, settings: terrainLodSettings, baseLodCellSize: baseLodCellSize)
        }

        private func sampleStride(
            for coord: ChunkCoord,
            relativeTo center: ChunkCoord,
            settings: TerrainLodSettings,
            baseLodCellSize: Int
        ) -> Int {
            let maxSampleStride = settings.maxSampleStride
            guard maxSampleStride > 1 else {
                return 1
            }

            let distanceChunks = max(abs(coord.x - center.x), abs(coord.z - center.z))
            let distanceBlocks = distanceChunks * ProtoChunk.sideLength
            guard distanceBlocks >= settings.nearDistance else {
                return 1
            }

            let lodBand = (distanceBlocks - settings.nearDistance) / settings.stepDistance
            var sampleStride = min(maxSampleStride, max(1, baseLodCellSize))
            for _ in 0..<lodBand where sampleStride < maxSampleStride {
                sampleStride = min(maxSampleStride, sampleStride << 1)
            }
            return sampleStride
        }

        private func impactedChunksForSampleStrideChangesLocked(
            previousCenter: ChunkCoord?,
            previousSettings: TerrainLodSettings,
            nextCenter: ChunkCoord?,
            nextSettings: TerrainLodSettings
        ) -> Set<ChunkCoord> {
            var impactedChunks: Set<ChunkCoord> = []
            let previousBaseLodCellSize = baseLodCellSizeLocked()
            let nextBaseLodCellSize = previousBaseLodCellSize

            for coord in chunks.keys {
                let previousStride = previousCenter.map {
                    sampleStride(for: coord, relativeTo: $0, settings: previousSettings, baseLodCellSize: previousBaseLodCellSize)
                } ?? 1
                let nextStride = nextCenter.map {
                    sampleStride(for: coord, relativeTo: $0, settings: nextSettings, baseLodCellSize: nextBaseLodCellSize)
                } ?? 1
                guard previousStride != nextStride else {
                    continue
                }

                impactedChunks.insert(coord)
                for neighbor in adjacentChunkCoords(to: coord) where chunks[neighbor] != nil {
                    impactedChunks.insert(neighbor)
                }
            }

            for coord in impactedChunks {
                markChunkDirtyLocked(coord)
            }
            return impactedChunks
        }

        private func baseLodCellSizeLocked() -> Int {
            if let cachedBaseLodCellSize {
                return cachedBaseLodCellSize
            }

            sampleLodLock.lock()
            defer { sampleLodLock.unlock() }
            if let cachedBaseLodCellSize {
                return cachedBaseLodCellSize
            }

            let fallback = 4
            guard let result = try? worldGenerator.sampleLOD(
                from: PosInt3D(x: 0, y: 0, z: 0),
                radius: 0,
                startingRadius: 0,
                radiusStep: 1,
                maxCellSizePower: 0,
                threadCount: 1,
                payloads: []
            ) else {
                cachedBaseLodCellSize = fallback
                return fallback
            }

            let resolved = max(1, Int(result.baseCellSize))
            cachedBaseLodCellSize = resolved
            return resolved
        }

        private func invalidatePendingMeshResultsLocked(for impactedChunks: Set<ChunkCoord>) {
            guard !impactedChunks.isEmpty else {
                return
            }
            for coord in impactedChunks {
                pendingMeshResults.removeValue(forKey: coord)
            }
        }

        private func invalidateLodSnapshotLocked() {
            lodSnapshotKey = nil
            lodSnapshot = nil
        }

        static func normalizedSampleStride(_ requestedStride: Int) -> Int {
            let clamped = max(1, min(ProtoChunk.sideLength, requestedStride))
            var normalized = 1
            while (normalized << 1) <= clamped {
                normalized <<= 1
            }
            return normalized
        }

        private func buildGreedyMesh(
            coord: ChunkCoord,
            chunk: CompactChunk,
            neighbors: [ChunkCoord: CompactChunk],
            sampleStrideByChunk: [ChunkCoord: Int]
        ) -> (origin: SIMD3<Int>, vertices: [VulkanEngine.Vertex3D]) {
            let chunkSampleStride = sampleStrideByChunk[coord] ?? 1
            var firstSolidSection = Int.max
            var lastSolidSection = Int.min
            for sectionIndex in 0..<chunk.sectionCount {
                guard let section = chunk.section(at: sectionIndex, sampleStride: chunkSampleStride),
                      section.hasAnySolid else {
                    continue
                }
                firstSolidSection = min(firstSolidSection, sectionIndex)
                lastSolidSection = max(lastSolidSection, sectionIndex)
            }

            let emptyOrigin = SIMD3<Int>(coord.x * 16, chunk.minY, coord.z * 16)
            let originX = coord.x * 16
            let originZ = coord.z * 16

            guard firstSolidSection != Int.max, lastSolidSection != Int.min else {
                return (emptyOrigin, [])
            }

            let originY = chunk.minY + firstSolidSection * ProtoChunk.sectionHeight
            let origin = SIMD3<Int>(originX, originY, originZ)
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
                return chunk.biomeEntry(
                    atLocalX: x,
                    y: absoluteLocalY,
                    z: z,
                    sampleStride: chunkSampleStride
                )?.packedColor
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
                let querySampleStride = sampleStrideByChunk[queryCoord] ?? 1
                let localX = floorMod(worldX, 16)
                let localZ = floorMod(worldZ, 16)
                let localY = worldY - queryChunk.minY
                guard localY >= 0, localY < queryChunk.height else {
                    return false
                }
                return queryChunk.isSolid(
                    atLocalX: localX,
                    y: localY,
                    z: localZ,
                    sampleStride: querySampleStride
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
                                Float(p[0]),
                                Float(p[1]),
                                Float(p[2])
                            )
                            let p1 = SIMD3<Float>(
                                Float(p[0] + du[0]),
                                Float(p[1] + du[1]),
                                Float(p[2] + du[2])
                            )
                            let p2 = SIMD3<Float>(
                                Float(p[0] + du[0] + dv[0]),
                                Float(p[1] + du[1] + dv[1]),
                                Float(p[2] + du[2] + dv[2])
                            )
                            let p3 = SIMD3<Float>(
                                Float(p[0] + dv[0]),
                                Float(p[1] + dv[1]),
                                Float(p[2] + dv[2])
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

            return (origin, vertices)
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
    let commandLogVisibleEntryLimit = 5
    let commandPromptLogVisibleEntryLimit = 10
    let commandLogBackgroundColor = SIMD4<Float>(0.0, 0.0, 0.0, 0.72)
    let commandLogSelectedBackgroundColor = SIMD4<Float>(0.20, 0.28, 0.44, 0.92)
    let commandLogErrorColor = SIMD4<Float>(0.92, 0.28, 0.24, 1.0)
    let keyframeMarkerColor = SIMD4<Float>(0.18, 0.92, 0.28, 1.0)
    let keyframePathColor = SIMD4<Float>(0.92, 0.16, 0.14, 1.0)
    let keyframeMarkerHalfSize: Float = 0.65
    let keyframePathHalfWidth: Float = 0.08
    let keyframeOverlayDepthBias: Float = 0.35
    let cinematicPlaybackSpeed: Double = 8.0
    let minimumCinematicSegmentDuration: Double = 0.35

    var externalCommandExecutor: ((String, String, TerrainRenderer) throws -> Bool)?
    var keycodeForAction: ((KeybindAction) -> SDL_Keycode)?
    var renderDistanceDidChange: ((Int) -> Void)?
    var chunkMeshes: [ChunkCoord: ChunkRenderMesh] = [:]
    var hudBuffer: VulkanOwnedBuffer?
    var hudMemory: VulkanOwnedDeviceMemory?
    var hudVertexCount: UInt32 = 0
    var hudVertexCapacity = 0
    var lastHudText = ""
    var lastHudViewport = SIMD2<Int>(repeating: -1)
    var lastHudBiome = ""
    var keyframeOverlayBuffer: VulkanOwnedBuffer?
    var keyframeOverlayMemory: VulkanOwnedDeviceMemory?
    var keyframeOverlayVertexCount: UInt32 = 0
    var keyframeOverlayVertexCapacity = 0

    var cameraPosition = SIMD3<Double>(x: 0.0, y: 160.0, z: 0.0)
    var cameraYaw: Float = -.pi / 4.0
    var cameraPitch: Float = -.pi / 5.5
    var smoothedFps: Float = 0
    var keyframes: [Keyframe] = [] {
        didSet {
            cachedCinematicPath = nil
        }
    }
    var keyframePlaybackSpeed: Double = 8.0
    var showsKeyframes = true
    var isRenderingForExport = false

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
    var commandLogScrollOffset = 0
    var activeCommandLogHistoryIndex: Int?
    var cachedCinematicPath: CinematicPath?
    var cinematicPlaybackSession: CinematicPlaybackSession?

    init(
        worldGenerator: WorldGenerator,
        biomeColorPalette: BiomeColorPalette,
        renderRadius: Int = 12,
        terrainLodNearDistance: Int = 128,
        terrainLodStepDistance: Int = 128,
        terrainLodMaxScale: Int = 8,
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
            biomeColorPalette: biomeColorPalette,
            terrainLodSettings: TerrainLodSettings(
                nearDistance: max(0, terrainLodNearDistance),
                stepDistance: max(1, terrainLodStepDistance),
                maxSampleStride: Streamer.normalizedSampleStride(terrainLodMaxScale)
            )
        )
    }

    func render(
        engine: VulkanEngine,
        window: OpaquePointer?,
        imageAvailable: VkSemaphore,
        renderFinishedByImage: [VkSemaphore]
    ) throws -> VulkanEngine.CapturedFrame? {
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
            eye: .zero,
            center: viewForward(),
            up: SIMD3<Float>(0, 1, 0)
        )
        let projection = perspectiveRH(
            fovYRadians: effectiveFovYRadians,
            aspect: aspect,
            nearZ: 0.05,
            farZ: 8192.0
        )

        try engine.updateTransform3D(projection)
        try engine.updateModel3D(matrix_identity_float4x4)
        try engine.updateView3D(view)
        try engine.updateTransform2D(hudTransform(width: width, height: height))
        engine.setClearColor(SIMD4<Float>(0.63, 0.82, 0.98, 1.0))
        if isCinematicPlaying || isRenderingForExport {
            hudVertexCount = 0
            lastHudText = ""
            lastHudViewport = SIMD2<Int>(repeating: -1)
            lastHudBiome = ""
            keyframeOverlayVertexCount = 0
        } else {
            try updateHudIfNeeded(engine: engine, viewportWidth: Int(width), viewportHeight: Int(height))
            try updateKeyframeOverlayIfNeeded(engine: engine)
        }

        let imageIndex = try engine.device.acquireNextImage(from: engine.swapchain, semaphore: imageAvailable)
        guard Int(imageIndex) < renderFinishedByImage.count else {
            throw TerrainRendererError.invalidSwapchainImageIndex
        }
        let renderFinished = renderFinishedByImage[Int(imageIndex)]

        var batches: [VulkanEngine.DrawBatch3D] = chunkMeshes.keys.sorted { lhs, rhs in
            if lhs.z != rhs.z { return lhs.z < rhs.z }
            return lhs.x < rhs.x
        }.compactMap { coord in
            guard let mesh = chunkMeshes[coord], mesh.vertexCount > 0 else {
                return nil
            }
            let modelOffset = SIMD4<Float>(
                Float(Double(mesh.origin.x) - cameraPosition.x),
                Float(Double(mesh.origin.y) - cameraPosition.y),
                Float(Double(mesh.origin.z) - cameraPosition.z),
                0
            )
            return .init(buffer: mesh.buffer, vertexCount: mesh.vertexCount, modelOffset: modelOffset)
        }
        if let keyframeOverlayBuffer, keyframeOverlayVertexCount > 0 {
            batches.append(
                .init(
                    buffer: keyframeOverlayBuffer,
                    vertexCount: keyframeOverlayVertexCount,
                    modelOffset: SIMD4<Float>(
                        -Float(cameraPosition.x),
                        -Float(cameraPosition.y),
                        -Float(cameraPosition.z),
                        0
                    )
                )
            )
        }
        let hudBatches: [VulkanEngine.DrawBatch2D]
        if let hudBuffer, hudVertexCount > 0 {
            hudBatches = [.init(buffer: hudBuffer, vertexCount: hudVertexCount)]
        } else {
            hudBatches = []
        }

        let capturedFrame = try engine.drawBatches3DAnd2D(
            batches3D: batches,
            batches2D: hudBatches,
            framebufferIndex: Int(imageIndex),
            waitSemaphores: [imageAvailable],
            signalSemaphores: [renderFinished],
            captureFrame: isRenderingForExport
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
        return capturedFrame
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

            let uploadStart = TerrainRenderer.currentTimeSeconds()
            if !result.vertices.isEmpty {
                let (buffer, memory) = try engine.createVertexBuffer3D(result.vertices)
                chunkMeshes[result.coord] = ChunkRenderMesh(
                    buffer: buffer,
                    memory: memory,
                    vertexCount: UInt32(result.vertices.count),
                    origin: result.origin
                )
            }

            var profile = result.profile
            profile.uploadSeconds = TerrainRenderer.currentTimeSeconds() - uploadStart
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

    func setRenderRadius(_ renderRadius: Int) {
        _ = streamer.setRenderRadius(to: renderRadius)
    }

    func setTerrainLodSettings(
        nearDistance: Int,
        stepDistance: Int,
        maxSampleStride: Int
    ) {
        streamer.setTerrainLodSettings(
            nearDistance: nearDistance,
            stepDistance: stepDistance,
            maxSampleStride: maxSampleStride
        )
    }

    func currentRenderRadius() -> Int {
        streamer.currentRenderRadius()
    }
}

enum TerrainRendererError: Error {
    case invalidSwapchainImageIndex
}
