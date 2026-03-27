import Foundation
import SwiftSDL
import Vulkan

final class DebugBlockStateRenderer {
    private let repository: VanillaAssetRepository
    private let modelLoader: VanillaBlockModelLoader
    private let structureRenderer: StructureRenderer
    private let blockSpacing: Float
    private let limit: Int?
    private var prepared = false

    init(
        repository: VanillaAssetRepository,
        blockSpacing: Float = 3.0,
        limit: Int? = nil
    ) {
        self.repository = repository
        self.modelLoader = VanillaBlockModelLoader(repository: repository)
        self.structureRenderer = StructureRenderer(repository: repository)
        self.blockSpacing = blockSpacing
        self.limit = limit
    }

    func prepare(engine: VulkanEngine) throws {
        guard !prepared else {
            return
        }

        let blockstates = try modelLoader.loadRepresentativeBlockstates(limit: limit)
        var quads: [StructureRenderer.TexturedQuad] = []
        quads.reserveCapacity(blockstates.count * 12)

        for (index, state) in blockstates.enumerated() {
            let offset = SIMD3<Float>(Float(index) * blockSpacing, 0, 0)
            quads.append(contentsOf: modelLoader.texturedQuads(for: state, worldOffset: offset))
        }

        try structureRenderer.setQuads(quads, engine: engine)
        prepared = true

        let summary = "Prepared debug blockstate renderer with \(blockstates.count) representative blockstates from \(repository.rootURL.path)\n"
        FileHandle.standardError.write(Data(summary.utf8))
    }

    func handleEvent(_ event: SDL_Event, window _: OpaquePointer?) {
        structureRenderer.handleEvent(event)
    }

    func update(deltaTime: Float) {
        structureRenderer.update(deltaTime: deltaTime)
    }

    func render(
        engine: VulkanEngine,
        window: OpaquePointer?,
        imageAvailable: VkSemaphore,
        renderFinishedByImage: [VkSemaphore]
    ) throws {
        try prepare(engine: engine)
        try structureRenderer.render(
            engine: engine,
            window: window,
            imageAvailable: imageAvailable,
            renderFinishedByImage: renderFinishedByImage
        )
    }
}
