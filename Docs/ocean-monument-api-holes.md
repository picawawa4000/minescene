# Ocean Monument API Holes

While wiring MineScene's structure viewer to DPReader's `OceanMonument` API, these gaps in the public API showed up:

1. There is no public monument anchor/origin output.
MineScene needs a stable local origin for viewing, but the API exposes only `startChunk` and the generated world-space bounding box. The viewer currently normalizes the generated blocks by subtracting `graph.boundingBox.min`, which is an app-side assumption rather than a DPReader-provided placement origin.

2. There is no public render/material mapping for generated blocks.
The generator returns raw `BlockState`s, which is correct for simulation, but the API does not expose any monument-specific visual/material mapping. MineScene therefore has to manually map block ids like `minecraft:prismarine` and `minecraft:sea_lantern` to vanilla textures.

3. Elder guardians are exposed only as positions.
`OceanMonumentGenerationResult` returns `elderGuardians: [PosInt3D]`, but not any public render/entity metadata. MineScene can report their positions, but it cannot render them as entities from the monument API alone.

4. There is no public helper for localizing or translating the generated write volume.
The API provides `allTouchedBlocks()` in world coordinates, but callers that want a local structure-space view must translate those coordinates themselves.

5. There is no public final block-state sampler for the surrounding generated world.
MineScene can build a `WorldGenerator` and ask it for terrain shape or biome information, but not the final placed block state at a world position. That means the viewer has to approximate the surrounding world when feeding `OceanMonumentGenerationContext.blockSampler`, which can differ from Minecraft in places where actual ocean-floor materials, fluids, plants, ice, caves, or other post-noise blocks matter.
