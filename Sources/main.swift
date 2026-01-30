import VulkanBindings

let instance = try VulkanOwnedInstance(
    flags: [],
    enabledLayers: [],
    enabledExtensions: [],
    appName: "minescene",
    appVersion: 1,
    engineName: nil,
    engineVersion: nil,
    apiVersion: VulkanAPIVersion.v1_3.rawValue
)


let engine = try VulkanEngine(
    instance: instance,
    surface: any VulkanSurface,
    vertSpirv: [UInt32],
    fragSpirv: [UInt32]
)