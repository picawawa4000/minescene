import SwiftSDL
import VulkanBindings
import Vulkan

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

// Windowing and surface creation
let windowPtr = "MineScene".withCString() { title in
    SDL_CreateWindow(title, 640, 380, SDL_WindowFlags.vulkan.rawValue | SDL_WindowFlags.resizable.rawValue)
}
guard let windowPtr else {
    throw SDL_Error.error
}
let window = SDLObject<OpaquePointer>(windowPtr, tag: .custom("window"), destroy: { SDL_DestroyWindow($0) })

// Instance creation
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

// Vulkan instantiation (resources, etc.)
var engine = try VulkanEngine(
    instance: instance,
    surface: surface,
    vertSpirvPath: "Shaders/SPIRV/colour2D.vert.spv",
    fragSpirvPath: "Shaders/SPIRV/colour2D.frag.spv",
    desiredExtent: .init(width: 640, height: 380)
)

let imageIndex = try engine.device.acquireNextImage(from: engine.swapchain)
let (_vertexBuffer, _vertexMemory) = try engine.uploadVertices2D([
    .init(position: SIMD2<Float>(x: 0.0, y: -0.5), color: SIMD4<Float>(x: 1.0, y: 0.0, z: 0.0, w: 1.0)),
    .init(position: SIMD2<Float>(x: 0.5, y: 0.5), color: SIMD4<Float>(x: 0.0, y: 1.0, z: 0.0, w: 1.0)),
    .init(position: SIMD2<Float>(x: -0.5, y: 0.5), color: SIMD4<Float>(x: 0.0, y: 0.0, z: 1.0, w: 1.0))
], framebufferIndex: Int(imageIndex))

var swapchainHandle: VkSwapchainKHR? = engine.swapchain.swapchain
var imageIndexVar = imageIndex
try withUnsafePointer(to: &swapchainHandle) { swapchainPtr in
    try withUnsafePointer(to: &imageIndexVar) { imageIndexPtr in
        var presentInfo = VkPresentInfoKHR(
            sType: VK_STRUCTURE_TYPE_PRESENT_INFO_KHR,
            pNext: nil,
            waitSemaphoreCount: 0,
            pWaitSemaphores: nil,
            swapchainCount: 1,
            pSwapchains: swapchainPtr,
            pImageIndices: imageIndexPtr,
            pResults: nil
        )
        try engine.device.present(queue: engine.graphicsQueue, presentInfo: &presentInfo)
    }
}

var event = SDL_Event()
let startTicks = SDL_GetTicks()
var running = true
while running {
    while SDL_PollEvent(&event) {
        if event.eventType == .quit {
            running = false
        }
    }
    if SDL_GetTicks() - startTicks > 2000 {
        running = false
    }
    SDL_Delay(16)
}
