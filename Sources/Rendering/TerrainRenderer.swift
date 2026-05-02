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
        let hasAnySolid: Bool

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

        @inline(__always)
        private func cellIndex(atLocalX x: Int, y: Int, z: Int) -> Int {
            let cellX = x / sampleStride
            let cellY = y / sampleStride
            let cellZ = z / sampleStride
            return (cellY * cellSideLength + cellZ) * cellSideLength + cellX
        }
    }

    private struct CompactChunk {
        let minY: Int
        let height: Int
        let sampleStride: Int
        let sections: [CompactSection]?
        let firstSolidSection: Int?
        let lastSolidSection: Int?
        let surfaceHeights: [Int32]?
        let surfaceCellSizes: [UInt16]?
        let surfaceCellOriginXs: [Int16]?
        let surfaceCellOriginZs: [Int16]?
        let surfaceBiomePalette: [CompactBiomeEntry]?
        let surfaceBiomeIndices: [UInt8]?

        var minimumAvailableSampleStride: Int { sampleStride }
        var sectionCount: Int { sections?.count ?? 0 }
        var isSurfaceOnly: Bool { surfaceHeights != nil }

        @inline(__always)
        func section(at index: Int) -> CompactSection? {
            guard let sections,
                  index >= 0,
                  index < sections.count else {
                return nil
            }
            return sections[index]
        }

        @inline(__always)
        func biomeEntry(atLocalX x: Int, y: Int, z: Int) -> CompactBiomeEntry? {
            guard x >= 0, x < 16, z >= 0, z < 16 else {
                return nil
            }
            if let surfaceHeights, let surfaceBiomePalette, let surfaceBiomeIndices {
                let index = z * 16 + x
                guard surfaceHeights[index] != Int32.min else {
                    return nil
                }
                return surfaceBiomePalette[Int(surfaceBiomeIndices[index])]
            }
            guard y >= 0, y < height else {
                return nil
            }
            let sectionIndex = y >> 4
            let localY = y & 15
            guard let sections else {
                return nil
            }
            return sections[sectionIndex].biomeEntry(
                atLocalX: x,
                y: localY,
                z: z
            )
        }

        @inline(__always)
        func isSolid(atLocalX x: Int, y: Int, z: Int) -> Bool {
            guard x >= 0, x < 16, z >= 0, z < 16 else {
                return false
            }
            if let surfaceHeights {
                guard y >= 0, y < height else {
                    return false
                }
                let surfaceY = surfaceHeights[z * 16 + x]
                guard surfaceY != Int32.min else {
                    return false
                }
                return Int32(minY + y) <= surfaceY
            }
            guard y >= 0, y < height else {
                return false
            }
            let sectionIndex = y >> 4
            let localY = y & 15
            guard let sections else {
                return false
            }
            return sections[sectionIndex].isSolid(
                atLocalX: x,
                y: localY,
                z: z
            )
        }

        @inline(__always)
        func surfaceHeight(atLocalX x: Int, z: Int) -> Int32? {
            guard let surfaceHeights,
                  x >= 0, x < 16,
                  z >= 0, z < 16 else {
                return nil
            }
            let value = surfaceHeights[z * 16 + x]
            return value == Int32.min ? nil : value
        }

        @inline(__always)
        func surfaceCellSize(atLocalX x: Int, z: Int) -> Int? {
            guard let surfaceHeights,
                  let surfaceCellSizes,
                  x >= 0, x < 16,
                  z >= 0, z < 16 else {
                return nil
            }
            let index = z * 16 + x
            guard surfaceHeights[index] != Int32.min else {
                return nil
            }
            let size = Int(surfaceCellSizes[index])
            return size > 0 ? size : nil
        }

        @inline(__always)
        func surfaceCellOriginX(atLocalX x: Int, z: Int) -> Int? {
            guard let surfaceHeights,
                  let surfaceCellOriginXs,
                  x >= 0, x < 16,
                  z >= 0, z < 16 else {
                return nil
            }
            let index = z * 16 + x
            guard surfaceHeights[index] != Int32.min else {
                return nil
            }
            return Int(surfaceCellOriginXs[index])
        }

        @inline(__always)
        func surfaceCellOriginZ(atLocalX x: Int, z: Int) -> Int? {
            guard let surfaceHeights,
                  let surfaceCellOriginZs,
                  x >= 0, x < 16,
                  z >= 0, z < 16 else {
                return nil
            }
            let index = z * 16 + x
            guard surfaceHeights[index] != Int32.min else {
                return nil
            }
            return Int(surfaceCellOriginZs[index])
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
        let inFlightLodBuildChunks: Int
        let dirtyMeshChunks: Int
        let inFlightMeshChunks: Int
        let totalTargetChunks: Int
        let lodCompletedChunks: Int?
        let lodTotalChunks: Int?
        let lodCompletedSamples: Int?
        let lodTotalSamples: Int?
    }

    struct CinematicPreparationStatus {
        let readyChunks: Int
        let totalChunks: Int
        let generatingChunks: Int
        let lodBuildingChunks: Int
        let meshingChunks: Int
        let lodCompletedChunks: Int?
        let lodTotalChunks: Int?
        let lodCompletedSamples: Int?
        let lodTotalSamples: Int?
    }

    struct ProgramScenePreparationStatus {
        let sceneIndex: Int
        let preparation: CinematicPreparationStatus
    }

    struct PinnedChunkSquare: Hashable {
        let center: ChunkCoord
        let radius: Int
    }

    @discardableResult
    static func forEachChunkCoord(
        in squares: [PinnedChunkSquare],
        _ body: (ChunkCoord) -> Bool
    ) -> Bool {
        guard let minZ = squares.map({ $0.center.z - $0.radius }).min(),
              let maxZ = squares.map({ $0.center.z + $0.radius }).max() else {
            return true
        }

        for z in minZ...maxZ {
            var intervals: [(start: Int, end: Int)] = []
            intervals.reserveCapacity(squares.count)

            for square in squares {
                guard abs(z - square.center.z) <= square.radius else {
                    continue
                }
                intervals.append(
                    (start: square.center.x - square.radius, end: square.center.x + square.radius)
                )
            }

            guard !intervals.isEmpty else {
                continue
            }

            intervals.sort {
                if $0.start != $1.start { return $0.start < $1.start }
                return $0.end < $1.end
            }

            var currentInterval = intervals[0]
            for interval in intervals.dropFirst() {
                if interval.start <= currentInterval.end + 1 {
                    currentInterval.end = max(currentInterval.end, interval.end)
                    continue
                }

                for x in currentInterval.start...currentInterval.end {
                    if !body(ChunkCoord(x: x, z: z)) {
                        return false
                    }
                }
                currentInterval = interval
            }

            for x in currentInterval.start...currentInterval.end {
                if !body(ChunkCoord(x: x, z: z)) {
                    return false
                }
            }
        }

        return true
    }

    static func countChunkCoords(in squares: [PinnedChunkSquare]) -> Int {
        var count = 0
        forEachChunkCoord(in: squares) { _ in
            count += 1
            return true
        }
        return count
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
        let preloadPositions: [SIMD3<Double>]
    }

    enum CinematicPlaybackPhase {
        case preparing
        case playing(startTimeSeconds: Double)
    }

    struct CinematicPlaybackSession {
        let path: CinematicPath
        let pinnedChunkSquares: [PinnedChunkSquare]
        var phase: CinematicPlaybackPhase
    }

    final class Streamer: @unchecked Sendable {
        private static let supportedSampleStrides = [1, 2, 4, 8, 16]

        private struct LODSnapshotRequest {
            let origin: PosInt3D
            let radius: Int32
            let nearDistance: Int
            let stepDistance: Int
            let maxCellSizePower: Int
            let targetChunkSampleStrides: [ChunkCoord: Int]
        }

        private enum ChunkGenerationMode {
            case full
            case lod
        }

        private let worldGenerator: WorldGenerator
        private let generationWorkerCount: Int
        private let retargetAroundCameraMovement: Bool
        private let biomeColorPalette: BiomeColorPalette
        private let surfaceOnly: Bool
        private let baseLodCellSizeLock = NSLock()
        private var cachedBaseLodCellSize: Int?
        private var lodProgress: TerrainLODProgress?
        private var surfaceLodProgress: TerrainLODProgress?

        private let lock = NSLock()
        private let generationQueue = DispatchQueue(label: "TerrainRenderer.Generation", qos: .userInitiated, attributes: .concurrent)
        private let meshQueue = DispatchQueue(label: "TerrainRenderer.Mesh", qos: .userInitiated, attributes: .concurrent)

        private var renderRadius: Int
        private var orderedOffsets: [ChunkCoord]
        private var terrainLodSettings: TerrainLodSettings
        private var targetCenter: ChunkCoord?
        private var targetCameraBlock = SIMD3<Int>(Int.min, Int.min, Int.min)
        private var pinnedChunkSquares: [PinnedChunkSquare] = []
        private var pinnedChunkCoords: [ChunkCoord] = []
        private var pinnedChunkCoordSet: Set<ChunkCoord> = []
        private var pinnedGenerationSelectionCount = 0
        private var pinnedMeshSelectionCount = 0
        private var isShutDown = false
        private var chunks: [ChunkCoord: CompactChunk] = [:]
        private var availableSampleStrideByChunk: [ChunkCoord: Int] = [:]
        private var inFlightChunks: [ChunkCoord: ChunkGenerationMode] = [:]
        private var activeLodBatchTargets: Set<ChunkCoord> = []
        private var activeGenerationWorkers = 0
        private var activeWorkEpoch = 0
        private var staleChunksNeedingRegeneration: Set<ChunkCoord> = []

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
            terrainLodSettings: TerrainLodSettings,
            surfaceOnly: Bool
        ) {
            self.worldGenerator = worldGenerator
            self.renderRadius = max(0, renderRadius)
            self.generationWorkerCount = max(1, generationWorkerCount)
            self.retargetAroundCameraMovement = retargetAroundCameraMovement
            self.biomeColorPalette = biomeColorPalette
            self.terrainLodSettings = terrainLodSettings
            self.surfaceOnly = surfaceOnly
            self.orderedOffsets = Self.makeOrderedOffsets(radius: self.renderRadius)
        }

        func adjustRenderRadius(by delta: Int) -> Int {
            setRenderRadius(to: renderRadius + delta)
        }

        func setRenderRadius(to requestedRadius: Int) -> Int {
            var generationWorkersToStart = 0
            var meshWorkersToStart = 0
            var currentRenderRadius = 0
            var workEpoch = 0

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
            workEpoch = activeWorkEpoch
            lock.unlock()

            startGenerationWorkers(generationWorkersToStart, epoch: workEpoch)
            startMeshWorkers(meshWorkersToStart, epoch: workEpoch)
            return currentRenderRadius
        }

        func currentRenderRadius() -> Int {
            lock.lock()
            let currentRenderRadius = renderRadius
            lock.unlock()
            return currentRenderRadius
        }

        func setPinnedChunkSquares(_ nextPinnedChunkSquares: [PinnedChunkSquare]) {
            var generationWorkersToStart = 0
            var meshWorkersToStart = 0
            var workEpoch = 0

            lock.lock()
            let pinnedChanged = pinnedChunkSquares != nextPinnedChunkSquares
            pinnedChunkSquares = nextPinnedChunkSquares
            if pinnedChanged {
                rebuildPinnedChunkCacheLocked()
                invalidateLodSnapshotLocked()
                pinnedGenerationSelectionCount = 0
                pinnedMeshSelectionCount = 0
            }
            let removed = pruneChunksLockedIfNeeded()
            for removedCoord in removed {
                markChunkRemovedLocked(removedCoord)
            }
            generationWorkersToStart = startGenerationWorkersLocked()
            meshWorkersToStart = startMeshWorkersLocked()
            workEpoch = activeWorkEpoch
            lock.unlock()

            startGenerationWorkers(generationWorkersToStart, epoch: workEpoch)
            startMeshWorkers(meshWorkersToStart, epoch: workEpoch)
        }

        func pinnedChunksReady() -> Bool {
            lock.lock()
            defer { lock.unlock() }

            guard !pinnedChunkSquares.isEmpty else {
                return true
            }

            for coord in pinnedChunkCoords {
                if availableSampleStrideByChunk[coord] == nil || inFlightChunks[coord] != nil {
                    return false
                }
                if dirtyMeshChunks.contains(coord)
                    || inFlightMeshChunks.contains(coord)
                    || pendingMeshResults[coord] != nil
                    || staleChunksNeedingRegeneration.contains(coord) {
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
            var lodBuildingChunks = 0
            var meshingChunks = 0

            let totalChunks = pinnedChunkCountLocked()
            for coord in pinnedChunkCoords {
                let isLoaded = availableSampleStrideByChunk[coord] != nil
                let generationMode = inFlightChunks[coord]
                let isGenerating = generationMode != nil
                let isMeshing =
                    dirtyMeshChunks.contains(coord)
                    || inFlightMeshChunks.contains(coord)
                    || pendingMeshResults[coord] != nil
                    || staleChunksNeedingRegeneration.contains(coord)

                if isLoaded && !isGenerating && !isMeshing {
                    readyChunks += 1
                }
                if generationMode == .full {
                    generatingChunks += 1
                }
                if generationMode == .lod {
                    lodBuildingChunks += 1
                }
                if isMeshing {
                    meshingChunks += 1
                }
            }

            let activeProgress = surfaceOnly ? surfaceLodProgress : lodProgress

            return CinematicPreparationStatus(
                readyChunks: readyChunks,
                totalChunks: totalChunks,
                generatingChunks: generatingChunks,
                lodBuildingChunks: lodBuildingChunks,
                meshingChunks: meshingChunks,
                lodCompletedChunks: activeProgress?.completedChunkCount,
                lodTotalChunks: activeProgress?.totalChunkCount,
                lodCompletedSamples: activeProgress?.completedSampleCount,
                lodTotalSamples: activeProgress?.totalSampleCount
            )
        }

        func updateTarget(center: ChunkCoord, cameraBlock: SIMD3<Int>) {
            var generationWorkersToStart = 0
            var meshWorkersToStart = 0
            var workEpoch = 0
            lock.lock()
            let hasPinnedChunks = !pinnedChunkSquares.isEmpty
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
            if centerChanged && !hasPinnedChunks {
                invalidateLodSnapshotLocked()
                let removed = pruneChunksLocked(around: effectiveCenter)
                for removedCoord in removed {
                    markChunkRemovedLocked(removedCoord)
                }
            }
            if centerChanged && !hasPinnedChunks {
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
            workEpoch = activeWorkEpoch
            lock.unlock()

            startGenerationWorkers(generationWorkersToStart, epoch: workEpoch)
            startMeshWorkers(meshWorkersToStart, epoch: workEpoch)
        }

        func primeTarget(center: ChunkCoord, cameraBlock: SIMD3<Int>) {
            lock.lock()
            targetCenter = center
            targetCameraBlock = cameraBlock
            lock.unlock()
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
            let generatedChunks = availableSampleStrideByChunk.keys.reduce(into: 0) { count, coord in
                if isTargetChunkLocked(coord) {
                    count += 1
                }
            }
            let inFlightGenerationChunks = inFlightChunks.reduce(into: 0) { count, entry in
                let (coord, mode) = entry
                if isTargetChunkLocked(coord), mode == .full {
                    count += 1
                }
            }
            let inFlightLodBuildChunks = inFlightChunks.reduce(into: 0) { count, entry in
                let (coord, mode) = entry
                if isTargetChunkLocked(coord), mode == .lod {
                    count += 1
                }
            }
            let activeProgress = surfaceOnly ? surfaceLodProgress : lodProgress

            return StreamDebugStatus(
                generatedChunks: generatedChunks,
                inFlightGenerationChunks: inFlightGenerationChunks,
                inFlightLodBuildChunks: inFlightLodBuildChunks,
                dirtyMeshChunks: dirtyMeshChunks.count,
                inFlightMeshChunks: inFlightMeshChunks.count,
                totalTargetChunks: targetChunkCountLocked(),
                lodCompletedChunks: activeProgress?.completedChunkCount,
                lodTotalChunks: activeProgress?.totalChunkCount,
                lodCompletedSamples: activeProgress?.completedSampleCount,
                lodTotalSamples: activeProgress?.totalSampleCount
            )
        }

        func requestMeshRebuild() {
            var generationWorkersToStart = 0
            var meshWorkersToStart = 0
            var workEpoch = 0

            lock.lock()
            for coord in chunks.keys {
                markChunkDirtyLocked(coord)
            }
            for coord in availableSampleStrideByChunk.keys where chunks[coord] == nil {
                staleChunksNeedingRegeneration.insert(coord)
            }
            pendingMeshResults.removeAll(keepingCapacity: true)
            invalidateLodSnapshotLocked()
            generationWorkersToStart = startGenerationWorkersLocked()
            meshWorkersToStart = startMeshWorkersLocked()
            workEpoch = activeWorkEpoch
            lock.unlock()

            startGenerationWorkers(generationWorkersToStart, epoch: workEpoch)
            startMeshWorkers(meshWorkersToStart, epoch: workEpoch)
        }

        func discardChunkStateKeepingMeshes() {
            lock.lock()
            activeWorkEpoch &+= 1
            chunks.removeAll(keepingCapacity: false)
            availableSampleStrideByChunk.removeAll(keepingCapacity: false)
            inFlightChunks.removeAll(keepingCapacity: false)
            activeLodBatchTargets.removeAll(keepingCapacity: false)
            activeGenerationWorkers = 0
            staleChunksNeedingRegeneration.removeAll(keepingCapacity: false)
            dirtyMeshChunks.removeAll(keepingCapacity: false)
            inFlightMeshChunks.removeAll(keepingCapacity: false)
            activeMeshWorkers = 0
            chunkMeshRevision.removeAll(keepingCapacity: false)
            pendingMeshResults.removeAll(keepingCapacity: false)
            pendingRemovedChunks.removeAll(keepingCapacity: false)
            generationSecondsByChunk.removeAll(keepingCapacity: false)
            lodProgress = nil
            surfaceLodProgress = nil
            lock.unlock()
        }

        func shutdown() {
            lock.lock()
            isShutDown = true
            activeWorkEpoch &+= 1
            targetCenter = nil
            targetCameraBlock = SIMD3<Int>(Int.min, Int.min, Int.min)
            pinnedChunkSquares.removeAll(keepingCapacity: false)
            rebuildPinnedChunkCacheLocked()
            chunks.removeAll(keepingCapacity: false)
            availableSampleStrideByChunk.removeAll(keepingCapacity: false)
            inFlightChunks.removeAll(keepingCapacity: false)
            activeLodBatchTargets.removeAll(keepingCapacity: false)
            activeGenerationWorkers = 0
            staleChunksNeedingRegeneration.removeAll(keepingCapacity: false)
            dirtyMeshChunks.removeAll(keepingCapacity: false)
            inFlightMeshChunks.removeAll(keepingCapacity: false)
            activeMeshWorkers = 0
            chunkMeshRevision.removeAll(keepingCapacity: false)
            pendingMeshResults.removeAll(keepingCapacity: false)
            pendingRemovedChunks.removeAll(keepingCapacity: false)
            generationSecondsByChunk.removeAll(keepingCapacity: false)
            lodProgress = nil
            surfaceLodProgress = nil
            lock.unlock()
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
            var workEpoch = 0

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
            workEpoch = activeWorkEpoch
            lock.unlock()

            startMeshWorkers(meshWorkersToStart, epoch: workEpoch)
        }

        private func generationWorkerLoop(epoch: Int) {
            while true {
                let chunkCoord: ChunkCoord
                let desiredSampleStride: Int
                let lodSnapshotRequest: LODSnapshotRequest?
                let lodBatchTargetChunkSampleStrides: [ChunkCoord: Int]
                let totalTargetChunks: Int
                lock.lock()
                guard epoch == activeWorkEpoch else {
                    lock.unlock()
                    return
                }
                guard let nextChunk = nextMissingChunkLocked() else {
                    activeGenerationWorkers = max(0, activeGenerationWorkers - 1)
                    lock.unlock()
                    return
                }
                chunkCoord = nextChunk
                desiredSampleStride = desiredGenerationSampleStrideLocked(for: nextChunk)
                let generationMode = generationModeLocked(desiredSampleStride: desiredSampleStride)
                totalTargetChunks = targetChunkCountLocked()
                if generationMode == .lod {
                    let targetChunkSampleStrides = desiredLodTargetChunkSampleStridesLocked()
                    lodBatchTargetChunkSampleStrides = targetChunkSampleStrides
                    lodSnapshotRequest = makeLodSnapshotRequestLocked(
                        targetChunkSampleStrides: targetChunkSampleStrides
                    )
                    activeLodBatchTargets.formUnion(targetChunkSampleStrides.keys)
                    for coord in targetChunkSampleStrides.keys {
                        inFlightChunks[coord] = .lod
                    }
                } else {
                    lodBatchTargetChunkSampleStrides = [:]
                    lodSnapshotRequest = nil
                    inFlightChunks[nextChunk] = .full
                }
                lock.unlock()

                let generationStart = TerrainRenderer.currentTimeSeconds()
                let compactChunk: CompactChunk?
                let unfinishedLodTargets: Set<ChunkCoord>
                if generationMode == .lod {
                    if let lodSnapshotRequest, !lodBatchTargetChunkSampleStrides.isEmpty {
                        unfinishedLodTargets = streamLodBatch(
                            request: lodSnapshotRequest,
                            totalTargetChunks: totalTargetChunks,
                            generationStart: generationStart,
                            epoch: epoch
                        )
                    } else {
                        clearLodProgress(surfaceOnly: surfaceOnly)
                        unfinishedLodTargets = Set(lodBatchTargetChunkSampleStrides.keys)
                    }
                    compactChunk = nil
                } else {
                    unfinishedLodTargets = []
                    compactChunk = makeCompactChunk(at: chunkCoord)
                }
                let generationSeconds = TerrainRenderer.currentTimeSeconds() - generationStart

                var generationWorkersToStart = 0
                var meshWorkersToStart = 0
                var workEpoch = 0
                lock.lock()
                guard epoch == activeWorkEpoch else {
                    lock.unlock()
                    return
                }
                if generationMode == .lod {
                    activeLodBatchTargets.subtract(unfinishedLodTargets)
                    for coord in unfinishedLodTargets {
                        inFlightChunks.removeValue(forKey: coord)
                    }
                } else {
                    inFlightChunks.removeValue(forKey: chunkCoord)
                    if let compactChunk, shouldKeepChunkLocked(chunkCoord) {
                        chunks[chunkCoord] = compactChunk
                        availableSampleStrideByChunk[chunkCoord] = compactChunk.minimumAvailableSampleStride
                        staleChunksNeedingRegeneration.remove(chunkCoord)
                        generationSecondsByChunk[chunkCoord] = generationSeconds
                        markChunkDirtyLocked(chunkCoord)
                        for neighbor in adjacentChunkCoords(to: chunkCoord) where chunks[neighbor] != nil {
                            markChunkDirtyLocked(neighbor)
                        }
                    }
                }
                let removed = pruneChunksLockedIfNeeded()
                for removedCoord in removed {
                    markChunkRemovedLocked(removedCoord)
                }
                generationWorkersToStart = startGenerationWorkersLocked()
                meshWorkersToStart = startMeshWorkersLocked()
                workEpoch = activeWorkEpoch
                lock.unlock()

                startGenerationWorkers(generationWorkersToStart, epoch: workEpoch)
                startMeshWorkers(meshWorkersToStart, epoch: workEpoch)
            }
        }

        private func desiredLodTargetChunkSampleStridesLocked() -> [ChunkCoord: Int] {
            var targetChunkSampleStrides: [ChunkCoord: Int] = [:]
            var seen: Set<ChunkCoord> = []

            if let center = targetCenter {
                for offset in orderedOffsets {
                    let coord = ChunkCoord(x: center.x + offset.x, z: center.z + offset.z)
                    guard seen.insert(coord).inserted else {
                        continue
                    }
                    guard shouldGenerateChunkLocked(coord) else {
                        continue
                    }
                    if surfaceOnly {
                        targetChunkSampleStrides[coord] = 1
                    } else {
                        let desiredSampleStride = desiredGenerationSampleStrideLocked(for: coord)
                        if desiredSampleStride > 1 {
                            targetChunkSampleStrides[coord] = desiredSampleStride
                        }
                    }
                }
            }

            _ = forEachPinnedChunkCoordLocked { coord in
                guard seen.insert(coord).inserted else {
                    return true
                }
                guard shouldGenerateChunkLocked(coord) else {
                    return true
                }
                if surfaceOnly {
                    targetChunkSampleStrides[coord] = 1
                } else {
                    let desiredSampleStride = desiredGenerationSampleStrideLocked(for: coord)
                    if desiredSampleStride > 1 {
                        targetChunkSampleStrides[coord] = desiredSampleStride
                    }
                }
                return true
            }

            return targetChunkSampleStrides
        }

        private func makeLodSnapshotRequestLocked(
            targetChunkSampleStrides: [ChunkCoord: Int]
        ) -> LODSnapshotRequest? {
            guard !targetChunkSampleStrides.isEmpty else {
                return nil
            }

            let targetCoords = Array(targetChunkSampleStrides.keys)
            guard let minTargetChunkX = targetCoords.map(\.x).min(),
                  let maxTargetChunkX = targetCoords.map(\.x).max(),
                  let minTargetChunkZ = targetCoords.map(\.z).min(),
                  let maxTargetChunkZ = targetCoords.map(\.z).max() else {
                return nil
            }

            let minChunkX = minTargetChunkX - 2
            let maxChunkX = maxTargetChunkX + 1
            let minChunkZ = minTargetChunkZ - 2
            let maxChunkZ = maxTargetChunkZ + 1
            let minBlockX = minChunkX * ProtoChunk.sideLength
            let maxBlockX = (maxChunkX + 1) * ProtoChunk.sideLength - 1
            let minBlockZ = minChunkZ * ProtoChunk.sideLength
            let maxBlockZ = (maxChunkZ + 1) * ProtoChunk.sideLength - 1

            let originX: Int32
            let originZ: Int32
            if let targetCenter {
                originX = Int32(targetCenter.x * ProtoChunk.sideLength + ProtoChunk.sideLength / 2)
                originZ = Int32(targetCenter.z * ProtoChunk.sideLength + ProtoChunk.sideLength / 2)
            } else if targetCameraBlock.x != Int.min, targetCameraBlock.z != Int.min {
                originX = Int32(targetCameraBlock.x)
                originZ = Int32(targetCameraBlock.z)
            } else {
                originX = Int32((minBlockX + maxBlockX) / 2)
                originZ = Int32((minBlockZ + maxBlockZ) / 2)
            }

            let radius = Int32(
                max(
                    abs(minBlockX - Int(originX)),
                    abs(maxBlockX - Int(originX)),
                    abs(minBlockZ - Int(originZ)),
                    abs(maxBlockZ - Int(originZ))
                ) + terrainLodSettings.maxSampleStride
            )
            let origin = PosInt3D(x: Int32(originX), y: 0, z: Int32(originZ))
            let baseCellSize = baseLodCellSizeLocked()
            let maxCellSizePower = terrainLodSettings.maxSampleStride <= 1 || terrainLodSettings.maxSampleStride <= baseCellSize
                ? 0
                : max(0, terrainLodSettings.maxSampleStride.trailingZeroBitCount - baseCellSize.trailingZeroBitCount)

            return LODSnapshotRequest(
                origin: origin,
                radius: radius,
                nearDistance: terrainLodSettings.nearDistance,
                stepDistance: terrainLodSettings.stepDistance,
                maxCellSizePower: maxCellSizePower,
                targetChunkSampleStrides: targetChunkSampleStrides
            )
        }
        private func nextMissingChunkLocked() -> ChunkCoord? {
            if !pinnedChunkSquares.isEmpty {
                defer { pinnedGenerationSelectionCount &+= 1 }
                if pinnedGenerationSelectionCount % 4 == 3,
                   let farthest = lowestPriorityPinnedChunkLocked(where: shouldGenerateChunkLocked) {
                    return farthest
                }
                return highestPriorityPinnedChunkLocked(where: shouldGenerateChunkLocked)
            }
            if let center = targetCenter {
                for offset in orderedOffsets {
                    let coord = ChunkCoord(x: center.x + offset.x, z: center.z + offset.z)
                    if shouldGenerateChunkLocked(coord) {
                        return coord
                    }
                }
            }
            return firstPinnedChunkCoordLocked(where: shouldGenerateChunkLocked)
        }

        private func shouldGenerateChunkLocked(_ coord: ChunkCoord) -> Bool {
            guard inFlightChunks[coord] == nil,
                  !activeLodBatchTargets.contains(coord) else {
                return false
            }
            if staleChunksNeedingRegeneration.contains(coord) {
                return true
            }
            if surfaceOnly {
                return availableSampleStrideByChunk[coord] == nil
            }
            guard let chunk = chunks[coord] else {
                if let availableSampleStride = availableSampleStrideByChunk[coord] {
                    return availableSampleStride > desiredGenerationSampleStrideLocked(for: coord)
                }
                return true
            }
            return chunk.minimumAvailableSampleStride > desiredGenerationSampleStrideLocked(for: coord)
        }

        private func desiredGenerationSampleStrideLocked(for coord: ChunkCoord) -> Int {
            if isPinnedChunkLocked(coord) {
                return 1
            }
            return sampleStrideLocked(for: coord)
        }

        private func generationModeLocked(desiredSampleStride: Int) -> ChunkGenerationMode {
            if surfaceOnly || desiredSampleStride > 1 {
                return .lod
            }
            return .full
        }

        private func startGenerationWorkersLocked() -> Int {
            guard !isShutDown, targetCenter != nil || !pinnedChunkSquares.isEmpty else {
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
            if !pinnedChunkSquares.isEmpty {
                let predicate: (ChunkCoord) -> Bool = { coord in
                    self.dirtyMeshChunks.contains(coord)
                        && !self.inFlightMeshChunks.contains(coord)
                        && self.chunks[coord] != nil
                }
                defer { pinnedMeshSelectionCount &+= 1 }
                if pinnedMeshSelectionCount % 4 == 3,
                   let farthest = lowestPriorityPinnedChunkLocked(where: predicate) {
                    return farthest
                }
                return highestPriorityPinnedChunkLocked(where: predicate)
            }
            let orderedLoaded = chunks.keys
                .filter(isTargetChunkLocked)
                .sorted(by: isHigherPriorityChunk(_:than:))
            for coord in orderedLoaded where dirtyMeshChunks.contains(coord) && !inFlightMeshChunks.contains(coord) {
                return coord
            }
            return nil
        }

        private func startMeshWorkersLocked() -> Int {
            guard !isShutDown, targetCenter != nil || !pinnedChunkSquares.isEmpty else {
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

        private func meshWorkerLoop(epoch: Int) {
            while true {
                let snapshot: ChunkMeshSnapshot
                lock.lock()
                guard epoch == activeWorkEpoch else {
                    lock.unlock()
                    return
                }
                guard let coord = nextDirtyChunkLocked(),
                      let chunk = chunks[coord] else {
                    activeMeshWorkers = max(0, activeMeshWorkers - 1)
                    lock.unlock()
                    return
                }
                dirtyMeshChunks.remove(coord)
                inFlightMeshChunks.insert(coord)
                let revision = chunkMeshRevision[coord] ?? 0
                let availableChunks = availableChunkCountLocked()
                var neighbors: [ChunkCoord: CompactChunk] = [coord: chunk]
                for neighbor in adjacentChunkCoords(to: coord) {
                    if let neighborChunk = chunks[neighbor] {
                        neighbors[neighbor] = neighborChunk
                    }
                }
                let generationSeconds = generationSecondsByChunk[coord] ?? 0
                let totalTargetChunks = targetChunkCountLocked()
                lock.unlock()

                snapshot = ChunkMeshSnapshot(
                    coord: coord,
                    revision: revision,
                    chunk: chunk,
                    neighbors: neighbors,
                    generationSeconds: generationSeconds,
                    totalTargetChunks: totalTargetChunks,
                    availableChunks: availableChunks
                )

                let result = buildChunkMesh(snapshot: snapshot)

                var meshWorkersToStart = 0
                var workEpoch = 0
                lock.lock()
                guard epoch == activeWorkEpoch else {
                    lock.unlock()
                    return
                }
                inFlightMeshChunks.remove(coord)
                if chunks[coord] != nil, (chunkMeshRevision[coord] ?? 0) == result.revision {
                    pendingMeshResults[coord] = result
                    generationSecondsByChunk[coord] = 0
                }
                meshWorkersToStart = startMeshWorkersLocked()
                workEpoch = activeWorkEpoch
                lock.unlock()

                startMeshWorkers(meshWorkersToStart, epoch: workEpoch)
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
                neighbors: snapshot.neighbors
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

        private func makeCompactChunk(at chunkCoord: ChunkCoord) -> CompactChunk? {
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
                        biomeIndices: biomeIndices,
                        hasAnySolid: bitmap.contains(where: { $0 != 0 })
                    )
                )
            }

            return makeCompactChunk(
                minY: Int(protoChunk.minY),
                height: Int(protoChunk.height),
                sampleStride: 1,
                sections: fullResolutionSections
            )
        }
        private static func sourceChunkKeysNeededForMeshingStatic(_ targetChunkCoord: ChunkCoord) -> [TerrainLODChunkKey] {
            var keys: [TerrainLODChunkKey] = []
            keys.reserveCapacity(16)
            for sourceChunkZ in (targetChunkCoord.z - 2)...(targetChunkCoord.z + 1) {
                for sourceChunkX in (targetChunkCoord.x - 2)...(targetChunkCoord.x + 1) {
                    keys.append(TerrainLODChunkKey(x: Int32(sourceChunkX), z: Int32(sourceChunkZ)))
                }
            }
            return keys
        }

        private func sourceChunkKeysNeededForMeshing(_ targetChunkCoord: ChunkCoord) -> [TerrainLODChunkKey] {
            Self.sourceChunkKeysNeededForMeshingStatic(targetChunkCoord)
        }

        private func relevantLodColumns(
            for chunkCoord: ChunkCoord,
            in sourceChunksByKey: [TerrainLODChunkKey: TerrainLODChunk]
        ) -> [TerrainLODColumn] {
            let chunkMinX = chunkCoord.x * ProtoChunk.sideLength
            let chunkMaxXExclusive = chunkMinX + ProtoChunk.sideLength
            let chunkMinZ = chunkCoord.z * ProtoChunk.sideLength
            let chunkMaxZExclusive = chunkMinZ + ProtoChunk.sideLength
            var relevant: [TerrainLODColumn] = []

            for sourceChunk in sourceChunksByKey.values {
                for column in sourceChunk.columns {
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

            return relevant
        }

        private func relevantSurfaceCells(
            for chunkCoord: ChunkCoord,
            in sourceChunksByKey: [TerrainLODChunkKey: TerrainSurfaceLODChunk]
        ) -> [TerrainSurfaceLODCell] {
            let chunkMinX = chunkCoord.x * ProtoChunk.sideLength
            let chunkMaxXExclusive = chunkMinX + ProtoChunk.sideLength
            let chunkMinZ = chunkCoord.z * ProtoChunk.sideLength
            let chunkMaxZExclusive = chunkMinZ + ProtoChunk.sideLength
            var relevant: [TerrainSurfaceLODCell] = []

            for sourceChunk in sourceChunksByKey.values {
                for cell in sourceChunk.cells {
                    let cellMaxXExclusive = Int(cell.x + cell.cellSize)
                    let cellMaxZExclusive = Int(cell.z + cell.cellSize)
                    guard Int(cell.x) < chunkMaxXExclusive,
                          cellMaxXExclusive > chunkMinX,
                          Int(cell.z) < chunkMaxZExclusive,
                          cellMaxZExclusive > chunkMinZ else {
                        continue
                    }
                    relevant.append(cell)
                }
            }

            return relevant
        }

        private struct GeneratedLodMesh {
            let origin: SIMD3<Int>
            let vertices: [VulkanEngine.Vertex3D]
            let availableSampleStride: Int
            let meshSeconds: Double
        }

        private final class StreamingLodMeshAccumulator: @unchecked Sendable {
            private struct PendingBuild: @unchecked Sendable {
                let targetChunkCoord: ChunkCoord
                let sourceChunksByKey: [TerrainLODChunkKey: TerrainLODChunk]
            }

            private let lock = NSLock()
            private let desiredSampleStrideByChunk: [ChunkCoord: Int]
            private let sourceKeysByTargetChunk: [ChunkCoord: [TerrainLODChunkKey]]
            private let targetChunksBySourceKey: [TerrainLODChunkKey: [ChunkCoord]]
            private var remainingConsumersBySourceChunk: [TerrainLODChunkKey: Int]
            private var sourceChunksByKey: [TerrainLODChunkKey: TerrainLODChunk] = [:]
            private var completedTargets: Set<ChunkCoord> = []
            private let scheduleBuild: (@escaping @Sendable () -> Void) -> Void
            private let build: @Sendable (ChunkCoord, [TerrainLODChunkKey: TerrainLODChunk], Int, Int, Int) -> GeneratedLodMesh?
            private let emit: @Sendable (ChunkCoord, GeneratedLodMesh) -> Void

            init(
                desiredSampleStrideByChunk: [ChunkCoord: Int],
                scheduleBuild: @escaping (@escaping @Sendable () -> Void) -> Void,
                build: @escaping @Sendable (ChunkCoord, [TerrainLODChunkKey: TerrainLODChunk], Int, Int, Int) -> GeneratedLodMesh?,
                emit: @escaping @Sendable (ChunkCoord, GeneratedLodMesh) -> Void
            ) {
                self.desiredSampleStrideByChunk = desiredSampleStrideByChunk
                var resolvedSourceKeysByTargetChunk: [ChunkCoord: [TerrainLODChunkKey]] = [:]
                resolvedSourceKeysByTargetChunk.reserveCapacity(desiredSampleStrideByChunk.count)
                var targetChunksBySourceKey: [TerrainLODChunkKey: [ChunkCoord]] = [:]
                var remainingConsumersBySourceChunk: [TerrainLODChunkKey: Int] = [:]

                for targetChunkCoord in desiredSampleStrideByChunk.keys {
                    let sourceKeys = Streamer.sourceChunkKeysNeededForMeshingStatic(targetChunkCoord)
                    resolvedSourceKeysByTargetChunk[targetChunkCoord] = sourceKeys
                    for sourceKey in sourceKeys {
                        targetChunksBySourceKey[sourceKey, default: []].append(targetChunkCoord)
                        remainingConsumersBySourceChunk[sourceKey, default: 0] += 1
                    }
                }

                self.sourceKeysByTargetChunk = resolvedSourceKeysByTargetChunk
                self.targetChunksBySourceKey = targetChunksBySourceKey
                self.remainingConsumersBySourceChunk = remainingConsumersBySourceChunk
                self.scheduleBuild = scheduleBuild
                self.build = build
                self.emit = emit
            }

            func accept(chunk: TerrainLODChunk, minY: Int, maxYExclusive: Int) {
                var pendingBuilds: [PendingBuild] = []

                lock.lock()
                sourceChunksByKey[chunk.key] = chunk
                let candidateTargets = Set(targetChunksBySourceKey[chunk.key] ?? [])
                for targetChunkCoord in candidateTargets {
                    guard !completedTargets.contains(targetChunkCoord),
                          let sourceKeys = sourceKeysByTargetChunk[targetChunkCoord],
                          sourceKeys.allSatisfy({ sourceChunksByKey[$0] != nil }) else {
                        continue
                    }

                    completedTargets.insert(targetChunkCoord)
                    let neededSourceChunks = Dictionary(
                        uniqueKeysWithValues: sourceKeys.compactMap { sourceKey in
                            sourceChunksByKey[sourceKey].map { (sourceKey, $0) }
                        }
                    )
                    pendingBuilds.append(
                        PendingBuild(
                            targetChunkCoord: targetChunkCoord,
                            sourceChunksByKey: neededSourceChunks
                        )
                    )

                    for sourceKey in sourceKeys {
                        guard let remainingConsumers = remainingConsumersBySourceChunk[sourceKey] else {
                            continue
                        }
                        if remainingConsumers <= 1 {
                            remainingConsumersBySourceChunk.removeValue(forKey: sourceKey)
                            sourceChunksByKey.removeValue(forKey: sourceKey)
                        } else {
                            remainingConsumersBySourceChunk[sourceKey] = remainingConsumers - 1
                        }
                    }
                }
                lock.unlock()

                for pendingBuild in pendingBuilds {
                    guard let desiredSampleStride = desiredSampleStrideByChunk[pendingBuild.targetChunkCoord] else {
                        continue
                    }
                    let build = build
                    let emit = emit
                    scheduleBuild {
                        guard let mesh = build(
                            pendingBuild.targetChunkCoord,
                            pendingBuild.sourceChunksByKey,
                            desiredSampleStride,
                            minY,
                            maxYExclusive
                        ) else {
                            return
                        }
                        emit(pendingBuild.targetChunkCoord, mesh)
                    }
                }
            }

            func unfinishedTargets() -> Set<ChunkCoord> {
                lock.lock()
                let unfinished = Set(desiredSampleStrideByChunk.keys).subtracting(completedTargets)
                lock.unlock()
                return unfinished
            }
        }

        private final class StreamingSurfaceLodMeshAccumulator: @unchecked Sendable {
            private struct PendingBuild: @unchecked Sendable {
                let targetChunkCoord: ChunkCoord
                let sourceChunksByKey: [TerrainLODChunkKey: TerrainSurfaceLODChunk]
            }

            private let lock = NSLock()
            private let sourceKeysByTargetChunk: [ChunkCoord: [TerrainLODChunkKey]]
            private let targetChunksBySourceKey: [TerrainLODChunkKey: [ChunkCoord]]
            private var remainingConsumersBySourceChunk: [TerrainLODChunkKey: Int]
            private var sourceChunksByKey: [TerrainLODChunkKey: TerrainSurfaceLODChunk] = [:]
            private var completedTargets: Set<ChunkCoord> = []
            private let scheduleBuild: (@escaping @Sendable () -> Void) -> Void
            private let build: @Sendable (ChunkCoord, [TerrainLODChunkKey: TerrainSurfaceLODChunk], Int, Int) -> GeneratedLodMesh?
            private let emit: @Sendable (ChunkCoord, GeneratedLodMesh) -> Void

            init(
                targetChunkCoords: Set<ChunkCoord>,
                scheduleBuild: @escaping (@escaping @Sendable () -> Void) -> Void,
                build: @escaping @Sendable (ChunkCoord, [TerrainLODChunkKey: TerrainSurfaceLODChunk], Int, Int) -> GeneratedLodMesh?,
                emit: @escaping @Sendable (ChunkCoord, GeneratedLodMesh) -> Void
            ) {
                var resolvedSourceKeysByTargetChunk: [ChunkCoord: [TerrainLODChunkKey]] = [:]
                resolvedSourceKeysByTargetChunk.reserveCapacity(targetChunkCoords.count)
                var targetChunksBySourceKey: [TerrainLODChunkKey: [ChunkCoord]] = [:]
                var remainingConsumersBySourceChunk: [TerrainLODChunkKey: Int] = [:]

                for targetChunkCoord in targetChunkCoords {
                    let sourceKeys = Streamer.sourceChunkKeysNeededForMeshingStatic(targetChunkCoord)
                    resolvedSourceKeysByTargetChunk[targetChunkCoord] = sourceKeys
                    for sourceKey in sourceKeys {
                        targetChunksBySourceKey[sourceKey, default: []].append(targetChunkCoord)
                        remainingConsumersBySourceChunk[sourceKey, default: 0] += 1
                    }
                }

                self.sourceKeysByTargetChunk = resolvedSourceKeysByTargetChunk
                self.targetChunksBySourceKey = targetChunksBySourceKey
                self.remainingConsumersBySourceChunk = remainingConsumersBySourceChunk
                self.scheduleBuild = scheduleBuild
                self.build = build
                self.emit = emit
            }

            func accept(chunk: TerrainSurfaceLODChunk, minY: Int, maxYExclusive: Int) {
                var pendingBuilds: [PendingBuild] = []

                lock.lock()
                sourceChunksByKey[chunk.key] = chunk
                let candidateTargets = Set(targetChunksBySourceKey[chunk.key] ?? [])
                for targetChunkCoord in candidateTargets {
                    guard !completedTargets.contains(targetChunkCoord),
                          let sourceKeys = sourceKeysByTargetChunk[targetChunkCoord],
                          sourceKeys.allSatisfy({ sourceChunksByKey[$0] != nil }) else {
                        continue
                    }

                    completedTargets.insert(targetChunkCoord)
                    let neededSourceChunks = Dictionary(
                        uniqueKeysWithValues: sourceKeys.compactMap { sourceKey in
                            sourceChunksByKey[sourceKey].map { (sourceKey, $0) }
                        }
                    )
                    pendingBuilds.append(
                        PendingBuild(
                            targetChunkCoord: targetChunkCoord,
                            sourceChunksByKey: neededSourceChunks
                        )
                    )

                    for sourceKey in sourceKeys {
                        guard let remainingConsumers = remainingConsumersBySourceChunk[sourceKey] else {
                            continue
                        }
                        if remainingConsumers <= 1 {
                            remainingConsumersBySourceChunk.removeValue(forKey: sourceKey)
                            sourceChunksByKey.removeValue(forKey: sourceKey)
                        } else {
                            remainingConsumersBySourceChunk[sourceKey] = remainingConsumers - 1
                        }
                    }
                }
                lock.unlock()

                for pendingBuild in pendingBuilds {
                    let build = build
                    let emit = emit
                    scheduleBuild {
                        guard let mesh = build(
                            pendingBuild.targetChunkCoord,
                            pendingBuild.sourceChunksByKey,
                            minY,
                            maxYExclusive
                        ) else {
                            return
                        }
                        emit(pendingBuild.targetChunkCoord, mesh)
                    }
                }
            }

            func unfinishedTargets() -> Set<ChunkCoord> {
                lock.lock()
                let unfinished = Set(sourceKeysByTargetChunk.keys).subtracting(completedTargets)
                lock.unlock()
                return unfinished
            }
        }

        private func buildDirectLodMeshResult(
            at chunkCoord: ChunkCoord,
            desiredSampleStride: Int,
            retainedNeighborChunks: [ChunkCoord: CompactChunk],
            neighborDesiredSampleStrides: [ChunkCoord: Int],
            sourceChunksByKey: [TerrainLODChunkKey: TerrainLODChunk],
            minY: Int,
            maxYExclusive: Int
        ) -> GeneratedLodMesh? {
            var neighbors = retainedNeighborChunks
            neighbors.reserveCapacity(5)
            for coord in [chunkCoord] + adjacentChunkCoords(to: chunkCoord) where neighbors[coord] == nil {
                if let compactChunk = makeCompactChunkUsingSampleLOD(
                    at: coord,
                    desiredSampleStride: neighborDesiredSampleStrides[coord] ?? desiredSampleStride,
                    in: sourceChunksByKey,
                    minY: minY,
                    maxYExclusive: maxYExclusive
                ) {
                    neighbors[coord] = compactChunk
                }
            }

            guard let chunk = neighbors[chunkCoord] else {
                return nil
            }

            let meshStart = TerrainRenderer.currentTimeSeconds()
            let meshBuild = buildGreedyMesh(
                coord: chunkCoord,
                chunk: chunk,
                neighbors: neighbors
            )
            return GeneratedLodMesh(
                origin: meshBuild.origin,
                vertices: meshBuild.vertices,
                availableSampleStride: chunk.minimumAvailableSampleStride,
                meshSeconds: TerrainRenderer.currentTimeSeconds() - meshStart
            )
        }

        private func buildDirectSurfaceLodMeshResult(
            at chunkCoord: ChunkCoord,
            retainedNeighborChunks: [ChunkCoord: CompactChunk],
            sourceChunksByKey: [TerrainLODChunkKey: TerrainSurfaceLODChunk],
            minY: Int,
            maxYExclusive: Int
        ) -> GeneratedLodMesh? {
            var neighbors = retainedNeighborChunks
            neighbors.reserveCapacity(5)
            for coord in [chunkCoord] + adjacentChunkCoords(to: chunkCoord) where neighbors[coord] == nil {
                if let compactChunk = makeSurfaceCompactChunk(
                    at: coord,
                    in: sourceChunksByKey,
                    minY: minY,
                    maxYExclusive: maxYExclusive
                ) {
                    neighbors[coord] = compactChunk
                }
            }

            guard let chunk = neighbors[chunkCoord] else {
                return nil
            }

            let meshStart = TerrainRenderer.currentTimeSeconds()
            let meshBuild = buildGreedyMesh(
                coord: chunkCoord,
                chunk: chunk,
                neighbors: neighbors
            )
            return GeneratedLodMesh(
                origin: meshBuild.origin,
                vertices: meshBuild.vertices,
                availableSampleStride: chunk.minimumAvailableSampleStride,
                meshSeconds: TerrainRenderer.currentTimeSeconds() - meshStart
            )
        }

        private func retainedNeighborChunks(for chunkCoord: ChunkCoord) -> [ChunkCoord: CompactChunk] {
            lock.lock()
            var retainedNeighbors: [ChunkCoord: CompactChunk] = [:]
            let coordsNeededForMeshing = [chunkCoord] + adjacentChunkCoords(to: chunkCoord)
            retainedNeighbors.reserveCapacity(coordsNeededForMeshing.count)
            for coord in coordsNeededForMeshing {
                if let chunk = chunks[coord] {
                    retainedNeighbors[coord] = chunk
                }
            }
            lock.unlock()
            return retainedNeighbors
        }

        private func desiredNeighborSampleStrides(for chunkCoord: ChunkCoord) -> [ChunkCoord: Int] {
            lock.lock()
            var desiredNeighborSampleStrides: [ChunkCoord: Int] = [:]
            let coordsNeededForMeshing = [chunkCoord] + adjacentChunkCoords(to: chunkCoord)
            desiredNeighborSampleStrides.reserveCapacity(coordsNeededForMeshing.count)
            for coord in coordsNeededForMeshing {
                desiredNeighborSampleStrides[coord] = desiredGenerationSampleStrideLocked(for: coord)
            }
            lock.unlock()
            return desiredNeighborSampleStrides
        }

        private func recordGeneratedLodMesh(
            _ generatedLodMesh: GeneratedLodMesh,
            for chunkCoord: ChunkCoord,
            generationSeconds: Double,
            totalTargetChunks: Int,
            epoch: Int
        ) {
            lock.lock()
            defer { lock.unlock() }

            guard epoch == activeWorkEpoch else {
                return
            }

            inFlightChunks.removeValue(forKey: chunkCoord)
            activeLodBatchTargets.remove(chunkCoord)
            guard shouldKeepChunkLocked(chunkCoord) else {
                generationSecondsByChunk.removeValue(forKey: chunkCoord)
                return
            }

            availableSampleStrideByChunk[chunkCoord] = generatedLodMesh.availableSampleStride
            staleChunksNeedingRegeneration.remove(chunkCoord)
            generationSecondsByChunk.removeValue(forKey: chunkCoord)
            pendingMeshResults[chunkCoord] = ChunkMeshResult(
                coord: chunkCoord,
                revision: 0,
                origin: generatedLodMesh.origin,
                vertices: generatedLodMesh.vertices,
                profile: MeshProfile(
                    generationSeconds: generationSeconds,
                    meshSeconds: generatedLodMesh.meshSeconds,
                    uploadSeconds: 0
                ),
                availableChunks: availableChunkCountLocked(),
                totalTargetChunks: totalTargetChunks
            )
        }

        private func streamLodBatch(
            request: LODSnapshotRequest,
            totalTargetChunks: Int,
            generationStart: Double,
            epoch: Int
        ) -> Set<ChunkCoord> {
            if surfaceOnly {
                let accumulator = StreamingSurfaceLodMeshAccumulator(
                    targetChunkCoords: Set(request.targetChunkSampleStrides.keys),
                    scheduleBuild: { [weak self] work in
                        self?.meshQueue.async(execute: work)
                    },
                    build: { [weak self] chunkCoord, sourceChunksByKey, minY, maxYExclusive in
                        guard let self else {
                            return nil
                        }
                        return self.buildDirectSurfaceLodMeshResult(
                            at: chunkCoord,
                            retainedNeighborChunks: self.retainedNeighborChunks(for: chunkCoord),
                            sourceChunksByKey: sourceChunksByKey,
                            minY: minY,
                            maxYExclusive: maxYExclusive
                        )
                    },
                    emit: { [weak self] chunkCoord, generatedLodMesh in
                        self?.recordGeneratedLodMesh(
                            generatedLodMesh,
                            for: chunkCoord,
                            generationSeconds: TerrainRenderer.currentTimeSeconds() - generationStart,
                            totalTargetChunks: totalTargetChunks,
                            epoch: epoch
                        )
                    }
                )

                guard (try? worldGenerator.streamSurfaceLOD(
                    from: request.origin,
                    radius: request.radius,
                    startingRadius: Int32(request.nearDistance),
                    radiusStep: Int32(request.stepDistance),
                    maxCellSizePower: request.maxCellSizePower,
                    threadCount: generationWorkerCount,
                    progressHandler: { [weak self] progress in
                        self?.recordLodProgress(progress, surfaceOnly: true)
                    },
                    streamer: { chunk, minY, maxYExclusive in
                        accumulator.accept(
                            chunk: chunk,
                            minY: Int(minY),
                            maxYExclusive: Int(maxYExclusive)
                        )
                    }
                )) != nil else {
                    clearLodProgress(surfaceOnly: true)
                    return Set(request.targetChunkSampleStrides.keys)
                }

                return accumulator.unfinishedTargets()
            }

            let accumulator = StreamingLodMeshAccumulator(
                desiredSampleStrideByChunk: request.targetChunkSampleStrides,
                scheduleBuild: { [weak self] work in
                    self?.meshQueue.async(execute: work)
                },
                build: { [weak self] chunkCoord, sourceChunksByKey, desiredSampleStride, minY, maxYExclusive in
                    guard let self else {
                        return nil
                    }
                    return self.buildDirectLodMeshResult(
                        at: chunkCoord,
                        desiredSampleStride: desiredSampleStride,
                        retainedNeighborChunks: self.retainedNeighborChunks(for: chunkCoord),
                        neighborDesiredSampleStrides: self.desiredNeighborSampleStrides(for: chunkCoord),
                        sourceChunksByKey: sourceChunksByKey,
                        minY: minY,
                        maxYExclusive: maxYExclusive
                    )
                },
                emit: { [weak self] chunkCoord, generatedLodMesh in
                    self?.recordGeneratedLodMesh(
                        generatedLodMesh,
                        for: chunkCoord,
                        generationSeconds: TerrainRenderer.currentTimeSeconds() - generationStart,
                        totalTargetChunks: totalTargetChunks,
                        epoch: epoch
                    )
                }
            )

            guard (try? worldGenerator.streamLOD(
                from: request.origin,
                radius: request.radius,
                startingRadius: Int32(request.nearDistance),
                radiusStep: Int32(request.stepDistance),
                maxCellSizePower: request.maxCellSizePower,
                threadCount: generationWorkerCount,
                payloads: [.biome],
                progressHandler: { [weak self] progress in
                    self?.recordLodProgress(progress, surfaceOnly: false)
                },
                streamer: { chunk, minY, maxYExclusive in
                    accumulator.accept(
                        chunk: chunk,
                        minY: Int(minY),
                        maxYExclusive: Int(maxYExclusive)
                    )
                }
            )) != nil else {
                clearLodProgress(surfaceOnly: false)
                return Set(request.targetChunkSampleStrides.keys)
            }

            return accumulator.unfinishedTargets()
        }

        private func makeSurfaceCompactChunk(
            at chunkCoord: ChunkCoord,
            in sourceChunksByKey: [TerrainLODChunkKey: TerrainSurfaceLODChunk],
            minY: Int,
            maxYExclusive: Int
        ) -> CompactChunk? {
            let relevantCells = relevantSurfaceCells(for: chunkCoord, in: sourceChunksByKey)
            guard !relevantCells.isEmpty else {
                return nil
            }

            let chunkMinX = chunkCoord.x * ProtoChunk.sideLength
            let chunkMinZ = chunkCoord.z * ProtoChunk.sideLength
            let chunkMaxXExclusive = chunkMinX + ProtoChunk.sideLength
            let chunkMaxZExclusive = chunkMinZ + ProtoChunk.sideLength
            let unknownBiome = CompactBiomeEntry(
                name: "unknown",
                packedColor: biomeColorPalette.packedRGBA8(forBiomeID: nil)
            )
            var biomePalette = [unknownBiome]
            var paletteIndexByName = [unknownBiome.name: 0]
            var surfaceHeights = [Int32](repeating: Int32.min, count: ProtoChunk.sideLength * ProtoChunk.sideLength)
            var surfaceCellSizes = [UInt16](repeating: 0, count: ProtoChunk.sideLength * ProtoChunk.sideLength)
            var surfaceCellOriginXs = [Int16](repeating: 0, count: ProtoChunk.sideLength * ProtoChunk.sideLength)
            var surfaceCellOriginZs = [Int16](repeating: 0, count: ProtoChunk.sideLength * ProtoChunk.sideLength)
            var surfaceBiomeIndices = [UInt8](repeating: 0, count: ProtoChunk.sideLength * ProtoChunk.sideLength)
            var minimumCellSize = Int.max

            for cell in relevantCells {
                minimumCellSize = min(minimumCellSize, Int(cell.cellSize))
                let localStartX = max(0, Int(cell.x) - chunkMinX)
                let localStartZ = max(0, Int(cell.z) - chunkMinZ)
                let localEndX = min(chunkMaxXExclusive - chunkMinX, Int(cell.x + cell.cellSize) - chunkMinX)
                let localEndZ = min(chunkMaxZExclusive - chunkMinZ, Int(cell.z + cell.cellSize) - chunkMinZ)
                guard localStartX < localEndX, localStartZ < localEndZ else {
                    continue
                }

                let biomeName = cell.surfaceBiome?.name ?? "unknown"
                let paletteIndex: Int
                if let existing = paletteIndexByName[biomeName] {
                    paletteIndex = existing
                } else {
                    paletteIndex = biomePalette.count
                    precondition(paletteIndex < 256, "surface biome palette exceeded UInt8 capacity")
                    paletteIndexByName[biomeName] = paletteIndex
                    biomePalette.append(
                        CompactBiomeEntry(
                            name: biomeName,
                            packedColor: biomeColorPalette.packedRGBA8(forBiomeID: biomeName)
                        )
                    )
                }

                for localZ in localStartZ..<localEndZ {
                    for localX in localStartX..<localEndX {
                        let index = localZ * ProtoChunk.sideLength + localX
                        let newCellSize = UInt16(clamping: Int(cell.cellSize))
                        let existingCellSize = surfaceCellSizes[index]
                        let existingHasSurface = surfaceHeights[index] != Int32.min
                        let newHasSurface = cell.surfaceY != nil
                        let shouldReplace =
                            existingCellSize == 0
                            || (
                                newHasSurface != existingHasSurface
                                && newHasSurface
                            )
                            || (
                                newHasSurface == existingHasSurface
                                && (
                                    newCellSize < existingCellSize
                                    || (
                                        newCellSize == existingCellSize
                                        && !existingHasSurface
                                        && newHasSurface
                                    )
                                )
                            )
                        guard shouldReplace else {
                            continue
                        }

                        surfaceHeights[index] = cell.surfaceY ?? Int32.min
                        surfaceCellSizes[index] = newCellSize
                        surfaceCellOriginXs[index] = Int16(clamping: Int(cell.x) - chunkMinX)
                        surfaceCellOriginZs[index] = Int16(clamping: Int(cell.z) - chunkMinZ)
                        surfaceBiomeIndices[index] = UInt8(paletteIndex)
                    }
                }
            }

            return CompactChunk(
                minY: minY,
                height: maxYExclusive - minY,
                sampleStride: minimumCellSize == Int.max ? 1 : minimumCellSize,
                sections: nil,
                firstSolidSection: nil,
                lastSolidSection: nil,
                surfaceHeights: surfaceHeights,
                surfaceCellSizes: surfaceCellSizes,
                surfaceCellOriginXs: surfaceCellOriginXs,
                surfaceCellOriginZs: surfaceCellOriginZs,
                surfaceBiomePalette: biomePalette,
                surfaceBiomeIndices: surfaceBiomeIndices
            )
        }

        private func makeCompactChunkUsingSampleLOD(
            at chunkCoord: ChunkCoord,
            desiredSampleStride: Int,
            in sourceChunksByKey: [TerrainLODChunkKey: TerrainLODChunk],
            minY: Int,
            maxYExclusive: Int
        ) -> CompactChunk? {
            let relevantColumns = relevantLodColumns(for: chunkCoord, in: sourceChunksByKey)
            guard !relevantColumns.isEmpty else {
                return nil
            }

            let chunkMinX = chunkCoord.x * ProtoChunk.sideLength
            let chunkMinZ = chunkCoord.z * ProtoChunk.sideLength
            let baseSampleStride = relevantColumns.reduce(desiredSampleStride) { min($0, Int($1.cellSize)) }
            guard Self.supportedSampleStrides.contains(baseSampleStride),
                  ProtoChunk.sideLength % baseSampleStride == 0 else {
                return nil
            }

            let height = maxYExclusive - minY
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

            let chunkMaxXExclusive = chunkMinX + ProtoChunk.sideLength
            let chunkMaxZExclusive = chunkMinZ + ProtoChunk.sideLength
            let heightInCells = height / baseSampleStride

            @inline(__always)
            func ceilDivPositive(_ value: Int, by divisor: Int) -> Int {
                (value + divisor - 1) / divisor
            }

            for column in relevantColumns {
                let columnCellSize = max(baseSampleStride, Int(column.cellSize))
                let columnMinX = Int(column.x)
                let columnMaxXExclusive = columnMinX + columnCellSize
                let columnMinZ = Int(column.z)
                let columnMaxZExclusive = columnMinZ + columnCellSize
                let overlapStartX = max(chunkMinX, columnMinX)
                let overlapEndX = min(chunkMaxXExclusive, columnMaxXExclusive)
                let overlapStartZ = max(chunkMinZ, columnMinZ)
                let overlapEndZ = min(chunkMaxZExclusive, columnMaxZExclusive)
                guard overlapStartX < overlapEndX, overlapStartZ < overlapEndZ else {
                    continue
                }
                let localStartCellX = max(0, min(cellSideLength, (overlapStartX - chunkMinX) / baseSampleStride))
                let localEndCellX = max(localStartCellX, min(cellSideLength, ceilDivPositive(overlapEndX - chunkMinX, by: baseSampleStride)))
                let localStartCellZ = max(0, min(cellSideLength, (overlapStartZ - chunkMinZ) / baseSampleStride))
                let localEndCellZ = max(localStartCellZ, min(cellSideLength, ceilDivPositive(overlapEndZ - chunkMinZ, by: baseSampleStride)))
                guard localStartCellX < localEndCellX, localStartCellZ < localEndCellZ else {
                    continue
                }

                for (sampleIndex, isSolid) in column.samples.enumerated() {
                    guard isSolid else {
                        continue
                    }

                    let sampleMinY = minY + sampleIndex * columnCellSize
                    let sampleMaxYExclusive = sampleMinY + columnCellSize
                    let overlapStartY = max(minY, sampleMinY)
                    let overlapEndY = min(minY + height, sampleMaxYExclusive)
                    guard overlapStartY < overlapEndY else {
                        continue
                    }
                    let localStartCellY = max(0, min(heightInCells, (overlapStartY - minY) / baseSampleStride))
                    let localEndCellY = max(localStartCellY, min(heightInCells, ceilDivPositive(overlapEndY - minY, by: baseSampleStride)))
                    guard localStartCellY < localEndCellY else {
                        continue
                    }
                    let biomeName = column.samplePayloads?[sampleIndex].biome?.name
                    let biomeEntry = CompactBiomeEntry(
                        name: biomeName ?? "unknown",
                        packedColor: biomeColorPalette.packedRGBA8(forBiomeID: biomeName)
                    )

                    for filledCellY in localStartCellY..<localEndCellY {
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
                        for filledCellZ in localStartCellZ..<localEndCellZ {
                            for filledCellX in localStartCellX..<localEndCellX {
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
                    biomeIndices: builder.biomeIndices,
                    hasAnySolid: builder.bitmap.contains(where: { $0 != 0 })
                )
            }
            return makeCompactChunk(
                minY: minY,
                height: height,
                sampleStride: baseSampleStride,
                sections: baseSections
            )
        }

        private func makeCompactChunk(
            minY: Int,
            height: Int,
            sampleStride: Int,
            sections: [CompactSection]
        ) -> CompactChunk {
            var firstSolidSection: Int?
            var lastSolidSection: Int?
            for (index, section) in sections.enumerated() where section.hasAnySolid {
                if firstSolidSection == nil {
                    firstSolidSection = index
                }
                lastSolidSection = index
            }

            return CompactChunk(
                minY: minY,
                height: height,
                sampleStride: sampleStride,
                sections: sections,
                firstSolidSection: firstSolidSection,
                lastSolidSection: lastSolidSection,
                surfaceHeights: nil,
                surfaceCellSizes: nil,
                surfaceCellOriginXs: nil,
                surfaceCellOriginZs: nil,
                surfaceBiomePalette: nil,
                surfaceBiomeIndices: nil
            )
        }

        private func pruneChunksLockedIfNeeded() -> [ChunkCoord] {
            if !pinnedChunkSquares.isEmpty {
                var removed: [ChunkCoord] = []
                for coord in availableSampleStrideByChunk.keys {
                    if !isPinnedChunkLocked(coord) {
                        removed.append(coord)
                    }
                }
                return removed
            }
            if let center = targetCenter {
                return pruneChunksLocked(around: center)
            }

            var removed: [ChunkCoord] = []
            for coord in availableSampleStrideByChunk.keys {
                let keep = isPinnedChunkLocked(coord)
                if !keep {
                    removed.append(coord)
                }
            }
            return removed
        }

        @discardableResult
        private func pruneChunksLocked(around center: ChunkCoord) -> [ChunkCoord] {
            var removed: [ChunkCoord] = []
            for coord in availableSampleStrideByChunk.keys {
                let keep = shouldKeepChunk(coord, around: center, extraMargin: 1)
                if !keep {
                    removed.append(coord)
                }
            }
            return removed
        }

        private func shouldKeepChunk(_ coord: ChunkCoord, around center: ChunkCoord, extraMargin: Int = 0) -> Bool {
            if isPinnedChunkLocked(coord) {
                return true
            }
            return abs(coord.x - center.x) <= renderRadius + extraMargin && abs(coord.z - center.z) <= renderRadius + extraMargin
        }

        private func shouldKeepChunkLocked(_ coord: ChunkCoord) -> Bool {
            if !pinnedChunkSquares.isEmpty {
                return isPinnedChunkLocked(coord)
            }
            if let center = targetCenter {
                return shouldKeepChunk(coord, around: center)
            }
            return isPinnedChunkLocked(coord)
        }

        private func isTargetChunkLocked(_ coord: ChunkCoord) -> Bool {
            if !pinnedChunkSquares.isEmpty {
                return isPinnedChunkLocked(coord)
            }
            if let center = targetCenter,
               abs(coord.x - center.x) <= renderRadius,
               abs(coord.z - center.z) <= renderRadius {
                return true
            }
            return isPinnedChunkLocked(coord)
        }

        private func isPinnedChunkLocked(_ coord: ChunkCoord) -> Bool {
            pinnedChunkCoordSet.contains(coord)
        }

        private func firstPinnedChunkCoordLocked(where predicate: (ChunkCoord) -> Bool) -> ChunkCoord? {
            var match: ChunkCoord?
            _ = forEachPinnedChunkCoordLocked { coord in
                if predicate(coord) {
                    match = coord
                    return false
                }
                return true
            }
            return match
        }

        private func highestPriorityPinnedChunkLocked(where predicate: (ChunkCoord) -> Bool) -> ChunkCoord? {
            var best: ChunkCoord?
            _ = forEachPinnedChunkCoordLocked { coord in
                guard predicate(coord) else {
                    return true
                }
                if let currentBest = best {
                    if isHigherPriorityChunk(coord, than: currentBest) {
                        best = coord
                    }
                } else {
                    best = coord
                }
                return true
            }
            return best
        }

        private func lowestPriorityPinnedChunkLocked(where predicate: (ChunkCoord) -> Bool) -> ChunkCoord? {
            var worst: ChunkCoord?
            _ = forEachPinnedChunkCoordLocked { coord in
                guard predicate(coord) else {
                    return true
                }
                if let currentWorst = worst {
                    if isHigherPriorityChunk(currentWorst, than: coord) {
                        worst = coord
                    }
                } else {
                    worst = coord
                }
                return true
            }
            return worst
        }

        @discardableResult
        private func forEachPinnedChunkCoordLocked(_ body: (ChunkCoord) -> Bool) -> Bool {
            for coord in pinnedChunkCoords {
                if !body(coord) {
                    return false
                }
            }
            return true
        }

        private func pinnedChunkCountLocked() -> Int {
            pinnedChunkCoords.count
        }

        private func targetChunkCountLocked() -> Int {
            if !pinnedChunkSquares.isEmpty {
                return pinnedChunkCountLocked()
            }
            var count = targetCenter == nil ? 0 : orderedOffsets.count
            forEachPinnedChunkCoordLocked { coord in
                if let center = targetCenter,
                   abs(coord.x - center.x) <= renderRadius,
                   abs(coord.z - center.z) <= renderRadius {
                    return true
                }
                count += 1
                return true
            }
            return count
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
            chunks.removeValue(forKey: coord)
            availableSampleStrideByChunk.removeValue(forKey: coord)
            staleChunksNeedingRegeneration.remove(coord)
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

        private func availableChunkCountLocked() -> Int {
            availableSampleStrideByChunk.count
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

            for coord in availableSampleStrideByChunk.keys {
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
                if chunks[coord] != nil {
                    markChunkDirtyLocked(coord)
                } else {
                    staleChunksNeedingRegeneration.insert(coord)
                }
            }
            return impactedChunks
        }

        private func baseLodCellSizeLocked() -> Int {
            if let cachedBaseLodCellSize {
                return cachedBaseLodCellSize
            }

            baseLodCellSizeLock.lock()
            defer { baseLodCellSizeLock.unlock() }
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
            lodProgress = nil
            surfaceLodProgress = nil
        }

        private func rebuildPinnedChunkCacheLocked() {
            guard !pinnedChunkSquares.isEmpty else {
                pinnedChunkCoords.removeAll(keepingCapacity: false)
                pinnedChunkCoordSet.removeAll(keepingCapacity: false)
                return
            }

            var coords: [ChunkCoord] = []
            coords.reserveCapacity(TerrainRenderer.countChunkCoords(in: pinnedChunkSquares))
            TerrainRenderer.forEachChunkCoord(in: pinnedChunkSquares) { coord in
                coords.append(coord)
                return true
            }
            pinnedChunkCoords = coords
            pinnedChunkCoordSet = Set(coords)
        }

        private func startGenerationWorkers(_ count: Int, epoch: Int) {
            guard count > 0 else {
                return
            }
            for _ in 0..<count {
                generationQueue.async { [self] in
                    generationWorkerLoop(epoch: epoch)
                }
            }
        }

        private func startMeshWorkers(_ count: Int, epoch: Int) {
            guard count > 0 else {
                return
            }
            for _ in 0..<count {
                meshQueue.async { [self] in
                    meshWorkerLoop(epoch: epoch)
                }
            }
        }

        private func recordLodProgress(_ progress: TerrainLODProgress, surfaceOnly: Bool) {
            lock.lock()
            if surfaceOnly {
                surfaceLodProgress = progress
            } else {
                lodProgress = progress
            }
            lock.unlock()
        }

        private func clearLodProgress(surfaceOnly: Bool) {
            lock.lock()
            if surfaceOnly {
                surfaceLodProgress = nil
            } else {
                lodProgress = nil
            }
            lock.unlock()
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
            neighbors: [ChunkCoord: CompactChunk]
        ) -> (origin: SIMD3<Int>, vertices: [VulkanEngine.Vertex3D]) {
            if chunk.isSurfaceOnly {
                return buildSurfaceMesh(
                    coord: coord,
                    chunk: chunk,
                    neighbors: neighbors
                )
            }
            return buildVolumeGreedyMesh(
                coord: coord,
                chunk: chunk,
                neighbors: neighbors
            )
        }

        private func buildVolumeGreedyMesh(
            coord: ChunkCoord,
            chunk: CompactChunk,
            neighbors: [ChunkCoord: CompactChunk]
        ) -> (origin: SIMD3<Int>, vertices: [VulkanEngine.Vertex3D]) {
            let emptyOrigin = SIMD3<Int>(coord.x * 16, chunk.minY, coord.z * 16)
            let originX = coord.x * 16
            let originZ = coord.z * 16

            guard let firstSolidSection = chunk.firstSolidSection,
                  let lastSolidSection = chunk.lastSolidSection else {
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
                    z: z
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
                let localX = floorMod(worldX, 16)
                let localZ = floorMod(worldZ, 16)
                let localY = worldY - queryChunk.minY
                guard localY >= 0, localY < queryChunk.height else {
                    return false
                }
                return queryChunk.isSolid(
                    atLocalX: localX,
                    y: localY,
                    z: localZ
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

        private func buildSurfaceMesh(
            coord: ChunkCoord,
            chunk: CompactChunk,
            neighbors: [ChunkCoord: CompactChunk]
        ) -> (origin: SIMD3<Int>, vertices: [VulkanEngine.Vertex3D]) {
            let origin = SIMD3<Int>(coord.x * 16, chunk.minY, coord.z * 16)
            guard chunk.surfaceHeights != nil else {
                return (origin, [])
            }

            var vertices: [VulkanEngine.Vertex3D] = []
            vertices.reserveCapacity(2_304)

            @inline(__always)
            func localSurfaceHeight(_ x: Int, _ z: Int) -> Int32? {
                chunk.surfaceHeight(atLocalX: x, z: z)
            }

            @inline(__always)
            func localSurfaceCellSize(_ x: Int, _ z: Int) -> Int {
                chunk.surfaceCellSize(atLocalX: x, z: z) ?? 1
            }

            @inline(__always)
            func localSurfaceCellOriginX(_ x: Int, _ z: Int) -> Int {
                chunk.surfaceCellOriginX(atLocalX: x, z: z) ?? x
            }

            @inline(__always)
            func localSurfaceCellOriginZ(_ x: Int, _ z: Int) -> Int {
                chunk.surfaceCellOriginZ(atLocalX: x, z: z) ?? z
            }

            @inline(__always)
            func packedBiomeColor(_ x: Int, _ z: Int) -> UInt32 {
                chunk.biomeEntry(atLocalX: x, y: 0, z: z)?.packedColor
                    ?? biomeColorPalette.packedRGBA8(forBiomeID: nil)
            }

            @inline(__always)
            func worldSurfaceHeight(_ worldX: Int, _ worldZ: Int) -> Int32? {
                let queryCoord = ChunkCoord(
                    x: floorDiv(worldX, 16),
                    z: floorDiv(worldZ, 16)
                )
                guard let queryChunk = neighbors[queryCoord] else {
                    return nil
                }
                let localX = floorMod(worldX, 16)
                let localZ = floorMod(worldZ, 16)
                return queryChunk.surfaceHeight(atLocalX: localX, z: localZ)
            }

            @inline(__always)
            func worldSurfaceCellSize(_ worldX: Int, _ worldZ: Int) -> Int {
                let queryCoord = ChunkCoord(
                    x: floorDiv(worldX, 16),
                    z: floorDiv(worldZ, 16)
                )
                guard let queryChunk = neighbors[queryCoord] else {
                    return max(1, chunk.sampleStride)
                }
                let localX = floorMod(worldX, 16)
                let localZ = floorMod(worldZ, 16)
                return queryChunk.surfaceCellSize(atLocalX: localX, z: localZ) ?? max(1, queryChunk.sampleStride)
            }

            @inline(__always)
            func localTopY(_ surfaceY: Int32) -> Float {
                Float(surfaceY + 1 - Int32(chunk.minY))
            }

            let currentChunkWorldMinX = coord.x * ProtoChunk.sideLength
            let currentChunkWorldMinZ = coord.z * ProtoChunk.sideLength
            let nilNeighborDropY = Float(max(16, chunk.sampleStride * 4))

            @inline(__always)
            func sideBottomY(topY: Float, neighborSurfaceY: Int32?) -> Float {
                if let neighborSurfaceY {
                    return localTopY(neighborSurfaceY)
                }
                return max(0, topY - nilNeighborDropY)
            }

            @inline(__always)
            func shouldRenderVerticalFace(
                surfaceY: Int32,
                localCellSize: Int,
                neighborSurfaceY: Int32?,
                neighborCellSize: Int
            ) -> Bool {
                guard let neighborSurfaceY else {
                    return true
                }
                let drop = Int(surfaceY - neighborSurfaceY)
                guard drop > 0 else {
                    return false
                }
                if localCellSize == 1 && neighborCellSize == 1 {
                    return true
                }
                return drop >= (localCellSize + neighborCellSize)
            }

            @inline(__always)
            func appendTopRect(localX: Int, localZ: Int, width: Int, height: Int, surfaceY: Int32, packedColor: UInt32) {
                let topY = localTopY(surfaceY)
                appendQuad(
                    &vertices,
                    a: SIMD3<Float>(Float(localX), topY, Float(localZ)),
                    b: SIMD3<Float>(Float(localX), topY, Float(localZ + height)),
                    c: SIMD3<Float>(Float(localX + width), topY, Float(localZ + height)),
                    d: SIMD3<Float>(Float(localX + width), topY, Float(localZ)),
                    color: shadedBiomeColor(
                        packedBaseColor: packedColor,
                        axis: 1,
                        positiveFace: true
                    )
                )
            }

            @inline(__always)
            func appendWestFace(localX: Int, startZ: Int, endZ: Int, topY: Float, bottomY: Float, packedColor: UInt32) {
                appendQuad(
                    &vertices,
                    a: SIMD3<Float>(Float(localX), topY, Float(startZ)),
                    b: SIMD3<Float>(Float(localX), bottomY, Float(startZ)),
                    c: SIMD3<Float>(Float(localX), bottomY, Float(endZ)),
                    d: SIMD3<Float>(Float(localX), topY, Float(endZ)),
                    color: shadedBiomeColor(packedBaseColor: packedColor, axis: 0, positiveFace: false)
                )
            }

            @inline(__always)
            func appendEastFace(localX: Int, startZ: Int, endZ: Int, topY: Float, bottomY: Float, packedColor: UInt32) {
                appendQuad(
                    &vertices,
                    a: SIMD3<Float>(Float(localX), topY, Float(endZ)),
                    b: SIMD3<Float>(Float(localX), bottomY, Float(endZ)),
                    c: SIMD3<Float>(Float(localX), bottomY, Float(startZ)),
                    d: SIMD3<Float>(Float(localX), topY, Float(startZ)),
                    color: shadedBiomeColor(packedBaseColor: packedColor, axis: 0, positiveFace: true)
                )
            }

            @inline(__always)
            func appendNorthFace(localZ: Int, startX: Int, endX: Int, topY: Float, bottomY: Float, packedColor: UInt32) {
                appendQuad(
                    &vertices,
                    a: SIMD3<Float>(Float(endX), topY, Float(localZ)),
                    b: SIMD3<Float>(Float(endX), bottomY, Float(localZ)),
                    c: SIMD3<Float>(Float(startX), bottomY, Float(localZ)),
                    d: SIMD3<Float>(Float(startX), topY, Float(localZ)),
                    color: shadedBiomeColor(packedBaseColor: packedColor, axis: 2, positiveFace: false)
                )
            }

            @inline(__always)
            func appendSouthFace(localZ: Int, startX: Int, endX: Int, topY: Float, bottomY: Float, packedColor: UInt32) {
                appendQuad(
                    &vertices,
                    a: SIMD3<Float>(Float(startX), topY, Float(localZ)),
                    b: SIMD3<Float>(Float(startX), bottomY, Float(localZ)),
                    c: SIMD3<Float>(Float(endX), bottomY, Float(localZ)),
                    d: SIMD3<Float>(Float(endX), topY, Float(localZ)),
                    color: shadedBiomeColor(packedBaseColor: packedColor, axis: 2, positiveFace: true)
                )
            }

            for localZ in 0..<ProtoChunk.sideLength {
                for localX in 0..<ProtoChunk.sideLength {
                    guard let surfaceY = localSurfaceHeight(localX, localZ) else {
                        continue
                    }

                    let cellSize = localSurfaceCellSize(localX, localZ)
                    let cellOriginX = localSurfaceCellOriginX(localX, localZ)
                    let cellOriginZ = localSurfaceCellOriginZ(localX, localZ)
                    let localStartX = max(0, cellOriginX)
                    let localStartZ = max(0, cellOriginZ)
                    guard localX == localStartX, localZ == localStartZ else {
                        continue
                    }

                    let localEndX = min(ProtoChunk.sideLength, cellOriginX + cellSize)
                    let localEndZ = min(ProtoChunk.sideLength, cellOriginZ + cellSize)
                    guard localStartX < localEndX, localStartZ < localEndZ else {
                        continue
                    }

                    let packedColor = packedBiomeColor(localX, localZ)
                    let topY = localTopY(surfaceY)
                    appendTopRect(
                        localX: localStartX,
                        localZ: localStartZ,
                        width: localEndX - localStartX,
                        height: localEndZ - localStartZ,
                        surfaceY: surfaceY,
                        packedColor: packedColor
                    )

                    let worldStartX = currentChunkWorldMinX + localStartX
                    let worldStartZ = currentChunkWorldMinZ + localStartZ
                    let worldEndX = currentChunkWorldMinX + localEndX
                    let worldEndZ = currentChunkWorldMinZ + localEndZ

                    var runStartZ: Int? = nil
                    var runBottomY: Float = 0
                    for edgeWorldZ in worldStartZ..<worldEndZ {
                        let neighborSurfaceY = worldSurfaceHeight(worldStartX - 1, edgeWorldZ)
                        let neighborCellSize = worldSurfaceCellSize(worldStartX - 1, edgeWorldZ)
                        if shouldRenderVerticalFace(
                            surfaceY: surfaceY,
                            localCellSize: cellSize,
                            neighborSurfaceY: neighborSurfaceY,
                            neighborCellSize: neighborCellSize
                        ) {
                            let bottomY = sideBottomY(topY: topY, neighborSurfaceY: neighborSurfaceY)
                            if runStartZ == nil {
                                runStartZ = edgeWorldZ
                                runBottomY = bottomY
                            } else if bottomY != runBottomY {
                                appendWestFace(
                                    localX: localStartX,
                                    startZ: runStartZ! - currentChunkWorldMinZ,
                                    endZ: edgeWorldZ - currentChunkWorldMinZ,
                                    topY: topY,
                                    bottomY: runBottomY,
                                    packedColor: packedColor
                                )
                                runStartZ = edgeWorldZ
                                runBottomY = bottomY
                            }
                        } else if let currentRunStartZ = runStartZ {
                            appendWestFace(
                                localX: localStartX,
                                startZ: currentRunStartZ - currentChunkWorldMinZ,
                                endZ: edgeWorldZ - currentChunkWorldMinZ,
                                topY: topY,
                                bottomY: runBottomY,
                                packedColor: packedColor
                            )
                            runStartZ = nil
                        }
                    }
                    if let currentRunStartZ = runStartZ {
                        appendWestFace(
                            localX: localStartX,
                            startZ: currentRunStartZ - currentChunkWorldMinZ,
                            endZ: worldEndZ - currentChunkWorldMinZ,
                            topY: topY,
                            bottomY: runBottomY,
                            packedColor: packedColor
                        )
                    }

                    runStartZ = nil
                    for edgeWorldZ in worldStartZ..<worldEndZ {
                        let neighborSurfaceY = worldSurfaceHeight(worldEndX, edgeWorldZ)
                        let neighborCellSize = worldSurfaceCellSize(worldEndX, edgeWorldZ)
                        if shouldRenderVerticalFace(
                            surfaceY: surfaceY,
                            localCellSize: cellSize,
                            neighborSurfaceY: neighborSurfaceY,
                            neighborCellSize: neighborCellSize
                        ) {
                            let bottomY = sideBottomY(topY: topY, neighborSurfaceY: neighborSurfaceY)
                            if runStartZ == nil {
                                runStartZ = edgeWorldZ
                                runBottomY = bottomY
                            } else if bottomY != runBottomY {
                                appendEastFace(
                                    localX: localEndX,
                                    startZ: runStartZ! - currentChunkWorldMinZ,
                                    endZ: edgeWorldZ - currentChunkWorldMinZ,
                                    topY: topY,
                                    bottomY: runBottomY,
                                    packedColor: packedColor
                                )
                                runStartZ = edgeWorldZ
                                runBottomY = bottomY
                            }
                        } else if let currentRunStartZ = runStartZ {
                            appendEastFace(
                                localX: localEndX,
                                startZ: currentRunStartZ - currentChunkWorldMinZ,
                                endZ: edgeWorldZ - currentChunkWorldMinZ,
                                topY: topY,
                                bottomY: runBottomY,
                                packedColor: packedColor
                            )
                            runStartZ = nil
                        }
                    }
                    if let currentRunStartZ = runStartZ {
                        appendEastFace(
                            localX: localEndX,
                            startZ: currentRunStartZ - currentChunkWorldMinZ,
                            endZ: worldEndZ - currentChunkWorldMinZ,
                            topY: topY,
                            bottomY: runBottomY,
                            packedColor: packedColor
                        )
                    }

                    var runStartX: Int? = nil
                    for edgeWorldX in worldStartX..<worldEndX {
                        let neighborSurfaceY = worldSurfaceHeight(edgeWorldX, worldStartZ - 1)
                        let neighborCellSize = worldSurfaceCellSize(edgeWorldX, worldStartZ - 1)
                        if shouldRenderVerticalFace(
                            surfaceY: surfaceY,
                            localCellSize: cellSize,
                            neighborSurfaceY: neighborSurfaceY,
                            neighborCellSize: neighborCellSize
                        ) {
                            let bottomY = sideBottomY(topY: topY, neighborSurfaceY: neighborSurfaceY)
                            if runStartX == nil {
                                runStartX = edgeWorldX
                                runBottomY = bottomY
                            } else if bottomY != runBottomY {
                                appendNorthFace(
                                    localZ: localStartZ,
                                    startX: runStartX! - currentChunkWorldMinX,
                                    endX: edgeWorldX - currentChunkWorldMinX,
                                    topY: topY,
                                    bottomY: runBottomY,
                                    packedColor: packedColor
                                )
                                runStartX = edgeWorldX
                                runBottomY = bottomY
                            }
                        } else if let currentRunStartX = runStartX {
                            appendNorthFace(
                                localZ: localStartZ,
                                startX: currentRunStartX - currentChunkWorldMinX,
                                endX: edgeWorldX - currentChunkWorldMinX,
                                topY: topY,
                                bottomY: runBottomY,
                                packedColor: packedColor
                            )
                            runStartX = nil
                        }
                    }
                    if let currentRunStartX = runStartX {
                        appendNorthFace(
                            localZ: localStartZ,
                            startX: currentRunStartX - currentChunkWorldMinX,
                            endX: worldEndX - currentChunkWorldMinX,
                            topY: topY,
                            bottomY: runBottomY,
                            packedColor: packedColor
                        )
                    }

                    runStartX = nil
                    for edgeWorldX in worldStartX..<worldEndX {
                        let neighborSurfaceY = worldSurfaceHeight(edgeWorldX, worldEndZ)
                        let neighborCellSize = worldSurfaceCellSize(edgeWorldX, worldEndZ)
                        if shouldRenderVerticalFace(
                            surfaceY: surfaceY,
                            localCellSize: cellSize,
                            neighborSurfaceY: neighborSurfaceY,
                            neighborCellSize: neighborCellSize
                        ) {
                            let bottomY = sideBottomY(topY: topY, neighborSurfaceY: neighborSurfaceY)
                            if runStartX == nil {
                                runStartX = edgeWorldX
                                runBottomY = bottomY
                            } else if bottomY != runBottomY {
                                appendSouthFace(
                                    localZ: localEndZ,
                                    startX: runStartX! - currentChunkWorldMinX,
                                    endX: edgeWorldX - currentChunkWorldMinX,
                                    topY: topY,
                                    bottomY: runBottomY,
                                    packedColor: packedColor
                                )
                                runStartX = edgeWorldX
                                runBottomY = bottomY
                            }
                        } else if let currentRunStartX = runStartX {
                            appendSouthFace(
                                localZ: localEndZ,
                                startX: currentRunStartX - currentChunkWorldMinX,
                                endX: edgeWorldX - currentChunkWorldMinX,
                                topY: topY,
                                bottomY: runBottomY,
                                packedColor: packedColor
                            )
                            runStartX = nil
                        }
                    }
                    if let currentRunStartX = runStartX {
                        appendSouthFace(
                            localZ: localEndZ,
                            startX: currentRunStartX - currentChunkWorldMinX,
                            endX: worldEndX - currentChunkWorldMinX,
                            topY: topY,
                            bottomY: runBottomY,
                            packedColor: packedColor
                        )
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
    let surfaceOnly: Bool
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
    var suspendStreamingUpdates = false

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
    var programScenePreparationStatus: ProgramScenePreparationStatus?

    init(
        worldGenerator: WorldGenerator,
        biomeColorPalette: BiomeColorPalette,
        renderRadius: Int = 12,
        terrainLodNearDistance: Int = 128,
        terrainLodStepDistance: Int = 128,
        terrainLodMaxScale: Int = 8,
        surfaceOnly: Bool = false,
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
        self.surfaceOnly = surfaceOnly
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
            ),
            surfaceOnly: surfaceOnly
        )
    }

    deinit {
        streamer.shutdown()
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

        var batches: [VulkanEngine.DrawBatch3D] = []
        batches.reserveCapacity(chunkMeshes.count + (keyframeOverlayVertexCount > 0 ? 1 : 0))
        for mesh in chunkMeshes.values where mesh.vertexCount > 0 {
            let modelOffset = SIMD4<Float>(
                Float(Double(mesh.origin.x) - cameraPosition.x),
                Float(Double(mesh.origin.y) - cameraPosition.y),
                Float(Double(mesh.origin.z) - cameraPosition.z),
                0
            )
            batches.append(
                .init(
                    buffer: mesh.buffer,
                    vertexCount: mesh.vertexCount,
                    modelOffset: modelOffset
                )
            )
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

    func takeChunkMeshes() -> [ChunkCoord: ChunkRenderMesh] {
        let meshes = chunkMeshes
        chunkMeshes = [:]
        return meshes
    }

    func replaceChunkMeshes(with meshes: [ChunkCoord: ChunkRenderMesh]) {
        chunkMeshes = meshes
    }

    func discardChunkStateKeepingMeshes() {
        streamer.discardChunkStateKeepingMeshes()
    }

    func primeStreamingTargetToCurrentCamera() {
        let cameraBlock = SIMD3<Int>(
            Int(floor(cameraPosition.x)),
            Int(floor(cameraPosition.y)),
            Int(floor(cameraPosition.z))
        )
        let cameraChunk = ChunkCoord(
            x: floorDiv(cameraBlock.x, 16),
            z: floorDiv(cameraBlock.z, 16)
        )
        streamer.primeTarget(center: cameraChunk, cameraBlock: cameraBlock)
    }

    func shutdownStreaming() {
        suspendStreamingUpdates = true
        streamer.shutdown()
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
