import Foundation
import SwiftSDL
import VulkanBindings
import Vulkan
import DPReader

@_silgen_name("SDL_Vulkan_GetInstanceExtensions")
private func sdlVulkanGetInstanceExtensions(_ count: UnsafeMutablePointer<UInt32>?) -> UnsafePointer<UnsafePointer<CChar>?>?

private func getSdlVulkanInstanceExtensions() throws -> [String] {
    var count: UInt32 = 0
    guard let extensionsPtr = sdlVulkanGetInstanceExtensions(&count) else {
        throw SDL_Error.error
    }
    let buffer = UnsafeBufferPointer(start: extensionsPtr, count: Int(count))
    return buffer.compactMap { $0 }.map { String(cString: $0) }
}

let windowPtr = "MineScene".withCString { title in
    SDL_CreateWindow(title, 800, 800, SDL_WindowFlags.vulkan.rawValue | SDL_WindowFlags.resizable.rawValue)
}
guard let windowPtr else {
    throw SDL_Error.error
}
let window = SDLObject<OpaquePointer>(windowPtr, tag: .custom("window"), destroy: { SDL_DestroyWindow($0) })

var instanceFlags: VulkanInstanceCreateFlags = []
var instanceExtensions = try getSdlVulkanInstanceExtensions()
#if os(macOS)
instanceFlags.insert(.enumeratePortability)
instanceExtensions.append(VK_KHR_PORTABILITY_ENUMERATION_EXTENSION_NAME)
#endif
instanceExtensions = Array(Set(instanceExtensions))

let instance = try VulkanOwnedInstance(
    flags: instanceFlags,
    enabledLayers: [],
    enabledExtensions: instanceExtensions,
    appName: "minescene",
    appVersion: 1,
    engineName: nil,
    engineVersion: nil,
    apiVersion: VulkanAPIVersion.v1_3.rawValue
)

let surface = try createVulkanSurface(from: window, instance: instance)

let engine = try VulkanEngine(
    instance: instance,
    surface: surface,
    vertSpirvPath: "Shaders/SPIRV/colour2D.vert.spv",
    fragSpirvPath: "Shaders/SPIRV/colour2D.frag.spv",
    desiredExtent: .init(width: 800, height: 800)
)

let seed: UInt64 = 503815372
// Change this if you extracted the datapack somewhere else
// (although it's recommended to extract it directly here)
let dataPackPath = "vanilla/1.21.11"
let dataPackURL = URL(fileURLWithPath: dataPackPath, isDirectory: true)
let dataPack = try DataPack(fromRootPath: dataPackURL)
let worldGenerator = try WorldGenerator(withWorldSeed: seed, usingDataPacks: [dataPack], usingSettings: RegistryKey(referencing: "minecraft:overworld"))

let map = try BiomeMapRenderer.render(
    worldGenerator: worldGenerator,
    topLeftX: 0,
    topLeftZ: 0,
    width: 128,
    height: 128,
    stride: 4,
    sampleY: 256
)
let vertices = BiomeMapRenderer.makeVertices2D(from: map)

let imageAvailable = try engine.device.createSemaphore()
let renderFinished = try engine.device.createSemaphore()
let imageIndex = try engine.device.acquireNextImage(from: engine.swapchain, semaphore: imageAvailable.semaphore)
let (_vertexBuffer, _vertexMemory) = try engine.uploadVertices2D(
    vertices,
    framebufferIndex: Int(imageIndex),
    waitSemaphores: [imageAvailable.semaphore],
    signalSemaphores: [renderFinished.semaphore]
)

var swapchainHandle: VkSwapchainKHR? = engine.swapchain.swapchain
var imageIndexVar = imageIndex
try withUnsafePointer(to: &swapchainHandle) { swapchainPtr in
    try withUnsafePointer(to: &imageIndexVar) { imageIndexPtr in
        var renderFinishedSemaphore: VkSemaphore? = renderFinished.semaphore
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

var event = SDL_Event()
var running = true
while running {
    while SDL_PollEvent(&event) {
        if event.eventType == .quit {
            running = false
        }
    }
    SDL_Delay(16)
}
