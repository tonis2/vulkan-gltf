import std::io;
import vk;
import glfw;
import stb;
import camera;
import std::math;

import std::collections::list;
import pipelines;
import std::time;
import vge;

const WIDTH = 1300;
const HEIGHT = 900;
const ENABLE_VALIDATION_LAYERS = false;
const MAX_FRAMES_IN_FLIGHT = 2;


String[] icons = {
    "assets/textures/book.png",
    "assets/textures/pizza.png",
    "assets/textures/tree.png",
};

String[] images = {
    "assets/textures/spirited.png",
    "assets/textures/spirited_bg.jpg",
    "assets/textures/howl.png",
    "assets/textures/howl_bg.jpg",
    "assets/textures/mono.png",
    "assets/textures/mono_bg.jpg",
};

struct Drawing {
    uint type;
    int texture_id;

    float border_width;

    Vec2f size;
    Vec2f corner;

    Vec4f border_radius;
    Vec4f color;
    Vec4f border_color;
    Matrix4f transform;
}

struct PushConstantData {
    uint draw_index;
    vk::DeviceAddress canvas;
}

struct UniformBuffer {
    Matrix4f perspective;
    Matrix4f view;
    Vec2f resolution;
}

// Load shaders
char[*] vertex_shader_data = $embed("./shaders/vertex.spv");
char[*] fragment_shader_data = $embed("./shaders/fragment.spv");

Instance instance;
DebugUtilsMessengerEXT debug_messenger;
PhysicalDevice physical_device;
QueueFamily queue_family;
Device device;

ZStringList validations;
ZStringList extensions;
ZStringList device_extensions;

vk::Format depth_format;
DescriptorImageInfo depth_texture;
vk::Image depth_image;

MemoryBlock canvas_buffer;
MemoryBlock uniform_buffer;

vk::Allocation local_allocation;
vk::Allocation device_allocation;

DescriptorImages textures;

fn void! main()
{
    camera::Camera camera = camera::new(.eye = {0.0, 0.0, 1.0}, .aspect = WIDTH/HEIGHT, .min_zoom = 0.1, .max_zoom = 10);

    UniformBuffer uniform_data = {
        camera.perspective.transpose(),
        camera.view.transpose(),
        Vec2f {WIDTH, HEIGHT}
    };

    List(<Drawing>) canvas;
    defer canvas.free();

    Matrix4f transform = camera::matrixRotation(Vec3f{0.0, 1.0, 0.0}, 30)
    .transpose();

    for (uint i = 0; i < 6; i += 2) {

        Vec2f box_size = {WIDTH / 4, HEIGHT / 2};
        float padding = 20.0;
        float offset = padding + i * (box_size.x / 2 + padding);

        canvas.push({
            .type = 0,
            .corner = {offset, box_size.y / 3},
            .size = {box_size.x, box_size.y},
            .border_width = 1.0,
            .border_color = {1.0, 1.0, 1.0, 1.0},
            .border_radius = {1.0, 1.0, 1.0, 1.0},
            .color = {0.1, 0.5, 0.4, 1.0},
            .texture_id = i + 1,
            .transform = transform
        });

        float corner_offset = padding + i * (box_size.x / 2 + padding);

        canvas.push({
            .type = 0,
            .corner = {corner_offset, box_size.y / 3},
            .size = {box_size.x, box_size.y}, 
            .texture_id = i,
            .transform = transform
        });
    }

    glfw::init();
    glfw::windowHint(glfw::GLFW_CLIENT_API, glfw::GLFW_NO_API);
    glfw::windowHint(glfw::GLFW_RESIZABLE, glfw::GLFW_FALSE);
    glfw::windowHint(glfw::CONTEXT_VERSION_MAJOR, 4);
    glfw::windowHint(glfw::CONTEXT_VERSION_MINOR, 1);
    GLFWwindow window = glfw::createWindow(WIDTH, HEIGHT, "Vulkan UI", null, null);

    if (window == null)
    {
        io::printfn("Failed to init glfw window");
        return;
    }

    EventHandler eventHandler = { .window = window };
    eventHandler.init();

    validations.add_array({"VK_LAYER_KHRONOS_validation"});
    device_extensions.add_array({"VK_KHR_swapchain", "VK_KHR_push_descriptor", "VK_KHR_dynamic_rendering"});

    // SETUP extensions
    ZStringList glfw_extensions = glfw::getRequiredExtensions();
    extensions.add_all(&glfw_extensions);
    glfw_extensions.free();


    if (ENABLE_VALIDATION_LAYERS) {
     extensions.add_array({"VK_EXT_debug_utils"});
    }

    if (env::os_is_darwin()) {
      extensions.push("VK_KHR_portability_enumeration");
      device_extensions.push("VK_KHR_portability_subset");
    }

    vk::checkExtensionSupport(extensions)!;

    InstanceCreateInfo instanceInfo = vk::instanceCreateInfoBuilder()
    .setApplicationInfo(&&ApplicationInfo{
      .pApplicationName = "Hello GLTF",
      .pEngineName = "Super engine",
      .applicationVersion = vk::@makeApiVersion(0,1,0,0),
      .engineVersion = vk::@makeApiVersion(0,1,0,0),
      .apiVersion = vk::@makeApiVersion(0,1,3,0)
    })
    .setFlags(env::os_is_darwin() ? vk::INSTANCE_CREATE_ENUMERATE_PORTABILITY_BIT_KHR : 0)
    .setEnabledExtensionNames(extensions.array_view());

    DebugUtilsMessengerCreateInfoEXT debug_info = vk::debugUtilsMessengerCreateInfoEXTBuilder()
        .setMessageSeverity(vk::DEBUG_UTILS_MESSAGE_SEVERITY_VERBOSE_BIT_EXT | vk::DEBUG_UTILS_MESSAGE_SEVERITY_WARNING_BIT_EXT | vk::DEBUG_UTILS_MESSAGE_SEVERITY_ERROR_BIT_EXT)
        .setMessageType(vk::DEBUG_UTILS_MESSAGE_TYPE_GENERAL_BIT_EXT | vk::DEBUG_UTILS_MESSAGE_TYPE_VALIDATION_BIT_EXT | vk::DEBUG_UTILS_MESSAGE_TYPE_PERFORMANCE_BIT_EXT)
        .setPfnUserCallback((PFN_vkDebugUtilsMessengerCallbackEXT)&vk::debugCallback);

    // Debug enabled
    if (ENABLE_VALIDATION_LAYERS) {
      vk::checkValidationLayersSupport(validations)!;
      instanceInfo.enabledLayerCount = (uint)validations.len();
      instanceInfo.ppEnabledLayerNames = (char*)validations.entries;
    }

    vk::createInstance(&instanceInfo, null, &instance)!;
    vk::loadExtensions(instance);

    if (ENABLE_VALIDATION_LAYERS) {
     debug_messenger = debug_info.build(instance)!;
    }

    SurfaceKHR surface = glfw::createWindowSurface(instance, window, null)!;

    bool found_device = false;
    // Macro to find a valid device
    instance.@requestDevice(;PhysicalDevice pdevice) {
      QueueFamily queue;
      // Check for device extension support
      bool supports_extensions = pdevice.checkExtensionSupport(device_extensions)!;
      QueuePropertiesList queue_properties = pdevice.getQueueProperties()!;

      queue.graphics = queue_properties.find(fn (usz index, QueueFamilyProperties props) => (usz)props.queueFlags & vk::QUEUE_GRAPHICS_BIT != 0);
      if (surface.checkSurfaceSupport(queue.graphics, pdevice)!) queue.present = queue.graphics;

      if (queue.is_ready() && supports_extensions) {
         physical_device = pdevice;
         queue_family = queue;
         found_device = true;
      }
    }!;

    if (!found_device) {
      io::printfn("Did not found suitable device!");
      return;
    }

    // Required for using push descriptors
    PhysicalDeviceProperties2 deviceProps2 = vk::physicalDeviceProperties2Builder()
                                                .setNext(&&vk::physicalDevicePushDescriptorPropertiesKHRBuilder().setMaxPushDescriptors(1));

    vk::getPhysicalDeviceProperties2(physical_device, &deviceProps2);

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

    vk::getPhysicalDeviceFeatures2(physical_device, &device_features);

    DeviceQueueCreateInfo graphicsInfo = vk::deviceQueueCreateInfoBuilder()
    .setQueueFamilyIndex(queue_family.graphics)
    .setQueuePriorities({1.0});

    device = vk::deviceCreateInfoBuilder()
      .setQueueCreateInfos({ graphicsInfo })
      .setEnabledExtensionNames(device_extensions.array_view())
      .setNext(&device_features)
      .build(physical_device)!;

    queue_family.graphics_handle = device.getQueue(queue_family.graphics);

    SurfaceFormatList surface_formats = surface.getFormats(physical_device)!;
    PresentModeList present_modes = surface.getPresentModes(physical_device)!;
    SurfaceCapabilitiesKHR capabilities = surface.deviceSurfaceCapabilities(physical_device)!;

    defer {
      surface_formats.free();
      present_modes.free();
    }
    
    depth_format = vk::findDepthFormat(.device = physical_device, .features = vk::FORMAT_FEATURE_DEPTH_STENCIL_ATTACHMENT_BIT);
    SurfaceFormatKHR format = SurfaceFormatKHR {.format = vk::FORMAT_B8G8R8A8_UNORM, .colorSpace = vk::COLOR_SPACE_SRGB_NONLINEAR_KHR};

    uint min_images = capabilities.maxImageCount != 0 ? capabilities.maxImageCount : capabilities.minImageCount + 2;
    SwapchainCreateInfoKHR swapchain_info = vk::swapchainCreateInfoKHRBuilder()
      .setMinImageCount(min_images)
      .setImageUsage(vk::IMAGE_USAGE_COLOR_ATTACHMENT_BIT)
      .setImageSharingMode(vk::SHARING_MODE_EXCLUSIVE)
      .setCompositeAlpha(vk::COMPOSITE_ALPHA_OPAQUE_BIT_KHR)
      .setPresentMode(vk::PRESENT_MODE_MAILBOX_KHR)
      .setPreTransform(capabilities.currentTransform)
      .setImageColorSpace(format.colorSpace)
      .setImageFormat(format.format)
      .setSurface(surface)
      .setImageArrayLayers(1)
      .setImageExtent({ .width = WIDTH, .height = HEIGHT });

    SwapchainKHR swapchain = swapchain_info.buildKHR(device)!;
    ImageViewList swapchain_views;
    vk::ImageList swapchain_images = swapchain.getImages(device, swapchain_info.minImageCount)!;

    for (int i = 0; i < swapchain_info.minImageCount; ++i) {
        ImageView view = vk::imageViewCreateInfoBuilder()
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
        .setImage(swapchain_images[i])
        .build(device)!;
        swapchain_views.push(view);
    }

    CommandPool command_pool = device.createCommandPool(.queue = queue_family.graphics)!;
    CommandBufferList command_buffers = device.createCommandBuffers(command_pool, swapchain_info.minImageCount)!;

    // Create allocator of 50MB - DEVICE_ONLY memory
    device_allocation = vk::Allocation {
        .device = device,
        .pdevice = physical_device,
        .properties = vk::MEMORY_PROPERTY_DEVICE_LOCAL_BIT,
        .flags = vk::MEMORY_ALLOCATE_DEVICE_ADDRESS_BIT | vk::MEMORY_ALLOCATE_DEVICE_ADDRESS_CAPTURE_REPLAY_BIT,
        .size = 50_000_000
    }.build()!;

    loadTextures()!;
    // Allocation where data can be changed from CPU
    local_allocation = vk::Allocation {
        .device = device,
        .pdevice = physical_device,
        .properties = vk::MEMORY_PROPERTY_HOST_VISIBLE_BIT | vk::MEMORY_PROPERTY_HOST_CACHED_BIT,
        .flags = vk::MEMORY_ALLOCATE_DEVICE_ADDRESS_BIT | vk::MEMORY_ALLOCATE_DEVICE_ADDRESS_CAPTURE_REPLAY_BIT,
        .size = 20_000_000
    }.build()!;

    uniform_buffer = vk::bufferCreateInfoBuilder()
        .setUsage(vk::BUFFER_USAGE_UNIFORM_BUFFER_BIT)
        .setSharingMode(vk::SHARING_MODE_EXCLUSIVE)
        .setSize(UniformBuffer.sizeof)
        .bind(&local_allocation)!;

    canvas_buffer = vk::bufferCreateInfoBuilder()
        .setUsage(vk::BUFFER_USAGE_SHADER_DEVICE_ADDRESS_BIT)
        .setSharingMode(vk::SHARING_MODE_EXCLUSIVE)
        .setSize(canvas.byte_size())
        .bind(&local_allocation)!;

    uniform_buffer.upload(&uniform_data, UniformBuffer.sizeof, device);
    canvas_buffer.upload(canvas.entries, canvas.byte_size(), device);

    WriteDescriptorSet[] descriptorSets = {
        vk::writeDescriptorSetBuilder()
        .setDescriptorType(vk::DESCRIPTOR_TYPE_UNIFORM_BUFFER)
        .setDstBinding(0)
        .setBufferInfo({
            {
                .buffer = uniform_buffer.buffer,
                .offset = 0,
                .range = UniformBuffer.sizeof,
            },
        }),
        vk::writeDescriptorSetBuilder()
        .setDstBinding(1)
        .setDescriptorType(vk::DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER)
        .setImageInfo(textures.array_view()),
    };

    DescriptorSetLayout descriptor_layout = vk::descriptorSetLayoutCreateInfoBuilder()
        .setFlags(vk::DESCRIPTOR_SET_LAYOUT_CREATE_PUSH_DESCRIPTOR_BIT_KHR)
        .setBindings({
            {
                .binding = 0,
                .descriptorType = vk::DESCRIPTOR_TYPE_UNIFORM_BUFFER,
                .descriptorCount = 1,
                .stageFlags = vk::SHADER_STAGE_VERTEX_BIT | vk::SHADER_STAGE_FRAGMENT_BIT
            },
            {
                .binding = 1,
                .descriptorType = vk::DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER,
                .descriptorCount = (uint)textures.len(),
                .stageFlags = vk::SHADER_STAGE_FRAGMENT_BIT
            },
    }).build(device)!;

    RenderState pipeline = RenderState {
        .descriptor_layout = descriptor_layout,
        .shader = device.createShader(.vertex = &vertex_shader_data, .fragment = &fragment_shader_data)!,
        .cull_mode = vk::CULL_MODE_NONE,
        .front_face = vk::FRONT_FACE_COUNTER_CLOCKWISE,
        .topology = vk::PRIMITIVE_TOPOLOGY_TRIANGLE_LIST,
        .enable_depth = false,
        .push_constants = {
            {
                .offset = 0,
                .size = PushConstantData.sizeof,
                .stageFlags = vk::SHADER_STAGE_VERTEX_BIT | vk::SHADER_STAGE_FRAGMENT_BIT,
            },
        },
        .dynamic_states = {
            vk::DYNAMIC_STATE_VIEWPORT,
            vk::DYNAMIC_STATE_SCISSOR,
        },
        .blend_attachments = {
            {
                .colorWriteMask =
                    vk::COLOR_COMPONENT_R_BIT |
                    vk::COLOR_COMPONENT_G_BIT |
                    vk::COLOR_COMPONENT_B_BIT |
                    vk::COLOR_COMPONENT_A_BIT,
                .blendEnable = vk::TRUE,
                .srcColorBlendFactor = vk::BLEND_FACTOR_SRC_ALPHA,
                .dstColorBlendFactor = vk::BLEND_FACTOR_ONE_MINUS_SRC_ALPHA,
                .colorBlendOp = vk::BLEND_OP_ADD,
                .srcAlphaBlendFactor = vk::BLEND_FACTOR_ONE,
                .dstAlphaBlendFactor = vk::BLEND_FACTOR_ONE_MINUS_SRC_ALPHA,
                .alphaBlendOp = vk::BLEND_OP_ADD,
            }
        },
        .color_attachments = {
           vk::FORMAT_B8G8R8A8_UNORM
        },
        .depth_format = depth_format
    }.build(device)!;

    SemaphoreList wait_semaphores;
    SemaphoreList signal_semaphores;
    FenceList frame_fences;

    for (uint i = 0; i < MAX_FRAMES_IN_FLIGHT; ++i) {
        wait_semaphores.push(vk::semaphoreCreateInfoBuilder().build(device))!;
        signal_semaphores.push(vk::semaphoreCreateInfoBuilder().build(device))!;
        frame_fences.push(vk::fenceCreateInfoBuilder().setFlags(vk::FENCE_CREATE_SIGNALED_BIT).build(device))!;
    }

    Clock time = clock::now();

    uint frame = 0;
    while(!glfw::windowShouldClose(window)) {
        eventHandler.update();
        
        Fence frame_fence = frame_fences[frame];
        Semaphore wait_semaphore = wait_semaphores[frame];
        Semaphore signal_semaphore = signal_semaphores[frame];

        frame_fence.wait(device)!;
        frame_fence.reset(device)!;

        uint next_image = swapchain.getNextImage(device, wait_semaphore);

        RenderingInfo rendering_info = vk::renderingInfoBuilder()
        .setLayerCount(1)
        .setRenderArea({
            .offset = Offset2D{ .x = 0, .y = 0 },
            .extent = swapchain_info.imageExtent,
        })
        .setColorAttachments({
            vk::renderingAttachmentInfoBuilder()
            .setImageView(swapchain_views[next_image])
            .setImageLayout(vk::IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL)
            .setStoreOp(vk::ATTACHMENT_STORE_OP_STORE)
            .setLoadOp(vk::ATTACHMENT_LOAD_OP_CLEAR)
            .setClearValue({
                .color = { .float32 = { 0.0, 0.0, 0.0, 1.0 }}
            })
        })
        .setDepthAttachment(&&vk::renderingAttachmentInfoBuilder()
            .setImageView(depth_texture.imageView)
            .setImageLayout(vk::IMAGE_LAYOUT_DEPTH_STENCIL_ATTACHMENT_OPTIMAL)
            .setStoreOp(vk::ATTACHMENT_STORE_OP_STORE)
            .setLoadOp(vk::ATTACHMENT_LOAD_OP_CLEAR)
            .setClearValue({
            .depthStencil = { 1.0f, 0 }
        }));

        CommandBuffer command_buffer = command_buffers[next_image];
        vk::resetCommandBuffer(command_buffer, 0)!;
        vk::beginCommandBuffer(command_buffer, &&vk::commandBufferBeginInfoBuilder())!;

        ImageMemoryBarrier image_memory_start = vk::imageMemoryBarrierBuilder()
        .setDstAccessMask(vk::ACCESS_COLOR_ATTACHMENT_WRITE_BIT)
        .setOldLayout(vk::IMAGE_LAYOUT_UNDEFINED)
        .setNewLayout(vk::IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL)
        .setImage(swapchain_images[next_image])
        .setSubresourceRange({
            .aspectMask = vk::IMAGE_ASPECT_COLOR_BIT,
            .baseMipLevel = 0,
            .levelCount = 1,
            .baseArrayLayer = 0,
            .layerCount = 1,
        });

        vk::cmdPipelineBarrier(
            command_buffer,
            vk::PIPELINE_STAGE_TOP_OF_PIPE_BIT,
            vk::PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT,
            0,
            0,
            null,
            0,
            null,
            1,
            &image_memory_start
        );

        vk::cmdBeginRenderingKHR(command_buffer, &rendering_info);

        vk::cmdSetViewport(command_buffer, 0, 1, &&vk::Viewport{ .width = WIDTH, .height = HEIGHT, .minDepth = 0.0, .maxDepth = 1.0, .y = 0, .x = 0 });
        vk::cmdSetScissor(command_buffer, 0, 1, &&vk::Rect2D { .extent = swapchain_info.imageExtent, .offset = { .x = 0, .y = 0 }});

        vk::cmdBindPipeline(command_buffer, vk::PIPELINE_BIND_POINT_GRAPHICS, pipeline.pipeline);
        vk::cmdPushDescriptorSetKHR(command_buffer, vk::PIPELINE_BIND_POINT_GRAPHICS, pipeline.pipeline_layout, 0, descriptorSets.len, descriptorSets.ptr);

        PushConstantData constant_data = {
            .draw_index = 0,
            .canvas = canvas_buffer.address,
        };

        foreach (uint index, item: canvas) {
            constant_data.draw_index = index;
            vk::cmdPushConstants(command_buffer, pipeline.pipeline_layout, vk::SHADER_STAGE_VERTEX_BIT | vk::SHADER_STAGE_FRAGMENT_BIT, 0, PushConstantData.sizeof, &constant_data);    
            vk::cmdDraw(command_buffer, 6, 1, 0, 0);
        }

        vk::cmdEndRenderingKHR(command_buffer);

        ImageMemoryBarrier image_memory_end = vk::imageMemoryBarrierBuilder()
        .setSrcAccessMask(vk::ACCESS_COLOR_ATTACHMENT_WRITE_BIT)
        .setOldLayout(vk::IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL)
        .setNewLayout(vk::IMAGE_LAYOUT_PRESENT_SRC_KHR)
        .setImage(swapchain_images[next_image])
        .setSubresourceRange({
            .aspectMask = vk::IMAGE_ASPECT_COLOR_BIT,
            .baseMipLevel = 0,
            .levelCount = 1,
            .baseArrayLayer = 0,
            .layerCount = 1,
        });

        vk::cmdPipelineBarrier(
            command_buffer,
            vk::PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT,
            vk::PIPELINE_STAGE_BOTTOM_OF_PIPE_BIT,
            0,
            0,
            null,
            0,
            null,
            1,
            &image_memory_end
        );

        SubmitInfo submit_info = vk::submitInfoBuilder()
        .setWaitSemaphores({ wait_semaphore })
        .setCommandBuffers({ command_buffer })
        .setSignalSemaphores({ signal_semaphore })
        .setWaitDstStageMask({ vk::PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT });

        vk::endCommandBuffer(command_buffer)!;
        vk::queueSubmit(queue_family.graphics_handle, 1, &submit_info, frame_fence)!;

        PresentInfoKHR present_info = vk::presentInfoKHRBuilder()
        .setWaitSemaphores({ signal_semaphore })
        .setSwapchains({ swapchain })
        .setImageIndices({ next_image });

        vk::queuePresentKHR(queue_family.graphics_handle, &present_info)!;
        frame = (frame + 1) % 2;
    }


    device.waitIdle();
    if (ENABLE_VALIDATION_LAYERS) debug_messenger.free(instance);

    device_allocation.free();
    local_allocation.free();
    textures.free();

    swapchain.free(device);
    foreach (view : swapchain_views) view.free(device);
    depth_texture.free(device);

    swapchain_images.free();
    swapchain_views.free();

    command_pool.free(device);

    descriptor_layout.free(device);
    pipeline.free(device);

    wait_semaphores.release(device);
    signal_semaphores.release(device);
    frame_fences.release(device);
    surface.free(instance);

    device.free();
    instance.free();
}


fn void! loadTextures() {
    depth_texture.createDepthTexture(.allocator = &device_allocation, .queue = queue_family, .size = {WIDTH, HEIGHT}, .format = depth_format)!;
    foreach (source : images) textures.loadPath(source, .allocator = &device_allocation, .queue = queue_family)!;
}