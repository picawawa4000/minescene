#if canImport(simd)
import simd
#endif

struct BiomeColorPalette {
    private let colorsRGBA8: [String: (UInt8, UInt8, UInt8, UInt8)]
    private let fallbackRGBA8: (UInt8, UInt8, UInt8, UInt8)

    init(
        colorsRGBA8: [String: (UInt8, UInt8, UInt8, UInt8)],
        fallbackRGBA8: (UInt8, UInt8, UInt8, UInt8) = (255, 0, 255, 255)
    ) {
        self.colorsRGBA8 = Dictionary(uniqueKeysWithValues: colorsRGBA8.map { biomeID, color in
            (Self.normalizedBiomeID(biomeID), color)
        })
        self.fallbackRGBA8 = fallbackRGBA8
    }

    static func defaultPalette() -> Self {
        Self(colorsRGBA8: [
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
            "minecraft:end_barrens": (170, 180, 90, 255),
            "minecraft:end_highlands": (190, 200, 110, 255),
            "minecraft:end_midlands": (180, 190, 100, 255),
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
            "minecraft:small_end_islands": (160, 170, 85, 255),
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
            "minecraft:the_end": (128, 128, 255, 255),
            "minecraft:the_void": (0, 0, 0, 255),
            "minecraft:warm_ocean": (70, 200, 220, 255),
            "minecraft:warped_forest": (30, 130, 120, 255),
            "minecraft:windswept_forest": (70, 130, 90, 255),
            "minecraft:windswept_gravelly_hills": (110, 110, 110, 255),
            "minecraft:windswept_hills": (120, 120, 120, 255),
            "minecraft:windswept_savanna": (160, 160, 70, 255),
            "minecraft:wooded_badlands": (210, 130, 70, 255),
        ])
    }

    static func normalizedBiomeID(_ biomeID: String) -> String {
        let trimmed = biomeID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return trimmed
        }
        if trimmed.contains(":") {
            return trimmed
        }
        return "minecraft:\(trimmed)"
    }

    func overridingColorsRGBA8(
        _ overrides: [String: (UInt8, UInt8, UInt8, UInt8)]
    ) -> Self {
        var merged = colorsRGBA8
        for (biomeID, color) in overrides {
            merged[Self.normalizedBiomeID(biomeID)] = color
        }
        return Self(colorsRGBA8: merged, fallbackRGBA8: fallbackRGBA8)
    }

    func rgba8(forBiomeID biomeID: String?) -> (UInt8, UInt8, UInt8, UInt8) {
        guard let biomeID else {
            return fallbackRGBA8
        }
        return colorsRGBA8[Self.normalizedBiomeID(biomeID)] ?? fallbackRGBA8
    }

    func float4(forBiomeID biomeID: String?) -> SIMD4<Float> {
        let color = rgba8(forBiomeID: biomeID)
        return SIMD4<Float>(
            Float(color.0) / 255,
            Float(color.1) / 255,
            Float(color.2) / 255,
            Float(color.3) / 255
        )
    }

    func packedRGBA8(forBiomeID biomeID: String?) -> UInt32 {
        let color = rgba8(forBiomeID: biomeID)
        return UInt32(color.0)
            | (UInt32(color.1) << 8)
            | (UInt32(color.2) << 16)
            | (UInt32(color.3) << 24)
    }
}
