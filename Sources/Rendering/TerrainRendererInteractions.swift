import SwiftSDL
import simd

extension TerrainRenderer {
    var currentCameraPosition: SIMD3<Float> {
        cameraPosition
    }

    func handleEvent(_ event: SDL_Event, window: OpaquePointer?) {
        if commandPromptActive {
            handleCommandPromptEvent(event, window: window)
            return
        }

        switch event.eventType {
        case .keyDown:
            if event.key.repeat {
                return
            }
            if keyMatches(event.key.key, action: .openCommandPrompt) {
                openCommandPrompt(window: window)
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

    func setKeyState(key: SDL_Keycode, pressed: Bool) {
        if keyMatches(key, action: .moveForward) {
            keyW = pressed
        }
        if keyMatches(key, action: .moveLeft) {
            keyA = pressed
        }
        if keyMatches(key, action: .moveBackward) {
            keyS = pressed
        }
        if keyMatches(key, action: .moveRight) {
            keyD = pressed
        }
        if keyMatches(key, action: .moveUp) {
            keySpace = pressed
        }
        if keyMatches(key, action: .moveDown) {
            keyShift = pressed
        }
        if keyMatches(key, action: .fastMove) {
            keyR = pressed
        }
        if keyMatches(key, action: .zoom) {
            keyX = pressed
        }
        if pressed, keyMatches(key, action: .decreaseRenderDistance) {
            let renderRadius = streamer.adjustRenderRadius(by: -1)
            renderDistanceDidChange?(renderRadius)
        }
        if pressed, keyMatches(key, action: .increaseRenderDistance) {
            let renderRadius = streamer.adjustRenderRadius(by: 1)
            renderDistanceDidChange?(renderRadius)
        }
    }

    func resetMovementKeys() {
        keyW = false
        keyA = false
        keyS = false
        keyD = false
        keySpace = false
        keyShift = false
        keyR = false
        keyX = false
    }

    func update(deltaTime: Float) {
        if deltaTime > 0 {
            let instantaneousFps = min(240, 1 / deltaTime)
            if smoothedFps == 0 {
                smoothedFps = instantaneousFps
            } else {
                smoothedFps += (instantaneousFps - smoothedFps) * 0.12
            }
            if commandPromptActive {
                commandPromptCursorElapsed += deltaTime
            }
            if !commandLogEntries.isEmpty {
                for index in commandLogEntries.indices {
                    commandLogEntries[index].age += deltaTime
                }
                commandLogEntries.removeAll { $0.age >= commandLogHoldDuration + commandLogFadeDuration }
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

    func viewForward() -> SIMD3<Float> {
        let cp = cos(cameraPitch)
        return normalizeOrZero(SIMD3<Float>(
            x: cos(cameraYaw) * cp,
            y: sin(cameraPitch),
            z: sin(cameraYaw) * cp
        ))
    }

    func normalizeOrZero(_ v: SIMD3<Float>) -> SIMD3<Float> {
        let lenSq = simd_length_squared(v)
        if lenSq <= 1e-8 {
            return .zero
        }
        return v / sqrt(lenSq)
    }

    func floorDiv(_ value: Int, _ divisor: Int) -> Int {
        if value >= 0 {
            return value / divisor
        }
        return -(((-value) + divisor - 1) / divisor)
    }

    func keyMatches(_ key: SDL_Keycode, action: KeybindAction) -> Bool {
        key == (keycodeForAction?(action) ?? action.defaultValue.keycode)
    }

    func lookAtRH(eye: SIMD3<Float>, center: SIMD3<Float>, up: SIMD3<Float>) -> simd_float4x4 {
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

    func perspectiveRH(fovYRadians: Float, aspect: Float, nearZ: Float, farZ: Float) -> simd_float4x4 {
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
}
