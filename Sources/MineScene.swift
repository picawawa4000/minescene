import Foundation
import SwiftSDL
import VulkanBindings
import Vulkan
import DPReader

@_silgen_name("SDL_Vulkan_GetInstanceExtensions")
private func sdlVulkanGetInstanceExtensions(_ count: UnsafeMutablePointer<UInt32>?) -> UnsafePointer<UnsafePointer<CChar>?>?

@main
final class MineSceneApp {
    private final class SDLRuntime {
        init() throws {
            try SDL_Init(.video)
        }

        deinit {
            SDL_Quit()
        }
    }

    private let sdl: SDLRuntime
    private var window: SDLObject<OpaquePointer>?
    private var instance: VulkanOwnedInstance?
    private var surface: VulkanOwnedSurface?
    private var engine: VulkanEngine?
    private var worldGenerator: WorldGenerator?
    private var terrainRenderer: TerrainRenderer?
    private var imageAvailable: VulkanOwnedSemaphore?
    private var renderFinishedByImage: [VulkanOwnedSemaphore] = []

    init() throws {
        self.sdl = try SDLRuntime()

        let windowPtr = "MineScene".withCString { title in
            SDL_CreateWindow(title, 1200, 840, SDL_WindowFlags.vulkan.rawValue | SDL_WindowFlags.resizable.rawValue)
        }
        guard let windowPtr else {
            throw SDL_Error.error
        }
        self.window = SDLObject<OpaquePointer>(windowPtr, tag: .custom("window"), destroy: { SDL_DestroyWindow($0) })
        if !SDL_SetWindowRelativeMouseMode(windowPtr, true) {
            throw SDL_Error.error
        }

        var instanceFlags: VulkanInstanceCreateFlags = []
        var instanceExtensions = try MineSceneApp.getSdlVulkanInstanceExtensions()
#if os(macOS)
        instanceFlags.insert(.enumeratePortability)
        instanceExtensions.append(VK_KHR_PORTABILITY_ENUMERATION_EXTENSION_NAME)
#endif
        instanceExtensions = Array(Set(instanceExtensions))

#if DEBUG
        let instanceLayers = ["VK_LAYER_KHRONOS_validation"]
#else
        let instanceLayers: [String] = []
#endif

        let instance = try VulkanOwnedInstance(
            flags: instanceFlags,
            enabledLayers: instanceLayers,
            enabledExtensions: instanceExtensions,
            appName: "minescene",
            appVersion: 1,
            engineName: nil,
            engineVersion: nil,
            apiVersion: VulkanAPIVersion.v1_3.rawValue
        )
        self.instance = instance

        guard let window else {
            throw SDL_Error.error
        }
        let surface = try createVulkanSurface(from: window, instance: instance)
        self.surface = surface

        let seed: UInt64 = 123456789
        let dataPackPath = "vanilla/1.21.11"
        let dataPackURL = URL(fileURLWithPath: dataPackPath, isDirectory: true)
        let dataPack = try DataPack(fromRootPath: dataPackURL)
        let worldGenerator = try WorldGenerator(
            withWorldSeed: seed,
            usingDataPacks: [dataPack],
            usingSettings: RegistryKey(referencing: "minecraft:overworld")
        )
        self.worldGenerator = worldGenerator

        let engine = try VulkanEngine(
            instance: instance,
            surface: surface,
            vertSpirvPath: "Shaders/SPIRV/colour2D.vert.spv",
            fragSpirvPath: "Shaders/SPIRV/colour2D.frag.spv",
            vertSpirv3DPath: "Shaders/SPIRV/colour3D.vert.spv",
            fragSpirv3DPath: "Shaders/SPIRV/colour3D.frag.spv",
            desiredExtent: .init(width: 1200, height: 840)
        )
        self.engine = engine

        self.imageAvailable = try engine.device.createSemaphore()
        self.renderFinishedByImage = try engine.swapchainImages.map { _ in
            try engine.device.createSemaphore()
        }
        self.terrainRenderer = TerrainRenderer(worldGenerator: worldGenerator)
    }

    static func main() throws {
        let app = try MineSceneApp()
        try app.run()
    }

    private func run() throws {
        var running = true
        var event = SDL_Event()
        var previousTickNs = DispatchTime.now().uptimeNanoseconds

        while running {
            while SDL_PollEvent(&event) {
                switch event.eventType {
                case .quit:
                    running = false
                case .keyDown:
                    if !event.key.repeat, event.key.key == SDLK_ESCAPE {
                        running = false
                    } else {
                        terrainRenderer?.handleEvent(event)
                    }
                default:
                    terrainRenderer?.handleEvent(event)
                }
            }

            let nowNs = DispatchTime.now().uptimeNanoseconds
            let deltaTime = Float(nowNs - previousTickNs) / 1_000_000_000.0
            previousTickNs = nowNs
            terrainRenderer?.update(deltaTime: deltaTime)

            try renderFrame()
            SDL_Delay(16)
        }

        if let engine {
            _ = try? engine.device.waitIdle()
        }

        terrainRenderer = nil
        imageAvailable = nil
        renderFinishedByImage.removeAll()
        engine?.shutdown()
        engine = nil
        worldGenerator = nil
        surface = nil
        instance = nil
        window = nil
    }

    private func renderFrame() throws {
        guard let terrainRenderer, let engine, let imageAvailable, !renderFinishedByImage.isEmpty else {
            return
        }
        try terrainRenderer.render(
            engine: engine,
            window: window?.pointer,
            imageAvailable: imageAvailable.semaphore,
            renderFinishedByImage: renderFinishedByImage.map(\.semaphore)
        )
    }

    private static func getSdlVulkanInstanceExtensions() throws -> [String] {
        var count: UInt32 = 0
        guard let extensionsPtr = sdlVulkanGetInstanceExtensions(&count) else {
            throw SDL_Error.error
        }
        let buffer = UnsafeBufferPointer(start: extensionsPtr, count: Int(count))
        return buffer.compactMap { $0 }.map { String(cString: $0) }
    }
}
