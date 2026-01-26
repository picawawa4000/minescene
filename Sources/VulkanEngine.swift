import VulkanBindings
import Vulkan

class VulkanEngine {
    let instance: VulkanOwnedInstance
    let device: VulkanPhysicalDevice

    init() throws {
        self.instance = VulkanOwnedInstance(flags: [], enabledLayers: [], enabledExtensions: [])
        let physicalDevices = self.instance.enumeratePhysicalDevices()
        if physicalDevices.count == 0 {
            throw Errors.noPhysicalDevices
        }
        for physicalDevice in physicalDevices {
            let properties = physicalDevice.getProperties()
            let features = physicalDevice.getFeatures()
            let queueFamilies = physicalDevice.getQueueFamilies()
        }
    }

    enum Errors: Error {
        case noPhysicalDevices
    }
}