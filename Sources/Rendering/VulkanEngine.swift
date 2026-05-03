import Foundation
import VulkanBindings
import Vulkan
#if canImport(simd)
import simd
#endif

final class VulkanEngine {
    private final class Resources {
        var commandPool: VulkanOwnedCommandPool?
        let commandBuffer: VulkanCommandBuffer
        var inFlightFence: VulkanOwnedFence?

        var swapchain: VulkanOwnedSwapchain?
        let swapchainImages: [VkImage]
        var swapchainImageViews: [VulkanOwnedImageView]?
        var depthImage: VulkanOwnedImage?
        var depthImageMemory: VulkanOwnedDeviceMemory?
        var depthImageView: VulkanOwnedImageView?
        var swapchainFramebuffers: [VulkanOwnedFramebuffer]?
        let swapchainFormat: VkFormat
        let depthFormat: VkFormat
        let swapchainExtent: VkExtent2D

        var renderPass: VulkanOwnedRenderPass?
        var mode2D: DrawingMode2D?
        var mode3D: DrawingMode3D?

        init(
            commandPool: VulkanOwnedCommandPool,
            commandBuffer: VulkanCommandBuffer,
            inFlightFence: VulkanOwnedFence,
            swapchain: VulkanOwnedSwapchain,
            swapchainImages: [VkImage],
            swapchainImageViews: [VulkanOwnedImageView],
            depthImage: VulkanOwnedImage,
            depthImageMemory: VulkanOwnedDeviceMemory,
            depthImageView: VulkanOwnedImageView,
            swapchainFramebuffers: [VulkanOwnedFramebuffer],
            swapchainFormat: VkFormat,
            depthFormat: VkFormat,
            swapchainExtent: VkExtent2D,
            renderPass: VulkanOwnedRenderPass,
            mode2D: DrawingMode2D,
            mode3D: DrawingMode3D
        ) {
            self.commandPool = commandPool
            self.commandBuffer = commandBuffer
            self.inFlightFence = inFlightFence
            self.swapchain = swapchain
            self.swapchainImages = swapchainImages
            self.swapchainImageViews = swapchainImageViews
            self.depthImage = depthImage
            self.depthImageMemory = depthImageMemory
            self.depthImageView = depthImageView
            self.swapchainFramebuffers = swapchainFramebuffers
            self.swapchainFormat = swapchainFormat
            self.depthFormat = depthFormat
            self.swapchainExtent = swapchainExtent
            self.renderPass = renderPass
            self.mode2D = mode2D
            self.mode3D = mode3D
        }

        deinit {
            // Explicit teardown order: pipelines -> framebuffers -> render pass -> depth -> views -> swapchain -> command pool.
            mode3D = nil
            mode2D = nil
            swapchainFramebuffers = nil
            renderPass = nil
            depthImageView = nil
            depthImageMemory = nil
            depthImage = nil
            swapchainImageViews = nil
            swapchain = nil
            inFlightFence = nil
            commandPool = nil
        }
    }

    @inline(__always)
    private static func vulkanResultCheck(_ result: VkResult) throws {
        if result != VK_SUCCESS {
            throw Errors.vulkanFailure(result)
        }
    }

    @inline(__always)
    private static func packRGBA8(_ color: SIMD4<Float>) -> UInt32 {
        let r = UInt32(clamping: Int((max(0, min(1, color.x)) * 255).rounded()))
        let g = UInt32(clamping: Int((max(0, min(1, color.y)) * 255).rounded()))
        let b = UInt32(clamping: Int((max(0, min(1, color.z)) * 255).rounded()))
        let a = UInt32(clamping: Int((max(0, min(1, color.w)) * 255).rounded()))
        return r | (g << 8) | (b << 16) | (a << 24)
    }

    deinit {
        shutdown()
    }

    func shutdown() {
        _ = vkDeviceWaitIdle(device.device)
        resources = nil
    }
    enum DescriptorBindings2D {
        static let transform: UInt32 = 0
    }

    enum DescriptorBindings3D {
        static let transform: UInt32 = 0
        static let model: UInt32 = 1
        static let view: UInt32 = 2
    }

    struct Vertex2D {
        var position: SIMD2<Float>
        var color: SIMD4<Float>
    }

    struct Vertex3D {
        var x: Float
        var y: Float
        var z: Float
        var color: UInt32

        init(position: SIMD3<Float>, color: SIMD4<Float>) {
            self.x = position.x
            self.y = position.y
            self.z = position.z
            self.color = VulkanEngine.packRGBA8(color)
        }
    }

    struct DrawBatch2D {
        let buffer: VulkanOwnedBuffer
        let vertexCount: UInt32
    }

    struct DrawBatch3D {
        let buffer: VulkanOwnedBuffer
        let vertexCount: UInt32
        let modelOffset: SIMD4<Float>
    }

    struct CapturedFrame {
        let width: Int
        let height: Int
        let bytesPerRow: Int
        let bgra8Data: Data
    }

    final class VulkanOwnedDescriptorSetLayout {
        let descriptorSetLayout: VkDescriptorSetLayout
        private let device: VkDevice

        init(device: VkDevice, descriptorSetLayout: VkDescriptorSetLayout) {
            self.device = device
            self.descriptorSetLayout = descriptorSetLayout
        }

        deinit {
            vkDestroyDescriptorSetLayout(self.device, self.descriptorSetLayout, nil)
        }
    }

    struct DrawingMode2D {
        let descriptorSetLayout: VulkanOwnedDescriptorSetLayout
        let pipelineLayout: VulkanOwnedPipelineLayout
        let pipeline: VulkanOwnedPipeline
        let descriptorPool: VulkanOwnedDescriptorPool
        let descriptorSet: VkDescriptorSet
        let uniformBuffer: VulkanOwnedBuffer
        let uniformMemory: VulkanOwnedDeviceMemory
    }

    struct DrawingMode3D {
        let descriptorSetLayout: VulkanOwnedDescriptorSetLayout
        let pipelineLayout: VulkanOwnedPipelineLayout
        let pipeline: VulkanOwnedPipeline?
        let descriptorPool: VulkanOwnedDescriptorPool
        let descriptorSet: VkDescriptorSet
        let transformUniformBuffer: VulkanOwnedBuffer
        let transformUniformMemory: VulkanOwnedDeviceMemory
        let modelUniformBuffer: VulkanOwnedBuffer
        let modelUniformMemory: VulkanOwnedDeviceMemory
        let viewUniformBuffer: VulkanOwnedBuffer
        let viewUniformMemory: VulkanOwnedDeviceMemory
    }

    final class VulkanOwnedDescriptorPool {
        let descriptorPool: VkDescriptorPool
        private let device: VkDevice

        init(device: VkDevice, descriptorPool: VkDescriptorPool) {
            self.device = device
            self.descriptorPool = descriptorPool
        }

        deinit {
            vkDestroyDescriptorPool(self.device, self.descriptorPool, nil)
        }
    }

    let instance: VulkanInstance
    let surface: VkSurfaceKHR
    let physicalDevice: VulkanPhysicalDevice
    let device: VulkanOwnedDevice
    let graphicsQueue: VkQueue
    let queueFamilyIndex: UInt32
    private var resources: Resources?
    private var clearColor = SIMD4<Float>(0.0, 0.0, 0.9, 1.0)

    var commandPool: VulkanOwnedCommandPool { resources!.commandPool! }
    var commandBuffer: VulkanCommandBuffer { resources!.commandBuffer }
    var inFlightFence: VulkanOwnedFence { resources!.inFlightFence! }

    var swapchain: VulkanOwnedSwapchain { resources!.swapchain! }
    var swapchainImages: [VkImage] { resources!.swapchainImages }
    var swapchainImageViews: [VulkanOwnedImageView] { resources!.swapchainImageViews ?? [] }
    var depthImage: VulkanOwnedImage { resources!.depthImage! }
    var depthImageMemory: VulkanOwnedDeviceMemory { resources!.depthImageMemory! }
    var depthImageView: VulkanOwnedImageView { resources!.depthImageView! }
    var swapchainFramebuffers: [VulkanOwnedFramebuffer] { resources!.swapchainFramebuffers ?? [] }
    var swapchainFormat: VkFormat { resources!.swapchainFormat }
    var depthFormat: VkFormat { resources!.depthFormat }
    var swapchainExtent: VkExtent2D { resources!.swapchainExtent }

    var renderPass: VulkanOwnedRenderPass { resources!.renderPass! }
    var mode2D: DrawingMode2D { resources!.mode2D! }
    var mode3D: DrawingMode3D { resources!.mode3D! }

    /// Creates a new Vulkan engine.
    /// Parameters:
    ///   - instance: The Vulkan instance to use. The underlying instance must remain valid for the lifetime of the engine.
    ///   - surface: The Vulkan surface to render to.
    ///   - vertSpirv: The SPIR-V bytecode for the vertex shader.
    ///   - fragSpirv: The SPIR-V bytecode for the fragment shader.
    ///   - desiredExtent: The desired extent of the swapchain images. Defaults to 640x480.
    init(
        instance: VulkanInstance,
        surface: VulkanSurface,
        vertSpirv: [UInt32],
        fragSpirv: [UInt32],
        vertSpirv3D: [UInt32]? = nil,
        fragSpirv3D: [UInt32]? = nil,
        validationLayers: [String]? = nil,
        desiredExtent: VkExtent2D = VkExtent2D(width: 640, height: 480)
    ) throws {
        self.instance = instance
        self.surface = surface.surface
        let enabledValidationLayers: [String]
#if DEBUG
        enabledValidationLayers = validationLayers ?? ["VK_LAYER_KHRONOS_validation"]
#else
        enabledValidationLayers = validationLayers ?? []
#endif

        let physicalDevices = try instance.enumeratePhysicalDevices()
        let selection = try VulkanEngine.selectPhysicalDevice(from: physicalDevices, surface: self.surface)
        self.physicalDevice = selection.device
        self.queueFamilyIndex = selection.queueFamilyIndex
        let deviceBundle = try VulkanEngine.createDeviceAndQueue(
            physicalDevice: self.physicalDevice,
            queueFamilyIndex: self.queueFamilyIndex,
            enabledLayers: enabledValidationLayers
        )
        self.device = deviceBundle.device
        self.graphicsQueue = deviceBundle.queue

        let commandBundle = try VulkanEngine.createCommandResources(
            device: self.device,
            queueFamilyIndex: self.queueFamilyIndex
        )

        let swapchainBundle = try VulkanEngine.createSwapchainBundle(
            device: self.device,
            physicalDevice: self.physicalDevice,
            surface: self.surface,
            desiredExtent: desiredExtent
        )
        let depthFormat = try VulkanEngine.chooseDepthFormat(physicalDevice: self.physicalDevice)
        let depthResources = try VulkanEngine.createDepthResources(
            device: self.device,
            physicalDevice: self.physicalDevice,
            format: depthFormat,
            extent: swapchainBundle.extent
        )
        let renderPass = try VulkanEngine.createRenderPass(
            device: self.device,
            colorFormat: swapchainBundle.format,
            depthFormat: depthFormat
        )

        let swapchainFramebuffers = try VulkanEngine.createFramebuffers(
            device: self.device,
            renderPass: renderPass,
            imageViews: swapchainBundle.imageViews,
            depthImageView: depthResources.imageView,
            extent: swapchainBundle.extent
        )

        let mode2DLayout = try VulkanEngine.createDescriptorSetLayout2D(device: self.device)
        let mode2DPipelineLayout = try VulkanEngine.createPipelineLayout(
            device: self.device,
            descriptorSetLayout: mode2DLayout
        )
        let mode2DDescriptorPool = try VulkanEngine.createDescriptorPool(
            device: self.device,
            maxSets: 1,
            poolSizes: [
                VkDescriptorPoolSize(type: VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER, descriptorCount: 1)
            ]
        )
        let mode2DDescriptorSet = try VulkanEngine.allocateDescriptorSet(
            device: self.device,
            descriptorPool: mode2DDescriptorPool,
            layout: mode2DLayout
        )
        let (mode2DUniformBuffer, mode2DUniformMemory) = try VulkanEngine.createUniformBuffer2D(
            device: self.device,
            physicalDevice: self.physicalDevice
        )
        VulkanEngine.updateDescriptorSet(
            device: self.device,
            descriptorSet: mode2DDescriptorSet,
            binding: DescriptorBindings2D.transform,
            buffer: mode2DUniformBuffer,
            range: VkDeviceSize(MemoryLayout<Float>.size * 16)
        )
        let pipeline2D = try VulkanEngine.createPipeline(
            device: self.device,
            renderPass: renderPass,
            extent: swapchainBundle.extent,
            pipelineLayout: mode2DPipelineLayout,
            vertexInput: VulkanEngine.vertexInput2D(),
            cullMode: VkCullModeFlags(VK_CULL_MODE_NONE.rawValue),
            enableDepthTest: false,
            enableBlending: true,
            vertSpirv: vertSpirv,
            fragSpirv: fragSpirv
        )
        let mode2D = DrawingMode2D(
            descriptorSetLayout: mode2DLayout,
            pipelineLayout: mode2DPipelineLayout,
            pipeline: pipeline2D,
            descriptorPool: mode2DDescriptorPool,
            descriptorSet: mode2DDescriptorSet,
            uniformBuffer: mode2DUniformBuffer,
            uniformMemory: mode2DUniformMemory
        )

        let mode3DLayout = try VulkanEngine.createDescriptorSetLayout3D(device: self.device)
        let mode3DPushConstantRange = VkPushConstantRange(
            stageFlags: VkShaderStageFlags(VK_SHADER_STAGE_VERTEX_BIT.rawValue),
            offset: 0,
            size: UInt32(MemoryLayout<SIMD4<Float>>.stride)
        )
        let mode3DPipelineLayout = try VulkanEngine.createPipelineLayout(
            device: self.device,
            descriptorSetLayout: mode3DLayout,
            pushConstantRange: mode3DPushConstantRange
        )
        let mode3DDescriptorPool = try VulkanEngine.createDescriptorPool(
            device: self.device,
            maxSets: 1,
            poolSizes: [
                VkDescriptorPoolSize(type: VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER, descriptorCount: 3)
            ]
        )
        let mode3DDescriptorSet = try VulkanEngine.allocateDescriptorSet(
            device: self.device,
            descriptorPool: mode3DDescriptorPool,
            layout: mode3DLayout
        )
        let (mode3DTransformUniformBuffer, mode3DTransformUniformMemory) = try VulkanEngine.createUniformBuffer3D(
            device: self.device,
            physicalDevice: self.physicalDevice
        )
        let (mode3DModelUniformBuffer, mode3DModelUniformMemory) = try VulkanEngine.createUniformBuffer3D(
            device: self.device,
            physicalDevice: self.physicalDevice
        )
        let (mode3DViewUniformBuffer, mode3DViewUniformMemory) = try VulkanEngine.createUniformBuffer3D(
            device: self.device,
            physicalDevice: self.physicalDevice
        )
        VulkanEngine.updateDescriptorSet(
            device: self.device,
            descriptorSet: mode3DDescriptorSet,
            binding: DescriptorBindings3D.transform,
            buffer: mode3DTransformUniformBuffer,
            range: VkDeviceSize(MemoryLayout<Float>.size * 16)
        )
        VulkanEngine.updateDescriptorSet(
            device: self.device,
            descriptorSet: mode3DDescriptorSet,
            binding: DescriptorBindings3D.model,
            buffer: mode3DModelUniformBuffer,
            range: VkDeviceSize(MemoryLayout<Float>.size * 16)
        )
        VulkanEngine.updateDescriptorSet(
            device: self.device,
            descriptorSet: mode3DDescriptorSet,
            binding: DescriptorBindings3D.view,
            buffer: mode3DViewUniformBuffer,
            range: VkDeviceSize(MemoryLayout<Float>.size * 16)
        )
        let pipeline3D: VulkanOwnedPipeline?
        if let vertSpirv3D, let fragSpirv3D {
            pipeline3D = try VulkanEngine.createPipeline(
                device: self.device,
                renderPass: renderPass,
                extent: swapchainBundle.extent,
                pipelineLayout: mode3DPipelineLayout,
                vertexInput: VulkanEngine.vertexInput3D(),
                cullMode: VkCullModeFlags(VK_CULL_MODE_BACK_BIT.rawValue),
                enableDepthTest: true,
                enableBlending: false,
                vertSpirv: vertSpirv3D,
                fragSpirv: fragSpirv3D
            )
        } else {
            pipeline3D = nil
        }
        let mode3D = DrawingMode3D(
            descriptorSetLayout: mode3DLayout,
            pipelineLayout: mode3DPipelineLayout,
            pipeline: pipeline3D,
            descriptorPool: mode3DDescriptorPool,
            descriptorSet: mode3DDescriptorSet,
            transformUniformBuffer: mode3DTransformUniformBuffer,
            transformUniformMemory: mode3DTransformUniformMemory,
            modelUniformBuffer: mode3DModelUniformBuffer,
            modelUniformMemory: mode3DModelUniformMemory,
            viewUniformBuffer: mode3DViewUniformBuffer,
            viewUniformMemory: mode3DViewUniformMemory
        )

        self.resources = Resources(
            commandPool: commandBundle.commandPool,
            commandBuffer: commandBundle.commandBuffer,
            inFlightFence: commandBundle.inFlightFence,
            swapchain: swapchainBundle.swapchain,
            swapchainImages: swapchainBundle.images,
            swapchainImageViews: swapchainBundle.imageViews,
            depthImage: depthResources.image,
            depthImageMemory: depthResources.memory,
            depthImageView: depthResources.imageView,
            swapchainFramebuffers: swapchainFramebuffers,
            swapchainFormat: swapchainBundle.format,
            depthFormat: depthFormat,
            swapchainExtent: swapchainBundle.extent,
            renderPass: renderPass,
            mode2D: mode2D,
            mode3D: mode3D
        )
    }

    convenience init(
        instance: VulkanOwnedInstance,
        surface: VulkanSurface,
        vertSpirvPath: String,
        fragSpirvPath: String,
        vertSpirv3DPath: String? = nil,
        fragSpirv3DPath: String? = nil,
        validationLayers: [String]? = nil,
        desiredExtent: VkExtent2D = VkExtent2D(width: 640, height: 480)
    ) throws {
        let vertCode = try VulkanEngine.loadSpirvWords(from: vertSpirvPath)
        let fragCode = try VulkanEngine.loadSpirvWords(from: fragSpirvPath)
        let vertCode3D = try vertSpirv3DPath.map { try VulkanEngine.loadSpirvWords(from: $0) }
        let fragCode3D = try fragSpirv3DPath.map { try VulkanEngine.loadSpirvWords(from: $0) }
        try self.init(
            instance: instance,
            surface: surface,
            vertSpirv: vertCode,
            fragSpirv: fragCode,
            vertSpirv3D: vertCode3D,
            fragSpirv3D: fragCode3D,
            validationLayers: validationLayers,
            desiredExtent: desiredExtent
        )
    }

    private static func deviceExtensions(for physicalDevice: VulkanPhysicalDevice) -> [String] {
        let extensions = physicalDevice.enumerateDeviceExtensionProperties()
        let available = Set(extensions.map { extensionNameString($0) })
        var enabled = [VK_KHR_SWAPCHAIN_EXTENSION_NAME]
        if available.contains("VK_KHR_portability_subset") {
            enabled.append("VK_KHR_portability_subset")
        }
        return enabled
    }

    private static func loadSpirvWords(from path: String) throws -> [UInt32] {
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        if data.count % MemoryLayout<UInt32>.size != 0 {
            throw Errors.invalidSpirvData
        }
        return data.withUnsafeBytes { rawBuffer in
            let wordBuffer = rawBuffer.bindMemory(to: UInt32.self)
            return Array(wordBuffer)
        }
    }

    private struct SpirvEntryPoint {
        let executionModel: UInt32
        let name: String
    }

    private static let spirvOpEntryPoint: UInt32 = 15
    private static let spirvExecutionModelVertex: UInt32 = 0
    private static let spirvExecutionModelFragment: UInt32 = 4

    private static func decodeSpirvString(_ words: ArraySlice<UInt32>) -> String {
        var bytes: [UInt8] = []
        bytes.reserveCapacity(words.count * 4)
        for word in words {
            let b0 = UInt8(word & 0xFF)
            if b0 == 0 { break }
            bytes.append(b0)
            let b1 = UInt8((word >> 8) & 0xFF)
            if b1 == 0 { break }
            bytes.append(b1)
            let b2 = UInt8((word >> 16) & 0xFF)
            if b2 == 0 { break }
            bytes.append(b2)
            let b3 = UInt8((word >> 24) & 0xFF)
            if b3 == 0 { break }
            bytes.append(b3)
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    private static func parseSpirvEntryPoints(_ spirv: [UInt32]) -> [SpirvEntryPoint] {
        guard spirv.count >= 5 else { return [] }
        var ret: [SpirvEntryPoint] = []
        var index = 5
        while index < spirv.count {
            let instruction = spirv[index]
            let wordCount = Int(instruction >> 16)
            let opcode = instruction & 0xFFFF
            guard wordCount > 0, index + wordCount <= spirv.count else {
                break
            }
            if opcode == spirvOpEntryPoint, wordCount >= 4 {
                let executionModel = spirv[index + 1]
                let nameStart = index + 3
                let nameEnd = index + wordCount
                let name = decodeSpirvString(spirv[nameStart..<nameEnd])
                ret.append(.init(executionModel: executionModel, name: name))
            }
            index += wordCount
        }
        return ret
    }

    private static func preferredEntryPointName(
        from entryPoints: [SpirvEntryPoint],
        executionModel: UInt32,
        preferredNames: [String]
    ) -> String? {
        let names = entryPoints.filter { $0.executionModel == executionModel }.map(\.name)
        guard !names.isEmpty else { return nil }
        for preferred in preferredNames where names.contains(preferred) {
            return preferred
        }
        return names[0]
    }

    private static func selectPhysicalDevice(
        from physicalDevices: [VulkanPhysicalDevice],
        surface: VkSurfaceKHR
    ) throws -> (device: VulkanPhysicalDevice, queueFamilyIndex: UInt32) {
        for physicalDevice in physicalDevices {
            if let queueFamilyIndex = try? findGraphicsPresentQueueFamilyIndex(physicalDevice, surface: surface) {
                return (physicalDevice, queueFamilyIndex)
            }
        }
        if physicalDevices.isEmpty {
            throw Errors.noPhysicalDevices
        }
        throw Errors.noSuitableQueueFamily
    }

    private static func findGraphicsPresentQueueFamilyIndex(
        _ physicalDevice: VulkanPhysicalDevice,
        surface: VkSurfaceKHR
    ) throws -> UInt32 {
        let queueFamilies = physicalDevice.getQueueFamilyProperties()
        for (index, family) in queueFamilies.enumerated() {
            if (family.queueFlags & VkQueueFlags(VK_QUEUE_GRAPHICS_BIT.rawValue)) != 0 {
                let queueIndex = UInt32(index)
                let presentSupported = (try? physicalDevice.getSurfaceSupport(surface: surface, queueFamilyIndex: queueIndex)) ?? false
                if presentSupported {
                    return queueIndex
                }
            }
        }
        throw Errors.noSuitableQueueFamily
    }

    private static func extensionNameString(_ properties: VkExtensionProperties) -> String {
        withUnsafePointer(to: properties.extensionName) { ptr in
            let cStringPtr = UnsafeRawPointer(ptr).assumingMemoryBound(to: CChar.self)
            return String(cString: cStringPtr)
        }
    }

    private static func createDeviceAndQueue(
        physicalDevice: VulkanPhysicalDevice,
        queueFamilyIndex: UInt32,
        enabledLayers: [String]
    ) throws -> (device: VulkanOwnedDevice, queue: VkQueue) {
        let queuePriority: Float = 1.0
        let queueCreateInfo = withUnsafePointer(to: queuePriority) { prioritiesPtr in
            VkDeviceQueueCreateInfo.create(
                flags: 0,
                queueFamilyIndex: queueFamilyIndex,
                queueCount: 1,
                pQueuePriorities: prioritiesPtr
            )
        }

        let deviceExtensions = VulkanEngine.deviceExtensions(for: physicalDevice)
        let device = try physicalDevice.createDevice(
            queueCreateInfos: [queueCreateInfo],
            enabledLayers: enabledLayers,
            enabledExtensions: deviceExtensions
        )
        let queue = device.getQueue(familyIndex: queueFamilyIndex, queueIndex: 0)
        return (device, queue)
    }

    private static func createCommandResources(
        device: VulkanOwnedDevice,
        queueFamilyIndex: UInt32
    ) throws -> (commandPool: VulkanOwnedCommandPool, commandBuffer: VulkanCommandBuffer, inFlightFence: VulkanOwnedFence) {
        let commandPool = try device.createCommandPool(flags: [.resetCommandBuffer], queueFamilyIndex: queueFamilyIndex)
        let commandBuffer = try device.allocateCommandBuffers(from: commandPool, count: 1).first!
        let inFlightFence = try device.createFence(flags: [.signaled])
        return (commandPool, commandBuffer, inFlightFence)
    }

    private static func createSwapchainBundle(
        device: VulkanOwnedDevice,
        physicalDevice: VulkanPhysicalDevice,
        surface: VkSurfaceKHR,
        desiredExtent: VkExtent2D
    ) throws -> (
        swapchain: VulkanOwnedSwapchain,
        images: [VkImage],
        imageViews: [VulkanOwnedImageView],
        format: VkFormat,
        extent: VkExtent2D
    ) {
        let swapchainSupport = try querySwapchainSupport(physicalDevice: physicalDevice, surface: surface)
        let surfaceFormat = chooseSurfaceFormat(from: swapchainSupport.formats)
        let presentMode = choosePresentMode(from: swapchainSupport.presentModes)
        let swapExtent = chooseSwapExtent(
            capabilities: swapchainSupport.capabilities,
            desiredExtent: desiredExtent
        )

        let minImageCount = swapchainSupport.capabilities.minImageCount
        var imageCount = minImageCount + 1
        if swapchainSupport.capabilities.maxImageCount > 0 {
            imageCount = min(imageCount, swapchainSupport.capabilities.maxImageCount)
        }

        var swapchainCreateInfo = VkSwapchainCreateInfoKHR(
            sType: VK_STRUCTURE_TYPE_SWAPCHAIN_CREATE_INFO_KHR,
            pNext: nil,
            flags: 0,
            surface: surface,
            minImageCount: imageCount,
            imageFormat: surfaceFormat.format,
            imageColorSpace: surfaceFormat.colorSpace,
            imageExtent: swapExtent,
            imageArrayLayers: 1,
            imageUsage: VkImageUsageFlags(
                VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT.rawValue |
                VK_IMAGE_USAGE_TRANSFER_SRC_BIT.rawValue
            ),
            imageSharingMode: VK_SHARING_MODE_EXCLUSIVE,
            queueFamilyIndexCount: 0,
            pQueueFamilyIndices: nil,
            preTransform: swapchainSupport.capabilities.currentTransform,
            compositeAlpha: VK_COMPOSITE_ALPHA_OPAQUE_BIT_KHR,
            presentMode: presentMode,
            clipped: VK_TRUE,
            oldSwapchain: nil
        )
        let swapchain = try device.createSwapchain(&swapchainCreateInfo)
        let images = try device.getSwapchainImages(swapchain)
        let imageViews = try images.map { image in
            var imageViewCreateInfo = VkImageViewCreateInfo.create(
                flags: 0,
                image: image,
                viewType: VK_IMAGE_VIEW_TYPE_2D,
                format: surfaceFormat.format,
                components: VkComponentMapping(
                    r: VK_COMPONENT_SWIZZLE_IDENTITY,
                    g: VK_COMPONENT_SWIZZLE_IDENTITY,
                    b: VK_COMPONENT_SWIZZLE_IDENTITY,
                    a: VK_COMPONENT_SWIZZLE_IDENTITY
                ),
                subresourceRange: VkImageSubresourceRange(
                    aspectMask: VkImageAspectFlags(VK_IMAGE_ASPECT_COLOR_BIT.rawValue),
                    baseMipLevel: 0,
                    levelCount: 1,
                    baseArrayLayer: 0,
                    layerCount: 1
                )
            )
            return try device.createImageView(&imageViewCreateInfo)
        }

        return (swapchain, images, imageViews, surfaceFormat.format, swapExtent)
    }

    private static func chooseDepthFormat(physicalDevice: VulkanPhysicalDevice) throws -> VkFormat {
        let candidates: [VkFormat] = [
            VK_FORMAT_D32_SFLOAT,
            VK_FORMAT_D32_SFLOAT_S8_UINT,
            VK_FORMAT_D24_UNORM_S8_UINT
        ]
        for format in candidates {
            let properties = physicalDevice.getFormatProperties(format: format)
            if (properties.optimalTilingFeatures & VkFormatFeatureFlags(VK_FORMAT_FEATURE_DEPTH_STENCIL_ATTACHMENT_BIT.rawValue)) != 0 {
                return format
            }
        }
        throw Errors.depthFormatUnsupported
    }

    private static func createDepthResources(
        device: VulkanOwnedDevice,
        physicalDevice: VulkanPhysicalDevice,
        format: VkFormat,
        extent: VkExtent2D
    ) throws -> (image: VulkanOwnedImage, memory: VulkanOwnedDeviceMemory, imageView: VulkanOwnedImageView) {
        var imageCreateInfo = VkImageCreateInfo.create(
            flags: 0,
            imageType: VK_IMAGE_TYPE_2D,
            format: format,
            extent: VkExtent3D(width: extent.width, height: extent.height, depth: 1),
            mipLevels: 1,
            arrayLayers: 1,
            samples: VK_SAMPLE_COUNT_1_BIT,
            tiling: VK_IMAGE_TILING_OPTIMAL,
            usage: VkImageUsageFlags(VK_IMAGE_USAGE_DEPTH_STENCIL_ATTACHMENT_BIT.rawValue),
            sharingMode: VK_SHARING_MODE_EXCLUSIVE,
            queueFamilyIndexCount: 0,
            pQueueFamilyIndices: nil,
            initialLayout: VK_IMAGE_LAYOUT_UNDEFINED
        )
        let image = try device.createImage(&imageCreateInfo)
        let requirements = device.getImageMemoryRequirements(image)
        let memoryTypeIndex = try findMemoryTypeIndex(
            physicalDevice,
            typeBits: requirements.memoryTypeBits,
            properties: VkMemoryPropertyFlags(VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT.rawValue)
        )
        var allocInfo = VkMemoryAllocateInfo.create(
            allocationSize: requirements.size,
            memoryTypeIndex: memoryTypeIndex
        )
        let memory = try device.allocateMemory(&allocInfo)
        try device.bindImageMemory(image: image, memory: memory)

        var imageViewCreateInfo = VkImageViewCreateInfo.create(
            flags: 0,
            image: image.image,
            viewType: VK_IMAGE_VIEW_TYPE_2D,
            format: format,
            components: VkComponentMapping(
                r: VK_COMPONENT_SWIZZLE_IDENTITY,
                g: VK_COMPONENT_SWIZZLE_IDENTITY,
                b: VK_COMPONENT_SWIZZLE_IDENTITY,
                a: VK_COMPONENT_SWIZZLE_IDENTITY
            ),
            subresourceRange: VkImageSubresourceRange(
                aspectMask: VkImageAspectFlags(VK_IMAGE_ASPECT_DEPTH_BIT.rawValue),
                baseMipLevel: 0,
                levelCount: 1,
                baseArrayLayer: 0,
                layerCount: 1
            )
        )
        let imageView = try device.createImageView(&imageViewCreateInfo)
        return (image, memory, imageView)
    }

    private static func createRenderPass(
        device: VulkanOwnedDevice,
        colorFormat: VkFormat,
        depthFormat: VkFormat
    ) throws -> VulkanOwnedRenderPass {
        var colorAttachment = VkAttachmentDescription(
            flags: 0,
            format: colorFormat,
            samples: VK_SAMPLE_COUNT_1_BIT,
            loadOp: VK_ATTACHMENT_LOAD_OP_CLEAR,
            storeOp: VK_ATTACHMENT_STORE_OP_STORE,
            stencilLoadOp: VK_ATTACHMENT_LOAD_OP_DONT_CARE,
            stencilStoreOp: VK_ATTACHMENT_STORE_OP_DONT_CARE,
            initialLayout: VK_IMAGE_LAYOUT_UNDEFINED,
            finalLayout: VK_IMAGE_LAYOUT_PRESENT_SRC_KHR
        )
        var depthAttachment = VkAttachmentDescription(
            flags: 0,
            format: depthFormat,
            samples: VK_SAMPLE_COUNT_1_BIT,
            loadOp: VK_ATTACHMENT_LOAD_OP_CLEAR,
            storeOp: VK_ATTACHMENT_STORE_OP_DONT_CARE,
            stencilLoadOp: VK_ATTACHMENT_LOAD_OP_DONT_CARE,
            stencilStoreOp: VK_ATTACHMENT_STORE_OP_DONT_CARE,
            initialLayout: VK_IMAGE_LAYOUT_UNDEFINED,
            finalLayout: VK_IMAGE_LAYOUT_DEPTH_STENCIL_ATTACHMENT_OPTIMAL
        )
        var attachments = [colorAttachment, depthAttachment]
        var colorAttachmentRef = VkAttachmentReference(
            attachment: 0,
            layout: VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL
        )
        var depthAttachmentRef = VkAttachmentReference(
            attachment: 1,
            layout: VK_IMAGE_LAYOUT_DEPTH_STENCIL_ATTACHMENT_OPTIMAL
        )
        return try attachments.withUnsafeMutableBufferPointer { attachmentsPtr in
            try withUnsafePointer(to: &colorAttachmentRef) { colorRefPtr in
                try withUnsafePointer(to: &depthAttachmentRef) { depthRefPtr in
                    var subpass = VkSubpassDescription(
                        flags: 0,
                        pipelineBindPoint: VK_PIPELINE_BIND_POINT_GRAPHICS,
                        inputAttachmentCount: 0,
                        pInputAttachments: nil,
                        colorAttachmentCount: 1,
                        pColorAttachments: colorRefPtr,
                        pResolveAttachments: nil,
                        pDepthStencilAttachment: depthRefPtr,
                        preserveAttachmentCount: 0,
                        pPreserveAttachments: nil
                    )
                    return try withUnsafePointer(to: &subpass) { subpassPtr in
                        var renderPassCreateInfo = VkRenderPassCreateInfo.create(
                            flags: 0,
                            attachmentCount: UInt32(attachmentsPtr.count),
                            pAttachments: attachmentsPtr.baseAddress,
                            subpassCount: 1,
                            pSubpasses: subpassPtr,
                            dependencyCount: 0,
                            pDependencies: nil
                        )
                        return try device.createRenderPass(&renderPassCreateInfo)
                    }
                }
            }
        }
    }

    private static func createFramebuffers(
        device: VulkanOwnedDevice,
        renderPass: VulkanOwnedRenderPass,
        imageViews: [VulkanOwnedImageView],
        depthImageView: VulkanOwnedImageView,
        extent: VkExtent2D
    ) throws -> [VulkanOwnedFramebuffer] {
        try imageViews.map { imageView in
            let imageViewRefs: [VkImageView?] = [imageView.imageView, depthImageView.imageView]
            return try imageViewRefs.withUnsafeBufferPointer { imageViewPtr in
                var framebufferCreateInfo = VkFramebufferCreateInfo.create(
                    flags: 0,
                    renderPass: renderPass.renderPass,
                    attachmentCount: UInt32(imageViewRefs.count),
                    pAttachments: imageViewPtr.baseAddress,
                    width: extent.width,
                    height: extent.height,
                    layers: 1
                )
                return try device.createFramebuffer(&framebufferCreateInfo)
            }
        }
    }

    private static func createPipeline(
        device: VulkanOwnedDevice,
        renderPass: VulkanOwnedRenderPass,
        extent: VkExtent2D,
        pipelineLayout: VulkanOwnedPipelineLayout,
        vertexInput: VertexInputDescription,
        cullMode: VkCullModeFlags = VkCullModeFlags(VK_CULL_MODE_NONE.rawValue),
        enableDepthTest: Bool = false,
        enableBlending: Bool = false,
        vertSpirv: [UInt32],
        fragSpirv: [UInt32]
    ) throws -> VulkanOwnedPipeline {
        let vertModule = try device.createShaderModule(code: vertSpirv)
        let fragModule = try device.createShaderModule(code: fragSpirv)
        let vertexEntryPoints = parseSpirvEntryPoints(vertSpirv)
        let fragmentEntryPoints = parseSpirvEntryPoints(fragSpirv)
        guard let vertexEntry = preferredEntryPointName(
            from: vertexEntryPoints,
            executionModel: spirvExecutionModelVertex,
            preferredNames: ["mainVS", "main"]
        ),
        let fragmentEntry = preferredEntryPointName(
            from: fragmentEntryPoints,
            executionModel: spirvExecutionModelFragment,
            preferredNames: ["mainPS", "main"]
        ) else {
            throw Errors.invalidSpirvData
        }

        return try vertexEntry.withCString { vertexEntryPoint in
            try fragmentEntry.withCString { fragmentEntryPoint in
                var shaderStages = [
                    VkPipelineShaderStageCreateInfo(
                        sType: VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO,
                        pNext: nil,
                        flags: 0,
                        stage: VK_SHADER_STAGE_VERTEX_BIT,
                        module: vertModule.shaderModule,
                        pName: vertexEntryPoint,
                        pSpecializationInfo: nil
                    ),
                    VkPipelineShaderStageCreateInfo(
                        sType: VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO,
                        pNext: nil,
                        flags: 0,
                        stage: VK_SHADER_STAGE_FRAGMENT_BIT,
                        module: fragModule.shaderModule,
                        pName: fragmentEntryPoint,
                        pSpecializationInfo: nil
                    )
                ]

                var inputAssembly = VkPipelineInputAssemblyStateCreateInfo(
                    sType: VK_STRUCTURE_TYPE_PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO,
                    pNext: nil,
                    flags: 0,
                    topology: VK_PRIMITIVE_TOPOLOGY_TRIANGLE_LIST,
                    primitiveRestartEnable: VK_FALSE
                )
                var viewport = VkViewport(
                    x: 0,
                    y: 0,
                    width: Float(extent.width),
                    height: Float(extent.height),
                    minDepth: 0,
                    maxDepth: 1
                )
                var scissor = VkRect2D(
                    offset: VkOffset2D(x: 0, y: 0),
                    extent: extent
                )
                var viewportState = VkPipelineViewportStateCreateInfo(
                    sType: VK_STRUCTURE_TYPE_PIPELINE_VIEWPORT_STATE_CREATE_INFO,
                    pNext: nil,
                    flags: 0,
                    viewportCount: 1,
                    pViewports: nil,
                    scissorCount: 1,
                    pScissors: nil
                )
                var rasterization = VkPipelineRasterizationStateCreateInfo(
                    sType: VK_STRUCTURE_TYPE_PIPELINE_RASTERIZATION_STATE_CREATE_INFO,
                    pNext: nil,
                    flags: 0,
                    depthClampEnable: VK_FALSE,
                    rasterizerDiscardEnable: VK_FALSE,
                    polygonMode: VK_POLYGON_MODE_FILL,
                    cullMode: cullMode,
                    frontFace: VK_FRONT_FACE_COUNTER_CLOCKWISE,
                    depthBiasEnable: VK_FALSE,
                    depthBiasConstantFactor: 0,
                    depthBiasClamp: 0,
                    depthBiasSlopeFactor: 0,
                    lineWidth: 1
                )
                var multisample = VkPipelineMultisampleStateCreateInfo(
                    sType: VK_STRUCTURE_TYPE_PIPELINE_MULTISAMPLE_STATE_CREATE_INFO,
                    pNext: nil,
                    flags: 0,
                    rasterizationSamples: VK_SAMPLE_COUNT_1_BIT,
                    sampleShadingEnable: VK_FALSE,
                    minSampleShading: 1,
                    pSampleMask: nil,
                    alphaToCoverageEnable: VK_FALSE,
                    alphaToOneEnable: VK_FALSE
                )
                var depthStencil = VkPipelineDepthStencilStateCreateInfo(
                    sType: VK_STRUCTURE_TYPE_PIPELINE_DEPTH_STENCIL_STATE_CREATE_INFO,
                    pNext: nil,
                    flags: 0,
                    depthTestEnable: enableDepthTest ? VK_TRUE : VK_FALSE,
                    depthWriteEnable: enableDepthTest ? VK_TRUE : VK_FALSE,
                    depthCompareOp: VK_COMPARE_OP_LESS,
                    depthBoundsTestEnable: VK_FALSE,
                    stencilTestEnable: VK_FALSE,
                    front: VkStencilOpState(),
                    back: VkStencilOpState(),
                    minDepthBounds: 0,
                    maxDepthBounds: 1
                )
                var colorBlendAttachment = VkPipelineColorBlendAttachmentState(
                    blendEnable: enableBlending ? VK_TRUE : VK_FALSE,
                    srcColorBlendFactor: enableBlending ? VK_BLEND_FACTOR_SRC_ALPHA : VK_BLEND_FACTOR_ONE,
                    dstColorBlendFactor: enableBlending ? VK_BLEND_FACTOR_ONE_MINUS_SRC_ALPHA : VK_BLEND_FACTOR_ZERO,
                    colorBlendOp: VK_BLEND_OP_ADD,
                    srcAlphaBlendFactor: VK_BLEND_FACTOR_ONE,
                    dstAlphaBlendFactor: enableBlending ? VK_BLEND_FACTOR_ONE_MINUS_SRC_ALPHA : VK_BLEND_FACTOR_ZERO,
                    alphaBlendOp: VK_BLEND_OP_ADD,
                    colorWriteMask: VkColorComponentFlags(
                        VK_COLOR_COMPONENT_R_BIT.rawValue |
                            VK_COLOR_COMPONENT_G_BIT.rawValue |
                            VK_COLOR_COMPONENT_B_BIT.rawValue |
                            VK_COLOR_COMPONENT_A_BIT.rawValue
                    )
                )
                var colorBlend = VkPipelineColorBlendStateCreateInfo(
                    sType: VK_STRUCTURE_TYPE_PIPELINE_COLOR_BLEND_STATE_CREATE_INFO,
                    pNext: nil,
                    flags: 0,
                    logicOpEnable: VK_FALSE,
                    logicOp: VK_LOGIC_OP_COPY,
                    attachmentCount: 1,
                    pAttachments: nil,
                    blendConstants: (0, 0, 0, 0)
                )

                return try shaderStages.withUnsafeMutableBufferPointer { stagesPtr in
                    try vertexInput.withUnsafePointers { vertexInputStatePtr in
                        try withUnsafePointer(to: &inputAssembly) { inputAssemblyPtr in
                            try withUnsafePointer(to: &viewport) { viewportPtr in
                                try withUnsafePointer(to: &scissor) { scissorPtr in
                                    viewportState.pViewports = viewportPtr
                                    viewportState.pScissors = scissorPtr
                                    return try withUnsafePointer(to: &viewportState) { viewportStatePtr in
                                        try withUnsafePointer(to: &rasterization) { rasterizationPtr in
                                            try withUnsafePointer(to: &multisample) { multisamplePtr in
                                                try withUnsafePointer(to: &depthStencil) { depthStencilPtr in
                                                    try withUnsafePointer(to: &colorBlendAttachment) { colorBlendAttachmentPtr in
                                                        colorBlend.pAttachments = colorBlendAttachmentPtr
                                                        return try withUnsafePointer(to: &colorBlend) { colorBlendPtr in
                                                            var graphicsPipelineCreateInfo = VkGraphicsPipelineCreateInfo(
                                                                sType: VK_STRUCTURE_TYPE_GRAPHICS_PIPELINE_CREATE_INFO,
                                                                pNext: nil,
                                                                flags: 0,
                                                                stageCount: UInt32(stagesPtr.count),
                                                                pStages: stagesPtr.baseAddress,
                                                                pVertexInputState: vertexInputStatePtr,
                                                                pInputAssemblyState: inputAssemblyPtr,
                                                                pTessellationState: nil,
                                                                pViewportState: viewportStatePtr,
                                                                pRasterizationState: rasterizationPtr,
                                                                pMultisampleState: multisamplePtr,
                                                                pDepthStencilState: depthStencilPtr,
                                                                pColorBlendState: colorBlendPtr,
                                                                pDynamicState: nil,
                                                                layout: pipelineLayout.pipelineLayout,
                                                                renderPass: renderPass.renderPass,
                                                                subpass: 0,
                                                                basePipelineHandle: nil,
                                                                basePipelineIndex: 0
                                                            )
                                                            return try device.createGraphicsPipeline(
                                                                createInfo: &graphicsPipelineCreateInfo
                                                            )
                                                        }
                                                    }
                                                }
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    private static func querySwapchainSupport(
        physicalDevice: VulkanPhysicalDevice,
        surface: VkSurfaceKHR
    ) throws -> (capabilities: VkSurfaceCapabilitiesKHR, formats: [VkSurfaceFormatKHR], presentModes: [VkPresentModeKHR]) {
        let capabilities = try physicalDevice.getSurfaceCapabilities(surface: surface)
        let formats = try physicalDevice.getSurfaceFormats(surface: surface)
        let presentModes = try physicalDevice.getSurfacePresentModes(surface: surface)
        guard !formats.isEmpty, !presentModes.isEmpty else {
            throw Errors.swapchainUnsupported
        }
        return (capabilities, formats, presentModes)
    }

    private static func chooseSurfaceFormat(from formats: [VkSurfaceFormatKHR]) -> VkSurfaceFormatKHR {
        if formats.count == 1 && formats[0].format == VK_FORMAT_UNDEFINED {
            return VkSurfaceFormatKHR(format: VK_FORMAT_B8G8R8A8_UNORM, colorSpace: VK_COLOR_SPACE_SRGB_NONLINEAR_KHR)
        }
        for format in formats {
            if format.format == VK_FORMAT_B8G8R8A8_UNORM && format.colorSpace == VK_COLOR_SPACE_SRGB_NONLINEAR_KHR {
                return format
            }
        }
        return formats[0]
    }

    private static func choosePresentMode(from modes: [VkPresentModeKHR]) -> VkPresentModeKHR {
        if modes.contains(VK_PRESENT_MODE_MAILBOX_KHR) {
            return VK_PRESENT_MODE_MAILBOX_KHR
        }
        return VK_PRESENT_MODE_FIFO_KHR
    }

    private static func chooseSwapExtent(
        capabilities: VkSurfaceCapabilitiesKHR,
        desiredExtent: VkExtent2D
    ) -> VkExtent2D {
        if capabilities.currentExtent.width != UInt32.max {
            return capabilities.currentExtent
        }
        let width = max(capabilities.minImageExtent.width, min(desiredExtent.width, capabilities.maxImageExtent.width))
        let height = max(capabilities.minImageExtent.height, min(desiredExtent.height, capabilities.maxImageExtent.height))
        return VkExtent2D(width: width, height: height)
    }

    private static func createDescriptorSetLayout2D(device: VulkanOwnedDevice) throws -> VulkanOwnedDescriptorSetLayout {
        var binding = VkDescriptorSetLayoutBinding(
            binding: DescriptorBindings2D.transform,
            descriptorType: VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER,
            descriptorCount: 1,
            stageFlags: VkShaderStageFlags(VK_SHADER_STAGE_VERTEX_BIT.rawValue),
            pImmutableSamplers: nil
        )
        var layout: VkDescriptorSetLayout?
        return try withUnsafePointer(to: &binding) { bindingPtr in
            var createInfo = VkDescriptorSetLayoutCreateInfo(
                sType: VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO,
                pNext: nil,
                flags: 0,
                bindingCount: 1,
                pBindings: bindingPtr
            )
            try VulkanEngine.vulkanResultCheck(vkCreateDescriptorSetLayout(device.device, &createInfo, nil, &layout))
            return VulkanOwnedDescriptorSetLayout(device: device.device, descriptorSetLayout: layout!)
        }
    }

    private static func createDescriptorSetLayout3D(device: VulkanOwnedDevice) throws -> VulkanOwnedDescriptorSetLayout {
        var bindings = [
            VkDescriptorSetLayoutBinding(
                binding: DescriptorBindings3D.transform,
                descriptorType: VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER,
                descriptorCount: 1,
                stageFlags: VkShaderStageFlags(VK_SHADER_STAGE_VERTEX_BIT.rawValue),
                pImmutableSamplers: nil
            ),
            VkDescriptorSetLayoutBinding(
                binding: DescriptorBindings3D.model,
                descriptorType: VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER,
                descriptorCount: 1,
                stageFlags: VkShaderStageFlags(VK_SHADER_STAGE_VERTEX_BIT.rawValue),
                pImmutableSamplers: nil
            ),
            VkDescriptorSetLayoutBinding(
                binding: DescriptorBindings3D.view,
                descriptorType: VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER,
                descriptorCount: 1,
                stageFlags: VkShaderStageFlags(VK_SHADER_STAGE_VERTEX_BIT.rawValue),
                pImmutableSamplers: nil
            )
        ]
        var layout: VkDescriptorSetLayout?
        return try bindings.withUnsafeMutableBufferPointer { bindingsPtr in
            var createInfo = VkDescriptorSetLayoutCreateInfo(
                sType: VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO,
                pNext: nil,
                flags: 0,
                bindingCount: UInt32(bindingsPtr.count),
                pBindings: bindingsPtr.baseAddress
            )
            try VulkanEngine.vulkanResultCheck(vkCreateDescriptorSetLayout(device.device, &createInfo, nil, &layout))
            return VulkanOwnedDescriptorSetLayout(device: device.device, descriptorSetLayout: layout!)
        }
    }

    private static func createPipelineLayout(
        device: VulkanOwnedDevice,
        descriptorSetLayout: VulkanOwnedDescriptorSetLayout,
        pushConstantRange: VkPushConstantRange? = nil
    ) throws -> VulkanOwnedPipelineLayout {
        let layouts: [VkDescriptorSetLayout?] = [descriptorSetLayout.descriptorSetLayout]
        return try layouts.withUnsafeBufferPointer { layoutsPtr in
            if var pushConstantRange {
                return try withUnsafePointer(to: &pushConstantRange) { pushConstantRangePtr in
                    var createInfo = VkPipelineLayoutCreateInfo.create(
                        flags: 0,
                        setLayoutCount: UInt32(layoutsPtr.count),
                        pSetLayouts: layoutsPtr.baseAddress,
                        pushConstantRangeCount: 1,
                        pPushConstantRanges: pushConstantRangePtr
                    )
                    return try device.createPipelineLayout(&createInfo)
                }
            }

            var createInfo = VkPipelineLayoutCreateInfo.create(
                flags: 0,
                setLayoutCount: UInt32(layoutsPtr.count),
                pSetLayouts: layoutsPtr.baseAddress,
                pushConstantRangeCount: 0,
                pPushConstantRanges: nil
            )
            return try device.createPipelineLayout(&createInfo)
        }
    }

    private static func createDescriptorPool(
        device: VulkanOwnedDevice,
        maxSets: UInt32,
        poolSizes: [VkDescriptorPoolSize]
    ) throws -> VulkanOwnedDescriptorPool {
        var pool: VkDescriptorPool?
        return try poolSizes.withUnsafeBufferPointer { poolSizesPtr in
            var createInfo = VkDescriptorPoolCreateInfo(
                sType: VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO,
                pNext: nil,
                flags: 0,
                maxSets: maxSets,
                poolSizeCount: UInt32(poolSizesPtr.count),
                pPoolSizes: poolSizesPtr.baseAddress
            )
            try VulkanEngine.vulkanResultCheck(vkCreateDescriptorPool(device.device, &createInfo, nil, &pool))
            return VulkanOwnedDescriptorPool(device: device.device, descriptorPool: pool!)
        }
    }

    private static func allocateDescriptorSet(
        device: VulkanOwnedDevice,
        descriptorPool: VulkanOwnedDescriptorPool,
        layout: VulkanOwnedDescriptorSetLayout
    ) throws -> VkDescriptorSet {
        var set: VkDescriptorSet?
        var layoutHandle: VkDescriptorSetLayout? = layout.descriptorSetLayout
        return try withUnsafePointer(to: &layoutHandle) { layoutPtr in
            var allocInfo = VkDescriptorSetAllocateInfo(
                sType: VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO,
                pNext: nil,
                descriptorPool: descriptorPool.descriptorPool,
                descriptorSetCount: 1,
                pSetLayouts: layoutPtr
            )
            try VulkanEngine.vulkanResultCheck(vkAllocateDescriptorSets(device.device, &allocInfo, &set))
            return set!
        }
    }

    private static func updateDescriptorSet(
        device: VulkanOwnedDevice,
        descriptorSet: VkDescriptorSet,
        binding: UInt32,
        buffer: VulkanOwnedBuffer,
        range: VkDeviceSize
    ) {
        var bufferInfo = VkDescriptorBufferInfo(
            buffer: buffer.buffer,
            offset: 0,
            range: range
        )
        withUnsafePointer(to: &bufferInfo) { bufferInfoPtr in
            var write = VkWriteDescriptorSet(
                sType: VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET,
                pNext: nil,
                dstSet: descriptorSet,
                dstBinding: binding,
                dstArrayElement: 0,
                descriptorCount: 1,
                descriptorType: VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER,
                pImageInfo: nil,
                pBufferInfo: bufferInfoPtr,
                pTexelBufferView: nil
            )
            vkUpdateDescriptorSets(device.device, 1, &write, 0, nil)
        }
    }

    private static func createUniformBuffer2D(
        device: VulkanOwnedDevice,
        physicalDevice: VulkanPhysicalDevice
    ) throws -> (VulkanOwnedBuffer, VulkanOwnedDeviceMemory) {
        let identity: [Float] = [
            1, 0, 0, 0,
            0, 1, 0, 0,
            0, 0, 1, 0,
            0, 0, 0, 1
        ]
        return try createUniformBuffer(device: device, physicalDevice: physicalDevice, data: identity)
    }

    private static func createUniformBuffer3D(
        device: VulkanOwnedDevice,
        physicalDevice: VulkanPhysicalDevice
    ) throws -> (VulkanOwnedBuffer, VulkanOwnedDeviceMemory) {
        let identity: [Float] = [
            1, 0, 0, 0,
            0, 1, 0, 0,
            0, 0, 1, 0,
            0, 0, 0, 1
        ]
        return try createUniformBuffer(device: device, physicalDevice: physicalDevice, data: identity)
    }

    private static func createUniformBuffer<T>(
        device: VulkanOwnedDevice,
        physicalDevice: VulkanPhysicalDevice,
        data: [T]
    ) throws -> (VulkanOwnedBuffer, VulkanOwnedDeviceMemory) {
        let bufferSize = VkDeviceSize(MemoryLayout<T>.stride * data.count)
        var bufferCreateInfo = VkBufferCreateInfo(
            sType: VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO,
            pNext: nil,
            flags: 0,
            size: bufferSize,
            usage: VkBufferUsageFlags(VK_BUFFER_USAGE_UNIFORM_BUFFER_BIT.rawValue),
            sharingMode: VK_SHARING_MODE_EXCLUSIVE,
            queueFamilyIndexCount: 0,
            pQueueFamilyIndices: nil
        )
        let buffer = try device.createBuffer(&bufferCreateInfo)
        let requirements = device.getBufferMemoryRequirements(buffer)
        let memoryTypeIndex = try findMemoryTypeIndex(
            physicalDevice,
            typeBits: requirements.memoryTypeBits,
            properties: VkMemoryPropertyFlags(
                VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT.rawValue |
                VK_MEMORY_PROPERTY_HOST_COHERENT_BIT.rawValue
            )
        )
        var allocInfo = VkMemoryAllocateInfo.create(
            allocationSize: requirements.size,
            memoryTypeIndex: memoryTypeIndex
        )
        let memory = try device.allocateMemory(&allocInfo)
        try device.bindBufferMemory(buffer: buffer, memory: memory)
        let mapped = try device.mapMemory(memory, offset: 0, size: bufferSize)
        data.withUnsafeBytes { bytes in
            mapped.copyMemory(from: bytes.baseAddress!, byteCount: bytes.count)
        }
        device.unmapMemory(memory)
        return (buffer, memory)
    }

    private struct VertexInputDescription {
        let bindings: [VkVertexInputBindingDescription]
        let attributes: [VkVertexInputAttributeDescription]

        func withUnsafePointers<Result>(
            _ body: (UnsafePointer<VkPipelineVertexInputStateCreateInfo>) throws -> Result
        ) throws -> Result {
            try bindings.withUnsafeBufferPointer { bindingsPtr in
                try attributes.withUnsafeBufferPointer { attributesPtr in
                    var vertexInputState = VkPipelineVertexInputStateCreateInfo(
                        sType: VK_STRUCTURE_TYPE_PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO,
                        pNext: nil,
                        flags: 0,
                        vertexBindingDescriptionCount: UInt32(bindingsPtr.count),
                        pVertexBindingDescriptions: bindingsPtr.baseAddress,
                        vertexAttributeDescriptionCount: UInt32(attributesPtr.count),
                        pVertexAttributeDescriptions: attributesPtr.baseAddress
                    )
                    return try withUnsafePointer(to: &vertexInputState) { vertexInputStatePtr in
                        try body(vertexInputStatePtr)
                    }
                }
            }
        }
    }

    private static func vertexInput2D() -> VertexInputDescription {
        let binding = VkVertexInputBindingDescription(
            binding: 0,
            stride: UInt32(MemoryLayout<Vertex2D>.stride),
            inputRate: VK_VERTEX_INPUT_RATE_VERTEX
        )
        let positionOffset = UInt32(MemoryLayout<Vertex2D>.offset(of: \.position) ?? 0)
        let colorOffset = UInt32(MemoryLayout<Vertex2D>.offset(of: \.color) ?? 0)
        let attributes = [
            VkVertexInputAttributeDescription(
                location: 0,
                binding: 0,
                format: VK_FORMAT_R32G32_SFLOAT,
                offset: positionOffset
            ),
            VkVertexInputAttributeDescription(
                location: 1,
                binding: 0,
                format: VK_FORMAT_R32G32B32A32_SFLOAT,
                offset: colorOffset
            )
        ]
        return VertexInputDescription(bindings: [binding], attributes: attributes)
    }

    private static func vertexInput3D() -> VertexInputDescription {
        let binding = VkVertexInputBindingDescription(
            binding: 0,
            stride: UInt32(MemoryLayout<Vertex3D>.stride),
            inputRate: VK_VERTEX_INPUT_RATE_VERTEX
        )
        let positionOffset: UInt32 = 0
        let colorOffset = UInt32(MemoryLayout<Vertex3D>.offset(of: \.color) ?? 0)
        let attributes = [
            VkVertexInputAttributeDescription(
                location: 0,
                binding: 0,
                format: VK_FORMAT_R32G32B32_SFLOAT,
                offset: positionOffset
            ),
            VkVertexInputAttributeDescription(
                location: 1,
                binding: 0,
                format: VK_FORMAT_R8G8B8A8_UNORM,
                offset: colorOffset
            )
        ]
        return VertexInputDescription(bindings: [binding], attributes: attributes)
    }

    func uploadVertices2D(_ vertices: [Vertex2D]) throws -> (buffer: VulkanOwnedBuffer, memory: VulkanOwnedDeviceMemory) {
        try uploadVertices(
            vertices,
            pipeline: mode2D.pipeline,
            pipelineLayout: mode2D.pipelineLayout,
            descriptorSet: mode2D.descriptorSet
        )
    }

    func createVertexBuffer2D(_ vertices: [Vertex2D]) throws -> (buffer: VulkanOwnedBuffer, memory: VulkanOwnedDeviceMemory) {
        try createVertexBuffer(vertices)
    }

    func createVertexBuffer3D(_ vertices: [Vertex3D]) throws -> (buffer: VulkanOwnedBuffer, memory: VulkanOwnedDeviceMemory) {
        try createVertexBuffer(vertices)
    }

    func createVertexBuffer2DCapacity(_ vertexCapacity: Int) throws -> (buffer: VulkanOwnedBuffer, memory: VulkanOwnedDeviceMemory) {
        guard vertexCapacity > 0 else {
            throw Errors.emptyVertexData
        }
        let byteCount = VkDeviceSize(MemoryLayout<Vertex2D>.stride * vertexCapacity)
        return try createBufferWithMemory(size: byteCount)
    }

    func createVertexBuffer3DCapacity(_ vertexCapacity: Int) throws -> (buffer: VulkanOwnedBuffer, memory: VulkanOwnedDeviceMemory) {
        guard vertexCapacity > 0 else {
            throw Errors.emptyVertexData
        }
        let byteCount = VkDeviceSize(MemoryLayout<Vertex3D>.stride * vertexCapacity)
        return try createBufferWithMemory(size: byteCount)
    }

    func updateVertexBuffer2D(
        _ vertices: [Vertex2D],
        buffer: VulkanOwnedBuffer,
        memory: VulkanOwnedDeviceMemory,
        capacity: Int
    ) throws -> UInt32 {
        guard capacity > 0 else {
            throw Errors.emptyVertexData
        }
        if vertices.count > capacity {
            throw Errors.vertexDataExceedsCapacity
        }
        guard !vertices.isEmpty else {
            return 0
        }

        let copySize = VkDeviceSize(MemoryLayout<Vertex2D>.stride * vertices.count)
        let mapped = try device.mapMemory(memory, offset: 0, size: copySize)
        vertices.withUnsafeBytes { bytes in
            mapped.copyMemory(from: bytes.baseAddress!, byteCount: bytes.count)
        }
        device.unmapMemory(memory)
        _ = buffer
        return UInt32(vertices.count)
    }

    func updateVertexBuffer3D(
        _ vertices: [Vertex3D],
        buffer: VulkanOwnedBuffer,
        memory: VulkanOwnedDeviceMemory,
        capacity: Int
    ) throws -> UInt32 {
        guard capacity > 0 else {
            throw Errors.emptyVertexData
        }
        if vertices.count > capacity {
            throw Errors.vertexDataExceedsCapacity
        }
        guard !vertices.isEmpty else {
            return 0
        }

        let copySize = VkDeviceSize(MemoryLayout<Vertex3D>.stride * vertices.count)
        let mapped = try device.mapMemory(memory, offset: 0, size: copySize)
        vertices.withUnsafeBytes { bytes in
            mapped.copyMemory(from: bytes.baseAddress!, byteCount: bytes.count)
        }
        device.unmapMemory(memory)
        _ = buffer
        return UInt32(vertices.count)
    }

    func drawBatches2D(
        _ batches: [DrawBatch2D],
        framebufferIndex: Int,
        waitSemaphores: [VkSemaphore],
        signalSemaphores: [VkSemaphore]
    ) throws {
        let internalBatches = batches.map { ($0.buffer, $0.vertexCount) }
        try drawVertexBuffers(
            buffers: internalBatches,
            pipeline: mode2D.pipeline,
            pipelineLayout: mode2D.pipelineLayout,
            descriptorSet: mode2D.descriptorSet,
            framebufferIndex: framebufferIndex,
            waitSemaphores: waitSemaphores,
            signalSemaphores: signalSemaphores
        )
    }

    func drawBatches3D(
        _ batches: [DrawBatch3D],
        framebufferIndex: Int,
        waitSemaphores: [VkSemaphore],
        signalSemaphores: [VkSemaphore]
    ) throws {
        guard let pipeline = mode3D.pipeline else {
            throw Errors.missing3DPipeline
        }
        try drawVertexBuffers3D(
            buffers: batches.map { ($0.buffer, $0.vertexCount, $0.modelOffset) },
            pipeline: pipeline,
            pipelineLayout: mode3D.pipelineLayout,
            descriptorSet: mode3D.descriptorSet,
            framebufferIndex: framebufferIndex,
            waitSemaphores: waitSemaphores,
            signalSemaphores: signalSemaphores
        )
    }

    func drawBatches3DAnd2D(
        batches3D: [DrawBatch3D],
        batches2D: [DrawBatch2D],
        framebufferIndex: Int,
        waitSemaphores: [VkSemaphore],
        signalSemaphores: [VkSemaphore],
        captureFrame: Bool = false
    ) throws -> CapturedFrame? {
        guard let pipeline3D = mode3D.pipeline else {
            throw Errors.missing3DPipeline
        }
        guard framebufferIndex >= 0 && framebufferIndex < swapchainFramebuffers.count else {
            throw Errors.invalidFramebufferIndex
        }

        try device.waitForFences([inFlightFence.fence], waitAll: true, timeout: UInt64.max)
        try device.resetFences([inFlightFence.fence])
        try VulkanEngine.vulkanResultCheck(vkResetCommandBuffer(commandBuffer.commandBuffer, 0))
        try commandBuffer.begin()

        var clearValues = [
            VkClearValue(color: VkClearColorValue(float32: (clearColor.x, clearColor.y, clearColor.z, clearColor.w))),
            VkClearValue(depthStencil: VkClearDepthStencilValue(depth: 1, stencil: 0))
        ]
        var renderPassBeginInfo = VkRenderPassBeginInfo(
            sType: VK_STRUCTURE_TYPE_RENDER_PASS_BEGIN_INFO,
            pNext: nil,
            renderPass: renderPass.renderPass,
            framebuffer: swapchainFramebuffers[framebufferIndex].framebuffer,
            renderArea: VkRect2D(offset: VkOffset2D(x: 0, y: 0), extent: swapchainExtent),
            clearValueCount: UInt32(clearValues.count),
            pClearValues: nil
        )
        clearValues.withUnsafeBufferPointer { clearPtr in
            renderPassBeginInfo.pClearValues = clearPtr.baseAddress
            commandBuffer.beginRenderPass(renderPassBeginInfo: &renderPassBeginInfo, contents: VK_SUBPASS_CONTENTS_INLINE)
        }

        recordDrawBatches3D(
            batches3D.map { ($0.buffer, $0.vertexCount, $0.modelOffset) },
            pipeline: pipeline3D,
            pipelineLayout: mode3D.pipelineLayout,
            descriptorSet: mode3D.descriptorSet
        )
        recordDrawBatches(
            batches2D.map { ($0.buffer, $0.vertexCount) },
            pipeline: mode2D.pipeline,
            pipelineLayout: mode2D.pipelineLayout,
            descriptorSet: mode2D.descriptorSet
        )

        commandBuffer.endRenderPass()
        let capturedFrameResources: (buffer: VulkanOwnedBuffer, memory: VulkanOwnedDeviceMemory)?
        if captureFrame {
            capturedFrameResources = try recordSwapchainReadback(framebufferIndex: framebufferIndex)
        } else {
            capturedFrameResources = nil
        }
        try commandBuffer.end()
        try submitRecordedFrame(waitSemaphores: waitSemaphores, signalSemaphores: signalSemaphores)
        guard let capturedFrameResources else {
            return nil
        }

        try device.waitForFences([inFlightFence.fence], waitAll: true, timeout: UInt64.max)
        return try mapCapturedFrame(
            buffer: capturedFrameResources.buffer,
            memory: capturedFrameResources.memory
        )
    }

    func uploadVertices3D(_ vertices: [Vertex3D]) throws -> (buffer: VulkanOwnedBuffer, memory: VulkanOwnedDeviceMemory) {
        guard let pipeline = mode3D.pipeline else {
            throw Errors.missing3DPipeline
        }
        return try uploadVertices(
            vertices,
            pipeline: pipeline,
            pipelineLayout: mode3D.pipelineLayout,
            descriptorSet: mode3D.descriptorSet
        )
    }

    func uploadVertices2D(_ vertices: [Vertex2D], framebufferIndex: Int) throws -> (buffer: VulkanOwnedBuffer, memory: VulkanOwnedDeviceMemory) {
        try uploadVertices(
            vertices,
            pipeline: mode2D.pipeline,
            pipelineLayout: mode2D.pipelineLayout,
            descriptorSet: mode2D.descriptorSet,
            framebufferIndex: framebufferIndex
        )
    }

    func uploadVertices2D(
        _ vertices: [Vertex2D],
        framebufferIndex: Int,
        waitSemaphores: [VkSemaphore],
        signalSemaphores: [VkSemaphore]
    ) throws -> (buffer: VulkanOwnedBuffer, memory: VulkanOwnedDeviceMemory) {
        try uploadVertices(
            vertices,
            pipeline: mode2D.pipeline,
            pipelineLayout: mode2D.pipelineLayout,
            descriptorSet: mode2D.descriptorSet,
            framebufferIndex: framebufferIndex,
            waitSemaphores: waitSemaphores,
            signalSemaphores: signalSemaphores
        )
    }

    func uploadVertices3D(_ vertices: [Vertex3D], framebufferIndex: Int) throws -> (buffer: VulkanOwnedBuffer, memory: VulkanOwnedDeviceMemory) {
        guard let pipeline = mode3D.pipeline else {
            throw Errors.missing3DPipeline
        }
        return try uploadVertices(
            vertices,
            pipeline: pipeline,
            pipelineLayout: mode3D.pipelineLayout,
            descriptorSet: mode3D.descriptorSet,
            framebufferIndex: framebufferIndex
        )
    }

    func uploadVertices3D(
        _ vertices: [Vertex3D],
        framebufferIndex: Int,
        waitSemaphores: [VkSemaphore],
        signalSemaphores: [VkSemaphore]
    ) throws -> (buffer: VulkanOwnedBuffer, memory: VulkanOwnedDeviceMemory) {
        guard let pipeline = mode3D.pipeline else {
            throw Errors.missing3DPipeline
        }
        return try uploadVertices(
            vertices,
            pipeline: pipeline,
            pipelineLayout: mode3D.pipelineLayout,
            descriptorSet: mode3D.descriptorSet,
            framebufferIndex: framebufferIndex,
            waitSemaphores: waitSemaphores,
            signalSemaphores: signalSemaphores
        )
    }

    func updateTransform2D(_ transform: simd_float4x4) throws {
        let size = VkDeviceSize(MemoryLayout<simd_float4x4>.size)
        let mapped = try device.mapMemory(mode2D.uniformMemory, offset: 0, size: size)
        var local = transform
        withUnsafeBytes(of: &local) { bytes in
            mapped.copyMemory(from: bytes.baseAddress!, byteCount: bytes.count)
        }
        device.unmapMemory(mode2D.uniformMemory)
    }

    func updateTransform3D(_ transform: simd_float4x4) throws {
        let size = VkDeviceSize(MemoryLayout<simd_float4x4>.size)
        let mapped = try device.mapMemory(mode3D.transformUniformMemory, offset: 0, size: size)
        var local = transform
        withUnsafeBytes(of: &local) { bytes in
            mapped.copyMemory(from: bytes.baseAddress!, byteCount: bytes.count)
        }
        device.unmapMemory(mode3D.transformUniformMemory)
    }

    func updateModel3D(_ model: simd_float4x4) throws {
        let size = VkDeviceSize(MemoryLayout<simd_float4x4>.size)
        let mapped = try device.mapMemory(mode3D.modelUniformMemory, offset: 0, size: size)
        var local = model
        withUnsafeBytes(of: &local) { bytes in
            mapped.copyMemory(from: bytes.baseAddress!, byteCount: bytes.count)
        }
        device.unmapMemory(mode3D.modelUniformMemory)
    }

    func updateView3D(_ view: simd_float4x4) throws {
        let size = VkDeviceSize(MemoryLayout<simd_float4x4>.size)
        let mapped = try device.mapMemory(mode3D.viewUniformMemory, offset: 0, size: size)
        var local = view
        withUnsafeBytes(of: &local) { bytes in
            mapped.copyMemory(from: bytes.baseAddress!, byteCount: bytes.count)
        }
        device.unmapMemory(mode3D.viewUniformMemory)
    }

    func setClearColor(_ color: SIMD4<Float>) {
        clearColor = color
    }

    private func uploadVertices<T>(
        _ vertices: [T],
        pipeline: VulkanOwnedPipeline,
        pipelineLayout: VulkanOwnedPipelineLayout,
        descriptorSet: VkDescriptorSet?,
        framebufferIndex: Int = 0,
        waitSemaphores: [VkSemaphore] = [],
        signalSemaphores: [VkSemaphore] = []
    ) throws -> (buffer: VulkanOwnedBuffer, memory: VulkanOwnedDeviceMemory) {
        let (buffer, memory) = try createVertexBuffer(vertices)
        try drawVertexBuffers(
            buffers: [(buffer, UInt32(vertices.count))],
            pipeline: pipeline,
            pipelineLayout: pipelineLayout,
            descriptorSet: descriptorSet,
            framebufferIndex: framebufferIndex,
            waitSemaphores: waitSemaphores,
            signalSemaphores: signalSemaphores
        )
        return (buffer, memory)
    }

    private func createVertexBuffer<T>(_ vertices: [T]) throws -> (buffer: VulkanOwnedBuffer, memory: VulkanOwnedDeviceMemory) {
        if vertices.isEmpty {
            throw Errors.emptyVertexData
        }
        let bufferSize = VkDeviceSize(MemoryLayout<T>.stride * vertices.count)
        let (buffer, memory) = try createBufferWithMemory(size: bufferSize)

        let mapped = try device.mapMemory(memory, offset: 0, size: bufferSize)
        vertices.withUnsafeBytes { bytes in
            mapped.copyMemory(from: bytes.baseAddress!, byteCount: bytes.count)
        }
        device.unmapMemory(memory)
        return (buffer, memory)
    }

    private func createBufferWithMemory(
        size bufferSize: VkDeviceSize,
        usage: VkBufferUsageFlags = VkBufferUsageFlags(VK_BUFFER_USAGE_VERTEX_BUFFER_BIT.rawValue)
    ) throws -> (buffer: VulkanOwnedBuffer, memory: VulkanOwnedDeviceMemory) {
        var bufferCreateInfo = VkBufferCreateInfo(
            sType: VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO,
            pNext: nil,
            flags: 0,
            size: bufferSize,
            usage: usage,
            sharingMode: VK_SHARING_MODE_EXCLUSIVE,
            queueFamilyIndexCount: 0,
            pQueueFamilyIndices: nil
        )
        let buffer = try device.createBuffer(&bufferCreateInfo)
        let requirements = device.getBufferMemoryRequirements(buffer)
        let memoryTypeIndex = try VulkanEngine.findMemoryTypeIndex(
            physicalDevice,
            typeBits: requirements.memoryTypeBits,
            properties: VkMemoryPropertyFlags(
                VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT.rawValue |
                VK_MEMORY_PROPERTY_HOST_COHERENT_BIT.rawValue
            )
        )
        var allocInfo = VkMemoryAllocateInfo.create(
            allocationSize: requirements.size,
            memoryTypeIndex: memoryTypeIndex
        )
        let memory = try device.allocateMemory(&allocInfo)
        try device.bindBufferMemory(buffer: buffer, memory: memory)
        return (buffer, memory)
    }

    private func drawVertexBuffers(
        buffers: [(buffer: VulkanOwnedBuffer, vertexCount: UInt32)],
        pipeline: VulkanOwnedPipeline,
        pipelineLayout: VulkanOwnedPipelineLayout,
        descriptorSet: VkDescriptorSet?,
        framebufferIndex: Int,
        waitSemaphores: [VkSemaphore],
        signalSemaphores: [VkSemaphore]
    ) throws {
        guard framebufferIndex >= 0 && framebufferIndex < swapchainFramebuffers.count else {
            throw Errors.invalidFramebufferIndex
        }

        try device.waitForFences([inFlightFence.fence], waitAll: true, timeout: UInt64.max)
        try device.resetFences([inFlightFence.fence])
        try VulkanEngine.vulkanResultCheck(vkResetCommandBuffer(commandBuffer.commandBuffer, 0))
        try commandBuffer.begin()
        var clearValues = [
            VkClearValue(color: VkClearColorValue(float32: (clearColor.x, clearColor.y, clearColor.z, clearColor.w))),
            VkClearValue(depthStencil: VkClearDepthStencilValue(depth: 1, stencil: 0))
        ]
        var renderPassBeginInfo = VkRenderPassBeginInfo(
            sType: VK_STRUCTURE_TYPE_RENDER_PASS_BEGIN_INFO,
            pNext: nil,
            renderPass: renderPass.renderPass,
            framebuffer: swapchainFramebuffers[framebufferIndex].framebuffer,
            renderArea: VkRect2D(offset: VkOffset2D(x: 0, y: 0), extent: swapchainExtent),
            clearValueCount: UInt32(clearValues.count),
            pClearValues: nil
        )
        clearValues.withUnsafeBufferPointer { clearPtr in
            renderPassBeginInfo.pClearValues = clearPtr.baseAddress
            commandBuffer.beginRenderPass(renderPassBeginInfo: &renderPassBeginInfo, contents: VK_SUBPASS_CONTENTS_INLINE)
        }
        recordDrawBatches(
            buffers,
            pipeline: pipeline,
            pipelineLayout: pipelineLayout,
            descriptorSet: descriptorSet
        )
        commandBuffer.endRenderPass()
        try commandBuffer.end()
        try submitRecordedFrame(waitSemaphores: waitSemaphores, signalSemaphores: signalSemaphores)
    }

    private func drawVertexBuffers3D(
        buffers: [(buffer: VulkanOwnedBuffer, vertexCount: UInt32, modelOffset: SIMD4<Float>)],
        pipeline: VulkanOwnedPipeline,
        pipelineLayout: VulkanOwnedPipelineLayout,
        descriptorSet: VkDescriptorSet?,
        framebufferIndex: Int,
        waitSemaphores: [VkSemaphore],
        signalSemaphores: [VkSemaphore]
    ) throws {
        guard framebufferIndex >= 0 && framebufferIndex < swapchainFramebuffers.count else {
            throw Errors.invalidFramebufferIndex
        }

        try device.waitForFences([inFlightFence.fence], waitAll: true, timeout: UInt64.max)
        try device.resetFences([inFlightFence.fence])
        try VulkanEngine.vulkanResultCheck(vkResetCommandBuffer(commandBuffer.commandBuffer, 0))
        try commandBuffer.begin()
        var clearValues = [
            VkClearValue(color: VkClearColorValue(float32: (clearColor.x, clearColor.y, clearColor.z, clearColor.w))),
            VkClearValue(depthStencil: VkClearDepthStencilValue(depth: 1, stencil: 0))
        ]
        var renderPassBeginInfo = VkRenderPassBeginInfo(
            sType: VK_STRUCTURE_TYPE_RENDER_PASS_BEGIN_INFO,
            pNext: nil,
            renderPass: renderPass.renderPass,
            framebuffer: swapchainFramebuffers[framebufferIndex].framebuffer,
            renderArea: VkRect2D(offset: VkOffset2D(x: 0, y: 0), extent: swapchainExtent),
            clearValueCount: UInt32(clearValues.count),
            pClearValues: nil
        )
        clearValues.withUnsafeBufferPointer { clearPtr in
            renderPassBeginInfo.pClearValues = clearPtr.baseAddress
            commandBuffer.beginRenderPass(renderPassBeginInfo: &renderPassBeginInfo, contents: VK_SUBPASS_CONTENTS_INLINE)
        }
        recordDrawBatches3D(
            buffers,
            pipeline: pipeline,
            pipelineLayout: pipelineLayout,
            descriptorSet: descriptorSet
        )
        commandBuffer.endRenderPass()
        try commandBuffer.end()
        try submitRecordedFrame(waitSemaphores: waitSemaphores, signalSemaphores: signalSemaphores)
    }

    private func recordDrawBatches(
        _ buffers: [(buffer: VulkanOwnedBuffer, vertexCount: UInt32)],
        pipeline: VulkanOwnedPipeline,
        pipelineLayout: VulkanOwnedPipelineLayout,
        descriptorSet: VkDescriptorSet?
    ) {
        commandBuffer.bindPipeline(bindPoint: VK_PIPELINE_BIND_POINT_GRAPHICS, pipeline: pipeline.pipeline)
        if let descriptorSet {
            var set: VkDescriptorSet? = descriptorSet
            withUnsafePointer(to: &set) { setPtr in
                vkCmdBindDescriptorSets(
                    commandBuffer.commandBuffer,
                    VK_PIPELINE_BIND_POINT_GRAPHICS,
                    pipelineLayout.pipelineLayout,
                    0,
                    1,
                    setPtr,
                    0,
                    nil
                )
            }
        }

        for batch in buffers where batch.vertexCount > 0 {
            var vertexBuffer: VkBuffer? = batch.buffer.buffer
            var offset: VkDeviceSize = 0
            withUnsafePointer(to: &vertexBuffer) { bufferPtr in
                withUnsafePointer(to: &offset) { offsetPtr in
                    vkCmdBindVertexBuffers(commandBuffer.commandBuffer, 0, 1, bufferPtr, offsetPtr)
                }
            }
            commandBuffer.draw(vertexCount: batch.vertexCount)
        }
    }

    private func recordDrawBatches3D(
        _ buffers: [(buffer: VulkanOwnedBuffer, vertexCount: UInt32, modelOffset: SIMD4<Float>)],
        pipeline: VulkanOwnedPipeline,
        pipelineLayout: VulkanOwnedPipelineLayout,
        descriptorSet: VkDescriptorSet?
    ) {
        commandBuffer.bindPipeline(bindPoint: VK_PIPELINE_BIND_POINT_GRAPHICS, pipeline: pipeline.pipeline)
        if let descriptorSet {
            var set: VkDescriptorSet? = descriptorSet
            withUnsafePointer(to: &set) { setPtr in
                vkCmdBindDescriptorSets(
                    commandBuffer.commandBuffer,
                    VK_PIPELINE_BIND_POINT_GRAPHICS,
                    pipelineLayout.pipelineLayout,
                    0,
                    1,
                    setPtr,
                    0,
                    nil
                )
            }
        }

        for batch in buffers where batch.vertexCount > 0 {
            var modelOffset = batch.modelOffset
            withUnsafeBytes(of: &modelOffset) { modelOffsetBytes in
                vkCmdPushConstants(
                    commandBuffer.commandBuffer,
                    pipelineLayout.pipelineLayout,
                    VkShaderStageFlags(VK_SHADER_STAGE_VERTEX_BIT.rawValue),
                    0,
                    UInt32(modelOffsetBytes.count),
                    modelOffsetBytes.baseAddress
                )
            }

            var vertexBuffer: VkBuffer? = batch.buffer.buffer
            var offset: VkDeviceSize = 0
            withUnsafePointer(to: &vertexBuffer) { bufferPtr in
                withUnsafePointer(to: &offset) { offsetPtr in
                    vkCmdBindVertexBuffers(commandBuffer.commandBuffer, 0, 1, bufferPtr, offsetPtr)
                }
            }
            commandBuffer.draw(vertexCount: batch.vertexCount)
        }
    }

    private func recordSwapchainReadback(
        framebufferIndex: Int
    ) throws -> (buffer: VulkanOwnedBuffer, memory: VulkanOwnedDeviceMemory) {
        guard framebufferIndex >= 0 && framebufferIndex < swapchainImages.count else {
            throw Errors.invalidFramebufferIndex
        }

        let width = Int(swapchainExtent.width)
        let height = Int(swapchainExtent.height)
        let bytesPerRow = width * 4
        let byteCount = VkDeviceSize(bytesPerRow * height)
        let resources = try createBufferWithMemory(
            size: byteCount,
            usage: VkBufferUsageFlags(VK_BUFFER_USAGE_TRANSFER_DST_BIT.rawValue)
        )

        var toTransferBarrier = VkImageMemoryBarrier(
            sType: VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER,
            pNext: nil,
            srcAccessMask: VkAccessFlags(VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT.rawValue),
            dstAccessMask: VkAccessFlags(VK_ACCESS_TRANSFER_READ_BIT.rawValue),
            oldLayout: VK_IMAGE_LAYOUT_PRESENT_SRC_KHR,
            newLayout: VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL,
            srcQueueFamilyIndex: VK_QUEUE_FAMILY_IGNORED,
            dstQueueFamilyIndex: VK_QUEUE_FAMILY_IGNORED,
            image: swapchainImages[framebufferIndex],
            subresourceRange: VkImageSubresourceRange(
                aspectMask: VkImageAspectFlags(VK_IMAGE_ASPECT_COLOR_BIT.rawValue),
                baseMipLevel: 0,
                levelCount: 1,
                baseArrayLayer: 0,
                layerCount: 1
            )
        )
        vkCmdPipelineBarrier(
            commandBuffer.commandBuffer,
            VkPipelineStageFlags(VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT.rawValue),
            VkPipelineStageFlags(VK_PIPELINE_STAGE_TRANSFER_BIT.rawValue),
            0,
            0,
            nil,
            0,
            nil,
            1,
            &toTransferBarrier
        )

        var imageSubresource = VkImageSubresourceLayers(
            aspectMask: VkImageAspectFlags(VK_IMAGE_ASPECT_COLOR_BIT.rawValue),
            mipLevel: 0,
            baseArrayLayer: 0,
            layerCount: 1
        )
        var copyRegion = VkBufferImageCopy(
            bufferOffset: 0,
            bufferRowLength: 0,
            bufferImageHeight: 0,
            imageSubresource: imageSubresource,
            imageOffset: VkOffset3D(x: 0, y: 0, z: 0),
            imageExtent: VkExtent3D(width: swapchainExtent.width, height: swapchainExtent.height, depth: 1)
        )
        vkCmdCopyImageToBuffer(
            commandBuffer.commandBuffer,
            swapchainImages[framebufferIndex],
            VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL,
            resources.buffer.buffer,
            1,
            &copyRegion
        )

        var toPresentBarrier = VkImageMemoryBarrier(
            sType: VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER,
            pNext: nil,
            srcAccessMask: VkAccessFlags(VK_ACCESS_TRANSFER_READ_BIT.rawValue),
            dstAccessMask: 0,
            oldLayout: VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL,
            newLayout: VK_IMAGE_LAYOUT_PRESENT_SRC_KHR,
            srcQueueFamilyIndex: VK_QUEUE_FAMILY_IGNORED,
            dstQueueFamilyIndex: VK_QUEUE_FAMILY_IGNORED,
            image: swapchainImages[framebufferIndex],
            subresourceRange: VkImageSubresourceRange(
                aspectMask: VkImageAspectFlags(VK_IMAGE_ASPECT_COLOR_BIT.rawValue),
                baseMipLevel: 0,
                levelCount: 1,
                baseArrayLayer: 0,
                layerCount: 1
            )
        )
        vkCmdPipelineBarrier(
            commandBuffer.commandBuffer,
            VkPipelineStageFlags(VK_PIPELINE_STAGE_TRANSFER_BIT.rawValue),
            VkPipelineStageFlags(VK_PIPELINE_STAGE_BOTTOM_OF_PIPE_BIT.rawValue),
            0,
            0,
            nil,
            0,
            nil,
            1,
            &toPresentBarrier
        )

        return resources
    }

    private func mapCapturedFrame(
        buffer: VulkanOwnedBuffer,
        memory: VulkanOwnedDeviceMemory
    ) throws -> CapturedFrame {
        let width = Int(swapchainExtent.width)
        let height = Int(swapchainExtent.height)
        let bytesPerRow = width * 4
        let byteCount = bytesPerRow * height
        let mapped = try device.mapMemory(memory, offset: 0, size: VkDeviceSize(byteCount))
        let data = Data(bytes: mapped, count: byteCount)
        device.unmapMemory(memory)
        _ = buffer
        return CapturedFrame(
            width: width,
            height: height,
            bytesPerRow: bytesPerRow,
            bgra8Data: data
        )
    }

    private func submitRecordedFrame(
        waitSemaphores: [VkSemaphore],
        signalSemaphores: [VkSemaphore]
    ) throws {
        var commandBufferOptional: VkCommandBuffer? = commandBuffer.commandBuffer
        let waitOptional = waitSemaphores.map { Optional($0) }
        let signalOptional = signalSemaphores.map { Optional($0) }
        var waitStages = [VkPipelineStageFlags](repeating: VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT.rawValue, count: waitOptional.count)
        try waitOptional.withUnsafeBufferPointer { waitPtr in
            try waitStages.withUnsafeMutableBufferPointer { stagesPtr in
                try signalOptional.withUnsafeBufferPointer { signalPtr in
                    try withUnsafePointer(to: &commandBufferOptional) { commandBufferPtr in
                        let submitInfo = VkSubmitInfo.create(
                            waitSemaphoreCount: UInt32(waitPtr.count),
                            pWaitSemaphores: waitPtr.baseAddress,
                            pWaitDstStageMask: stagesPtr.baseAddress,
                            commandBufferCount: 1,
                            pCommandBuffers: commandBufferPtr,
                            signalSemaphoreCount: UInt32(signalPtr.count),
                            pSignalSemaphores: signalPtr.baseAddress
                        )
                        try device.submit(queue: graphicsQueue, submits: [submitInfo], fence: inFlightFence.fence)
                    }
                }
            }
        }
    }

    private static func findMemoryTypeIndex(
        _ physicalDevice: VulkanPhysicalDevice,
        typeBits: UInt32,
        properties: VkMemoryPropertyFlags
    ) throws -> UInt32 {
        let memoryProperties = physicalDevice.getMemoryProperties()
        let count = Int(memoryProperties.memoryTypeCount)
        return try withUnsafePointer(to: memoryProperties.memoryTypes) { typesPtr in
            let rawPtr = UnsafeRawPointer(typesPtr).bindMemory(to: VkMemoryType.self, capacity: count)
            for index in 0..<count {
                let type = rawPtr[index]
                let typeSupported = (typeBits & (1 << index)) != 0
                let hasProperties = (type.propertyFlags & properties) == properties
                if typeSupported && hasProperties {
                    return UInt32(index)
                }
            }
            throw Errors.noSuitableMemoryType
        }
    }

    enum Errors: Error {
        case noPhysicalDevices
        case noSuitableQueueFamily
        case invalidSpirvData
        case swapchainUnsupported
        case depthFormatUnsupported
        case noSuitableMemoryType
        case emptyVertexData
        case vertexDataExceedsCapacity
        case invalidFramebufferIndex
        case missing3DPipeline
        case vulkanFailure(VkResult)
    }
}
