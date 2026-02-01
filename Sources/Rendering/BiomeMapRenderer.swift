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
        stride: Int = 1,
        dimension: DPReader.RegistryKey<DPReader.Dimension> = DPReader.RegistryKey<DPReader.Dimension>(referencing: "minecraft:overworld"),
        sampleY: Int = 0
    ) throws -> BiomePixelMap {
        try render(
            worldGenerator: worldGenerator,
            topLeftX: topLeftX,
            topLeftZ: topLeftZ,
            width: width,
            height: height,
            biomeSampler: { generator, x, z in
                let pos = PosInt3D(
                    x: Int32(x),
                    y: Int32(sampleY),
                    z: Int32(z)
                )
                let biomeKey = try generator.sampleBiome(at: pos, in: dimension)
                return biomeKey?.name ?? "unknown"
            }
        )
    }

    static func render(
        worldGenerator: WorldGenerator,
        topLeftX: Int,
        topLeftZ: Int,
        width: Int,
        height: Int,
        stride: Int = 1,
        biomeSampler: (WorldGenerator, Int, Int) throws -> String
    ) throws -> BiomePixelMap {
        guard width > 0, height > 0 else {
            throw BiomeMapRendererError.invalidSize
        }
        guard stride > 0 else {
            throw BiomeMapRendererError.invalidSize
        }

        var pixels = [UInt8]()
        pixels.reserveCapacity(width * height * 4)

        for z in 0..<height {
            for x in 0..<width {
                let biomeId = try biomeSampler(
                    worldGenerator,
                    topLeftX + (x / stride) * stride,
                    topLeftZ + (z / stride) * stride
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

        let invW = 1.0 / Float(map.width)
        let invH = 1.0 / Float(map.height)
        let pixelWidth = 2.0 * invW
        let pixelHeight = 2.0 * invH
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

                let yFlipped = map.height - 1 - y
                let ndcX0 = -1.0 + Float(x) * pixelWidth
                let ndcY0 = 1.0 - Float(yFlipped) * pixelHeight
                let ndcX1 = ndcX0 + pixelWidth
                let ndcY1 = ndcY0 - pixelHeight

                vertices.append(.init(position: SIMD2<Float>(x: ndcX0, y: ndcY1), color: color))
                vertices.append(.init(position: SIMD2<Float>(x: ndcX1, y: ndcY1), color: color))
                vertices.append(.init(position: SIMD2<Float>(x: ndcX1, y: ndcY0), color: color))

                vertices.append(.init(position: SIMD2<Float>(x: ndcX0, y: ndcY1), color: color))
                vertices.append(.init(position: SIMD2<Float>(x: ndcX1, y: ndcY0), color: color))
                vertices.append(.init(position: SIMD2<Float>(x: ndcX0, y: ndcY0), color: color))
            }
        }

        return vertices
    }
}
