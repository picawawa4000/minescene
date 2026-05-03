#if canImport(simd)
import simd
#else
import Foundation

struct simd_float4x4 {
    var c0: SIMD4<Float>
    var c1: SIMD4<Float>
    var c2: SIMD4<Float>
    var c3: SIMD4<Float>

    init(_ c0: SIMD4<Float>, _ c1: SIMD4<Float>, _ c2: SIMD4<Float>, _ c3: SIMD4<Float>) {
        self.c0 = c0
        self.c1 = c1
        self.c2 = c2
        self.c3 = c3
    }
}

let matrix_identity_float4x4 = simd_float4x4(
    SIMD4<Float>(1, 0, 0, 0),
    SIMD4<Float>(0, 1, 0, 0),
    SIMD4<Float>(0, 0, 1, 0),
    SIMD4<Float>(0, 0, 0, 1)
)

func simd_length_squared(_ vector: SIMD3<Float>) -> Float {
    simd_dot(vector, vector)
}

func simd_length(_ vector: SIMD3<Float>) -> Float {
    sqrt(simd_length_squared(vector))
}

func simd_normalize(_ vector: SIMD3<Float>) -> SIMD3<Float> {
    let length = simd_length(vector)
    guard length > 0 else {
        return .zero
    }
    return vector / length
}

func simd_cross(_ lhs: SIMD3<Float>, _ rhs: SIMD3<Float>) -> SIMD3<Float> {
    SIMD3<Float>(
        lhs.y * rhs.z - lhs.z * rhs.y,
        lhs.z * rhs.x - lhs.x * rhs.z,
        lhs.x * rhs.y - lhs.y * rhs.x
    )
}

func simd_dot(_ lhs: SIMD3<Float>, _ rhs: SIMD3<Float>) -> Float {
    lhs.x * rhs.x + lhs.y * rhs.y + lhs.z * rhs.z
}
#endif
