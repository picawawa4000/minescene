import Foundation
import simd
import VulkanBindings
import Vulkan

final class VulkanEngine {
    @inline(__always)
    private static func vulkanResultCheck(_ result: VkResult) throws {
        if result != VK_SUCCESS {
            throw Errors.vulkanFailure(result)
        }
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
        var position: SIMD3<Float>
        var color: SIMD4<Float>
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
    }

    struct DrawingMode3D {
        let descriptorSetLayout: VulkanOwnedDescriptorSetLayout
        let pipelineLayout: VulkanOwnedPipelineLayout
        let pipeline: VulkanOwnedPipeline?
    }

    let instance: VulkanInstance
    let surface: VkSurfaceKHR
    let physicalDevice: VulkanPhysicalDevice
    let device: VulkanOwnedDevice
    let graphicsQueue: VkQueue
    let queueFamilyIndex: UInt32

    let commandPool: VulkanOwnedCommandPool
    let commandBuffer: VulkanCommandBuffer

    let swapchain: VulkanOwnedSwapchain
    let swapchainImages: [VkImage]
    let swapchainImageViews: [VulkanOwnedImageView]
    let swapchainFramebuffers: [VulkanOwnedFramebuffer]
    let swapchainFormat: VkFormat
    let swapchainExtent: VkExtent2D

    let renderPass: VulkanOwnedRenderPass
    let mode2D: DrawingMode2D
    let mode3D: DrawingMode3D

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
        desiredExtent: VkExtent2D = VkExtent2D(width: 640, height: 480)
    ) throws {
        self.instance = instance
        self.surface = surface.surface

        let physicalDevices = try instance.enumeratePhysicalDevices()
        let selection = try VulkanEngine.selectPhysicalDevice(from: physicalDevices, surface: self.surface)
        self.physicalDevice = selection.device
        self.queueFamilyIndex = selection.queueFamilyIndex
        let deviceBundle = try VulkanEngine.createDeviceAndQueue(
            physicalDevice: self.physicalDevice,
            queueFamilyIndex: self.queueFamilyIndex
        )
        self.device = deviceBundle.device
        self.graphicsQueue = deviceBundle.queue

        let commandBundle = try VulkanEngine.createCommandResources(
            device: self.device,
            queueFamilyIndex: self.queueFamilyIndex
        )
        self.commandPool = commandBundle.commandPool
        self.commandBuffer = commandBundle.commandBuffer

        let swapchainBundle = try VulkanEngine.createSwapchainBundle(
            device: self.device,
            physicalDevice: self.physicalDevice,
            surface: self.surface,
            desiredExtent: desiredExtent
        )
        self.swapchain = swapchainBundle.swapchain
        self.swapchainImages = swapchainBundle.images
        self.swapchainImageViews = swapchainBundle.imageViews
        self.swapchainFormat = swapchainBundle.format
        self.swapchainExtent = swapchainBundle.extent

        self.renderPass = try VulkanEngine.createRenderPass(
            device: self.device,
            format: self.swapchainFormat
        )

        self.swapchainFramebuffers = try VulkanEngine.createFramebuffers(
            device: self.device,
            renderPass: self.renderPass,
            imageViews: self.swapchainImageViews,
            extent: self.swapchainExtent
        )

        let mode2DLayout = try VulkanEngine.createDescriptorSetLayout2D(device: self.device)
        let mode2DPipelineLayout = try VulkanEngine.createPipelineLayout(
            device: self.device,
            descriptorSetLayout: mode2DLayout
        )
        let pipeline2D = try VulkanEngine.createPipeline(
            device: self.device,
            renderPass: self.renderPass,
            extent: self.swapchainExtent,
            pipelineLayout: mode2DPipelineLayout,
            vertexInput: VulkanEngine.vertexInput2D(),
            vertSpirv: vertSpirv,
            fragSpirv: fragSpirv
        )
        self.mode2D = DrawingMode2D(
            descriptorSetLayout: mode2DLayout,
            pipelineLayout: mode2DPipelineLayout,
            pipeline: pipeline2D
        )

        let mode3DLayout = try VulkanEngine.createDescriptorSetLayout3D(device: self.device)
        let mode3DPipelineLayout = try VulkanEngine.createPipelineLayout(
            device: self.device,
            descriptorSetLayout: mode3DLayout
        )
        let pipeline3D: VulkanOwnedPipeline?
        if let vertSpirv3D, let fragSpirv3D {
            pipeline3D = try VulkanEngine.createPipeline(
                device: self.device,
                renderPass: self.renderPass,
                extent: self.swapchainExtent,
                pipelineLayout: mode3DPipelineLayout,
                vertexInput: VulkanEngine.vertexInput3D(),
                vertSpirv: vertSpirv3D,
                fragSpirv: fragSpirv3D
            )
        } else {
            pipeline3D = nil
        }
        self.mode3D = DrawingMode3D(
            descriptorSetLayout: mode3DLayout,
            pipelineLayout: mode3DPipelineLayout,
            pipeline: pipeline3D
        )
    }

    convenience init(
        instance: VulkanOwnedInstance,
        surface: VulkanSurface,
        vertSpirvPath: String,
        fragSpirvPath: String,
        vertSpirv3DPath: String? = nil,
        fragSpirv3DPath: String? = nil,
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
            desiredExtent: desiredExtent
        )
    }

    private static func deviceExtensions(for physicalDevice: VulkanPhysicalDevice) -> [String] {
        let extensions = physicalDevice.enumerateDeviceExtensionProperties()
        let available = Set(extensions.map { extensionNameString($0) })
        var enabled = [VK_KHR_SWAPCHAIN_EXTENSION_NAME]
        if available.contains(VK_KHR_PORTABILITY_ENUMERATION_EXTENSION_NAME) {
            enabled.append(VK_KHR_PORTABILITY_ENUMERATION_EXTENSION_NAME)
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
        queueFamilyIndex: UInt32
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
            enabledLayers: [],
            enabledExtensions: deviceExtensions
        )
        let queue = device.getQueue(familyIndex: queueFamilyIndex, queueIndex: 0)
        return (device, queue)
    }

    private static func createCommandResources(
        device: VulkanOwnedDevice,
        queueFamilyIndex: UInt32
    ) throws -> (commandPool: VulkanOwnedCommandPool, commandBuffer: VulkanCommandBuffer) {
        let commandPool = try device.createCommandPool(queueFamilyIndex: queueFamilyIndex)
        let commandBuffer = try device.allocateCommandBuffers(from: commandPool, count: 1).first!
        return (commandPool, commandBuffer)
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
            imageUsage: VkImageUsageFlags(VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT.rawValue),
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

    private static func createRenderPass(device: VulkanOwnedDevice, format: VkFormat) throws -> VulkanOwnedRenderPass {
        var colorAttachment = VkAttachmentDescription(
            flags: 0,
            format: format,
            samples: VK_SAMPLE_COUNT_1_BIT,
            loadOp: VK_ATTACHMENT_LOAD_OP_DONT_CARE,
            storeOp: VK_ATTACHMENT_STORE_OP_STORE,
            stencilLoadOp: VK_ATTACHMENT_LOAD_OP_DONT_CARE,
            stencilStoreOp: VK_ATTACHMENT_STORE_OP_DONT_CARE,
            initialLayout: VK_IMAGE_LAYOUT_UNDEFINED,
            finalLayout: VK_IMAGE_LAYOUT_PRESENT_SRC_KHR
        )
        var colorAttachmentRef = VkAttachmentReference(
            attachment: 0,
            layout: VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL
        )
        return try withUnsafePointer(to: &colorAttachment) { attachmentPtr in
            try withUnsafePointer(to: &colorAttachmentRef) { colorRefPtr in
                var subpass = VkSubpassDescription(
                    flags: 0,
                    pipelineBindPoint: VK_PIPELINE_BIND_POINT_GRAPHICS,
                    inputAttachmentCount: 0,
                    pInputAttachments: nil,
                    colorAttachmentCount: 1,
                    pColorAttachments: colorRefPtr,
                    pResolveAttachments: nil,
                    pDepthStencilAttachment: nil,
                    preserveAttachmentCount: 0,
                    pPreserveAttachments: nil
                )
                return try withUnsafePointer(to: &subpass) { subpassPtr in
                    var renderPassCreateInfo = VkRenderPassCreateInfo.create(
                        flags: 0,
                        attachmentCount: 1,
                        pAttachments: attachmentPtr,
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

    private static func createFramebuffers(
        device: VulkanOwnedDevice,
        renderPass: VulkanOwnedRenderPass,
        imageViews: [VulkanOwnedImageView],
        extent: VkExtent2D
    ) throws -> [VulkanOwnedFramebuffer] {
        try imageViews.map { imageView in
            let imageViewRefs: [VkImageView?] = [imageView.imageView]
            return try imageViewRefs.withUnsafeBufferPointer { imageViewPtr in
                var framebufferCreateInfo = VkFramebufferCreateInfo.create(
                    flags: 0,
                    renderPass: renderPass.renderPass,
                    attachmentCount: 1,
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
        vertSpirv: [UInt32],
        fragSpirv: [UInt32]
    ) throws -> VulkanOwnedPipeline {
        let vertModule = try device.createShaderModule(code: vertSpirv)
        let fragModule = try device.createShaderModule(code: fragSpirv)

        let pipeline = try "main".withCString { entryPoint in
            var shaderStages = [
                VkPipelineShaderStageCreateInfo(
                    sType: VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO,
                    pNext: nil,
                    flags: 0,
                    stage: VK_SHADER_STAGE_VERTEX_BIT,
                    module: vertModule.shaderModule,
                    pName: entryPoint,
                    pSpecializationInfo: nil
                ),
                VkPipelineShaderStageCreateInfo(
                    sType: VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO,
                    pNext: nil,
                    flags: 0,
                    stage: VK_SHADER_STAGE_FRAGMENT_BIT,
                    module: fragModule.shaderModule,
                    pName: entryPoint,
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
                cullMode: VkCullModeFlags(VK_CULL_MODE_BACK_BIT.rawValue),
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
            var colorBlendAttachment = VkPipelineColorBlendAttachmentState(
                blendEnable: VK_FALSE,
                srcColorBlendFactor: VK_BLEND_FACTOR_ONE,
                dstColorBlendFactor: VK_BLEND_FACTOR_ZERO,
                colorBlendOp: VK_BLEND_OP_ADD,
                srcAlphaBlendFactor: VK_BLEND_FACTOR_ONE,
                dstAlphaBlendFactor: VK_BLEND_FACTOR_ZERO,
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
                                                        pDepthStencilState: nil,
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

        return pipeline
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
        descriptorSetLayout: VulkanOwnedDescriptorSetLayout
    ) throws -> VulkanOwnedPipelineLayout {
        let layouts: [VkDescriptorSetLayout?] = [descriptorSetLayout.descriptorSetLayout]
        return try layouts.withUnsafeBufferPointer { layoutsPtr in
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
        let positionOffset = UInt32(MemoryLayout<Vertex3D>.offset(of: \.position) ?? 0)
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
                format: VK_FORMAT_R32G32B32A32_SFLOAT,
                offset: colorOffset
            )
        ]
        return VertexInputDescription(bindings: [binding], attributes: attributes)
    }

    func uploadVertices2D(_ vertices: [Vertex2D]) throws -> (buffer: VulkanOwnedBuffer, memory: VulkanOwnedDeviceMemory) {
        try uploadVertices(vertices, pipeline: mode2D.pipeline)
    }

    func uploadVertices3D(_ vertices: [Vertex3D]) throws -> (buffer: VulkanOwnedBuffer, memory: VulkanOwnedDeviceMemory) {
        guard let pipeline = mode3D.pipeline else {
            throw Errors.missing3DPipeline
        }
        return try uploadVertices(vertices, pipeline: pipeline)
    }

    func uploadVertices2D(_ vertices: [Vertex2D], framebufferIndex: Int) throws -> (buffer: VulkanOwnedBuffer, memory: VulkanOwnedDeviceMemory) {
        try uploadVertices(vertices, pipeline: mode2D.pipeline, framebufferIndex: framebufferIndex)
    }

    func uploadVertices3D(_ vertices: [Vertex3D], framebufferIndex: Int) throws -> (buffer: VulkanOwnedBuffer, memory: VulkanOwnedDeviceMemory) {
        guard let pipeline = mode3D.pipeline else {
            throw Errors.missing3DPipeline
        }
        return try uploadVertices(vertices, pipeline: pipeline, framebufferIndex: framebufferIndex)
    }

    private func uploadVertices<T>(
        _ vertices: [T],
        pipeline: VulkanOwnedPipeline,
        framebufferIndex: Int = 0
    ) throws -> (buffer: VulkanOwnedBuffer, memory: VulkanOwnedDeviceMemory) {
        let (buffer, memory) = try createVertexBuffer(vertices)
        try drawVertices(
            buffer: buffer,
            vertexCount: UInt32(vertices.count),
            pipeline: pipeline,
            framebufferIndex: framebufferIndex
        )
        return (buffer, memory)
    }

    private func createVertexBuffer<T>(_ vertices: [T]) throws -> (buffer: VulkanOwnedBuffer, memory: VulkanOwnedDeviceMemory) {
        if vertices.isEmpty {
            throw Errors.emptyVertexData
        }
        let bufferSize = VkDeviceSize(MemoryLayout<T>.stride * vertices.count)
        var bufferCreateInfo = VkBufferCreateInfo(
            sType: VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO,
            pNext: nil,
            flags: 0,
            size: bufferSize,
            usage: VkBufferUsageFlags(VK_BUFFER_USAGE_VERTEX_BUFFER_BIT.rawValue),
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

        let mapped = try device.mapMemory(memory, offset: 0, size: bufferSize)
        vertices.withUnsafeBytes { bytes in
            mapped.copyMemory(from: bytes.baseAddress!, byteCount: bytes.count)
        }
        device.unmapMemory(memory)
        return (buffer, memory)
    }

    private func drawVertices(
        buffer: VulkanOwnedBuffer,
        vertexCount: UInt32,
        pipeline: VulkanOwnedPipeline,
        framebufferIndex: Int
    ) throws {
        guard framebufferIndex >= 0 && framebufferIndex < swapchainFramebuffers.count else {
            throw Errors.invalidFramebufferIndex
        }

        let commandBuffer = try device.allocateCommandBuffers(from: commandPool, count: 1).first!
        defer {
            device.freeCommandBuffers(from: commandPool, commandBuffers: [commandBuffer])
        }

        try commandBuffer.begin()
        var renderPassBeginInfo = VkRenderPassBeginInfo(
            sType: VK_STRUCTURE_TYPE_RENDER_PASS_BEGIN_INFO,
            pNext: nil,
            renderPass: renderPass.renderPass,
            framebuffer: swapchainFramebuffers[framebufferIndex].framebuffer,
            renderArea: VkRect2D(offset: VkOffset2D(x: 0, y: 0), extent: swapchainExtent),
            clearValueCount: 0,
            pClearValues: nil
        )
        commandBuffer.beginRenderPass(renderPassBeginInfo: &renderPassBeginInfo, contents: VK_SUBPASS_CONTENTS_INLINE)
        commandBuffer.bindPipeline(bindPoint: VK_PIPELINE_BIND_POINT_GRAPHICS, pipeline: pipeline.pipeline)

        var vertexBuffer: VkBuffer? = buffer.buffer
        var offset: VkDeviceSize = 0
        withUnsafePointer(to: &vertexBuffer) { bufferPtr in
            withUnsafePointer(to: &offset) { offsetPtr in
                vkCmdBindVertexBuffers(commandBuffer.commandBuffer, 0, 1, bufferPtr, offsetPtr)
            }
        }
        commandBuffer.draw(vertexCount: vertexCount)
        commandBuffer.endRenderPass()
        try commandBuffer.end()

        let fence = try device.createFence()
        var commandBufferOptional: VkCommandBuffer? = commandBuffer.commandBuffer
        try withUnsafePointer(to: &commandBufferOptional) { commandBufferPtr in
            let submitInfo = VkSubmitInfo.create(
                waitSemaphoreCount: 0,
                pWaitSemaphores: nil,
                pWaitDstStageMask: nil,
                commandBufferCount: 1,
                pCommandBuffers: commandBufferPtr,
                signalSemaphoreCount: 0,
                pSignalSemaphores: nil
            )
            try device.submit(queue: graphicsQueue, submits: [submitInfo], fence: fence.fence)
        }
        try device.waitForFences([fence.fence], waitAll: true, timeout: UInt64.max)
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
        case noSuitableMemoryType
        case emptyVertexData
        case invalidFramebufferIndex
        case missing3DPipeline
        case vulkanFailure(VkResult)
    }
}
