module helpers;

import vk;
import stb;
import c3w;

import std::math;
import std::io;
import std::collections::list;
import std::collections::map;
import std::encoding::json;


fault ContextErrors
{
    NO_SUITABLE_DEVICE,
}

fault TextureError
{
    FILE_NOT_FOUND,
}

def DescriptorImages = List(<DescriptorImageInfo>);
def BufferMap = HashMap(<String, MemoryBlock>);

struct DeviceContext {
    Instance instance;
    Device device;
    PhysicalDevice pdevice;
    SwapchainKHR swapchain;
    ImageViewList swapchain_views;
    ImageList swapchain_images;
    CommandPool command_pool;
    CommandBufferList command_buffers;
    QueueFamily queue_family;
    Format depth_format;
    SurfaceFormatKHR surface_format;
    Extent2D extent;
    DebugUtilsMessengerEXT debug_messenger;
    SurfaceKHR surface;
    bool debug;
}

fn void DeviceContext.free(self) {
    self.device.waitIdle();
    if (self.debug) self.debug_messenger.free(self.instance);

    foreach (view : self.swapchain_views) view.free(self.device);
    self.swapchain.free(self.device);

    self.swapchain_images.free();
    self.swapchain_views.free();
    self.command_pool.free(self.device);
    self.command_buffers.free();
    self.surface.free(self.instance);

    self.device.free();
    self.instance.free();
}

fn DeviceContext! createContext(c3w::Window win, bool debug = false) {
    DeviceContext context = {
        .debug = debug
    };

    ZStringList validations;
    ZStringList extensions;
    ZStringList device_extensions;

    device_extensions.add_array({"VK_KHR_swapchain", "VK_KHR_push_descriptor", "VK_KHR_dynamic_rendering"});
    validations.add_array({"VK_LAYER_KHRONOS_validation"});
    extensions.add_array({"VK_KHR_surface", "VK_EXT_debug_utils"});

    if (env::OS_TYPE == MACOS) {
        extensions.add_array({"VK_MVK_macos_surface", "VK_KHR_portability_enumeration"});
        device_extensions.push("VK_KHR_portability_subset");
    }

    if (env::OS_TYPE == WIN32) {
        extensions.add_array({"VK_KHR_win32_surface"});
    }

    if (env::OS_TYPE == LINUX) {
        extensions.add_array({"VK_KHR_xlib_surface"});
    }

    InstanceCreateInfo instanceInfo = vk::instanceCreateInfo()
    .setApplicationInfo(&&ApplicationInfo{
      .pApplicationName = "TEST",
      .pEngineName = "Super engine",
      .applicationVersion = vk::@makeApiVersion(0,1,0,0),
      .engineVersion = vk::@makeApiVersion(0,1,0,0),
      .apiVersion = vk::@makeApiVersion(0,1,3,0)
    })
    .setFlags(env::os_is_darwin() ? vk::INSTANCE_CREATE_ENUMERATE_PORTABILITY_BIT_KHR : 0)
    .setEnabledExtensionNames(extensions.array_view());

    DebugUtilsMessengerCreateInfoEXT debug_info = DebugUtilsMessengerCreateInfoEXT {
        .sType = vk::STRUCTURE_TYPE_DEBUG_UTILS_MESSENGER_CREATE_INFO_EXT,
        .messageSeverity = vk::DEBUG_UTILS_MESSAGE_SEVERITY_VERBOSE_BIT_EXT | vk::DEBUG_UTILS_MESSAGE_SEVERITY_WARNING_BIT_EXT | vk::DEBUG_UTILS_MESSAGE_SEVERITY_ERROR_BIT_EXT,
        .messageType = vk::DEBUG_UTILS_MESSAGE_TYPE_GENERAL_BIT_EXT | vk::DEBUG_UTILS_MESSAGE_TYPE_VALIDATION_BIT_EXT | vk::DEBUG_UTILS_MESSAGE_TYPE_PERFORMANCE_BIT_EXT,
        .pfnUserCallback = (PFN_vkDebugUtilsMessengerCallbackEXT)&vk::debugCallback
    };

    // Debug enabled
    if (debug) {
      vk::checkValidationLayersSupport(validations)!!;
      instanceInfo.enabledLayerCount = (uint)validations.len();
      instanceInfo.ppEnabledLayerNames = (char*)validations.entries;
    }

    vk::createInstance(&instanceInfo, null, &context.instance)!!;
    vk::loadExtensions(context.instance);

    if (debug) {
        context.debug_messenger = debug_info.build(context.instance)!!;
    }

    // Create surface
    $switch(env::OS_TYPE)
        $case LINUX: {
            XlibSurfaceCreateInfoKHR createInfo = {
                vk::STRUCTURE_TYPE_XLIB_SURFACE_CREATE_INFO_KHR, 
                null, 
                0, 
                win.src.display, 
                win.src.window, 
            };

            vk::createXlibSurfaceKHR(context.instance, &createInfo, null, &context.surface)!!;
        }
        $case MACOS: {
            MacOSSurfaceCreateInfoMVK createInfo = { 
                vk::STRUCTURE_TYPE_MACOS_SURFACE_CREATE_INFO_MVK, 
                null, 
                0, 
                win.src.window
            };
        }
        $case WIN32: {
            Win32SurfaceCreateInfoKHR createInfo = {
                .sType = vk::STRUCTURE_TYPE_WIN32_SURFACE_CREATE_INFO_KHR,
                .pNext = null,
                .flags = 0,
                .hinstance = win.src.instance,
                .hwnd = win.src.window
            };
            vk::createWin32SurfaceKHR(instance, &createInfo, null, &surface)!!;
        }
        $default: {}
    $endswitch

    DeviceList devices = context.instance.getDevices()!!;
    bool found_device = false;

    foreach (entry: devices) {
        QueueFamily queue;
        // Check for device extension support
        bool supports_extensions = entry.checkExtensionSupport(device_extensions)!!;
        QueuePropertiesList queue_properties = entry.getQueueProperties()!!;

        queue.graphics = queue_properties.find(fn (usz index, QueueFamilyProperties props) => (QueueFlagBits)props.queueFlags & vk::QUEUE_GRAPHICS_BIT != 0);

        PhysicalDeviceProperties properties;
        vk::getPhysicalDeviceProperties(entry, &properties);

        if (context.surface.checkSurfaceSupport(queue.graphics, entry)!!) queue.present = queue.graphics;
        if (queue.is_ready() && supports_extensions && properties.vendorID != 0) {
            io::printfn("Device selected %s", (ZString)properties.deviceName[0..]);

            context.pdevice = entry;
            context.queue_family = queue;
            found_device = true;
            break;
        }
    }

    devices.free();

    if (!found_device) {
        io::printfn("Did not found suitable device!");
        return ContextErrors.NO_SUITABLE_DEVICE?;
    }

    PhysicalDeviceDescriptorIndexingFeatures device_indexing_feature = {
        .sType = vk::STRUCTURE_TYPE_PHYSICAL_DEVICE_DESCRIPTOR_INDEXING_FEATURES,
    };

    PhysicalDeviceBufferDeviceAddressFeatures buffer_device_feature = {
        .sType = vk::STRUCTURE_TYPE_PHYSICAL_DEVICE_BUFFER_DEVICE_ADDRESS_FEATURES,
        .pNext = &device_indexing_feature,
        .bufferDeviceAddress = vk::TRUE,
        .bufferDeviceAddressCaptureReplay = vk::TRUE
    };

    PhysicalDeviceDynamicRenderingFeatures dynamic_rendering_feature = {
       .sType = vk::STRUCTURE_TYPE_PHYSICAL_DEVICE_DYNAMIC_RENDERING_FEATURES,
       .pNext = &buffer_device_feature
    };

    PhysicalDeviceSynchronization2Features syncronisation2_feature = {
       .sType = vk::STRUCTURE_TYPE_PHYSICAL_DEVICE_SYNCHRONIZATION_2_FEATURES,
       .pNext = &dynamic_rendering_feature,
       .synchronization2 = vk::TRUE
    };

    PhysicalDeviceFeatures2 device_features = {
        .sType = vk::STRUCTURE_TYPE_PHYSICAL_DEVICE_FEATURES_2,
        .pNext = &syncronisation2_feature,
    };

    vk::getPhysicalDeviceFeatures2(context.pdevice, &device_features);

    DeviceQueueCreateInfo graphicsInfo = vk::deviceQueueCreateInfo()
    .setQueueFamilyIndex(context.queue_family.graphics)
    .setQueuePriorities({1.0});

    context.device = vk::deviceCreateInfo()
      .setQueueCreateInfos({ graphicsInfo })
      .setEnabledExtensionNames(device_extensions.array_view())
      .setNext(&device_features)
      .build(context.pdevice)!;

    // Add actual queue handles to queue family, easier to keep them is one place
    context.queue_family.graphics_handle = context.device.getQueue(context.queue_family.graphics);

    SurfaceFormatList surface_formats = context.surface.getFormats(context.pdevice)!;
    PresentModeList present_modes = context.surface.getPresentModes(context.pdevice)!;
    SurfaceCapabilitiesKHR capabilities = context.surface.deviceSurfaceCapabilities(context.pdevice)!;

    defer {
      surface_formats.free();
      present_modes.free();
    }

    context.depth_format = vk::findDepthFormat(features: vk::FORMAT_FEATURE_DEPTH_STENCIL_ATTACHMENT_BIT, device: context.pdevice);

    SurfaceFormatKHR format = SurfaceFormatKHR {.format = vk::FORMAT_B8G8R8A8_UNORM, .colorSpace = vk::COLOR_SPACE_SRGB_NONLINEAR_KHR};
    context.surface_format = format;
    context.extent = capabilities.maxImageExtent;
    uint min_images = capabilities.maxImageCount != 0 ? capabilities.maxImageCount : capabilities.minImageCount + 2;

    SwapchainCreateInfoKHR swapchain_info = vk::swapchainCreateInfo()
      .setMinImageCount(min_images)
      .setImageUsage(vk::IMAGE_USAGE_COLOR_ATTACHMENT_BIT)
      .setImageSharingMode(vk::SHARING_MODE_EXCLUSIVE)
      .setCompositeAlpha(vk::COMPOSITE_ALPHA_OPAQUE_BIT_KHR)
      .setPresentMode(vk::PRESENT_MODE_MAILBOX_KHR)
      .setPreTransform(capabilities.currentTransform)
      .setImageColorSpace(format.colorSpace)
      .setImageFormat(format.format)
      .setSurface(context.surface)
      .setImageArrayLayers(1)
      .setImageExtent(context.extent);

    context.swapchain = swapchain_info.build(context.device)!;
    context.swapchain_images = context.swapchain.getImages(context.device, swapchain_info.minImageCount)!;

    for (int i = 0; i < swapchain_info.minImageCount; ++i) {
        ImageView view = vk::imageViewCreateInfo()
        .setViewType(vk::IMAGE_VIEW_TYPE_2D)
        .setFormat(format.format)
        .setComponents({
            .r = vk::COMPONENT_SWIZZLE_IDENTITY,
            .g = vk::COMPONENT_SWIZZLE_IDENTITY,
            .b = vk::COMPONENT_SWIZZLE_IDENTITY,
            .a = vk::COMPONENT_SWIZZLE_IDENTITY,
        })
        .setSubresourceRange({
            .aspectMask = vk::IMAGE_ASPECT_COLOR_BIT,
            .baseMipLevel = 0,
            .baseArrayLayer = 0,
            .layerCount = 1,
            .levelCount = 1,
        })
        .setImage(context.swapchain_images[i])
        .build(context.device)!;
        context.swapchain_views.push(view);
    }

    context.command_pool = context.device.createCommandPool(queue: context.queue_family.graphics)!;
    context.command_buffers = context.device.createCommandBuffers(context.command_pool, swapchain_info.minImageCount)!;

    return context;
}

fn void! BufferMap.upload(self, String name, void* data, ulong size) {
    MemoryBlock buffer = self[name]!;
    mem::copy(buffer.mapped + buffer.offset, &data, size);
}

fn void! BufferMap.upload_device(self, String name, void* data, usz size, QueueFamily queue) {
    MemoryBlock buffer = self[name]!;
    Device device = buffer.allocator.device;
    PhysicalDevice pdevice = buffer.allocator.pdevice;

    // Device only
    MemoryBlock stage_buffer = device.staging_buffer(size: size, data: data, pdevice: pdevice)!;

    device.@single_time_command(queue: queue.graphics_handle, queue_index: queue.graphics; CommandBuffer command_buffer) {
        vk::cmdCopyBuffer(command_buffer, stage_buffer.buffer, buffer.buffer, 1, &&BufferCopy {
            .srcOffset = 0,
            .dstOffset = 0,
            .size = size
        });
    }!;

    stage_buffer.free(device);
}

fn void! DescriptorImages.createImage(&self, stb::Image image_data, vk::Allocation* allocator, QueueFamily queue) {
    vk::Device device = allocator.device;
    vk::PhysicalDevice pdevice = allocator.pdevice; 

    Format image_format = vk::FORMAT_R8G8B8A8_UNORM;
    DescriptorImageInfo texture = { .imageLayout = vk::IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL };

    vk::Image texture_image = vk::imageCreateInfo()
        .setImageType(vk::IMAGE_TYPE_2D)
        .setExtent({.width = image_data.width, .height = image_data.height, .depth = 1 })
        .setMipLevels(1)
        .setArrayLayers(1)
        .setSamples(vk::SAMPLE_COUNT_1_BIT)
        .setUsage(vk::IMAGE_USAGE_TRANSFER_DST_BIT | vk::IMAGE_USAGE_SAMPLED_BIT)
        .setInitialLayout(vk::IMAGE_LAYOUT_UNDEFINED)
        .setTiling(vk::IMAGE_TILING_OPTIMAL)
        .setFormat(image_format)
        .build(device)!;
        texture_image.bind(allocator)!;

    MemoryBlock stage_image = device.staging_buffer(size: (usz)image_data.width * image_data.height * 4, data: image_data.pixels, pdevice: pdevice)!;
    defer stage_image.free(device);

    vk::ImageMemoryBarrier2 transfer_barrier = {
        .sType = vk::STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER_2,
        .srcStageMask = vk::PIPELINE_STAGE_TOP_OF_PIPE_BIT,
        .dstStageMask = vk::PIPELINE_STAGE_TRANSFER_BIT,
        .srcAccessMask = 0,
        .dstAccessMask = vk::ACCESS_2_TRANSFER_WRITE_BIT,
        .image = texture_image,
        .oldLayout = vk::IMAGE_LAYOUT_UNDEFINED,
        .newLayout = vk::IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
        .subresourceRange = {
            .aspectMask = vk::IMAGE_ASPECT_COLOR_BIT,
            .baseMipLevel = 0,
            .levelCount = 1,
            .baseArrayLayer = 0,
            .layerCount = 1,
    }};

    vk::ImageMemoryBarrier2 finalize_barrier = {
        .sType = vk::STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER_2,
        .srcStageMask = vk::PIPELINE_STAGE_TRANSFER_BIT,
        .dstStageMask = vk::PIPELINE_STAGE_FRAGMENT_SHADER_BIT,
        .srcAccessMask = vk::ACCESS_2_TRANSFER_WRITE_BIT,
        .dstAccessMask = vk::ACCESS_2_SHADER_READ_BIT,
        .image = texture_image,
        .oldLayout = vk::IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
        .newLayout = vk::IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL,
        .subresourceRange = {
            .aspectMask = vk::IMAGE_ASPECT_COLOR_BIT,
            .baseMipLevel = 0,
            .levelCount = 1,
            .baseArrayLayer = 0,
            .layerCount = 1,
        }
    };

    device.@single_time_command(queue: queue.graphics_handle, queue_index: queue.graphics; CommandBuffer command_buffer) {
        
        vk::cmdPipelineBarrier2(command_buffer, &&vk::dependencyInfo()
        .setImageMemoryBarriers({ transfer_barrier }));

        BufferImageCopy bufferCopyRegion = {
            .bufferOffset = 0,
            .bufferRowLength = 0,
            .bufferImageHeight = 0,
            .imageSubresource = {
                .aspectMask = vk::IMAGE_ASPECT_COLOR_BIT,
                .mipLevel = 0,
                .baseArrayLayer = 0,
                .layerCount = 1,
            },
            .imageOffset = {0, 0, 0},
            .imageExtent = {.width = image_data.width, .height = image_data.height, .depth = 1 }
        };

        vk::cmdCopyBufferToImage(
            command_buffer,
            stage_image.buffer,
            texture_image,
            vk::IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
            1,
            &bufferCopyRegion
        );

        vk::cmdPipelineBarrier2(command_buffer, &&vk::dependencyInfo()
        .setImageMemoryBarriers({ finalize_barrier }));
    }!;

    texture.sampler = vk::samplerCreateInfo()
                        .setMagFilter(vk::FILTER_NEAREST)
                        .setMinFilter(vk::FILTER_NEAREST)
                        .setAddressModeU(vk::SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE)
                        .setAddressModeV(vk::SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE)
                        .setAddressModeW(vk::SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE)
                        .setMipLodBias(0.0)
                        .setMinLod(0.0)
                        .setMaxLod(1.0)
                        .setMaxAnisotropy(1.0)
                        .setAnisotropyEnable(vk::FALSE)
                        .setBorderColor(vk::BORDER_COLOR_FLOAT_OPAQUE_WHITE)
                        .build(device)!;

    texture.imageView = vk::imageViewCreateInfo()
                    .setViewType(vk::IMAGE_VIEW_TYPE_2D)
                    .setFormat(image_format)
                    .setSubresourceRange({
                        .aspectMask = vk::IMAGE_ASPECT_COLOR_BIT,
                        .baseMipLevel = 0,
                        .baseArrayLayer = 0,
                        .layerCount = 1,
                        .levelCount = 1,
                    })
                    .setImage(texture_image)
                    .build(device)!;

    self.push(texture);
}

fn void! DescriptorImages.createDepthTexture(&self, vk::Allocation* allocator, QueueFamily queue, Vec2f size, vk::Format format) {
    DescriptorImageInfo texture;

    vk::Device device = allocator.device;
    vk::PhysicalDevice pdevice = allocator.pdevice; 

    texture.imageLayout = vk::IMAGE_LAYOUT_DEPTH_STENCIL_READ_ONLY_OPTIMAL;

    vk::Image depth_image = vk::imageCreateInfo()
    .setImageType(vk::IMAGE_TYPE_2D)
    .setExtent({.width = (uint)size.x, .height = (uint)size.y, .depth = 1 })
    .setMipLevels(1)
    .setArrayLayers(1)
    .setSamples(vk::SAMPLE_COUNT_1_BIT)
    .setUsage(vk::IMAGE_USAGE_DEPTH_STENCIL_ATTACHMENT_BIT | vk::IMAGE_USAGE_SAMPLED_BIT)
    .setInitialLayout(vk::IMAGE_LAYOUT_UNDEFINED)
    .setTiling(vk::IMAGE_TILING_OPTIMAL)
    .setFormat(format)
    .build(device)!;

    depth_image.bind(allocator)!;

    texture.sampler = vk::samplerCreateInfo()
    .setMagFilter(vk::FILTER_LINEAR)
    .setMinFilter(vk::FILTER_LINEAR)
    .setAddressModeU(vk::SAMPLER_ADDRESS_MODE_REPEAT)
    .setAddressModeV(vk::SAMPLER_ADDRESS_MODE_REPEAT)
    .setAddressModeW(vk::SAMPLER_ADDRESS_MODE_REPEAT)
    .setMipLodBias(0.0)
    .setMinLod(0.0)
    .setMaxLod(1.0)
    .setMaxAnisotropy(1.0)
    .setAnisotropyEnable(vk::FALSE)
    .setBorderColor(vk::BORDER_COLOR_FLOAT_OPAQUE_WHITE)
    .build(device)!;

    texture.imageView = vk::imageViewCreateInfo()
    .setViewType(vk::IMAGE_VIEW_TYPE_2D)
    .setFormat(format)
    .setSubresourceRange({
        .aspectMask = vk::IMAGE_ASPECT_DEPTH_BIT,
        .baseMipLevel = 0,
        .baseArrayLayer = 0,
        .layerCount = 1,
        .levelCount = 1,
    })
    .setImage(depth_image)
    .build(device)!;

    device.@single_time_command(queue: queue.graphics_handle, queue_index: queue.graphics; CommandBuffer command_buffer) {
        ImageMemoryBarrier imageMemoryBarrier = vk::imageMemoryBarrier()
        .setImage(depth_image)
        .setSubresourceRange({
            .aspectMask = vk::IMAGE_ASPECT_DEPTH_BIT,
            .baseMipLevel = 0,
            .baseArrayLayer = 0,
            .layerCount = 1,
            .levelCount = 1,
        })
        .setSrcAccessMask(0)
        .setDstAccessMask(vk::ACCESS_DEPTH_STENCIL_ATTACHMENT_WRITE_BIT)
        .setOldLayout(vk::IMAGE_LAYOUT_UNDEFINED)
        .setNewLayout(vk::IMAGE_LAYOUT_DEPTH_STENCIL_READ_ONLY_OPTIMAL);

        vk::cmdPipelineBarrier(
            command_buffer,
            vk::PIPELINE_STAGE_EARLY_FRAGMENT_TESTS_BIT | vk::PIPELINE_STAGE_LATE_FRAGMENT_TESTS_BIT,
            vk::PIPELINE_STAGE_EARLY_FRAGMENT_TESTS_BIT | vk::PIPELINE_STAGE_LATE_FRAGMENT_TESTS_BIT,
            0,
            0,
            null,
            0,
            null,
            1,
            &imageMemoryBarrier
        );
    }!;

    self.push(texture);
}

struct RenderState {
    Shader shader;

    DescriptorSetLayout descriptor_layout;
    PipelineLayout pipeline_layout;
    Pipeline pipeline;

    PrimitiveTopology topology;
    PolygonMode polygon_mode;
    CullModeFlagBits cull_mode;
    FrontFace front_face;

    bool enable_depth;

    vk::Format[] color_attachments;
    vk::Format depth_format;
    vk::PipelineColorBlendAttachmentState[] blend_attachments;
    vk::DynamicState[] dynamic_states;
    PushConstantRange[] push_constants;
}

fn void RenderState.free(self, Device device) {
    self.descriptor_layout.free(device);
    self.pipeline_layout.free(device);
    self.pipeline.free(device);
}

fn RenderState! RenderState.build(&self, Device device) {

    PipelineVertexInputStateCreateInfo vertex_info = vk::pipelineVertexInputStateCreateInfo().setVertexBindingDescriptionCount(0);

    PipelineInputAssemblyStateCreateInfo assembly_state = vk::pipelineInputAssemblyStateCreateInfo()
    .setTopology(self.topology);

    PipelineRasterizationStateCreateInfo rasterization_state = vk::pipelineRasterizationStateCreateInfo()
    .setDepthClampEnable(vk::FALSE)
    .setRasterizerDiscardEnable(vk::FALSE)
    .setDepthBiasEnable(vk::FALSE)
    .setPolygonMode(self.polygon_mode)
    .setLineWidth(1.0)
    .setCullMode(self.cull_mode)
    .setFrontFace(self.front_face);

    PipelineViewportStateCreateInfo view_port_state = {
        .sType = vk::STRUCTURE_TYPE_PIPELINE_VIEWPORT_STATE_CREATE_INFO,
        .viewportCount = 1,
        .scissorCount = 1,
    };

    PipelineMultisampleStateCreateInfo multi_sample_state = vk::pipelineMultisampleStateCreateInfo()
    .setSampleShadingEnable(vk::FALSE)
    .setRasterizationSamples(vk::SAMPLE_COUNT_1_BIT)
    .setMinSampleShading(1.0)
    .setAlphaToCoverageEnable(vk::FALSE)
    .setAlphaToOneEnable(vk::FALSE);

    PipelineColorBlendStateCreateInfo color_blend_state = vk::pipelineColorBlendStateCreateInfo()
    .setBlendConstants({ 0.0, 0.0, 0.0, 0.0 })
    .setLogicOp(vk::LOGIC_OP_COPY)
    .setAttachments(self.blend_attachments);

    PipelineDynamicStateCreateInfo dynamic_states = vk::pipelineDynamicStateCreateInfo()
    .setDynamicStates(self.dynamic_states);

    PipelineRenderingCreateInfo rendering_info = vk::pipelineRenderingCreateInfo()
    .setColorAttachmentFormats(self.color_attachments)
    .setDepthAttachmentFormat(self.depth_format);

    PipelineDepthStencilStateCreateInfo depth_state = vk::pipelineDepthStencilStateCreateInfo()
    .setDepthTestEnable((uint)self.enable_depth)
    .setDepthWriteEnable((uint)self.enable_depth)
    .setDepthCompareOp(vk::COMPARE_OP_LESS_OR_EQUAL)
    .setBack({.compareOp = vk::COMPARE_OP_ALWAYS});
    // DescriptorSetLayoutCreateInfo descriptorLayoutInfo = vk::descriptorSetLayoutCreateInfo()
    //                         .setFlags(vk::DESCRIPTOR_SET_LAYOUT_CREATE_PUSH_DESCRIPTOR_BIT_KHR);

    // foreach (descriptor: self.descriptors) {
    //     WriteDescriptorSet data = vk::writeDescriptorSet()
    //         .setDstBinding(descriptor.binding)
    //         .setDescriptorType(descriptor.type);

    //     DescriptorSetLayoutBinding binding = {
    //         .binding = descriptor.binding,
    //         .descriptorType = descriptor.type,
    //         .stageFlags = descriptor.stage
    //     };

    //     if (descriptor.type == vk::DESCRIPTOR_TYPE_UNIFORM_BUFFER) {
    //         data.setBufferInfo({
    //             {
    //                 .buffer = descriptor.buffer.buffer,
    //                 .offset = 0,
    //                 .range = descriptor.buffer.size,
    //             },
    //         });
    //         binding.descriptorCount = 1;
    //     }

    //     if (descriptor.type == vk::DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER) {
    //         data.setImageInfo(descriptor.textures.array_view());
    //         binding.descriptorCount = (uint)descriptor.textures.len();
    //     }

    //     self.descriptor_layout_bindings.push(binding);
    //     self.descriptor_data.push(data);
    // }

    // self.descriptor_layout = descriptorLayoutInfo
    // .setBindings(self.descriptor_layout_bindings.array_view())
    // .build(device)!;

    self.pipeline_layout = vk::pipelineLayoutCreateInfo()
    .setPushConstantRanges(self.push_constants)
    .setSetLayouts({ self.descriptor_layout }).build(device)!;

    GraphicsPipelineCreateInfo pipeline_info = vk::graphicsPipelineCreateInfo()
    .setStages(&self.shader.stages)
    .setLayout(self.pipeline_layout)
    .setVertexInputState(&vertex_info)
    .setDynamicState(&dynamic_states)
    .setRasterizationState(&rasterization_state)
    .setInputAssemblyState(&assembly_state)
    .setMultisampleState(&multi_sample_state)
    .setColorBlendState(&color_blend_state)
    .setViewportState(&view_port_state)
    .setDepthStencilState(&depth_state)
    .setNext(&rendering_info);

    self.pipeline = pipeline_info.build(device)!;

    return *self;
}

