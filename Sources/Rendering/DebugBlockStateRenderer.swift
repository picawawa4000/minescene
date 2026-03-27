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

    var keycodeForAction: ((KeybindAction) -> SDL_Keycode)? {
        get { structureRenderer.keycodeForAction }
        set { structureRenderer.keycodeForAction = newValue }
    }

    func prepare(engine: VulkanEngine) throws {
        guard !prepared else {
            return
        }

        let blockstates = try modelLoader.loadRepresentativeBlockstates(limit: limit)
        var quads: [StructureRenderer.TexturedQuad] = []
        quads.reserveCapacity(blockstates.count * 12)

        let columnCount = max(1, Int(ceil(sqrt(Double(max(1, blockstates.count))))))
        let rowCount = max(1, Int(ceil(Double(blockstates.count) / Double(columnCount))))
        let totalWidth = Float(max(0, columnCount - 1)) * blockSpacing
        let totalDepth = Float(max(0, rowCount - 1)) * blockSpacing

        for (index, state) in blockstates.enumerated() {
            let column = index % columnCount
            let row = index / columnCount
            let offset = SIMD3<Float>(
                Float(column) * blockSpacing - totalWidth * 0.5,
                0,
                Float(row) * blockSpacing - totalDepth * 0.5
            )
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
