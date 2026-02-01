import SwiftSDL
import VulkanBindings
import Vulkan

@_silgen_name("SDL_Vulkan_CreateSurface")
private func sdlVulkanCreateSurface(
    _ window: OpaquePointer?,
    _ instance: VkInstance?,
    _ allocator: UnsafePointer<VkAllocationCallbacks>?,
    _ surface: UnsafeMutablePointer<VkSurfaceKHR?>?
) -> Bool

func createVulkanSurface(from window: some Window, instance: VulkanOwnedInstance) throws -> VulkanOwnedSurface {
    var surface: VkSurfaceKHR?
    let created = sdlVulkanCreateSurface(window.pointer, instance.instance, nil, &surface)
    guard created, let surface else {
        throw SDL_Error.error
    }
    return VulkanOwnedSurface(instance: instance.instance, surface: surface)
}
