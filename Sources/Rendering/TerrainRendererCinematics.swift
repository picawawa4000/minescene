import Foundation
#if canImport(simd)
import simd
#endif

enum TerrainRendererKeyframeError: Error, CustomStringConvertible {
    case invalidID(Int)
    case notEnoughKeyframes

    var description: String {
        switch self {
        case .invalidID(let id):
            return "keyframe ID \(id) does not exist"
        case .notEnoughKeyframes:
            return "at least two keyframes are required to play an animation"
        }
    }
}

extension TerrainRenderer {
    var isCinematicActive: Bool {
        cinematicPlaybackSession != nil
    }

    var isCinematicPlaying: Bool {
        if case .playing = cinematicPlaybackSession?.phase {
            return true
        }
        return false
    }

    var currentCinematicPreparationStatus: CinematicPreparationStatus? {
        guard let session = cinematicPlaybackSession,
              case .preparing = session.phase else {
            return nil
        }
        return streamer.pinnedChunkPreparationStatus()
    }

    @discardableResult
    func appendCurrentCameraKeyframe() -> Int {
        let nextID = keyframes.count
        keyframes.append(
            Keyframe(
                position: cameraPosition,
                yaw: cameraYaw,
                pitch: cameraPitch
            )
        )
        return nextID
    }

    func removeKeyframe(id: Int) throws -> Keyframe {
        guard id >= 0, id < keyframes.count else {
            throw TerrainRendererKeyframeError.invalidID(id)
        }
        return keyframes.remove(at: id)
    }

    func currentCinematicPath() -> CinematicPath? {
        if let cachedCinematicPath {
            return cachedCinematicPath
        }
        guard keyframes.count >= 2 else {
            return nil
        }
        let path = buildCinematicPath(from: keyframes)
        cachedCinematicPath = path
        return path
    }

    func formatKeyframeDescription(id: Int, keyframe: Keyframe) -> String {
        "ID \(id): pos=\(formatCommandPosition(keyframe.position)) rot=(yaw: \(formatCommandAngle(keyframe.yaw)) deg, pitch: \(formatCommandAngle(keyframe.pitch)) deg)"
    }

    func startKeyframePlayback() throws {
        let preparation = try currentCinematicPreparationPlan()
        resetMovementKeys()
        cameraPosition = preparation.initialKeyframe.position
        cameraYaw = preparation.initialKeyframe.yaw
        cameraPitch = preparation.initialKeyframe.pitch
        commandPromptActive = false
        cinematicPlaybackSession = CinematicPlaybackSession(
            path: preparation.path,
            pinnedChunks: preparation.pinnedChunks,
            phase: .preparing
        )
        streamer.setPinnedChunks(preparation.pinnedChunks)
        logCommandMessage(
            "Preparing keyframe animation with \(keyframes.count) keyframes across \(preparation.pinnedChunks.count) chunks at \(formatPlaybackSpeed(keyframePlaybackSpeed))."
        )
    }

    func currentCinematicPreparationPlan() throws -> (
        path: CinematicPath,
        pinnedChunks: Set<ChunkCoord>,
        initialKeyframe: Keyframe
    ) {
        guard keyframes.count >= 2 else {
            throw TerrainRendererKeyframeError.notEnoughKeyframes
        }
        guard let path = currentCinematicPath() else {
            throw TerrainRendererKeyframeError.notEnoughKeyframes
        }
        return (
            path: path,
            pinnedChunks: requiredPinnedChunks(for: path),
            initialKeyframe: keyframes[0]
        )
    }

    func updateCinematicPlaybackIfNeeded() {
        guard var session = cinematicPlaybackSession else {
            return
        }

        switch session.phase {
        case .preparing:
            if streamer.pinnedChunksReady() {
                session.phase = .playing(startTimeSeconds: TerrainRenderer.currentTimeSeconds())
                cinematicPlaybackSession = session
                logCommandMessage("Starting keyframe animation.")
            }
        case .playing(let startTimeSeconds):
            let elapsed = max(0, TerrainRenderer.currentTimeSeconds() - startTimeSeconds)
            if elapsed >= session.path.totalDuration {
                if let finalSample = session.path.samples.last {
                    applyPlaybackSample(finalSample)
                }
                finishCinematicPlayback()
            } else {
                applyPlaybackSample(samplePlaybackPath(session.path, at: elapsed))
            }
        }
    }

    func updateKeyframeOverlayIfNeeded(engine: VulkanEngine) throws {
        guard showsKeyframes, !isCinematicPlaying else {
            keyframeOverlayVertexCount = 0
            return
        }

        var vertices: [VulkanEngine.Vertex3D] = []
        vertices.reserveCapacity(max(0, keyframes.count * 6 + max(0, (currentCinematicPath()?.samples.count ?? 0) - 1) * 6))

        if let path = currentCinematicPath() {
            appendCinematicPathVertices(path, into: &vertices)
        }
        for keyframe in keyframes {
            appendKeyframeBillboardVertices(for: keyframe, into: &vertices)
        }

        guard !vertices.isEmpty else {
            keyframeOverlayVertexCount = 0
            return
        }

        if keyframeOverlayBuffer == nil || keyframeOverlayMemory == nil || vertices.count > keyframeOverlayVertexCapacity {
            keyframeOverlayBuffer = nil
            keyframeOverlayMemory = nil
            keyframeOverlayVertexCapacity = max(vertices.count, max(256, keyframeOverlayVertexCapacity * 2))
            let (buffer, memory) = try engine.createVertexBuffer3DCapacity(keyframeOverlayVertexCapacity)
            keyframeOverlayBuffer = buffer
            keyframeOverlayMemory = memory
        }

        guard let keyframeOverlayBuffer, let keyframeOverlayMemory else {
            return
        }

        keyframeOverlayVertexCount = try engine.updateVertexBuffer3D(
            vertices,
            buffer: keyframeOverlayBuffer,
            memory: keyframeOverlayMemory,
            capacity: keyframeOverlayVertexCapacity
        )
    }

    func formatCommandPosition(_ position: SIMD3<Double>) -> String {
        "(\(formatCommandNumber(position.x)), \(formatCommandNumber(position.y)), \(formatCommandNumber(position.z)))"
    }

    func formatCommandAngle(_ angleRadians: Float) -> String {
        formatCommandNumber(Double(angleRadians * 180 / .pi))
    }

    func formatPlaybackSpeed(_ speed: Double) -> String {
        "\(formatCommandNumber(speed)) blocks/s"
    }

    func setKeyframePlaybackSpeed(_ speed: Double) {
        keyframePlaybackSpeed = max(0.001, speed)
        cachedCinematicPath = nil
    }

    private func finishCinematicPlayback() {
        cinematicPlaybackSession = nil
        streamer.setPinnedChunks([])
        logCommandMessage("Finished keyframe animation.")
    }

    private func applyPlaybackSample(_ sample: CinematicPathSample) {
        cameraPosition = sample.position
        cameraYaw = sample.yaw
        cameraPitch = sample.pitch
    }

    func samplePlaybackPath(_ path: CinematicPath, at time: Double) -> CinematicPathSample {
        guard path.samples.count > 1 else {
            return path.samples[0]
        }
        if time <= 0 {
            return path.samples[0]
        }
        if time >= path.totalDuration {
            return path.samples[path.samples.count - 1]
        }

        var lowerIndex = 0
        var upperIndex = path.samples.count - 1
        while lowerIndex + 1 < upperIndex {
            let middleIndex = (lowerIndex + upperIndex) / 2
            if path.samples[middleIndex].timeFromStart <= time {
                lowerIndex = middleIndex
            } else {
                upperIndex = middleIndex
            }
        }

        let lowerSample = path.samples[lowerIndex]
        let upperSample = path.samples[upperIndex]
        let intervalDuration = max(1e-6, upperSample.timeFromStart - lowerSample.timeFromStart)
        let t = Float((time - lowerSample.timeFromStart) / intervalDuration)
        return CinematicPathSample(
            position: interpolatePosition(lowerSample.position, upperSample.position, t: Double(t)),
            yaw: interpolateAngle(lowerSample.yaw, upperSample.yaw, t: t),
            pitch: lowerSample.pitch + (upperSample.pitch - lowerSample.pitch) * t,
            timeFromStart: time
        )
    }

    private func buildCinematicPath(from keyframes: [Keyframe]) -> CinematicPath {
        let tangents = keyframeTangents(for: keyframes)
        var samples: [CinematicPathSample] = []
        var totalDistance = 0.0

        for segmentIndex in 0..<(keyframes.count - 1) {
            let startKeyframe = keyframes[segmentIndex]
            let endKeyframe = keyframes[segmentIndex + 1]
            let chordLength = simd_length(endKeyframe.position - startKeyframe.position)
            let nominalSegmentDuration = max(chordLength / keyframePlaybackSpeed, minimumCinematicSegmentDuration)
            let sampleCount = max(24, Int(ceil(max(chordLength / 1.5, nominalSegmentDuration * 60.0))))
            let firstStep = segmentIndex == 0 ? 0 : 1

            for step in firstStep...sampleCount {
                let t = Double(step) / Double(sampleCount)
                let position = hermitePosition(
                    from: startKeyframe.position,
                    to: endKeyframe.position,
                    startTangent: tangents[segmentIndex],
                    endTangent: tangents[segmentIndex + 1],
                    t: t
                )
                if let previousSample = samples.last {
                    totalDistance += simd_length(position - previousSample.position)
                }
                samples.append(
                    CinematicPathSample(
                        position: position,
                        yaw: interpolateAngle(startKeyframe.yaw, endKeyframe.yaw, t: Float(t)),
                        pitch: startKeyframe.pitch + (endKeyframe.pitch - startKeyframe.pitch) * Float(t),
                        timeFromStart: totalDistance / keyframePlaybackSpeed
                    )
                )
            }
        }

        return CinematicPath(
            samples: samples,
            totalDuration: totalDistance / keyframePlaybackSpeed
        )
    }

    private func keyframeTangents(for keyframes: [Keyframe]) -> [SIMD3<Double>] {
        guard keyframes.count >= 2 else {
            return []
        }

        return keyframes.indices.map { index in
            let previousPosition = keyframes[max(0, index - 1)].position
            let currentPosition = keyframes[index].position
            let nextPosition = keyframes[min(keyframes.count - 1, index + 1)].position

            if index == 0 {
                return nextPosition - currentPosition
            }
            if index == keyframes.count - 1 {
                return currentPosition - previousPosition
            }
            return (nextPosition - previousPosition) * 0.5
        }
    }

    private func hermitePosition(
        from start: SIMD3<Double>,
        to end: SIMD3<Double>,
        startTangent: SIMD3<Double>,
        endTangent: SIMD3<Double>,
        t: Double
    ) -> SIMD3<Double> {
        let t2 = t * t
        let t3 = t2 * t
        let h00 = 2 * t3 - 3 * t2 + 1
        let h10 = t3 - 2 * t2 + t
        let h01 = -2 * t3 + 3 * t2
        let h11 = t3 - t2
        return start * h00 + startTangent * h10 + end * h01 + endTangent * h11
    }

    private func requiredPinnedChunks(for path: CinematicPath) -> Set<ChunkCoord> {
        let preloadRadius = max(0, currentRenderRadius() + 1)
        var chunks: Set<ChunkCoord> = []

        for sample in path.samples {
            let sampleBlock = SIMD3<Int>(
                Int(floor(sample.position.x)),
                Int(floor(sample.position.y)),
                Int(floor(sample.position.z))
            )
            let centerChunk = ChunkCoord(
                x: floorDiv(sampleBlock.x, 16),
                z: floorDiv(sampleBlock.z, 16)
            )
            for deltaZ in -preloadRadius...preloadRadius {
                for deltaX in -preloadRadius...preloadRadius {
                    chunks.insert(ChunkCoord(x: centerChunk.x + deltaX, z: centerChunk.z + deltaZ))
                }
            }
        }

        return chunks
    }

    private func appendCinematicPathVertices(_ path: CinematicPath, into vertices: inout [VulkanEngine.Vertex3D]) {
        guard path.samples.count >= 2 else {
            return
        }

        for index in 0..<(path.samples.count - 1) {
            let start = overlayPosition(SIMD3<Float>(path.samples[index].position))
            let end = overlayPosition(SIMD3<Float>(path.samples[index + 1].position))
            let direction = end - start
            let lengthSquared = simd_length_squared(direction)
            guard lengthSquared > 1e-6 else {
                continue
            }

            let normalizedDirection = direction / sqrt(lengthSquared)
            var firstPerpendicular = simd_cross(normalizedDirection, SIMD3<Float>(0, 1, 0))
            if simd_length_squared(firstPerpendicular) <= 1e-6 {
                firstPerpendicular = simd_cross(normalizedDirection, SIMD3<Float>(1, 0, 0))
            }
            firstPerpendicular = normalizeOrZero(firstPerpendicular) * keyframePathHalfWidth

            var secondPerpendicular = simd_cross(normalizedDirection, firstPerpendicular)
            if simd_length_squared(secondPerpendicular) <= 1e-6 {
                secondPerpendicular = simd_cross(normalizedDirection, SIMD3<Float>(0, 0, 1))
            }
            secondPerpendicular = normalizeOrZero(secondPerpendicular) * keyframePathHalfWidth

            appendOverlayQuad(
                &vertices,
                a: start + firstPerpendicular,
                b: start - firstPerpendicular,
                c: end - firstPerpendicular,
                d: end + firstPerpendicular,
                color: keyframePathColor
            )
            appendOverlayQuad(
                &vertices,
                a: start + secondPerpendicular,
                b: start - secondPerpendicular,
                c: end - secondPerpendicular,
                d: end + secondPerpendicular,
                color: keyframePathColor
            )
        }
    }

    private func appendKeyframeBillboardVertices(for keyframe: Keyframe, into vertices: inout [VulkanEngine.Vertex3D]) {
        let center = overlayPosition(SIMD3<Float>(keyframe.position))
        let camera = SIMD3<Float>(
            Float(cameraPosition.x),
            Float(cameraPosition.y),
            Float(cameraPosition.z)
        )
        var toCamera = normalizeOrZero(camera - center)
        if simd_length_squared(toCamera) <= 1e-6 {
            toCamera = -viewForward()
        }

        var right = simd_cross(SIMD3<Float>(0, 1, 0), toCamera)
        if simd_length_squared(right) <= 1e-6 {
            right = simd_cross(SIMD3<Float>(1, 0, 0), toCamera)
        }
        right = normalizeOrZero(right) * keyframeMarkerHalfSize

        var up = simd_cross(toCamera, right)
        if simd_length_squared(up) <= 1e-6 {
            up = SIMD3<Float>(0, keyframeMarkerHalfSize, 0)
        } else {
            up = normalizeOrZero(up) * keyframeMarkerHalfSize
        }

        let bottomLeft = center - right - up
        let bottomRight = center + right - up
        let topRight = center + right + up
        let topLeft = center - right + up

        appendOverlayQuad(
            &vertices,
            a: bottomLeft,
            b: bottomRight,
            c: topRight,
            d: topLeft,
            color: keyframeMarkerColor
        )
    }

    private func interpolatePosition(
        _ lhs: SIMD3<Double>,
        _ rhs: SIMD3<Double>,
        t: Double
    ) -> SIMD3<Double> {
        lhs + (rhs - lhs) * t
    }

    private func interpolateAngle(_ lhs: Float, _ rhs: Float, t: Float) -> Float {
        let delta = wrappedAngle(rhs - lhs)
        return wrappedAngle(lhs + delta * t)
    }

    private func wrappedAngle(_ angle: Float) -> Float {
        var wrapped = angle
        while wrapped <= -.pi {
            wrapped += 2 * .pi
        }
        while wrapped > .pi {
            wrapped -= 2 * .pi
        }
        return wrapped
    }

    private func overlayPosition(_ position: SIMD3<Float>) -> SIMD3<Float> {
        let camera = SIMD3<Float>(
            Float(cameraPosition.x),
            Float(cameraPosition.y),
            Float(cameraPosition.z)
        )
        let toCamera = camera - position
        let distanceSquared = simd_length_squared(toCamera)
        guard distanceSquared > 1e-8 else {
            return position + viewForward() * keyframeOverlayDepthBias
        }
        let depthBias = max(keyframeOverlayDepthBias, sqrt(distanceSquared) * 0.0005)
        return position + normalizeOrZero(toCamera) * depthBias
    }

    private func appendOverlayQuad(
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
        vertices.append(.init(position: a, color: color))
        vertices.append(.init(position: c, color: color))
        vertices.append(.init(position: b, color: color))
        vertices.append(.init(position: a, color: color))
        vertices.append(.init(position: d, color: color))
        vertices.append(.init(position: c, color: color))
    }
}
