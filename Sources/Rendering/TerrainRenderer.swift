import Foundation
import DPReader
import SwiftSDL
import Vulkan
import VulkanBindings
import simd

final class TerrainRenderer {
    private struct RebuildProfile {
        var generatedChunks = 0
        var generationSeconds: Double = 0
        var volumeSeconds: Double = 0
        var meshSeconds: Double = 0
        var uploadSeconds: Double = 0
    }

    private struct ChunkCoord: Hashable {
        let x: Int
        let z: Int
    }

    private struct ChunkSnapshot {
        let revision: Int
        let center: ChunkCoord
        let cameraBlock: SIMD3<Int>
        let chunks: [ChunkCoord: ProtoChunk]
        let generatedChunks: Int
        let generationSeconds: Double
        let totalTargetChunks: Int
    }

    private struct Volume {
        let originX: Int
        let originY: Int
        let originZ: Int
        let sizeX: Int
        let sizeY: Int
        let sizeZ: Int
        let solid: [UInt8]

        var yzStride: Int { sizeX * sizeZ }

        @inline(__always)
        func localIndex(x: Int, y: Int, z: Int) -> Int {
            ((y * sizeZ) + z) * sizeX + x
        }

        @inline(__always)
        func index(worldX: Int, worldY: Int, worldZ: Int) -> Int? {
            let lx = worldX - originX
            let ly = worldY - originY
            let lz = worldZ - originZ
            guard lx >= 0, lx < sizeX, ly >= 0, ly < sizeY, lz >= 0, lz < sizeZ else {
                return nil
            }
            return localIndex(x: lx, y: ly, z: lz)
        }
    }

    private struct BuildResult {
        let revision: Int
        let vertices: [VulkanEngine.Vertex3D]
        let profile: RebuildProfile
        let volumeDescription: String
        let availableChunks: Int
        let totalTargetChunks: Int
    }

    private final class Streamer: @unchecked Sendable {
        private let worldGenerator: WorldGenerator
        private let renderRadius: Int
        private let generationWorkerCount: Int
        private let retargetAroundCameraMovement: Bool
        private let stoneColor: SIMD4<Float>
        private let orderedOffsets: [ChunkCoord]

        private let lock = NSLock()
        private let generationQueue = DispatchQueue(label: "TerrainRenderer.Generation", qos: .userInitiated, attributes: .concurrent)
        private let rebuildQueue = DispatchQueue(label: "TerrainRenderer.Mesh", qos: .userInitiated)

        private var targetCenter: ChunkCoord?
        private var targetCameraBlock = SIMD3<Int>(Int.min, Int.min, Int.min)
        private var chunks: [ChunkCoord: ProtoChunk] = [:]
        private var inFlightChunks: Set<ChunkCoord> = []
        private var activeGenerationWorkers = 0

        private var rebuildRequested = false
        private var rebuildRunning = false
        private var pendingResult: BuildResult?
        private var revision = 0

        private var generatedChunksSinceLastBuild = 0
        private var generationSecondsSinceLastBuild: Double = 0

        init(
            worldGenerator: WorldGenerator,
            renderRadius: Int,
            generationWorkerCount: Int,
            retargetAroundCameraMovement: Bool,
            stoneColor: SIMD4<Float>
        ) {
            self.worldGenerator = worldGenerator
            self.renderRadius = max(0, renderRadius)
            self.generationWorkerCount = max(1, generationWorkerCount)
            self.retargetAroundCameraMovement = retargetAroundCameraMovement
            self.stoneColor = stoneColor
            self.orderedOffsets = Self.makeOrderedOffsets(radius: self.renderRadius)
        }

        func updateTarget(center: ChunkCoord, cameraBlock: SIMD3<Int>) {
            var workersToStart = 0
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
                pruneChunksLocked(around: effectiveCenter)
            }
            if centerChanged || blockChanged {
                revision += 1
                requestRebuildLocked()
            }
            workersToStart = startGenerationWorkersLocked()
            lock.unlock()

            for _ in 0..<workersToStart {
                generationQueue.async { [self] in
                    generationWorkerLoop()
                }
            }
        }

        func takeCompletedResult() -> BuildResult? {
            lock.lock()
            defer { lock.unlock() }
            let result = pendingResult
            pendingResult = nil
            return result
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

                var workersToStart = 0
                lock.lock()
                inFlightChunks.remove(chunkCoord)
                if generationSucceeded, let center = targetCenter, shouldKeepChunk(chunkCoord, around: center) {
                    chunks[chunkCoord] = protoChunk
                    generatedChunksSinceLastBuild += 1
                    generationSecondsSinceLastBuild += generationSeconds
                    revision += 1
                    requestRebuildLocked()
                }
                pruneChunksLockedIfNeeded()
                workersToStart = startGenerationWorkersLocked()
                lock.unlock()

                for _ in 0..<workersToStart {
                    generationQueue.async { [self] in
                        generationWorkerLoop()
                    }
                }
            }
        }

        private func requestRebuildLocked() {
            rebuildRequested = true
            guard !rebuildRunning else {
                return
            }
            rebuildRunning = true
            rebuildQueue.async { [self] in
                rebuildLoop()
            }
        }

        private func rebuildLoop() {
            while true {
                let snapshot: ChunkSnapshot?
                lock.lock()
                if !rebuildRequested {
                    rebuildRunning = false
                    lock.unlock()
                    return
                }
                rebuildRequested = false
                snapshot = makeSnapshotLocked()
                lock.unlock()

                guard let snapshot else {
                    continue
                }
                let result = build(snapshot: snapshot)

                lock.lock()
                if pendingResult == nil || result.revision >= pendingResult!.revision {
                    pendingResult = result
                }
                lock.unlock()
            }
        }

        private func makeSnapshotLocked() -> ChunkSnapshot? {
            guard let center = targetCenter else {
                return nil
            }

            pruneChunksLocked(around: center)
            let relevantChunks = chunks.filter { shouldKeepChunk($0.key, around: center) }
            let snapshot = ChunkSnapshot(
                revision: revision,
                center: center,
                cameraBlock: targetCameraBlock,
                chunks: relevantChunks,
                generatedChunks: generatedChunksSinceLastBuild,
                generationSeconds: generationSecondsSinceLastBuild,
                totalTargetChunks: orderedOffsets.count
            )
            generatedChunksSinceLastBuild = 0
            generationSecondsSinceLastBuild = 0
            return snapshot
        }

        private func build(snapshot: ChunkSnapshot) -> BuildResult {
            var profile = RebuildProfile(
                generatedChunks: snapshot.generatedChunks,
                generationSeconds: snapshot.generationSeconds,
                volumeSeconds: 0,
                meshSeconds: 0,
                uploadSeconds: 0
            )

            let volumeStart = CFAbsoluteTimeGetCurrent()
            let volume = rebuildVolume(center: snapshot.center, chunks: snapshot.chunks)
            let hiddenComponent = updateHiddenConnectedComponent(volume: volume, cameraBlock: snapshot.cameraBlock)
            profile.volumeSeconds = CFAbsoluteTimeGetCurrent() - volumeStart

            let meshStart = CFAbsoluteTimeGetCurrent()
            let vertices = buildGreedyMesh(volume: volume, hiddenConnectedComponent: hiddenComponent)
            profile.meshSeconds = CFAbsoluteTimeGetCurrent() - meshStart

            let volumeDescription: String
            if let volume {
                volumeDescription = "\(volume.sizeX)x\(volume.sizeY)x\(volume.sizeZ)"
            } else {
                volumeDescription = "none"
            }

            return BuildResult(
                revision: snapshot.revision,
                vertices: vertices,
                profile: profile,
                volumeDescription: volumeDescription,
                availableChunks: snapshot.chunks.count,
                totalTargetChunks: snapshot.totalTargetChunks
            )
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

        private func pruneChunksLockedIfNeeded() {
            guard let center = targetCenter else {
                chunks.removeAll(keepingCapacity: true)
                return
            }
            pruneChunksLocked(around: center)
        }

        private func pruneChunksLocked(around center: ChunkCoord) {
            chunks = chunks.filter { shouldKeepChunk($0.key, around: center, extraMargin: 1) }
        }

        private func shouldKeepChunk(_ coord: ChunkCoord, around center: ChunkCoord, extraMargin: Int = 0) -> Bool {
            abs(coord.x - center.x) <= renderRadius + extraMargin && abs(coord.z - center.z) <= renderRadius + extraMargin
        }

        private func rebuildVolume(center: ChunkCoord, chunks: [ChunkCoord: ProtoChunk]) -> Volume? {
            let chunkSpan = renderRadius * 2 + 1
            let sizeX = chunkSpan * 16
            let sizeZ = chunkSpan * 16

            guard let sampleChunk = chunks[ChunkCoord(x: center.x, z: center.z)] ?? chunks.values.first else {
                return nil
            }

            var firstSolidSection = Int.max
            var lastSolidSection = Int.min

            for chunk in chunks.values {
                for sectionIndex in 0..<chunk.sectionCount {
                    guard let section = chunk.section(at: sectionIndex) else {
                        continue
                    }
                    if section.bitmap.contains(where: { $0 != 0 }) {
                        firstSolidSection = min(firstSolidSection, sectionIndex)
                        lastSolidSection = max(lastSolidSection, sectionIndex)
                    }
                }
            }

            guard firstSolidSection != Int.max, lastSolidSection != Int.min else {
                return Volume(
                    originX: (center.x - renderRadius) * 16,
                    originY: Int(sampleChunk.minY),
                    originZ: (center.z - renderRadius) * 16,
                    sizeX: sizeX,
                    sizeY: 0,
                    sizeZ: sizeZ,
                    solid: []
                )
            }

            let minY = Int(sampleChunk.minY) + firstSolidSection * ProtoChunk.sectionHeight
            let sizeY = (lastSolidSection - firstSolidSection + 1) * ProtoChunk.sectionHeight
            var solid = [UInt8](repeating: 0, count: sizeX * sizeY * sizeZ)
            let minChunkX = center.x - renderRadius
            let minChunkZ = center.z - renderRadius

            for (coord, chunk) in chunks {
                let localChunkX = coord.x - minChunkX
                let localChunkZ = coord.z - minChunkZ
                guard localChunkX >= 0, localChunkX < chunkSpan, localChunkZ >= 0, localChunkZ < chunkSpan else {
                    continue
                }

                let baseX = localChunkX * 16
                let baseZ = localChunkZ * 16
                let startSection = max(0, firstSolidSection)
                let endSection = min(chunk.sectionCount - 1, lastSolidSection)
                if startSection > endSection {
                    continue
                }

                for sectionIndex in startSection...endSection {
                    guard let section = chunk.section(at: sectionIndex) else {
                        continue
                    }
                    let bitmap = section.bitmap
                    if bitmap.allSatisfy({ $0 == 0 }) {
                        continue
                    }

                    let baseY = (sectionIndex - firstSolidSection) * ProtoChunk.sectionHeight
                    for (wordIndex, wordValue) in bitmap.enumerated() where wordValue != 0 {
                        var word = wordValue
                        while word != 0 {
                            let bitIndex = word.trailingZeroBitCount
                            let blockIndex = wordIndex * 64 + bitIndex
                            let x = blockIndex & 15
                            let z = (blockIndex >> 4) & 15
                            let y = (blockIndex >> 8) & 15
                            let gx = baseX + x
                            let gy = baseY + y
                            let gz = baseZ + z
                            let index = ((gy * sizeZ) + gz) * sizeX + gx
                            solid[index] = 1
                            word &= word - 1
                        }
                    }
                }
            }

            return Volume(
                originX: minChunkX * 16,
                originY: minY,
                originZ: minChunkZ * 16,
                sizeX: sizeX,
                sizeY: sizeY,
                sizeZ: sizeZ,
                solid: solid
            )
        }

        private func updateHiddenConnectedComponent(volume: Volume?, cameraBlock: SIMD3<Int>) -> [UInt8]? {
            guard let volume,
                  let startIndex = volume.index(worldX: cameraBlock.x, worldY: cameraBlock.y, worldZ: cameraBlock.z),
                  startIndex < volume.solid.count,
                  volume.solid[startIndex] != 0 else {
                return nil
            }

            var visited = [UInt8](repeating: 0, count: volume.solid.count)
            var queue: [Int] = [startIndex]
            visited[startIndex] = 1

            var head = 0
            let sizeX = volume.sizeX
            let sizeY = volume.sizeY
            let sizeZ = volume.sizeZ
            let yzStride = volume.yzStride

            while head < queue.count {
                let idx = queue[head]
                head += 1

                let x = idx % sizeX
                let yz = idx / sizeX
                let z = yz % sizeZ
                let y = yz / sizeZ

                if x > 0 {
                    let n = idx - 1
                    if visited[n] == 0 && volume.solid[n] != 0 {
                        visited[n] = 1
                        queue.append(n)
                    }
                }
                if x + 1 < sizeX {
                    let n = idx + 1
                    if visited[n] == 0 && volume.solid[n] != 0 {
                        visited[n] = 1
                        queue.append(n)
                    }
                }
                if z > 0 {
                    let n = idx - sizeX
                    if visited[n] == 0 && volume.solid[n] != 0 {
                        visited[n] = 1
                        queue.append(n)
                    }
                }
                if z + 1 < sizeZ {
                    let n = idx + sizeX
                    if visited[n] == 0 && volume.solid[n] != 0 {
                        visited[n] = 1
                        queue.append(n)
                    }
                }
                if y > 0 {
                    let n = idx - yzStride
                    if visited[n] == 0 && volume.solid[n] != 0 {
                        visited[n] = 1
                        queue.append(n)
                    }
                }
                if y + 1 < sizeY {
                    let n = idx + yzStride
                    if visited[n] == 0 && volume.solid[n] != 0 {
                        visited[n] = 1
                        queue.append(n)
                    }
                }
            }

            return visited
        }

        private func buildGreedyMesh(volume: Volume?, hiddenConnectedComponent: [UInt8]?) -> [VulkanEngine.Vertex3D] {
            guard let volume else {
                return []
            }

            let dims = [volume.sizeX, volume.sizeY, volume.sizeZ]
            if dims.contains(where: { $0 <= 0 }) {
                return []
            }

            var vertices: [VulkanEngine.Vertex3D] = []
            vertices.reserveCapacity(600_000)

            @inline(__always)
            func isSolidLocal(_ x: Int, _ y: Int, _ z: Int) -> Bool {
                if x < 0 || x >= dims[0] || y < 0 || y >= dims[1] || z < 0 || z >= dims[2] {
                    return false
                }
                let idx = volume.localIndex(x: x, y: y, z: z)
                if volume.solid[idx] == 0 {
                    return false
                }
                if let hiddenConnectedComponent, hiddenConnectedComponent[idx] != 0 {
                    return false
                }
                return true
            }

            for d in 0..<3 {
                let u = (d + 1) % 3
                let v = (d + 2) % 3
                let maskSize = dims[u] * dims[v]
                var mask = [Int8](repeating: 0, count: maskSize)

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

                            let aSolid = x[d] >= 0 ? isSolidLocal(x[0], x[1], x[2]) : false
                            let bSolid = x[d] < dims[d] - 1 ? isSolidLocal(x[0] + q[0], x[1] + q[1], x[2] + q[2]) : false

                            if aSolid == bSolid {
                                mask[n] = 0
                            } else if aSolid {
                                mask[n] = 1
                            } else {
                                mask[n] = -1
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
                            while i + width < dims[u], mask[n + width] == c {
                                width += 1
                            }

                            var height = 1
                            var done = false
                            while j + height < dims[v], !done {
                                for k in 0..<width {
                                    if mask[n + k + height * dims[u]] != c {
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
                                Float(volume.originX + p[0]),
                                Float(volume.originY + p[1]),
                                Float(volume.originZ + p[2])
                            )
                            let p1 = SIMD3<Float>(
                                Float(volume.originX + p[0] + du[0]),
                                Float(volume.originY + p[1] + du[1]),
                                Float(volume.originZ + p[2] + du[2])
                            )
                            let p2 = SIMD3<Float>(
                                Float(volume.originX + p[0] + du[0] + dv[0]),
                                Float(volume.originY + p[1] + du[1] + dv[1]),
                                Float(volume.originZ + p[2] + du[2] + dv[2])
                            )
                            let p3 = SIMD3<Float>(
                                Float(volume.originX + p[0] + dv[0]),
                                Float(volume.originY + p[1] + dv[1]),
                                Float(volume.originZ + p[2] + dv[2])
                            )

                            if c > 0 {
                                appendQuad(&vertices, a: p0, b: p1, c: p2, d: p3)
                            } else {
                                appendQuad(&vertices, a: p0, b: p3, c: p2, d: p1)
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
            d: SIMD3<Float>
        ) {
            vertices.append(.init(position: a, color: stoneColor))
            vertices.append(.init(position: b, color: stoneColor))
            vertices.append(.init(position: c, color: stoneColor))
            vertices.append(.init(position: a, color: stoneColor))
            vertices.append(.init(position: c, color: stoneColor))
            vertices.append(.init(position: d, color: stoneColor))
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
    private let mouseSensitivity: Float
    private let profilingEnabled = ProcessInfo.processInfo.environment["MINESCENE_PROFILE"] == "1"
    private let streamer: Streamer
    private let hudShadowColor = SIMD4<Float>(0.08, 0.10, 0.16, 1.0)
    private let hudXColor = SIMD4<Float>(0.85, 0.22, 0.22, 1.0)
    private let hudYColor = SIMD4<Float>(0.22, 0.72, 0.28, 1.0)
    private let hudZColor = SIMD4<Float>(0.12, 0.20, 0.46, 1.0)
    private let hudFpsColor = SIMD4<Float>(0.62, 0.28, 0.78, 1.0)

    private var meshBuffer: VulkanOwnedBuffer?
    private var meshMemory: VulkanOwnedDeviceMemory?
    private var meshVertexCount: UInt32 = 0
    private var lastAppliedRevision = 0
    private var hudBuffer: VulkanOwnedBuffer?
    private var hudMemory: VulkanOwnedDeviceMemory?
    private var hudVertexCount: UInt32 = 0
    private var hudVertexCapacity = 0
    private var lastHudText = ""
    private var lastHudViewport = SIMD2<Int>(repeating: -1)

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

    init(
        worldGenerator: WorldGenerator,
        renderRadius: Int = 12,
        moveSpeed: Float = 32.0,
        mouseSensitivity: Float = 0.0025,
        generationWorkerCount: Int = max(1, ProcessInfo.processInfo.activeProcessorCount - 1)
    ) {
        self.moveSpeed = moveSpeed
        self.mouseSensitivity = mouseSensitivity
        self.streamer = Streamer(
            worldGenerator: worldGenerator,
            renderRadius: renderRadius,
            generationWorkerCount: generationWorkerCount,
            retargetAroundCameraMovement: false,
            stoneColor: SIMD4<Float>(0.34, 0.34, 0.36, 1.0)
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
            cameraPosition += movement * moveSpeed * max(0, deltaTime)
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

        let batches: [VulkanEngine.DrawBatch3D]
        if let meshBuffer, meshVertexCount > 0 {
            batches = [.init(buffer: meshBuffer, vertexCount: meshVertexCount)]
        } else {
            batches = []
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
        guard let result = streamer.takeCompletedResult(), result.revision > lastAppliedRevision else {
            return
        }

        meshBuffer = nil
        meshMemory = nil
        meshVertexCount = 0

        let uploadStart = CFAbsoluteTimeGetCurrent()
        if !result.vertices.isEmpty {
            let (buffer, memory) = try engine.createVertexBuffer3D(result.vertices)
            meshBuffer = buffer
            meshMemory = memory
            meshVertexCount = UInt32(result.vertices.count)
        }

        var profile = result.profile
        profile.uploadSeconds = CFAbsoluteTimeGetCurrent() - uploadStart
        lastAppliedRevision = result.revision
        logRebuild(
            profile: profile,
            volumeDescription: result.volumeDescription,
            vertexCount: result.vertices.count,
            availableChunks: result.availableChunks,
            totalTargetChunks: result.totalTargetChunks
        )
    }

    private func logRebuild(
        profile: RebuildProfile,
        volumeDescription: String,
        vertexCount: Int,
        availableChunks: Int,
        totalTargetChunks: Int
    ) {
        guard profilingEnabled else {
            return
        }
        let totalMs = (profile.generationSeconds + profile.volumeSeconds + profile.meshSeconds + profile.uploadSeconds) * 1000
        print(
            String(
                format: "Terrain rebuild: generated=%d available=%d/%d gen=%.1fms volume=%.1fms mesh=%.1fms upload=%.1fms total=%.1fms volume=%@ vertices=%d",
                profile.generatedChunks,
                availableChunks,
                totalTargetChunks,
                profile.generationSeconds * 1000,
                profile.volumeSeconds * 1000,
                profile.meshSeconds * 1000,
                profile.uploadSeconds * 1000,
                totalMs,
                volumeDescription,
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
        let positionRuns = [
            HudTextRun(text: String(format: "X: %.1f ", Double(cameraPosition.x)), color: hudXColor),
            HudTextRun(text: String(format: "Y: %.1f ", Double(cameraPosition.y)), color: hudYColor),
            HudTextRun(text: String(format: "Z: %.1f", Double(cameraPosition.z)), color: hudZColor)
        ]
        let fpsRuns = [
            HudTextRun(text: String(format: "FPS: %.0f", Double(smoothedFps)), color: hudFpsColor)
        ]
        let hudText = (positionRuns + fpsRuns).map(\.text).joined(separator: "\n")
        let viewport = SIMD2<Int>(viewportWidth, viewportHeight)
        guard hudText != lastHudText || viewport != lastHudViewport else {
            return
        }

        let vertices = makeHudVertices(lines: [positionRuns, fpsRuns])
        if vertices.isEmpty {
            hudVertexCount = 0
            lastHudText = hudText
            lastHudViewport = viewport
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
    }

    private struct HudTextRun {
        let text: String
        let color: SIMD4<Float>
    }

    private func makeHudVertices(lines: [[HudTextRun]]) -> [VulkanEngine.Vertex2D] {
        let cellSize: Float = 5
        let glyphAdvance: Float = 20
        let lineAdvance: Float = 34
        let shadowOffset = SIMD2<Float>(1, 1)
        let origin = SIMD2<Float>(12, 12)

        var vertices: [VulkanEngine.Vertex2D] = []
        let characterCount = lines.flatMap { $0 }.reduce(0) { $0 + $1.text.count }
        vertices.reserveCapacity(characterCount * 180)

        for (lineIndex, lineRuns) in lines.enumerated() {
            var cursorX = origin.x
            let lineY = origin.y + Float(lineIndex) * lineAdvance
            for run in lineRuns {
                for character in run.text {
                    let glyph = Self.hudGlyphs[character] ?? Self.hudGlyphs[" "]!
                    appendGlyph(
                        glyph,
                        origin: SIMD2<Float>(cursorX + shadowOffset.x, lineY + shadowOffset.y),
                        cellSize: cellSize,
                        color: hudShadowColor,
                        into: &vertices
                    )
                    appendGlyph(
                        glyph,
                        origin: SIMD2<Float>(cursorX, lineY),
                        cellSize: cellSize,
                        color: run.color,
                        into: &vertices
                    )
                    cursorX += glyphAdvance
                }
            }
        }

        return vertices
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
        "X": ["101", "101", "010", "101", "101"],
        "Y": ["101", "101", "010", "010", "010"],
        "Z": ["111", "001", "010", "100", "111"],
        "F": ["111", "100", "110", "100", "100"],
        "P": ["110", "101", "110", "100", "100"],
        "S": ["111", "100", "111", "001", "111"],
        ":": ["000", "010", "000", "010", "000"],
        ".": ["000", "000", "000", "000", "010"],
        "-": ["000", "000", "111", "000", "000"],
        " ": ["000", "000", "000", "000", "000"]
    ]
}

enum TerrainRendererError: Error {
    case invalidSwapchainImageIndex
}
